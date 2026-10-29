"""Value: remote recording acceptance requires real correction beside a no-correction green control; seam=none."""
import copy
import json
from pathlib import Path
import unittest

import replay_remote


class RemoteRecordingTest(unittest.TestCase):
    def test_complete_expected_histories_and_controls(self):
        observed = {runtime: replay_remote.expected(runtime == 'rust') for runtime in ('rust', 'godot')}
        self.assertEqual(len(replay_remote.controls(observed)), 12)
        for runtime in ('rust', 'godot'):
            replay_remote.validate(observed[runtime], runtime == 'rust')
            replay_remote.validate(replay_remote.expected(runtime == 'rust', True), runtime == 'rust', True)

    def test_missing_peer_or_correction_does_not_qualify(self):
        for runtime in ('rust', 'godot'):
            for fault in ('peer', 'correction', 'events', 'metadata-type'):
                actual = replay_remote.expected(runtime == 'rust')
                if fault == 'peer':
                    actual['peers'].pop()
                elif fault == 'correction':
                    actual['peers'][0]['records'] = [row for row in actual['peers'][0]['records'] if row['kind'] != 'load']
                elif fault == 'events':
                    if runtime == 'godot':
                        actual['peers'][0]['playback']['failure_frame'] = 1
                    else:
                        actual['peers'][0]['playback']['events'] = []
                else:
                    actual['peers'][0]['current_frame'] = 9.0
                with self.assertRaises(ValueError):
                    replay_remote.validate(actual, runtime == 'rust')

    def test_missing_or_duplicate_delivery_count_preserves_canonical_evidence_but_fails(self):
        for count in (3, 5, 6):
            actual = replay_remote.expected(False, True)
            original_peers = copy.deepcopy(actual['peers'])
            actual['deliveries'][0]['rows'] = count
            self.assertEqual(actual['peers'], original_peers)
            with self.assertRaisesRegex(ValueError, r'remote.godot.deliveries\[0\].rows:'):
                replay_remote.validate(actual, False, True)

    def test_executed_delivery_control_requires_every_exact_six_row_observation(self):
        root = Path(__file__).resolve().parents[2]
        for count in (6, 5, True, '6', 6.0):
            with self.subTest(count=count, kind=type(count).__name__):
                actual = replay_remote.expected(False, True)
                for delivery in actual['deliveries']:
                    delivery['rows'] = count
                def execute(*_):
                    return 'FORTRESS_REPLAY_RESULT ' + json.dumps(actual), ''
                if type(count) is int and count == 6:
                    self.assertEqual(replay_remote.delivery_control(Path('unused-godot'), root, root, execute),
                                     ['godot-measured-duplicate-delivery'])
                else:
                    with self.assertRaises(ValueError):
                        replay_remote.delivery_control(Path('unused-godot'), root, root, execute)
        for field, value in (('round', 99), ('rows', 5)):
            actual = replay_remote.expected(False, True)
            for delivery in actual['deliveries']:
                delivery['rows'] = 6
            actual['deliveries'][-1][field] = value
            with self.subTest(later_field=field), self.assertRaises(ValueError):
                replay_remote.delivery_control(Path('unused-godot'), root, root, execute)

    def test_neutral_control_is_not_a_correction_witness(self):
        for runtime in ('rust', 'godot'):
            neutral = replay_remote.expected(runtime == 'rust', True)
            self.assertFalse(any(row['kind'] == 'load' for peer in neutral['peers'] for row in peer['records']))
            with self.assertRaises(ValueError):
                replay_remote.validate(copy.deepcopy(neutral), runtime == 'rust')


if __name__ == '__main__':
    unittest.main()
