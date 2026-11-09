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
from ownership_rejection_fixture import batch_value, native_value, result


class DownloadControlTests(unittest.TestCase):
    # Value: protects=only the intended sole failure qualifies; fails_when=unrelated errors or success share output; seam=none
    def test_expected_error_accepts_only_its_top_level_message_and_stack(self):
        for control, diagnostic in probes.CONTROL_DIAGNOSTICS.items():
            message = 'Error: ' + diagnostic
            healthy = [message, message + '\n', message + '\n    at operation (/fixture/replay_download.cjs:20:3)\n',
                       message + '\r\n    at async run (file:///fixture/ownership.cjs:50:7)\r\n']
            for output in healthy:
                with self.subTest(control=control, output=output):
                    probes.validate_download_control(1, output, control)
            malformed = [message + ' unexpectedly\n', 'unrelated failure\n' + message + '\n',
                         message + '\nError: cleanup failed\n', message + '\n    Error: cleanup failed\n',
                         message + '\n    at operation (/fixture/run.cjs:1:1)\n  [cause]: Error: cleanup failed\n',
                         message + '\n{"browser":"Chromium"}\n', message + '\n\n', None, 1]
            for output in malformed:
                with self.subTest(control=control, output=output), self.assertRaises(ValueError):
                    probes.validate_download_control(1, output, control)
            for code in (0, 2, -9, True, 1.0):
                with self.subTest(control=control, code=code), self.assertRaises(ValueError):
                    probes.validate_download_control(code, message + '\n', control)


