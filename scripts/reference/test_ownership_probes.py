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
    for suite, names in sorted(probes.EXPECTED.items()):
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


def batch_value(command):
    """Mock the exact suite selected by a native child, including its exit code."""
    suites = [command[index + 1] for index, item in enumerate(command) if item == '--suite']
    value = native_value('-negative' in command[3])
    value['records'] = [row for row in value['records'] if row['suite'] in suites]
    value['count'] = len(value['records'])
    value['passed'] = not any(run['failures'] for row in value['records'] for run in row['runs'])
    return int(not value['passed']), value


class OwnershipBatchTests(unittest.TestCase):
    # Value: protects=case pages retain the full native suite and order; fails_when=pages lose, repeat or alter evidence; why_new=suite-only aggregation; seam=none
    def test_case_pages_reassemble_exact_native_order_and_reject_incomplete_evidence(self):
        suite = 'res://tests/unit/test_driver_peer_parity.gd'
        native = next(value for name, value in self.batches() if name == suite)
        native['records'].reverse()
        pages = [{**native, 'count': 1, 'records': [copy.deepcopy(record)]} for record in native['records']]
        self.assertEqual(probes.aggregate_case_pages(suite, pages, native), native)
        for mutation in ('missing', 'extra', 'order', 'case', 'repeat', 'assertions', 'errors', 'incomplete'):
            with self.subTest(mutation=mutation):
                altered = copy.deepcopy(pages)
                if mutation == 'missing':
                    altered.pop()
                elif mutation == 'extra':
                    altered.append(copy.deepcopy(altered[0]))
                elif mutation == 'order':
                    altered.reverse()
                elif mutation == 'case':
                    altered[0]['records'][0]['case'] = 'foreign'
                elif mutation == 'repeat':
                    altered[0]['records'][0]['runs'].pop()
                elif mutation == 'assertions':
                    for run in altered[0]['records'][0]['runs']:
                        run['assertions'] += 1
                elif mutation == 'errors':
                    altered[0]['errors'] = [{'kind': 'abort'}]
                else:
                    altered[0]['complete'] = False
                with self.assertRaises(ValueError):
                    probes.aggregate_case_pages(suite, altered, native)

    # Value: protects=complete partition coverage and live alias controls; fails_when=parts omit cases or controls; why_new=whole inventory only; seam=none
    def test_suite_parts_cover_every_case_with_only_the_control_repeated(self):
        control = 'res://tests/determinism/test_buffer_ownership.gd'
        first, second = [probes.select_suites(part) for part in ('1', '2')]
        self.assertEqual(set(first) | set(second), set(probes.EXPECTED))
        self.assertEqual(set(first) & set(second), {control})
        cases = {(suite, case) for part in (first, second) for suite, names in part.items() for case in names}
        self.assertEqual(cases, {(suite, case) for suite, names in probes.EXPECTED.items() for case in names})
        self.assertEqual(len(cases), probes.EXPECTED_COUNT)
        self.assertEqual(probes.select_suites('all'), probes.EXPECTED)
        for part in ('unknown', '', True, 1, 1.0, None):
            with self.subTest(part=part), self.assertRaises(ValueError):
                probes.select_suites(part)

    # Value: protects=declared partial receipts retain exact native/Web evidence; fails_when=scope or results lie; why_new=unpartitioned validation; seam=none
    def test_partition_coverage_rejects_missing_foreign_or_mismatched_evidence(self):
        selected = probes.select_suites('2')
        suites = {suite: sorted(cases) for suite, cases in selected.items()}
        for negative in (False, True):
            native = probes.aggregate_native([(suite, value) for suite, value in self.batches(negative) if suite in selected], negative, selected)
            records = [{'negative_control': negative, 'native': native, 'browser': {'result': copy.deepcopy(native)}}]
            probes.validate_coverage(records, '2', suites)
            for mutation in ('declaration', 'foreign', 'missing', 'browser', 'alias', 'control', 'order', 'cases', 'empty', 'part'):
                with self.subTest(negative=negative, mutation=mutation):
                    altered, declared = copy.deepcopy(records), copy.deepcopy(suites)
                    if mutation == 'declaration':
                        declared.pop(next(iter(declared)))
                    elif mutation == 'foreign':
                        declared['foreign'] = ['foreign']
                    elif mutation == 'missing':
                        altered[0]['native']['records'].pop()
                    elif mutation == 'browser':
                        altered[0]['browser']['result']['records'][0]['runs'][0]['assertions'] += 1
                    elif mutation == 'alias':
                        altered[0]['negative_control'] = int(negative)
                    elif mutation == 'control':
                        altered[0]['native']['records'] = [row for row in altered[0]['native']['records'] if row['case'] != 'owned_input']
                    elif mutation == 'order':
                        declared = dict(reversed(list(declared.items())))
                    elif mutation == 'cases':
                        declared[next(iter(declared))].reverse()
                    elif mutation == 'empty':
                        altered = []
                    with self.assertRaises(ValueError):
                        probes.validate_coverage(altered, '1' if mutation == 'part' else '2', declared)

    # Value: protects=complete ordered native/Web equality; fails_when=batch loses or substitutes records; why_new=whole-run tests cannot exercise aggregation; seam=none
    def batches(self, negative=False):
        value = native_value(negative)
        return [(suite, {**value, 'records': [row for row in value['records'] if row['suite'] == suite],
                         'count': len(probes.EXPECTED[suite]),
                         'passed': not (negative and suite.endswith('/test_buffer_ownership.gd'))})
                for suite in sorted(probes.EXPECTED)]

    def test_complete_batches_preserve_browser_record_order_and_repetitions(self):
        for negative in (False, True):
            with self.subTest(negative=negative):
                value = probes.aggregate_native(self.batches(negative), negative)
                expected = native_value(negative)
                expected['records'].sort(key=lambda row: row['suite'])
                self.assertEqual(value, expected)
                self.assertEqual(value['count'], probes.EXPECTED_COUNT)

    def test_aggregation_rejects_missing_duplicate_or_wrong_suite_batches(self):
        for mutation in ('missing_batch', 'duplicate_batch', 'wrong_suite', 'missing_record', 'duplicate_record', 'count',
                         'incomplete', 'errors', 'repeat', 'unrelated_failure', 'verdict', 'schema'):
            with self.subTest(mutation=mutation):
                batches = self.batches()
                suite, value = batches[0]
                if mutation == 'missing_batch':
                    batches.pop()
                elif mutation == 'duplicate_batch':
                    batches.append(copy.deepcopy(batches[0]))
                elif mutation == 'wrong_suite':
                    value['records'][0]['suite'] = batches[1][0]
                elif mutation == 'missing_record':
                    value['records'].pop()
                elif mutation == 'duplicate_record':
                    value['records'][-1] = copy.deepcopy(value['records'][0])
                elif mutation == 'count':
                    value['count'] += 1
                elif mutation == 'incomplete':
                    value['complete'] = False
                elif mutation == 'errors':
                    value['errors'] = [{'kind': 'repeat_divergence'}]
                elif mutation == 'repeat':
                    value['records'][0]['runs'][1]['states'] = [{'frame': 0, 'bytes': '09'}]
                elif mutation == 'unrelated_failure':
                    for run in value['records'][0]['runs']:
                        run['failures'] = [{'kind': 'unexpected'}]
                elif mutation == 'verdict':
                    value['passed'] = False
                else:
                    value['records'][0]['runs'][0]['assertions'] = True
                with self.assertRaises(ValueError):
                    probes.aggregate_native(batches, False)

    def test_negative_batch_requires_only_the_exact_alias_failures(self):
        for mutation in ('absent', 'unexpected', 'other_suite'):
            with self.subTest(mutation=mutation):
                batches = self.batches(True)
                owner = next(value for suite, value in batches if suite.endswith('/test_buffer_ownership.gd'))
                row = next(row for row in owner['records'] if row['case'] == 'owned_input')
                if mutation == 'absent':
                    for run in row['runs']:
                        run['failures'] = []
                elif mutation == 'unexpected':
                    for run in row['runs']:
                        run['failures'][0]['label'] = 'unrelated failure'
                else:
                    for run in batches[-1][1]['records'][0]['runs']:
                        run['failures'] = [{'kind': 'unexpected'}]
                    batches[-1][1]['passed'] = False
                with self.assertRaises(ValueError):
                    probes.aggregate_native(batches, True)


