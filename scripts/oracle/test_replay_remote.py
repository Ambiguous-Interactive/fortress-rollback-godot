"""Value: remote recording acceptance requires real correction beside a no-correction green control; seam=none."""
import copy
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

    def test_neutral_control_is_not_a_correction_witness(self):
        for runtime in ('rust', 'godot'):
            neutral = replay_remote.expected(runtime == 'rust', True)
            self.assertFalse(any(row['kind'] == 'load' for peer in neutral['peers'] for row in peer['records']))
            with self.assertRaises(ValueError):
                replay_remote.validate(copy.deepcopy(neutral), runtime == 'rust')


if __name__ == '__main__':
    unittest.main()