class ChooserMutationTests(unittest.TestCase):
    # Value: protects=chooser control executes exactly the missing production pause; fails_when=export is healthy or siblings drift; seam=owned exporter
    def test_export_mutation_is_exact_restored_and_fail_closed(self):
        for fault in (None, 'export', 'sibling', 'tool', 'missing'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                project = root / 'project'
                source = project / 'examples/online/replay_scene.gd'
                source.parent.mkdir(parents=True)
                original = ('extends Node\nfunc _open() -> void:\n\tif _is_scrubbing or viewer._is_busy():\n\t\treturn\n\tviewer.request_pause()\n\t_refresh()\n\n'
                            'func _other() -> void:\n\tviewer.request_pause()\n')
                if fault == 'missing':
                    original = original.replace('func _open()', 'func _renamed()')
                source.write_text(original)
                sibling = project / 'sibling.gd'
                sibling.write_text('original')
                editor = root / 'editor'
                editor.write_text('verified')
                paths = {'editor': editor}
                frozen = probes.tool_inventory(paths)
                staged = probes.inventory(probes.staged_paths(project))
                export = root / 'mutant-export'
                calls = []

                def execute(command, environment, log):
                    calls.append(command)
                    mutant = source.read_text()
                    self.assertNotIn('viewer.request_pause()', mutant.split('func _other()')[0])
                    self.assertIn('viewer.request_pause()', mutant.split('func _other()')[1])
                    (export / 'index.html').write_text('mutant export')
                    if fault == 'export':
                        raise RuntimeError('export failed')
                    if fault == 'sibling':
                        sibling.write_text('changed')
                    if fault == 'tool':
                        editor.write_text('changed')

                with mock.patch.object(probes, 'run', side_effect=execute):
                    if fault:
                        with self.assertRaises((ValueError, RuntimeError)):
                            probes.export_chooser_control(project, staged, [str(editor)], {}, export, paths, frozen, root / 'export.log')
                    else:
                        receipt = probes.export_chooser_control(project, staged, [str(editor)], {}, export, paths, frozen, root / 'export.log')
                        self.assertEqual(receipt['path'], 'examples/online/replay_scene.gd')
                        self.assertNotEqual(receipt['before_sha256'], receipt['after_sha256'])
                        self.assertEqual(receipt['export_inventory'], probes.tool_inventory({'export': export}))
                        probes.verify_staged(project, staged)
                self.assertEqual(source.read_text(), original)
                self.assertEqual(len(calls), 0 if fault == 'missing' else 1)


class OwnershipBatchTests(unittest.TestCase):
    # Value: protects=Firefox pages stay inside the hosted page deadline (#224); fails_when=a page
    # combines unmeasured, over-budget or peer-parity work; why_new=whole-run tests use fast fakes; seam=none
    def test_firefox_pages_pair_neighbors_only_inside_the_measured_budget(self):
        a, b, c, d, heavy = (f'res://tests/unit/test_suite_{name}.gd' for name in ('a', 'b', 'c', 'd', 'heavy'))
        parity = probes.PEER_PARITY_SUITE
        cases = [
            # (native seconds, ordered suites, expected pages)
            ({a: 5.0, b: 5.0, c: 5.0, d: 5.0}, [a, b, c, d], [[a, b], [c, d]]),
            ({a: 16.0, b: 16.0, c: 5.0, d: 5.0}, [a, b, c, d], [[a], [b, c], [d]]),
            # 15.0 + 15.0 equals the budget exactly, so the pair still shares one page.
            ({a: 15.0, b: 15.0, c: 5.0}, [a, b, c], [[a, b], [c]]),
            ({a: 5.0, d: 5.0}, [a, b, c, d], [[a], [b], [c], [d]]),
            ({a: 5.0, b: 5.0, c: 5.0}, [a, parity, b, c], [[a], [parity], [b, c]]),
            ({a: 5.0, b: 5.0, c: 5.0}, [parity, a, b, c], [[parity], [a, b], [c]]),
            ({a: 5.0, b: 5.0, c: 5.0}, [a, b, parity, c], [[a, b], [parity], [c]]),
            ({a: 5.0, b: 5.0}, [a, b], [[a, b]]),
            ({a: 5.0}, [a], [[a]]),
        ]
        for native_seconds, ordered, expected in cases:
            with self.subTest(ordered=ordered):
                self.assertEqual(probes.firefox_pages(ordered, native_seconds), expected)
        with self.subTest(budget='explicit'):
            self.assertEqual(probes.firefox_pages([a, b], {a: 9.0, b: 9.0}, budget=20.0), [[a, b]])
            self.assertEqual(probes.firefox_pages([a, b], {a: 11.0, b: 11.0}, budget=20.0), [[a], [b]])
        # Every grouped plan preserves the exact suite order without loss or
        # repetition, and the peer-parity suite never shares a page.
        inventory = sorted(probes.EXPECTED)
        pages = probes.firefox_pages(inventory, {suite: 0.0 for suite in inventory})
        self.assertEqual([suite for page in pages for suite in page], inventory)
        self.assertTrue(all(len(page) <= 2 and (len(page) == 1 or probes.PEER_PARITY_SUITE not in page)
                            for page in pages))
        self.assertIn([probes.PEER_PARITY_SUITE], pages)
        # An unmeasured suite stays alone even next to a measured neighbor.
        self.assertEqual(probes.firefox_pages([a, b], {b: 0.0}), [[a], [b]])

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
        parts = [probes.select_suites(part) for part in ('1', '2', '3', '4')]
        self.assertEqual(set().union(*(set(part) for part in parts)), set(probes.EXPECTED))
        for part in parts:
            self.assertIn(control, part)
        repeated = {suite for suite in probes.EXPECTED if sum(suite in part for part in parts) > 1}
        self.assertEqual(repeated, {control})
        cases = {(suite, case) for part in parts for suite, names in part.items() for case in names}
        self.assertEqual(cases, {(suite, case) for suite, names in probes.EXPECTED.items() for case in names})
        self.assertEqual(len(cases), probes.EXPECTED_COUNT)
        self.assertEqual(probes.select_suites('all'), probes.EXPECTED)
        for part in ('unknown', '', '5', True, 1, 1.0, None):
            with self.subTest(part=part), self.assertRaises(ValueError):
                probes.select_suites(part)

    # Value: protects=CI retains every declared partition and phase for both browsers; fails_when=matrix drops
    # a phase or part or command ignores selection; why_new=per-phase jobs match across browsers; seam=none
    def test_chromium_ci_declares_both_parts_and_passes_the_selector(self):
        workflow = (probes.ROOT / '.github/workflows/reference-baseline.yml').read_text()
        pattern = (r'version: "([^"]+)", browser: chromium, phase: (negative|positive), suite_part: "([1-4])", '
                   r'suffix: " (negative|positive) part ([1-4])", part_suffix: "(-(?:negative|positive)-part-[1-4])"')
        rows = re.findall(pattern, workflow)
        expected = {(version, phase, part, phase, part, f'-{phase}-part-{part}')
                    for version in ('4.3', '4.7.2')
                    for phase in ('negative', 'positive') for part in ('1', '2', '3', '4')}
        self.assertEqual(set(rows), expected)
        self.assertEqual(len(rows), 16)
        # The Firefox rows carry the same partition and phase coverage with the
        # compact part suffix, which must agree with each row's declared part so
        # artifact names stay unique; dropping one row must fail like Chromium.
        firefox = re.findall(r'version: "([^"]+)", browser: firefox, phase: (negative|positive), suite_part: "([1-4])", '
                             r'suffix: " (negative|positive) part ([1-4])", part_suffix: "-part-([1-4])"', workflow)
        self.assertEqual({row[:5] for row in firefox}, {(version, phase, part, phase, part)
                                                        for version, phase, part, _, _, _ in expected})
        self.assertEqual({(version, phase, part, suffix) for version, phase, part, _, _, suffix in firefox},
                         {(version, phase, part, part)
                          for version, phase, part, _, _, _ in expected})
        self.assertEqual(len(firefox), 16)
        command = workflow.split('          else\n            python3 scripts/reference/ownership_probes.py', 1)[1].split('          fi', 1)[0]
        self.assertIn('--phase "${{ matrix.phase }}" --suite-part "${{ matrix.suite_part }}"', command)
        self.assertIn("matrix.part_suffix", workflow)

    # Value: protects=declared partial receipts retain exact native/Web evidence; fails_when=scope or results lie; why_new=unpartitioned validation; seam=none
    def test_partition_coverage_rejects_missing_foreign_or_mismatched_evidence(self):
        selected = probes.select_suites('2')
        suites = {suite: sorted(cases) for suite, cases in selected.items()}
        for negative in (False, True):
            native = probes.aggregate_native([(suite, value) for suite, value in self.batches(negative) if suite in selected], negative, selected)
            records = [{'negative_control': negative, 'native': native, 'browser': {'result': copy.deepcopy(native)}}]
            if not negative and 'res://tests/unit/test_replay_viewer_prefix.gd' in selected:
                from test_replay_download import fixture
                records[0]['replay_downloads'] = fixture()
                from test_replay_download import control_fixture
                records[0]['replay_download_controls'] = control_fixture()
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
                                'scripts/reference/replay_download.py', 'scripts/reference/browser/replay_download.cjs',
                                'scripts/reference/browser/replay_chooser.cjs',
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
        # Defer scene-mutating suites until the host's parent finishes add_child.
        # Final publication stays in that single entry point, outside progress.
        host = probes.HOST
        ready = host.split('func _ready() -> void:', 1)[1].split('\nfunc ', 1)[0]
        self.assertIn('func _run_suites() -> void:', host)
        entry = host.split('func _run_suites() -> void:', 1)[1].split('\nfunc ', 1)[0]
        progress = host.split('func _publish_progress(', 1)[1].split('\nfunc ', 1)[0]
        self.assertEqual(ready.strip(), 'call_deferred("_run_suites")')
        self.assertIn('Scenarios.new().execute(', entry)
        self.assertIn('fortressOwnership =', entry)
        self.assertNotIn('fortressOwnershipProgress', entry)
        self.assertIn('fortressOwnershipProgress', progress)
        self.assertNotIn('fortressOwnership =', progress)
        for body in (ready, entry, progress):
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
