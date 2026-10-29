"""Independent controls for reserved-slot source spectator comparison."""
from copy import deepcopy
import unittest

from replay_launch import compare
from spectator_startup import expected_rust
from spectator_status import expected_bundle, controls


class SpectatorStatusTests(unittest.TestCase):
    # Value: protects=source status-sensitive boundaries; fails_when=reserved input/status or roster inventory is lost;
    # why_new=confirmed-only roster comparison omits disconnected inputs; seam=none
    def test_original_history_and_controls(self):
        traces = expected_bundle()
        self.assertEqual(len(traces), 280)
        self.assertEqual({trace['players'] for trace in traces}, set(range(2, 9)))
        self.assertEqual([(trace['players'], trace['reserved_slot']) for trace in traces[::8]],
                         [(players, slot) for players in range(2, 9) for slot in [players - 1, *range(players - 1)]])
        for trace in traces:
            self.assertEqual(len(trace['transcript']), 12 - trace['delay'])
            self.assertEqual(trace['service_observations'][:2], [trace['service_observations'][0]] * 2)
            for record in trace['transcript']:
                slot = trace['reserved_slot']
                self.assertEqual(record[1 + slot * 2:3 + slot * 2], [0, 3])
                self.assertEqual(record[2:-1:2], [3 if player == slot else 1 for player in range(trace['players'])])
        for original, mutant in zip(traces, expected_bundle(mutate_status=True)):
            for correct, changed in zip(original['transcript'], mutant['transcript']):
                self.assertEqual(correct[1:-1:2], changed[1:-1:2])
                self.assertNotEqual(correct[-1], changed[-1])
        expected = expected_rust(traces)
        self.assertEqual([item['name'] for item in controls(expected, expected)],
                         ['lost-disconnected-status', 'wrong-frozen-input', 'shifted-status-with-original-state',
                          'missing-reserved-slot-workload', 'wrong-reserved-slot', 'wrong-canonical-boundary'])
        with self.assertRaisesRegex(ValueError, r'result.traces\[0\].transcript\[0\]\[4\]: value mismatch'):
            compare(expected, expected_rust(expected_bundle(mutate_status=True)))
        swapped = deepcopy(expected)
        record = swapped['traces'][0]['transcript'][0]
        original_sum = sum(record[2:-1:2])
        record[2], record[4] = record[4], record[2]
        self.assertEqual(sum(record[2:-1:2]), original_sum)
        self.assertEqual(swapped['traces'][0]['transcript'][-1], expected['traces'][0]['transcript'][-1])
        with self.assertRaisesRegex(ValueError, r'result.traces\[0\].transcript\[0\]\[2\]: value mismatch'):
            compare(swapped, expected)
        for field in ('observations', 'service_observations', 'cycles', 'transcript'):
            mutant = deepcopy(traces)
            mutant[-1][field].pop()
            with self.subTest(field=field), self.assertRaises(ValueError):
                compare(mutant, traces)
        for value in [True, 3.0, '3']:
            mutant = deepcopy(expected)
            mutant['traces'][0]['transcript'][0][4] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'type mismatch'):
                compare(mutant, expected)


if __name__ == '__main__':
    unittest.main()