class OwnershipExactSchemaTests(unittest.TestCase):
    # Value: protects=lossless batch metadata; fails_when=unknown evidence is dropped by aggregation; why_new=required-key tests omit extra fields; seam=none
    def test_unknown_result_record_and_repetition_fields_are_rejected(self):
        for target in ('result', 'record', 'run'):
            with self.subTest(target=target):
                batches = OwnershipBatchTests().batches()
                value = batches[0][1]
                destination = {'result': value, 'record': value['records'][0], 'run': value['records'][0]['runs'][0]}[target]
                destination['foreign_field'] = {'abort': 'unrecognized error'}
                with self.assertRaises(ValueError):
                    probes.aggregate_native(batches, False)

    # Value: protects=exact nested numeric types; fails_when=bool/float aliases equal integers; why_new=only assertion-count types were checked; seam=none
    def test_negative_failure_numeric_aliases_are_rejected(self):
        for field in ('frame', 'byte'):
            for alias in (False, 0.0):
                with self.subTest(field=field, alias=repr(alias)):
                    value = native_value(True)
                    row = next(row for row in value['records'] if row['case'] == 'owned_input')
                    for run in row['runs']:
                        run['failures'][0][field] = alias
                    with self.assertRaises(ValueError):
                        probes.validate(value, True)

    def test_states_require_exact_frame_bytes_schema(self):
        for state in ({'frame': False, 'bytes': '0100'}, {'frame': 0.0, 'bytes': '0100'},
                      {'frame': 0, 'bytes': False}, {'frame': 0}, {'frame': 0, 'bytes': '0100', 'foreign': True}):
            with self.subTest(state=state):
                value = result()
                for run in value['records'][0]['runs']:
                    run['states'] = [copy.deepcopy(state)]
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_json_comparison_distinguishes_nested_numeric_types(self):
        control = {'records': [{'states': [{'frame': 0, 'bytes': '0100'}], 'failures': [{'byte': 0}]}]}
        self.assertTrue(probes.same_json(control, copy.deepcopy(control)))
        for field in ('states', 'failures'):
            for alias in (False, 0.0):
                with self.subTest(field=field, alias=repr(alias)):
                    changed = copy.deepcopy(control)
                    changed['records'][0][field][0]['frame' if field == 'states' else 'byte'] = alias
                    self.assertFalse(probes.same_json(control, changed))


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
                                       'scripts/reference/receipt_arguments.py', 'scripts/reference/local_ownership.py', 'scripts/reference/browser/webrtc_matrix.py',
                                       'scripts/reference/browser/webrtc_import.py', 'scripts/reference/signalfish_probe.py',
                                       'scripts/reference/browser/webrtc_display.cjs', 'scripts/reference/browser/package.json',
                                       'scripts/reference/browser/package-lock.json',
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
                    code, value = batch_value(command)
                    if mutation not in ('staged_copy', 'relocated_copy') and not changed:
                        filename = {'source': probes.FILES[0], 'manifest': 'docs/reference/pins.json',
                                    'imported_helper': 'scripts/reference/fetch.py'}[mutation]
                        target = root / filename
                        target.write_bytes(target.read_bytes() + b'changed after capture')
                        changed.append(True)
                    log.write_text('preserved owned diagnostics', encoding='utf-8')
                    return code, probes.PREFIX + json.dumps(value)

                def run(command, environment, log, timeout=180):
                    return '4.3.stable.fixture' if '--version' in command else ''

                data = {'godot': {'minimum': '4.3', 'current_stable': '4.3'},
                        'artifacts': {'Godot_v4.3-stable_linux.x86_64.zip': {}}}
                with (mock.patch.object(probes, 'ROOT', root), mock.patch.object(probes, 'CACHE', cache),
                      mock.patch.object(probes, 'load_manifest', return_value=data),
                      mock.patch.object(probes, 'fetch', return_value=archive), mock.patch.object(probes, 'run', side_effect=run),
                      mock.patch.object(probes, 'capture', side_effect=capture),
                      mock.patch.object(probes.shutil, 'copyfile', side_effect=copy_file),
                      mock.patch.object(probes.host_capacity, 'acquire_when_free', return_value=True),
                      mock.patch.object(probes.platform, 'machine', return_value='x86_64'),
                      mock.patch.object(probes.platform, 'system', return_value='Linux'),
                      mock.patch('sys.argv', ['ownership_probes.py', '--offline'])):
                    with self.assertRaisesRegex(ValueError, 'source.*changed|copied.*changed'):
                        probes.main()
                self.assertTrue(changed, 'fault must reach the staging/execution boundary')
                self.assertFalse(receipt.exists(), 'failed attempt must remove stale success')
                if mutation not in ('staged_copy', 'relocated_copy'):
                    self.assertTrue(list(output.glob('ownership-*-native-*.log')), 'execution logs survive rejection')

    def test_interrupted_run_publishes_and_retains_case_progress(self):
        # A rejected run must name the case that was executing and the time the
        # last completed case took, so a slow run can be told apart from an
        # engine or script failure.
        self.assertIn('_publish_progress', probes.HOST)
        self.assertIn('fortressOwnershipProgress', probes.HOST)
        self.assertIn('case_names, _publish_progress, _clock)', probes.HOST)
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

    def scenario(self, browser_log=None, native_timeout=False, expected=RuntimeError, native_fault=None, browser_fault=None,
                 version=None, selected="chromium", runtime_fault=None, project_fault=None, node_alias=False, runtime_before=None, tool_fault=None,
                 phase=None, suite_part='all'):
        """Run the ownership launcher against mocked tools and return its results."""
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        root = directory / 'root'
        cache = directory / 'cache'
        files = probes.FILES + ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs',
                                'scripts/reference/fetch.py', 'scripts/reference/run.py', 'scripts/reference/godot_smoke.py',
                                'scripts/reference/receipt_arguments.py', 'scripts/reference/local_ownership.py', 'scripts/reference/browser/webrtc_matrix.py',
                                       'scripts/reference/browser/webrtc_import.py', 'scripts/reference/signalfish_probe.py',
                                       'scripts/reference/browser/webrtc_display.cjs', 'scripts/reference/browser/package.json',
                                       'scripts/reference/browser/package-lock.json',
                                'docs/reference/pins.json', 'project.godot']
        for filename in files:
            target = root / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(probes.ROOT / filename, target)
        archive = directory / 'editor.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            for archive_version in ('4.3', '4.7.2'):
                package.writestr(f'Godot_v{archive_version}-stable_linux.x86_64', 'fake editor')
            package.writestr('chrome-linux/chrome', 'fake browser')
            package.writestr('templates/web_nothreads_release.zip', 'fake Web template')
        registry = cache / 'browser/node_modules/playwright-core/browsers.json'
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text('{"browsers": []}\n', encoding='utf-8')
        for relative in ('@playwright/test', 'playwright'):
            installed = cache / 'browser/node_modules' / relative
            installed.mkdir(parents=True)
            (installed / 'index.js').write_text('fake installed package')
        results = cache / 'results'
        results.mkdir(parents=True)

        browser_calls = []
        changed_project = []
        changed_runtime = []
        changed_tool = []
        godot_calls = []
        export_calls = []
        node_target = directory / 'verified-node'
        node_target.write_text('verified node')
        node_path = directory / 'node'
        node_path.symlink_to(node_target)

        def mutate_project(project, boundary):
            if not project_fault or changed_project or project_fault[0] != boundary:
                return
            changed_project.append(True)
            mutation = project_fault[1]
            target = project / 'addons/fortress_rollback/core/driver.gd'
            if mutation == 'source':
                target.write_bytes(target.read_bytes() + b'changed staged source')
            elif mutation == 'delete':
                target.unlink()
            elif mutation == 'metadata':
                Path(str(target) + '.uid').write_text('uid://changed')
            elif mutation == 'import':
                target = project / 'fixture.png'
                target.write_bytes(b'changed resource')
            else:
                (project / ('orphan.gd.uid' if mutation == 'orphan' else 'unknown.gd')).write_text('unpaired generated input')

        def run(command, environment, log, timeout=180):
            if Path(command[0]).name.startswith('Godot_'):
                godot_calls.append(command)
            if '--version' in command:
                return f'{Path(command[0]).parent.name}.stable.fixture'
            if '--editor' in command:
                project = Path(command[command.index('--path') + 1])
                Path(str(project / 'host.gd') + '.uid').write_text('uid://legitimate')
                (project / '.godot').mkdir(exist_ok=True)
                (project / '.godot/cache').write_text('mutable import cache')
                mutate_project(project, 'import')
                if tool_fault == 'import':
                    Path(command[0]).write_text('mutated editor during import')
                    changed_tool.append(True)
            if '--export-release' in command:
                export_calls.append(command)
                if tool_fault == 'export':
                    template = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates/4.3.stable/web_nothreads_release.zip'
                    template.write_text('mutated Web template during export')
                    changed_tool.append(True)
                mutate_project(Path(command[command.index('--path') + 1]), 'export')
            if str(command[1]).endswith('ownership.cjs'):
                browser_calls.append((command, log, timeout))
                if node_alias:
                    executed_node = node_path.resolve() if command[0] == 'node' else Path(command[0]).resolve()
                    self.assertEqual(executed_node, node_target, 'browser must execute verified Node despite changed PATH alias')
                mutate_project(cache / 'ownership-projects' / Path(command[2]).name, 'browser')
                negative = '-negative' in str(command[2])
                if browser_log is None:
                    value = native_value(negative)
                    suites = json.loads(command[3])
                    value['records'] = [row for row in value['records'] if row['suite'] in suites]
                    if len(command) == 5:
                        value['records'] = [row for row in value['records'] if row['case'] == command[4]]
                    value['count'] = len(value['records'])
                    value['passed'] = not any(run['failures'] for row in value['records'] for run in row['runs'])
                    if len(command) == 5 and browser_fault == 'case_assertions':
                        for run in value['records'][0]['runs']:
                            run['assertions'] += 1
                    browser = {'browser': selected.title(), 'version': 'fixture', 'result': value, 'errors': []}
                    if selected == 'firefox':
                        browser.update(firefox_preferences={'webgl.force-enabled': True, 'webgl.disabled': False,
                                                          'toolkit.shutdown.fastShutdownStage': 0},
                                       display={'x': 0, 'y': 0, 'width': 1280, 'height': 720, 'screen_width': 1280, 'screen_height': 1024})
                    if runtime_fault and len(browser_calls) == 1:
                        target = {'browser': Path(environment['FORTRESS_' + selected.upper() + '_EXECUTABLE']),
                                  'package': registry, 'export': Path(command[2]) / 'changed.js',
                                  'source': root / 'scripts/reference/browser/ownership.cjs',
                                  'display': root / 'scripts/reference/browser/webrtc_display.cjs'}[runtime_fault]
                        target.write_text('changed runtime input')
                    if len(browser_calls) == 1:
                        if browser_fault == 'unknown':
                            browser['foreign_field'] = {'abort': 'unrecognized error'}
                        elif browser_fault == 'missing_errors':
                            browser.pop('errors')
                        elif browser_fault == 'missing_version':
                            browser.pop('version')
                        elif browser_fault == 'false_errors':
                            browser['errors'] = False
                        elif browser_fault == 'null_errors':
                            browser['errors'] = None
                        elif browser_fault == 'empty_version':
                            browser['version'] = ''
                        elif browser_fault == 'numeric_version':
                            browser['version'] = 123
                        elif browser_fault == 'wrong_browser':
                            browser['browser'] = 'foreign browser'
                    elif len(browser_calls) == 2 and browser_fault == 'changed_version':
                        browser['version'] = 'changed fixture'
                    return json.dumps(browser)
                log.write_text(browser_log, encoding='utf-8')
                raise RuntimeError('Godot/browser command failed')
            return ''

        capture_calls = []

        def capture(command, environment, log, timeout):
            capture_calls.append((command, log, timeout))
            project = Path(command[command.index('--path') + 1])
            (project / '.godot/cache').write_text('mutable native cache')
            mutate_project(project, 'native')
            if tool_fault == 'native' and not changed_tool:
                Path(command[0]).write_text('mutated editor during native capture')
                changed_tool.append(True)
            if runtime_before in ('node', 'browser', 'package', 'source', 'display') and not changed_runtime:
                target = {'node': node_target, 'browser': Path(environment['FORTRESS_' + selected.upper() + '_EXECUTABLE']),
                          'package': registry, 'source': root / 'scripts/reference/browser/ownership.cjs',
                          'display': root / 'scripts/reference/browser/webrtc_display.cjs'}[runtime_before]
                target.write_text('mutated before first browser execution')
                changed_runtime.append(True)
            if node_alias and len(capture_calls) == 1:
                replacement = directory / 'unverified-node'
                replacement.write_text('unverified node')
                node_path.unlink()
                node_path.symlink_to(replacement)
            code, value = batch_value(command)
            output = probes.PREFIX + json.dumps(value) + '\n'
            output += probes.PROGRESS_PREFIX + json.dumps(NATIVE_PROGRESS) + '\n'
            if len(capture_calls) == 2 and native_fault:
                if native_fault == 'wrong_exit':
                    code = 1
                elif native_fault == 'missing_marker':
                    output = probes.PROGRESS_PREFIX + json.dumps(NATIVE_PROGRESS) + '\n'
                elif native_fault == 'duplicate_marker':
                    output += probes.PREFIX + json.dumps(value) + '\n'
                elif native_fault == 'script_error':
                    output += 'SCRIPT ERROR: injected abort\n'
                elif native_fault == 'engine_error':
                    output += 'ERROR: injected leak\n'
            log.write_text(output, encoding='utf-8')
            if native_timeout or (len(capture_calls) == 2 and native_fault == 'timeout'):
                raise subprocess.TimeoutExpired(command, timeout, output=output.encode('utf-8'))
            return code, output

        data = {'godot': {'minimum': '4.3', 'current_stable': '4.7.2'},
                'artifacts': {'Godot_v4.3-stable_linux.x86_64.zip': {},
                              'Godot_v4.7.2-stable_linux.x86_64.zip': {},
                              'Godot_v4.3-stable_export_templates.tpz': {},
                              'Godot_v4.7.2-stable_export_templates.tpz': {},
                              'chromium-1194-x86_64.zip': {}, 'firefox-1495-ubuntu24.04-x86_64.zip': {}},
                'browser': {'browser_registry_sha256': probes.digest(registry), 'chromium_revision': '1194', 'chromium_version': 'fixture',
                            'firefox_revision': '1495', 'firefox_version': 'fixture'}}
        def prepare_firefox(_pins, _arch, _offline, sources, environment, installation=None):
            self.assertEqual(installation, cache / 'ownership-firefox/x86_64')
            executable = installation / 'firefox/firefox'
            executable.parent.mkdir(parents=True)
            executable.write_text('fake verified Firefox')
            executable.chmod(0o755)
            sources.update(firefox_archive=archive, firefox_installation=installation, firefox_executable=executable)
            environment['FORTRESS_FIREFOX_EXECUTABLE'] = str(executable)

        original_inventory = probes.tool_inventory

        def tool_inventory(paths):
            frozen = original_inventory(paths)
            if tool_fault == 'editor_freeze' and 'editor' in paths and not changed_tool:
                paths['editor'].write_text('mutated editor before first use')
                changed_tool.append(True)
            if tool_fault == 'template_freeze' and 'web_templates' in paths and not changed_tool:
                (paths['web_templates'] / 'web_nothreads_release.zip').write_text('mutated Web template before export')
                changed_tool.append(True)
            if runtime_before == 'export' and 'export' in paths and not changed_runtime:
                (paths['export'] / 'changed.js').write_text('mutated export before first browser execution')
                changed_runtime.append(True)
            return frozen

        original_which = shutil.which
        def which(name):
            return str(node_path) if (node_alias or runtime_before == 'node') and name == 'node' else original_which(name)

        with mock.patch.object(probes.shutil, 'which', side_effect=which), \
                mock.patch.object(probes, 'tool_inventory', side_effect=tool_inventory), \
                mock.patch.object(probes, 'prepare_firefox', side_effect=prepare_firefox), \
                mock.patch.object(probes, 'ROOT', root), mock.patch.object(probes, 'CACHE', cache), \
                mock.patch.object(probes, 'load_manifest', return_value=data), \
                mock.patch.object(probes, 'fetch', return_value=archive), \
                mock.patch.object(probes, 'run', side_effect=run), \
                mock.patch.object(probes, 'capture', side_effect=capture), \
                mock.patch.object(probes.host_capacity, 'acquire_when_free', return_value=True), \
                mock.patch.object(probes.platform, 'machine', return_value='x86_64'), \
                mock.patch.object(probes.platform, 'system', return_value='Linux'), \
                mock.patch('sys.argv', ['ownership_probes.py', '--offline', '--web', '--browser', selected]
                           + ([] if version is None else ['--version', version]) + ([] if phase is None else ['--phase', phase])
                           + ([] if suite_part == 'all' else ['--suite-part', suite_part])):
            if expected is None:
                probes.main()
            else:
                # The rejected run still fails: the diagnosis is kept, not swallowed.
                with self.assertRaises(expected):
                    probes.main()
        if tool_fault:
            self.assertTrue(changed_tool, 'mutation must reach an extracted tool boundary')
            self.assertEqual(browser_calls, [], 'changed engine/template must not qualify a browser batch')
            if tool_fault == 'editor_freeze':
                self.assertEqual(godot_calls, [], 'changed editor must not execute')
            elif tool_fault == 'import':
                self.assertEqual(capture_calls, [], 'import mutation must stop before native execution')
            elif tool_fault == 'native':
                self.assertEqual(len(capture_calls), 1, 'native mutation must stop before another engine execution')
            elif tool_fault == 'template_freeze':
                self.assertEqual(export_calls, [], 'changed template must not be exported')
            else:
                self.assertEqual(len(export_calls), 1, 'export mutation must stop before browser execution')
        if runtime_before:
            self.assertTrue(changed_runtime, 'mutation must reach the frozen input boundary')
            self.assertEqual(browser_calls, [], 'changed runtime or export must never execute')
        if runtime_fault:
            self.assertEqual(len(browser_calls), 1, 'mutation during a batch must stop before another executes')
        if expected is None:
            round_count = (2 if version is None else 1) * (2 if phase in (None, 'both') else 1)
            expected_suites = probes.select_suites(suite_part)
            selections = [[command[index + 1] for index, item in enumerate(command) if item == '--suite']
                          for command, log, timeout in capture_calls]
            self.assertEqual(selections, [[suite] for suite in sorted(expected_suites)] * round_count,
                             'each round runs every suite once, each under its own watchdog')
            self.assertTrue(all(timeout == 180 for command, log, timeout in capture_calls))
            logs = [log for command, log, timeout in capture_calls]
            self.assertEqual(len(logs), len(set(logs)), 'each native batch keeps its own log')
            groups = [json.loads(command[3]) for command, log, timeout in browser_calls]
            suites = sorted(expected_suites)
            batch_size = 1 if selected == 'firefox' else 4
            expected_groups = []
            expected_cases = []
            for offset in range(0, len(suites), batch_size):
                group = suites[offset:offset + batch_size]
                if selected == 'firefox' and group == ['res://tests/unit/test_driver_peer_parity.gd']:
                    cases = [row['case'] for row in native_value(False)['records'] if row['suite'] == group[0]]
                else:
                    cases = [None]
                expected_groups.extend([group] * len(cases))
                expected_cases.extend(cases)
            self.assertEqual(groups, expected_groups * round_count)
            self.assertEqual([command[4] if len(command) == 5 else None for command, log, timeout in browser_calls], expected_cases * round_count)
            self.assertTrue(all(timeout == 240 for command, log, timeout in browser_calls))
            browser_logs = [log for command, log, timeout in browser_calls]
            self.assertEqual(len(browser_logs), len(set(browser_logs)), 'each browser batch keeps its own log')
        return results

    def rounds(self, results):
        return json.loads((results / 'ownership-rounds.json').read_text(encoding='utf-8'))

    # Value: protects=divergent case pages cannot publish or leave a running round; fails_when=assembly trusts repeats only; why_new=suite-level failures; seam=mocked browser
    def test_case_page_divergence_keeps_a_failed_round_and_no_receipt(self):
        results = self.scenario(expected=ValueError, selected='firefox', version='4.3', phase='positive', suite_part='1', browser_fault='case_assertions')
        self.assertFalse((results / 'ownership.json').exists())
        self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
        self.assertEqual(self.rounds(results)[0]['errors'], ['incomplete or divergent ownership case pages'])

    # Value: protects=complete partial-phase receipts; fails_when=selector loses work or claims both; why_new=default-only runs; seam=none
    def test_each_selected_phase_runs_exact_inventory_and_declares_scope(self):
        for phase in ('negative', 'positive', 'both'):
            with self.subTest(phase=phase):
                results = self.scenario(expected=None, selected='firefox', version='4.3', phase=phase)
                receipt = json.loads((results / 'ownership.json').read_text())
                phases = ['negative', 'positive'] if phase == 'both' else [phase]
                self.assertEqual(receipt['phases_requested'], phases)
                self.assertEqual([row['label'] for row in receipt['rounds']], ['4.3-' + name for name in phases])
                self.assertEqual([row['negative_control'] for row in receipt['records']], [name == 'negative' for name in phases])
                for row in receipt['records']:
                    self.assertEqual(row['browser']['result'], row['native'])
                    self.assertEqual(row['native']['count'], probes.EXPECTED_COUNT)
                self.assertIn('requested engine pins, phases and suite inventory only', receipt['scope'])

    # Value: protects=CI parts run both real controls with exact declared native/Web coverage; fails_when=selector drops work; why_new=whole-run orchestration; seam=none
    def test_suite_parts_run_exact_declared_inventory_and_both_controls(self):
        for part in ('1', '2'):
            with self.subTest(part=part):
                results = self.scenario(expected=None, selected='firefox', version='4.3', suite_part=part)
                receipt = json.loads((results / 'ownership.json').read_text())
                selected = probes.select_suites(part)
                self.assertEqual(receipt['suite_part_requested'], part)
                self.assertEqual(receipt['suites_requested'], {suite: sorted(cases) for suite, cases in selected.items()})
                self.assertEqual([row['negative_control'] for row in receipt['records']], [True, False])
                for row in receipt['records']:
                    self.assertEqual(row['native']['count'], sum(map(len, selected.values())))
                    self.assertEqual(row['browser']['result'], row['native'])

    # Value: protects=exact phase declarations; fails_when=missing, mismatched or alias inventory publishes; why_new=unpartitioned inventory; seam=none
    def test_requested_phase_inventory_rejects_missing_mismatched_unknown_and_alias_values(self):
        records = [{'engine_version': '4.3', 'negative_control': False}]
        rounds = [{'label': '4.3-positive', 'outcome': 'passed'}]
        probes.validate_phases(records, rounds, ['4.3'], ['positive'])
        for phases in ([], ['negative'], ['positive', 'negative'], ['positive', 'positive'], ['unknown'], [False], [0], 'positive'):
            with self.subTest(phases=phases), self.assertRaises(ValueError):
                probes.validate_phases(records, rounds, ['4.3'], phases)
        for negative in (0, 1, None, 'positive'):
            with self.subTest(negative=negative), self.assertRaises(ValueError):
                probes.validate_phases([{'engine_version': '4.3', 'negative_control': negative}], rounds, ['4.3'], ['positive'])
        with self.assertRaises(ValueError):
            probes.validate_phases([], [], ['4.3'], ['positive'])

    # Value: protects=engine CI partitions retain both controls and every case; fails_when=selector changes workload or pin; why_new=default-only orchestration; seam=none
    def test_one_selected_pin_runs_both_complete_rounds(self):
        for version in ('4.3', '4.7.2'):
            with self.subTest(version=version):
                results = self.scenario(expected=None, version=version)
                receipt = json.loads((results / 'ownership.json').read_text(encoding='utf-8'))
                self.assertEqual(receipt['versions_requested'], [version])
                self.assertEqual([row['label'] for row in receipt['rounds']], [version + '-negative', version + '-positive'])
                self.assertEqual([row['native']['count'] for row in receipt['records']], [probes.EXPECTED_COUNT] * 2)

    # Value: protects=Firefox qualifies every native case and control with pinned runtime provenance;
    # fails_when=another browser substitutes, runtime mutates, or Firefox weakens inventory; why_new=old orchestrator only supported Chromium; seam=none
    def test_firefox_runs_complete_inventory_for_both_pins(self):
        results = self.scenario(expected=None, selected='firefox')
        receipt = json.loads((results / 'ownership.json').read_text())
        self.assertEqual(receipt['phases_requested'], ['negative', 'positive'])
        self.assertEqual(receipt['browser_requested'], 'firefox')
        self.assertTrue(receipt['browser_runtime_inventory'])
        self.assertTrue(any('firefox_executable' in key for key in receipt['browser_runtime_inventory']))
        self.assertEqual(len(receipt['records']), 4)
        for row in receipt['records']:
            self.assertEqual(row['browser_artifact'], 'firefox-1495-ubuntu24.04-x86_64.zip')
            self.assertEqual(row['browser']['browser'], 'Firefox')
            self.assertEqual(row['browser']['result'], row['native'])
            self.assertEqual(row['native']['count'], probes.EXPECTED_COUNT)

    # Value: protects=verified runtime bytes before execution; fails_when=changes execute then fail only at publication;
    # why_new=after-use mutation tests establish rejection but not before-use gating; seam=mocked native/export boundaries
    def test_changed_runtime_or_export_never_executes(self):
        for selected in ('chromium', 'firefox'):
            for target in ('node', 'browser', 'package', 'export', 'source', 'display'):
                with self.subTest(selected=selected, target=target):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', runtime_before=target)
                    self.assertFalse((results / 'ownership.json').exists())
                    self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')

    # Value: protects=extracted engine and Web templates at actual use; fails_when=verified installation mutates later;
    # why_new=browser tool hashes omit native/export tools; seam=mocked extraction/import/native/export boundaries
    def test_engine_and_template_mutations_stop_before_another_use(self):
        for selected in ('chromium', 'firefox'):
            for boundary in ('editor_freeze', 'import', 'native', 'template_freeze', 'export'):
                with self.subTest(selected=selected, boundary=boundary):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', tool_fault=boundary)
                    self.assertFalse((results / 'ownership.json').exists())

    def test_runtime_or_export_mutation_cannot_qualify_either_browser(self):
        for selected in ('chromium', 'firefox'):
            for target in ('browser', 'package', 'export', 'source', 'display'):
                with self.subTest(selected=selected, target=target):
                    results = self.scenario(expected=ValueError, selected=selected, runtime_fault=target)
                    self.assertFalse((results / 'ownership.json').exists())
                    self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')

    # Value: protects=staged executed bytes and imported metadata; fails_when=stage mutation publishes success;
    # why_new=root hashes and finished exports do not cover execution inputs; seam=mocked engine boundaries
    def test_staged_project_changes_cannot_publish_success(self):
        for selected in ('chromium', 'firefox'):
            for boundary in ('import', 'native', 'export', 'browser'):
                for mutation in ('source', 'delete', 'orphan', 'unknown', 'import'):
                    with self.subTest(selected=selected, boundary=boundary, mutation=mutation):
                        results = self.scenario(expected=ValueError, selected=selected, version='4.3', project_fault=(boundary, mutation))
                        self.assertFalse((results / 'ownership.json').exists())
            for boundary in ('native', 'export', 'browser'):
                with self.subTest(selected=selected, boundary=boundary, mutation='metadata'):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', project_fault=(boundary, 'metadata'))
                    self.assertFalse((results / 'ownership.json').exists())

    def test_browser_executes_frozen_node_after_path_alias_replacement(self):
        for selected in ('chromium', 'firefox'):
            with self.subTest(selected=selected):
                self.scenario(expected=None, selected=selected, version='4.3', node_alias=True)

    # Value: protects=complete declared phase receipts; fails_when=missing controls or foreign pins publish; why_new=per-batch validation omits phase inventory; seam=none
    def test_completed_phase_inventory_rejects_missing_foreign_and_alias_phases(self):
        records = [{'engine_version': '4.3', 'negative_control': negative} for negative in (True, False)]
        rounds = [{'label': '4.3-' + label, 'outcome': 'passed'} for label in ('negative', 'positive')]
        probes.validate_phases(records, rounds, ['4.3'])
        for mutation in ('missing', 'foreign', 'alias', 'failed', 'wrong_label'):
            with self.subTest(mutation=mutation):
                altered_records, altered_rounds = copy.deepcopy(records), copy.deepcopy(rounds)
                if mutation == 'missing':
                    altered_records.pop()
                elif mutation == 'foreign':
                    altered_records[0]['engine_version'] = 'foreign'
                elif mutation == 'alias':
                    altered_records[0]['negative_control'] = 1
                elif mutation == 'failed':
                    altered_rounds[0]['outcome'] = 'failed'
                else:
                    altered_rounds[0]['label'] = 'foreign-negative'
                with self.assertRaises(ValueError):
                    probes.validate_phases(altered_records, altered_rounds, ['4.3'])

    def test_unknown_pin_or_phase_is_rejected_before_tool_qualification(self):
        for option, value in (('--version', 'untrusted'), ('--phase', 'unknown'), ('--phase', 'True'), ('--phase', '1'),
                              ('--suite-part', 'unknown'), ('--suite-part', 'True'), ('--suite-part', '1.0')):
            with self.subTest(option=option, value=value), tempfile.TemporaryDirectory() as directory:
                self.assert_invalid_execution_option(Path(directory), option, value)

    def assert_invalid_execution_option(self, directory, option, value):
        with (mock.patch.object(probes, 'CACHE', directory),
              mock.patch.object(probes, 'load_manifest', return_value={'godot': {'minimum': '4.3', 'current_stable': '4.7.2'}}),
              mock.patch.object(probes.host_capacity, 'acquire_when_free') as acquire,
              mock.patch.object(probes, 'run_probes') as execute,
              mock.patch('sys.argv', ['ownership_probes.py', option, value])):
            with self.assertRaises(SystemExit):
                probes.main()
            acquire.assert_not_called()
            execute.assert_not_called()

    def test_a_rejected_browser_run_retains_its_diagnosis(self):
        results = self.scenario(BROWSER_LOG)
        rounds = self.rounds(results)
        self.assertEqual(len(rounds), 1, 'the rejected round is the only one that ran')
        assert_rejection_observed(self, rounds[0])
        self.assertFalse((results / 'ownership.json').exists(), 'a rejected run publishes no receipt')

    def test_the_receipt_keeps_the_enriched_round_entries(self):
        results = self.scenario(expected=None)
        receipt = json.loads((results / 'ownership.json').read_text(encoding='utf-8'))
        self.assertEqual(receipt['versions_requested'], ['4.3', '4.7.2'])
        self.assertEqual(receipt['phases_requested'], ['negative', 'positive'])
        self.assertEqual(receipt['suite_part_requested'], 'all')
        self.assertEqual(receipt['suites_requested'], {suite: sorted(cases) for suite, cases in probes.EXPECTED.items()})
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

    # Value: protects=every browser batch's metadata; fails_when=an earlier malformed result is overwritten; why_new=single browser runs cannot erase prior metadata; seam=none
    def test_browser_metadata_is_checked_before_aggregation(self):
        for mutation in ('unknown', 'missing_errors', 'missing_version', 'false_errors', 'null_errors',
                         'empty_version', 'numeric_version', 'wrong_browser', 'changed_version'):
            with self.subTest(mutation=mutation):
                results = self.scenario(browser_fault=mutation, expected=ValueError)
                self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
                self.assertFalse((results / 'ownership.json').exists())

    # Value: protects=per-child exit and completion checks; fails_when=negative verdict leaks to healthy suites; why_new=aggregation has no process status; seam=none
    def test_later_native_batch_rejects_wrong_exit_incomplete_output_and_engine_errors(self):
        for mutation in ('wrong_exit', 'missing_marker', 'duplicate_marker', 'script_error', 'engine_error'):
            with self.subTest(mutation=mutation):
                results = self.scenario(native_fault=mutation, expected=ValueError)
                self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
                self.assertFalse((results / 'ownership.json').exists())
                self.assertEqual(len(list(results.glob('ownership-*-native-*.log'))), 2)

    # Value: protects=partial batch evidence; fails_when=later timeout hides completed batch or last case; why_new=first-child timeout cannot catch overwrites; seam=none
    def test_later_native_timeout_keeps_each_log_and_last_case(self):
        results = self.scenario(native_fault='timeout', expected=subprocess.TimeoutExpired)
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'progressing')
        self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertFalse((results / 'ownership.json').exists())
        logs = list(results.glob('ownership-*-native-*.log'))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all(probes.PROGRESS_PREFIX in log.read_text(encoding='utf-8') for log in logs))

    def test_the_retained_observation_is_bounded(self):
        noisy = json.dumps({**BROWSER_DETAIL, 'errors': [f'engine error {index}' for index in range(50)]})
        results = self.scenario(noisy + '\n')
        entry = self.rounds(results)[0]
        self.assertEqual(len(entry), 8, 'a round keeps a fixed number of fields')
        self.assertEqual(len(entry['errors']), probes.MAX_RETAINED_ERRORS)
        self.assertEqual(len(entry['browser_progress']), 7, 'a progress record keeps a fixed number of fields')
        self.assertEqual(entry['browser_progress']['case'], 'golden')


