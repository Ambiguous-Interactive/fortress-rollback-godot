"""Value: remote recording acceptance requires real correction beside a no-correction green control; seam=none."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import replay_remote


class RemoteRecordingTest(unittest.TestCase):
    def test_long_remote_history_requires_post_wrap_corrections_and_playback(self):
        observed = {runtime: replay_remote.expected(runtime == 'rust', long=True) for runtime in ('rust', 'godot')}
        for runtime in ('rust', 'godot'):
            replay_remote.validate(observed[runtime], runtime == 'rust', long=True)
            replay_remote.validate(replay_remote.expected(runtime == 'rust', True, long=True), runtime == 'rust', True, long=True)
            with self.assertRaises(ValueError):
                replay_remote.validate(replay_remote.expected(runtime == 'rust'), runtime == 'rust', long=True)
        self.assertEqual(len(replay_remote.long_controls(observed)), 10)
        for runtime in ('rust', 'godot'):
            short = replay_remote.expected(runtime == 'rust')
            with patch.object(replay_remote, 'expected', return_value=short):
                with self.assertRaisesRegex(ValueError, 'remote.required_long_boundary:'):
                    replay_remote.validate(short, runtime == 'rust', long=True)

    def test_long_source_delivery_counts_keep_periodic_checksum_reports(self):
        for neutral in (False, True):
            actual = replay_remote.expected(True, neutral, long=True)
            self.assertEqual([row['round'] for row in actual['deliveries'] if row['messages'] == 10], [63, 123, 183, 243])
            self.assertEqual([row['messages'] for row in actual['deliveries']].count(8), 124)
            for count in (8, 9, 11, 10.0, True):
                changed = copy.deepcopy(actual)
                changed['deliveries'][31]['messages'] = count
                with self.assertRaisesRegex(ValueError, r'remote.rust.deliveries\[31\].messages:'):
                    replay_remote.validate(changed, True, neutral, long=True)

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
