"""Value: process failures and incomplete game streams cannot leave oracle success receipts."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import launch
from test_contract import scenario, trace


def game_result():
    value = trace()
    return {'format': 1, 'complete': True, 'passed': True, 'count': 3,
            'request_count': 2, 'request_counts': {'save': 1, 'load': 0, 'advance': 1},
            'records': [{'index': i, 'kind': op['kind'], 'passed': True, 'frame': op['frame_after']}
                        for i, op in enumerate(value['operations'])],
            'engine_version': '4.3.stable', 'errors': []}


class LauncherTests(unittest.TestCase):
    def test_crash_rejects_plausible_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.CompletedProcess(['oracle'], 2, json.dumps(trace()), '')
            with patch.object(launch.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(ValueError, 'process failed'):
                    launch.execute(['oracle'], Path(directory) / 'log')

    def test_timeout_retains_partial_stream(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'log'
            error = subprocess.TimeoutExpired(['oracle'], 1, b'partial stdout', b'partial stderr')
            with patch.object(launch.subprocess, 'run', side_effect=error):
                with self.assertRaises(subprocess.TimeoutExpired):
                    launch.execute(['oracle'], log)
            self.assertIn('partial stdout', log.read_text())
            self.assertIn('partial stderr', log.read_text())

    def test_stale_success_removed_before_setup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            receipt.write_text('{"passed":true}')
            with patch.object(launch.sys, 'argv', ['launch', '--godot', 'missing', '--output', directory]):
                with patch.object(launch, 'sources', side_effect=RuntimeError('unavailable')):
                    with self.assertRaises(RuntimeError):
                        launch.main()
            self.assertFalse(receipt.exists())

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


if __name__ == '__main__':
    unittest.main()