# Value: runtime guard failures name exact logical inputs while rejecting symlinks before hashing.
class RuntimeDiagnosticTests(unittest.TestCase):
    def test_regular_runtime_files_keep_their_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'browser').mkdir()
            (root / 'browser/executable').write_bytes(b'verified executable')
            self.assertEqual(probes.tool_inventory({'firefox': root}), {
                'firefox/browser/executable': probes.digest(root / 'browser/executable')})

    def test_missing_and_root_symlink_diagnostics_name_only_the_logical_input(self):
        for kind in ('missing', 'symlink', 'dangling'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / 'selected'
                if kind == 'symlink':
                    (root / 'target').write_bytes(b'verified executable')
                    source.symlink_to(root / 'target')
                elif kind == 'dangling':
                    source.symlink_to(root / 'absent')
                with mock.patch.object(probes, 'digest') as digest:
                    with self.assertRaisesRegex(ValueError, '^ownership runtime input missing or symlinked: firefox$'):
                        probes.tool_inventory({'firefox': source})
                    digest.assert_not_called()

    def test_nested_link_diagnostics_name_the_relative_input_without_hashing_the_link(self):
        for kind in ('file', 'directory', 'dangling'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                installation = root / 'installation'
                (installation / 'browser').mkdir(parents=True)
                target = root / 'target'
                if kind == 'file':
                    target.write_bytes(b'foreign executable')
                elif kind == 'directory':
                    target.mkdir()
                    (target / 'foreign').write_bytes(b'foreign executable')
                (installation / 'browser/lock').symlink_to(target, target_is_directory=kind == 'directory')
                with mock.patch.object(probes, 'digest') as digest:
                    with self.assertRaisesRegex(ValueError, '^ownership runtime input is symlinked: firefox/browser/lock$'):
                        probes.tool_inventory({'firefox': installation})
                    digest.assert_not_called()


if __name__ == '__main__':
    unittest.main()
