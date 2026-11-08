"""Shared rejected-run fixtures for the ownership probe suites; tests stay in test_*.py files."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
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





class OwnershipRejectionFixture(unittest.TestCase):
    # A rejected run must keep the diagnosis that its raised error does not
    # carry: the case that was executing, the errors the engine or the browser
    # reported, and the state the rejection found.

    def scenario(self, browser_log=None, native_timeout=False, expected=RuntimeError, native_fault=None, browser_fault=None,
                 version=None, selected="chromium", runtime_fault=None, project_fault=None, node_alias=False, runtime_before=None, tool_fault=None,
                 phase=None, suite_part='all', download_fault=None, control_output=None):
        """Run the ownership launcher against mocked tools and return its results."""
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        root = directory / 'root'
        cache = directory / 'cache'
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
        alias_replaced = []
        # The native wave calls this fixture's capture from several threads, so
        # each one-time check-and-mutate sequence takes this lock.
        fixture_lock = threading.Lock()

        def mutate_project(project, boundary):
            with fixture_lock:
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

        # The native wave overlaps per-suite engine children, so a fault keys on
        # the suite identity it names instead of a global call order.
        native_suites = sorted(probes.select_suites(suite_part))
        faulted_native_suite = native_suites[1] if len(native_suites) > 1 else None

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
                Path(command[-1]).write_text('fixture Web export')
                if tool_fault == 'export':
                    template = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates/4.3.stable/web_nothreads_release.zip'
                    template.write_text('mutated Web template during export')
                    changed_tool.append(True)
                mutate_project(Path(command[command.index('--path') + 1]), 'export')
            if str(command[1]).endswith('ownership.cjs') and command[3] == '--replay-downloads':
                if download_fault == 'run':
                    raise RuntimeError('download command failure ' + 'x' * 600)
                if download_fault == 'json':
                    return '{'
                from test_replay_download import fixture
                browser = {'browser': selected.title(), 'version': 'fixture', 'result': fixture(Path(command[4])), 'errors': []}
                if download_fault == 'browser':
                    browser['errors'] = ['download browser failure']
                if download_fault == 'download':
                    browser['result']['cases'][0]['frames'] = 610
                if selected == 'firefox':
                    browser.update(firefox_preferences={'webgl.force-enabled': True, 'webgl.disabled': False,
                                                        'toolkit.shutdown.fastShutdownStage': 0},
                                   display={'x': 0, 'y': 0, 'width': 1280, 'height': 720, 'screen_width': 1280, 'screen_height': 1024})
                return json.dumps(browser)
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
            if str(command[1]).endswith('ownership.cjs'):
                name = environment['FORTRESS_REPLAY_DOWNLOAD_CONTROL']
                if control_output and name in control_output:
                    return 1, control_output[name]
                if download_fault == 'control-capture':
                    raise RuntimeError('download control capture failure')
                if download_fault == 'control':
                    return 0, ''
                if name == list(probes.CONTROL_DIAGNOSTICS)[-1]:
                    if download_fault == 'source':
                        (root / 'scripts/reference/browser/ownership.cjs').write_text('changed download source')
                    elif download_fault == 'staged':
                        (cache / 'ownership-projects/4.3-positive/host.gd').write_text('changed download staged source')
                    elif download_fault == 'tools':
                        registry.write_text('changed download runtime')
                return 1, 'Error: ' + probes.CONTROL_DIAGNOSTICS[name] + '\n'
            capture_calls.append((command, log, timeout))
            project = Path(command[command.index('--path') + 1])
            (project / '.godot/cache').write_text('mutable native cache')
            mutate_project(project, 'native')
            if runtime_before in ('node', 'browser', 'package', 'source', 'display'):
                with fixture_lock:
                    if not changed_runtime:
                        target = {'node': node_target, 'browser': Path(environment['FORTRESS_' + selected.upper() + '_EXECUTABLE']),
                                  'package': registry, 'source': root / 'scripts/reference/browser/ownership.cjs',
                                  'display': root / 'scripts/reference/browser/webrtc_display.cjs'}[runtime_before]
                        target.write_text('mutated before first browser execution')
                        changed_runtime.append(True)
            if node_alias:
                with fixture_lock:
                    if not alias_replaced:
                        alias_replaced.append(True)
                        replacement = directory / 'unverified-node'
                        replacement.write_text('unverified node')
                        node_path.unlink()
                        node_path.symlink_to(replacement)
            code, value = batch_value(command)
            output = probes.PREFIX + json.dumps(value) + '\n'
            output += probes.PROGRESS_PREFIX + json.dumps(NATIVE_PROGRESS) + '\n'
            native_suite = next((command[index + 1] for index, item in enumerate(command) if item == '--suite'), None)
            if native_suite == faulted_native_suite and native_fault:
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
            if tool_fault == 'native' and native_suite == native_suites[0]:
                with fixture_lock:
                    if not changed_tool:
                        Path(command[0]).write_text('mutated editor during native capture')
                        changed_tool.append(True)
            log.write_text(output, encoding='utf-8')
            if native_timeout or (native_fault == 'timeout' and native_suite == faulted_native_suite):
                raise subprocess.TimeoutExpired(command, timeout, output=output.encode('utf-8'))
            return code, output

        data = {'godot': {'minimum': '4.3', 'current_stable': '4.7.2'},
                'artifacts': {'Godot_v4.3-stable_linux.x86_64.zip': {},
                              'Godot_v4.7.2-stable_linux.x86_64.zip': {},
                              'Godot_v4.3-stable_export_templates.tpz': {},
                              'Godot_v4.7.2-stable_export_templates.tpz': {},
                              'chromium-1194-x86_64.zip': {}, 'firefox-1495-ubuntu24.04-x86_64.zip': {}},
                'browser': {'browser_registry_sha256': probes.digest(registry), 'chromium_revision': '1194', 'chromium_version': 'fixture',
                            'chromium_executables': {'x86_64': 'chrome-linux/chrome'},
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
                self.assertTrue(capture_calls, 'the native mutation must reach a per-suite engine boundary')
                self.assertEqual(browser_calls, [], 'a mutated engine must not qualify a browser batch')
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
            # The native wave overlaps per-suite engine children, so the calls
            # interleave; every suite still runs exactly once per round.
            self.assertEqual(sorted(selections), sorted([[suite] for suite in sorted(expected_suites)] * round_count),
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
