"""Independent inventories for reordered/duplicate spectator source comparison."""
from copy import deepcopy
import unittest

from replay_launch import compare
from spectator_reordered import expected_bundle, controls
from spectator_startup import expected_rust


class ReorderedSpectatorTests(unittest.TestCase):
    # Value: protects=real reordered delivery and every canonical prefix; fails_when=healthy traffic is relabeled as faults;
    # why_new=existing source comparison is in-order; seam=none
    def test_delivery_and_canonical_inventory(self):
        traces = expected_bundle()
        self.assertEqual(len(traces), 28)
        self.assertEqual([(trace['players'], trace['capacity'], trace['speed']) for trace in traces],
                         [(players, capacity, speed) for players in range(2, 9) for capacity in (4, 5) for speed in (1, 2)])
        for trace in traces:
            self.assertEqual(trace['deliveries'], [[frame, 0] for end in range(1, 12, 2) for frame in [end, end, end - 1, end - 1]])
            self.assertEqual(len(trace['canonical']), 11)
            self.assertEqual([record[0] for record in trace['transcript']], list(range(11)))
        original = expected_rust(traces)
        self.assertEqual([item['name'] for item in controls(original, original)], ['ordered-delivery', 'canonical-prefix'])
        ordered = expected_bundle(ordered=True)
        self.assertEqual([trace['canonical'] for trace in traces], [trace['canonical'] for trace in ordered])
        with self.assertRaisesRegex(ValueError, r'result.traces\[0\].deliveries: count mismatch'):
            compare(original, expected_rust(ordered))
        for changed in expected_bundle(swapped=True):
            correct = next(trace for trace in traces if (trace['players'], trace['capacity'], trace['speed']) ==
                           (changed['players'], changed['capacity'], changed['speed']))
            self.assertEqual([sum(record[1:]) for record in correct['transcript']], [sum(record[1:]) for record in changed['transcript']])
            self.assertNotEqual(correct['canonical'][0], changed['canonical'][0])
        for field in ('deliveries', 'canonical', 'transcript', 'cycles', 'observations', 'service_observations'):
            mutant = deepcopy(traces)
            mutant[-1][field].pop()
            with self.subTest(field=field), self.assertRaises(ValueError):
                compare(mutant, traces)
        for value in (True, 1.0, '1'):
            mutant = deepcopy(traces)
            mutant[0]['deliveries'][0][0] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'type mismatch'):
                compare(mutant, traces)


if __name__ == '__main__':
    unittest.main()
