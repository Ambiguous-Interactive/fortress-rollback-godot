"""Value: process failures and incomplete game streams cannot leave oracle success receipts."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import launch
import controls
import git_test_environment
from contract import checksum
from test_contract import scenario, trace


def game_result():
    value = trace()
    return {'format': 1, 'complete': True, 'passed': True, 'count': 3,
            'request_count': 2, 'request_counts': {'save': 1, 'load': 0, 'advance': 1},
            'records': [{'index': i, 'kind': op['kind'], 'passed': True, 'frame': op['frame_after']}
                        for i, op in enumerate(value['operations'])],
            'engine_version': '4.3.stable', 'errors': []}


class LauncherTests(unittest.TestCase):
    def test_load_control_rejects_unrelated_and_later_failures(self):
        prefix = 'FORTRESS_ORACLE_GAME_RESULT '
        actual = {'request_count': 6, 'errors': ['operation 17: request 6: state mismatch']}
        controls.validate_load_failure(prefix + json.dumps(actual), 6)
        for value in ({'request_count': 0, 'errors': ['cannot read trace']},
                      {'request_count': 7, 'errors': ['operation 17: request 7: state mismatch']},
                      {'request_count': 6, 'errors': ['checksum mismatch']},
                      {'request_count': 6.0, 'errors': ['state mismatch']}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                controls.validate_load_failure(prefix + json.dumps(value), 6)

    def test_load_mutant_changes_only_semantic_load(self):
        for kinds in (('load', 'save'), ('save', 'load')):
            with self.subTest(kinds=kinds):
                value = trace()
                requests = value['operations'][2]['requests']
                original = copy.deepcopy(requests[0])
                requests[:] = [dict(original, kind=kind) for kind in kinds]
                controls.mutate_load_state(value)
                for request in requests:
                    if request['kind'] == 'save':
                        self.assertEqual(request, dict(original, kind='save'))
                    else:
                        self.assertEqual(request['frame'], original['frame'])
                        self.assertEqual(request['state_bytes'][:8], original['state_bytes'][:8])
                        self.assertNotEqual(request['state_bytes'], original['state_bytes'])
                        self.assertEqual(request['checksum'], checksum(bytes.fromhex(request['state_bytes'])))

    def test_crash_rejects_plausible_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(launch.owned_process, 'run_split', return_value=(2, json.dumps(trace()), '')):
                with self.assertRaisesRegex(ValueError, 'process failed'):
                    launch.execute(['oracle'], Path(directory) / 'log')

    def test_timeout_propagates_after_the_owned_log(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'log'
            error = subprocess.TimeoutExpired(['oracle'], 1, 'partial stdoutpartial stderr')
            with patch.object(launch.owned_process, 'run_split', side_effect=error):
                with self.assertRaises(subprocess.TimeoutExpired):
                    launch.execute(['oracle'], log)
            text = log.read_text()
            self.assertEqual(text, 'COMMAND_STARTED: [\'oracle\']\n',
                             'execute only names the started command; the owned path owns the timeout record')

    def test_stale_success_removed_before_setup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            receipt.write_text('{"passed":true}')
            engine = Path(directory) / 'godot'
            engine.write_text('#!/bin/sh\n', encoding='utf-8')
            engine.chmod(0o755)
            with patch.object(launch.sys, 'argv', ['launch', '--godot', str(engine), '--output', directory]):
                with patch.object(launch, 'sources', side_effect=RuntimeError('unavailable')):
                    with self.assertRaises(RuntimeError):
                        launch.main()
            self.assertFalse(receipt.exists())

    def test_invalid_workers_invalidate_stale_receipt_without_starting_setup(self):
        for value in ('0', '9', '-1', 'bad', '1.5'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory) / 'receipt.json'
                receipt.write_text('{"passed":true}')
                result = subprocess.run([sys.executable, str(Path(launch.__file__)), '--godot', 'missing',
                                         '--output', directory, '--jobs', value], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('workers must be an integer in 1..8', result.stderr)
                self.assertEqual(json.loads(receipt.read_text()), {'passed': False, 'failure': 'invalid_arguments'})
                self.assertEqual(list(Path(directory).iterdir()), [receipt])

    def test_game_controls_cannot_pass_at_schema_failure_or_wrong_boundary(self):
        prefix = 'FORTRESS_ORACLE_GAME_RESULT '
        valid = {'passed': False, 'complete': True, 'errors': ['final state: state mismatch at frame 20'], 'request_count': 10}
        controls.validate_game_failure(prefix + json.dumps(valid), 'state mismatch', 10)
        for patch_value in ({'errors': ['state: invalid canonical bytes or checksum']},
                            {'request_count': 9}, {'request_count': 10.0}, {'complete': False}, {'passed': True}):
            with self.subTest(patch_value=patch_value), self.assertRaises(ValueError):
                controls.validate_game_failure(prefix + json.dumps(dict(valid, **patch_value)), 'state mismatch', 10)

    def test_both_formats_keep_persistent_process_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            witnesses = {version: ({'format': version}, {'format': version}) for version in (1, 2)}
            with patch.object(launch, 'negative_controls', return_value=['control']) as run:
                result = launch.versioned_controls(Path('binary'), Path('engine'), witnesses, output)
            self.assertEqual(result, {'1': ['control'], '2': ['control']})
            self.assertEqual([call.args[2]['format'] for call in run.call_args_list], [1, 2])
            self.assertEqual([call.args[3]['format'] for call in run.call_args_list], [1, 2])
            self.assertEqual([call.args[4] for call in run.call_args_list],
                             [output / 'controls-v1', output / 'controls-v2'])
            with self.assertRaisesRegex(ValueError, 'missing format-specific control witness'):
                launch.versioned_controls(Path('binary'), Path('engine'), {2: witnesses[2]}, output)

    def test_game_receipt_mutations(self):
        mutations = {
            'incomplete': lambda x: x.update(complete=False),
            'partial': lambda x: x['records'].pop(),
            'count': lambda x: x.update(count=True),
            'requests': lambda x: x.update(request_count=1),
            'request_kind': lambda x: x['request_counts'].update(load=True),
            'error': lambda x: x.update(errors=['failure']),
            'false_frame': lambda x: x['records'][0].update(frame=1),
            'unknown': lambda x: x.update(stale=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                value = copy.deepcopy(game_result())
                mutate(value)
                with self.assertRaises(ValueError):
                    launch.game_result('FORTRESS_ORACLE_GAME_RESULT ' + json.dumps(value), '', trace())
        good = 'FORTRESS_ORACLE_GAME_RESULT ' + json.dumps(game_result())
        self.assertTrue(launch.game_result(good, '', trace())['passed'])
        for stdout, stderr in ((good + '\n' + good, ''), (good, 'SCRIPT ERROR: bad'), ('', '')):
            with self.assertRaises(ValueError):
                launch.game_result(stdout, stderr, trace())

    def test_runtime_missing_operation_and_stale_fixture(self):
        value = trace()
        value['operations'].pop()
        with self.assertRaises(ValueError):
            launch.oracle_result(json.dumps(value), '', scenario())
        value = trace()
        value['upstream_revision'] = '0' * 40
        with self.assertRaises(ValueError):
            launch.oracle_result(json.dumps(value), '', scenario())


class SourceIdentityTests(unittest.TestCase):
    """Receipts must name the repository state that actually executed (#298)."""

    def fixture_repository(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        environment = git_test_environment.fixture_environment()
        commands = [['git', 'init'], ['git', 'config', 'user.email', 'fixture@example.com'],
                    ['git', 'config', 'user.name', 'fixture'], ['git', 'config', 'commit.gpgsign', 'false']]
        for command in commands:
            subprocess.run(command, cwd=directory, check=True, capture_output=True, env=environment)
        (directory / 'tracked.txt').write_text('executed bytes\n', encoding='utf-8')
        subprocess.run(['git', 'add', 'tracked.txt'], cwd=directory, check=True, capture_output=True, env=environment)
        subprocess.run(['git', 'commit', '-m', 'fixture'], cwd=directory, check=True, capture_output=True, env=environment)
        return directory, environment

    def identity(self, directory, environment):
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory, env=environment, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=directory, env=environment, text=True))
        return {'commit': commit, 'working_tree_dirty': dirty}

    def test_identity_matches_actual_repository_state(self):
        directory, environment = self.fixture_repository()
        self.assertEqual(launch.git_identity(directory), self.identity(directory, environment))
        first = launch.git_identity(directory)
        self.assertFalse(first['working_tree_dirty'])
        (directory / 'tracked.txt').write_text('edited bytes\n', encoding='utf-8')
        dirty = launch.git_identity(directory)
        self.assertEqual(dirty, self.identity(directory, environment))
        self.assertTrue(dirty['working_tree_dirty'])
        self.assertEqual(dirty['commit'], first['commit'])
        subprocess.run(['git', 'add', '-A'], cwd=directory, check=True, capture_output=True, env=environment)
        subprocess.run(['git', 'commit', '-m', 'second'], cwd=directory, check=True, capture_output=True, env=environment)
        changed = launch.git_identity(directory)
        self.assertFalse(changed['working_tree_dirty'])
        self.assertNotEqual(changed['commit'], first['commit'])

    def test_dirty_tree_is_a_stable_positive_control(self):
        directory, _ = self.fixture_repository()
        (directory / 'tracked.txt').write_text('local iteration bytes\n', encoding='utf-8')
        before = launch.git_identity(directory)
        launch.require_unchanged('repository identity', before, launch.git_identity(directory))
        self.assertTrue(before['working_tree_dirty'])

    def test_commit_and_dirty_drift_are_rejected(self):
        directory, environment = self.fixture_repository()
        before = launch.git_identity(directory)
        (directory / 'tracked.txt').write_text('intervening edit\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'repository identity'):
            launch.require_unchanged('repository identity', before, launch.git_identity(directory))
        subprocess.run(['git', 'add', '-A'], cwd=directory, check=True, capture_output=True, env=environment)
        subprocess.run(['git', 'commit', '-m', 'intervening commit'], cwd=directory, check=True, capture_output=True, env=environment)
        with self.assertRaisesRegex(ValueError, 'repository identity'):
            launch.require_unchanged('repository identity', before, launch.git_identity(directory))

    def test_unchanged_evidence_label_is_rejected_only_on_difference(self):
        launch.require_unchanged('local source inventory', {'a': 1}, {'a': 1})
        with self.assertRaisesRegex(ValueError, 'evidence identity changed: local source inventory'):
            launch.require_unchanged('local source inventory', {'a': 1}, {'a': 2})


if __name__ == '__main__':
    unittest.main()
