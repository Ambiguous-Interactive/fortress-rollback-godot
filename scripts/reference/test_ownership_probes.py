"""Value: ownership receipts reject incomplete, divergent or unrelated failure streams."""
import ast
import copy
import re
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
from unittest import mock
import unittest

import ownership_probes as probes


def result():
    records = []
    for suite, names in probes.EXPECTED.items():
        for name in sorted(names):
            records.append({'suite': suite, 'case': name, 'category': 'determinism', 'seed': '1701',
                            'runs': [{'assertions': 1, 'failures': [], 'states': []} for _ in range(2)]})
    return {'format': 1, 'complete': True, 'count': probes.EXPECTED_COUNT,
            'errors': [], 'passed': True, 'records': records}


def native_value(negative):
    """Return the inventory the mocked engine reports for a round."""
    value = result()
    if not negative:
        return value
    value['passed'] = False
    failures = [{'label': label, 'kind': 'bytes', 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'}
                for label in ('copied submission survives caller mutation', 'callback copy cannot edit history')]
    record = next(row for row in value['records'] if row['case'] == 'owned_input')
    for repetition in record['runs']:
        repetition['failures'] = copy.deepcopy(failures)
    return value


NATIVE_PROGRESS = {'completed': 12, 'unit': 'tick',
                   'executing': {'suite': 'res://tests/unit/test_driver.gd', 'case': 'parity', 'started': 34},
                   'last_completed': {'suite': 'res://tests/unit/test_driver.gd', 'case': 'reentry',
                                      'started': 12, 'finished': 30, 'elapsed': 18}}
BROWSER_DETAIL = {'stage': 'ownership-result',
                  'errors': ['Uncaught TypeError: cannot read properties of undefined (reading "runs")'],
                  'reported': False,
                  'progress': {'completed': 88, 'unit': 'us',
                               'executing': {'suite': 'res://tests/unit/test_replay.gd', 'case': 'golden', 'started': 900},
                               'last_completed': {'suite': 'res://tests/unit/test_replay.gd', 'case': 'records_corrected_match',
                                                  'started': 100, 'finished': 900, 'elapsed': 800}}}
# The browser runner prints its detail twice: once before it reads the page and
# once with the page's answer, and the launcher keeps the last one.
BROWSER_LOG = '\n'.join([json.dumps(BROWSER_DETAIL), json.dumps(BROWSER_DETAIL),
                         'Error: Timeout 120000ms exceeded']) + '\n'


def assert_rejection_observed(case, entry):
    """Assert a rejected round names its case, its errors and the state it was in."""
    case.assertEqual(entry['outcome'], 'progressing', 'a rejected round names the state it was in')
    case.assertIsNotNone(entry['browser_progress'], 'the rejected run keeps the progress of its last case')
    case.assertEqual(entry['browser_progress']['case'], 'golden')
    case.assertEqual(entry['browser_progress']['last_case'], 'records_corrected_match')
    case.assertEqual(entry['browser_progress']['elapsed'], 800)
    case.assertIsNotNone(entry['native_progress'], 'the native run keeps the progress of its last case')
    case.assertEqual(entry['native_progress']['case'], 'parity')
    case.assertEqual(entry['native_progress']['elapsed'], 18)
    case.assertTrue(entry['alive'], 'the rejected page was still alive')
    case.assertIn('Uncaught TypeError', ' '.join(entry['errors']), 'the browser errors survive the rejection')


class OwnershipReceiptTests(unittest.TestCase):
    # Protect the native/Web runner inventory against copied suites gaining cases.
    def test_selected_suite_declarations_match_inventory(self):
        for suite, expected in probes.EXPECTED.items():
            with self.subTest(suite=suite):
                source = (probes.ROOT / suite.removeprefix('res://')).read_text(encoding='utf-8')
                body = source.split('func cases() -> PackedStringArray:', 1)[1].split('\nfunc ', 1)[0]
                declaration = re.fullmatch(r'\s*return PackedStringArray\(\s*(\[.*?\])\s*\)\s*', body, re.DOTALL)
                self.assertIsNotNone(declaration, 'inventory guard requires a literal case declaration')
                cases = ast.literal_eval(declaration.group(1))
                self.assertEqual(len(cases), len(set(cases)), 'suite contains duplicate cases')
                self.assertEqual(set(cases), expected)

    def test_web_host_and_copy_inventory_cover_selected_suites(self):
        constants = dict(re.findall(r'const (\w+) = preload\("(res://[^"\n]+)"\)', probes.HOST))
        scripts = re.search(r'var scripts: Array\[Script\] = \[(.*?)\]', probes.HOST, re.S).group(1)
        selected = [constants[name.strip()] for name in scripts.split(',')]
        self.assertEqual(len(selected), len(set(selected)))
        self.assertEqual(set(selected), set(probes.EXPECTED))
        for resource in selected:
            self.assertIn(resource.removeprefix('res://'), probes.FILES)
        for filename in probes.FILES:
            if not filename.endswith('.gd'):
                continue
            with self.subTest(filename=filename):
                source = (probes.ROOT / filename).read_text(encoding='utf-8')
                for dependency in re.findall(r'preload\("res://([^"\n]+)"\)', source):
                    self.assertIn(dependency, probes.FILES, 'copied resource lacks a preload dependency')

    def test_source_changes_cannot_publish_success(self):
        for mutation in ('source', 'staged_copy', 'relocated_copy', 'manifest', 'imported_helper'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'root'
                cache = Path(directory) / 'cache'
                files = probes.FILES + ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs',
                                       'scripts/reference/fetch.py', 'scripts/reference/run.py', 'scripts/reference/godot_smoke.py',
                                       'scripts/reference/receipt_arguments.py', 'scripts/reference/local_ownership.py',
                                       'docs/reference/pins.json', 'project.godot']
                for filename in files:
                    target = root / filename
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(probes.ROOT / filename, target)
                archive = Path(directory) / 'editor.zip'
                with zipfile.ZipFile(archive, 'w') as package:
                    package.writestr('Godot_v4.3-stable_linux.x86_64', 'fake editor')
                output = cache / 'results'
                output.mkdir(parents=True)
                receipt = output / 'ownership.json'
                receipt.write_text('stale success', encoding='utf-8')
                changed = []
                original_copy = shutil.copyfile

                def copy_file(source, target):
                    original_copy(source, target)
                    if not changed and (mutation == 'staged_copy' or
                                        (mutation == 'relocated_copy' and Path(target).name == 'reference_checksum.gd')):
                        Path(target).write_bytes(Path(target).read_bytes() + b'changed staged copy')
                        changed.append(True)

                def capture(command, environment, log, timeout):
                    value = result()
                    negative = '-negative' in command[3]
                    if negative:
                        value['passed'] = False
                        record = next(row for row in value['records'] if row['case'] == 'owned_input')
                        for repetition in record['runs']:
                            repetition['failures'] = [
                                {'label': label, 'kind': 'bytes', 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'}
                                for label in ('copied submission survives caller mutation', 'callback copy cannot edit history')]
                    if mutation not in ('staged_copy', 'relocated_copy') and not changed:
                        filename = {'source': probes.FILES[0], 'manifest': 'docs/reference/pins.json',
                                    'imported_helper': 'scripts/reference/fetch.py'}[mutation]
                        target = root / filename
                        target.write_bytes(target.read_bytes() + b'changed after capture')
                        changed.append(True)
                    log.write_text('preserved owned diagnostics', encoding='utf-8')
                    return int(negative), probes.PREFIX + json.dumps(value)

                def run(command, environment, log):
                    return '4.3.stable.fixture' if '--version' in command else ''

                data = {'godot': {'minimum': '4.3', 'current_stable': '4.3'},
                        'artifacts': {'Godot_v4.3-stable_linux.x86_64.zip': {}}}
                with (mock.patch.object(probes, 'ROOT', root), mock.patch.object(probes, 'CACHE', cache),
                      mock.patch.object(probes, 'load_manifest', return_value=data),
                      mock.patch.object(probes, 'fetch', return_value=archive), mock.patch.object(probes, 'run', side_effect=run),
                      mock.patch.object(probes, 'capture', side_effect=capture),
                      mock.patch.object(probes.shutil, 'copyfile', side_effect=copy_file),
                      mock.patch.object(probes.platform, 'machine', return_value='x86_64'),
                      mock.patch.object(probes.platform, 'system', return_value='Linux'),
                      mock.patch('sys.argv', ['ownership_probes.py', '--offline'])):
                    with self.assertRaisesRegex(ValueError, 'source.*changed|copied.*changed'):
                        probes.main()
                self.assertTrue(changed, 'fault must reach the staging/execution boundary')
                self.assertFalse(receipt.exists(), 'failed attempt must remove stale success')
                if mutation not in ('staged_copy', 'relocated_copy'):
                    self.assertTrue(list(output.glob('ownership-*-native.log')), 'execution logs survive rejection')

    def test_interrupted_run_publishes_and_retains_case_progress(self):
        # A rejected run must name the case that was executing and the time the
        # last completed case took, so a slow run can be told apart from an
        # engine or script failure.
        self.assertIn('_publish_progress', probes.HOST)
        self.assertIn('fortressOwnershipProgress', probes.HOST)
        self.assertIn('PackedStringArray(), _publish_progress, _clock)', probes.HOST)
        self.assertIn('func _clock() -> int:', probes.HOST)
        self.assertIn('Time.get_ticks_usec()', probes.HOST)
        self.assertIn('progress["unit"] = "us"', probes.HOST)
        runner = (probes.ROOT / 'scripts/reference/browser/ownership.cjs').read_text(encoding='utf-8')
        self.assertIn('fortressOwnershipProgress', runner)
        self.assertIn('detail.progress', runner)

    def test_the_runner_measures_elapsed_time_with_an_injected_clock(self):
        # The runner must not read a wall clock itself: the host injects the
        # clock, so the native suites keep their deterministic clock and the
        # browser run uses the real host clock.
        runner = (probes.ROOT / 'tests/runner/scenario_runner.gd').read_text(encoding='utf-8')
        self.assertIn('clock: Callable = Callable()', runner)
        self.assertIn('"elapsed"', runner)
        self.assertNotIn('Time.get_ticks_usec()', runner)
        native = (probes.ROOT / 'tests/runner/run_tests.gd').read_text(encoding='utf-8')
        self.assertIn('_publish_progress, _clock', native)
        self.assertIn('record["unit"] = "tick"', native)
        self.assertNotIn('Time.get_ticks_usec()', native)

    def test_exported_host_publishes_the_inventory_outside_the_progress_callable(self):
        # The inventory publication must stay in the entry point: the progress
        # callable runs before every case and cannot reach the run's result.
        host = probes.HOST
        ready = host.split('func _ready() -> void:', 1)[1].split('\nfunc ', 1)[0]
        progress = host.split('func _publish_progress(', 1)[1].split('\nfunc ', 1)[0]
        self.assertIn('fortressOwnership =', ready)
        self.assertNotIn('fortressOwnershipProgress', ready)
        self.assertIn('fortressOwnershipProgress', progress)
        self.assertNotIn('fortressOwnership =', progress)
        for body in (ready, progress):
            names = re.findall(r'var (\w+)', body)
            self.assertEqual(len(names), len(set(names)), 'a function declares each local once')

    def test_complete_inventory(self):
        self.assertEqual(probes.validate(result(), False)['count'], probes.EXPECTED_COUNT)

    def test_missing_or_duplicate_inventory(self):
        for mutation in ('missing', 'duplicate'):
            with self.subTest(mutation=mutation):
                value = result()
                if mutation == 'missing':
                    value['records'].pop()
                else:
                    value['records'][-1] = copy.deepcopy(value['records'][0])
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_incomplete_zero_assertions_and_divergence(self):
        for mutation in ('incomplete', 'zero', 'divergence'):
            with self.subTest(mutation=mutation):
                value = result()
                if mutation == 'incomplete':
                    value['complete'] = False
                elif mutation == 'zero':
                    for repetition in value['records'][0]['runs']:
                        repetition['assertions'] = 0
                else:
                    value['records'][0]['runs'][1]['states'] = [{'frame': 0, 'bytes': '09'}]
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_schema_mutations(self):
        mutations = {
            'missing_errors': lambda value: value.pop('errors'),
            'errors_none': lambda value: value.update(errors=None),
            'records_dict': lambda value: value.update(records={}),
            'passed_integer': lambda value: value.update(passed=1),
            'assertions_boolean': lambda value: value['records'][0]['runs'][0].update(assertions=True),
            'runs_dict': lambda value: value['records'][0].update(runs={}),
            'states_none': lambda value: value['records'][0]['runs'][0].update(states=None),
            'failures_dict': lambda value: value['records'][0]['runs'][0].update(failures={}),
            'state_scalar': lambda value: value['records'][0]['runs'][0].update(states=[0]),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                value = result()
                mutate(value)
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_negative_control_requires_exact_failures(self):
        value = result()
        value['passed'] = False
        with self.assertRaises(ValueError):
            probes.validate(value, True)
        failures = [{'label': label, 'kind': 'bytes', 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'} for label in (
            'copied submission survives caller mutation', 'callback copy cannot edit history')]
        record = next(r for r in value['records'] if r['case'] == 'owned_input')
        for repetition in record['runs']:
            repetition['failures'] = copy.deepcopy(failures)
        self.assertFalse(probes.validate(value, True)['passed'])
        for repetition in record['runs']:
            repetition['failures'][0]['label'] = 'unexpected failure'
        with self.assertRaises(ValueError):
            probes.validate(value, True)


class OwnershipRejectionTests(unittest.TestCase):
    # A rejected run must keep the diagnosis that its raised error does not
    # carry: the case that was executing, the errors the engine or the browser
    # reported, and the state the rejection found.

    def scenario(self, browser_log=None, native_timeout=False, expected=RuntimeError):
        """Run the ownership launcher against mocked tools and return its results."""
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        root = directory / 'root'
        cache = directory / 'cache'
        files = probes.FILES + ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs',
                                'scripts/reference/fetch.py', 'scripts/reference/run.py', 'scripts/reference/godot_smoke.py',
                                'scripts/reference/receipt_arguments.py', 'scripts/reference/local_ownership.py',
                                'docs/reference/pins.json', 'project.godot']
        for filename in files:
            target = root / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(probes.ROOT / filename, target)
        archive = directory / 'editor.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            for version in ('4.3', '4.7.2'):
                package.writestr(f'Godot_v{version}-stable_linux.x86_64', 'fake editor')
        registry = cache / 'browser/node_modules/playwright-core/browsers.json'
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text('{"browsers": []}\n', encoding='utf-8')
        results = cache / 'results'
        results.mkdir(parents=True)

        def run(command, environment, log):
            if '--version' in command:
                return f'{Path(command[0]).parent.name}.stable.fixture'
            if str(command[1]).endswith('ownership.cjs'):
                negative = '-negative' in str(command[2])
                if browser_log is None:
                    return json.dumps({'browser': 'Chromium', 'version': 'fixture',
                                       'result': native_value(negative), 'errors': []})
                log.write_text(browser_log, encoding='utf-8')
                raise RuntimeError('Godot/browser command failed')
            return ''

        def capture(command, environment, log, timeout):
            negative = '-negative' in command[3]
            output = probes.PREFIX + json.dumps(native_value(negative)) + '\n'
            output += probes.PROGRESS_PREFIX + json.dumps(NATIVE_PROGRESS) + '\n'
            log.write_text(output, encoding='utf-8')
            if native_timeout:
                raise subprocess.TimeoutExpired(command, timeout, output=output)
            return int(negative), output

        data = {'godot': {'minimum': '4.3', 'current_stable': '4.7.2'},
                'artifacts': {'Godot_v4.3-stable_linux.x86_64.zip': {},
                              'Godot_v4.7.2-stable_linux.x86_64.zip': {},
                              'Godot_v4.3-stable_export_templates.tpz': {},
                              'Godot_v4.7.2-stable_export_templates.tpz': {},
                              'chromium-1194-x86_64.zip': {}},
                'browser': {'browser_registry_sha256': probes.digest(registry)}}
        with mock.patch.object(probes, 'ROOT', root), mock.patch.object(probes, 'CACHE', cache), \
                mock.patch.object(probes, 'load_manifest', return_value=data), \
                mock.patch.object(probes, 'fetch', return_value=archive), \
                mock.patch.object(probes, 'run', side_effect=run), \
                mock.patch.object(probes, 'capture', side_effect=capture), \
                mock.patch.object(probes.platform, 'machine', return_value='x86_64'), \
                mock.patch.object(probes.platform, 'system', return_value='Linux'), \
                mock.patch('sys.argv', ['ownership_probes.py', '--offline', '--web']):
            if expected is None:
                probes.main()
            else:
                # The rejected run still fails: the diagnosis is kept, not swallowed.
                with self.assertRaises(expected):
                    probes.main()
        return results

    def rounds(self, results):
        return json.loads((results / 'ownership-rounds.json').read_text(encoding='utf-8'))

    def test_a_rejected_browser_run_retains_its_diagnosis(self):
        results = self.scenario(BROWSER_LOG)
        rounds = self.rounds(results)
        self.assertEqual(len(rounds), 1, 'the rejected round is the only one that ran')
        assert_rejection_observed(self, rounds[0])
        self.assertFalse((results / 'ownership.json').exists(), 'a rejected run publishes no receipt')

    def test_the_receipt_keeps_the_enriched_round_entries(self):
        results = self.scenario(expected=None)
        receipt = json.loads((results / 'ownership.json').read_text(encoding='utf-8'))
        self.assertEqual([entry['label'] for entry in receipt['rounds']],
                         ['4.3-negative', '4.3-positive', '4.7.2-negative', '4.7.2-positive'])
        for entry in receipt['rounds']:
            self.assertEqual(entry['outcome'], 'passed')
            for field in ('alive', 'native_progress', 'browser_progress', 'errors', 'seconds'):
                self.assertIn(field, entry, 'the receipt keeps the enriched round fields')
            self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertEqual(receipt['rounds'], self.rounds(results),
                         'the receipt keeps the same enriched round entries the run observed')

    def test_a_mutant_that_discards_the_diagnosis_fails_the_observation(self):
        with mock.patch.object(probes, 'bounded_progress', return_value=None), \
                mock.patch.object(probes, 'bounded_errors', return_value=[]):
            results = self.scenario(BROWSER_LOG)
        with self.assertRaises(AssertionError):
            assert_rejection_observed(self, self.rounds(results)[0])

    def test_a_browser_failure_without_a_watchdog_detail_is_a_failure(self):
        results = self.scenario('node: the browser runner crashed\n')
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'failed')
        self.assertFalse(entry['alive'])
        self.assertIn('node: the browser runner crashed', ' '.join(entry['errors']))

    def test_a_native_deadline_keeps_the_case_it_was_executing(self):
        results = self.scenario(native_timeout=True, expected=subprocess.TimeoutExpired)
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'progressing')
        self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertEqual(entry['native_progress']['elapsed'], 18)
        self.assertFalse(entry['alive'], 'the native child was killed by the deadline')
        self.assertFalse((results / 'ownership.json').exists(), 'a rejected run publishes no receipt')

    def test_the_retained_observation_is_bounded(self):
        noisy = json.dumps({**BROWSER_DETAIL, 'errors': [f'engine error {index}' for index in range(50)]})
        results = self.scenario(noisy + '\n')
        entry = self.rounds(results)[0]
        self.assertEqual(len(entry), 8, 'a round keeps a fixed number of fields')
        self.assertEqual(len(entry['errors']), probes.MAX_RETAINED_ERRORS)
        self.assertEqual(len(entry['browser_progress']), 7, 'a progress record keeps a fixed number of fields')
        self.assertEqual(entry['browser_progress']['case'], 'golden')


if __name__ == '__main__':
    unittest.main()
