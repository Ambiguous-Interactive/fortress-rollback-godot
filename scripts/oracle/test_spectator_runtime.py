"""Offline controls for the production spectator-to-pinned-model projection."""
from copy import deepcopy
import unittest

import spectator_runtime as runtime


class SpectatorRuntimeTests(unittest.TestCase):
    @staticmethod
    def trace():
        return {'capacity': 2, 'observations': [
            {'current': -1, 'received': -1, 'tags': [-1, -1], 'inputs': [[0, 0], [0, 0]]},
            {'current': 11, 'received': 11, 'tags': [10, 11], 'inputs': [[0, 0], [1, 0]]}],
            'transcript': [[frame, frame % 2, 0] for frame in range(12)]}

    # Value: protects=real pinned Next checks; fails_when=projection replaces the model with its own transitions;
    # why_new=upstream-only model checking observes no production state; seam=none
    def test_projection_retains_pinned_transition_and_safety_relations(self):
        source = runtime.module(self.trace())
        self.assertIn('INSTANCE SpectatorSession WITH', source)
        self.assertIn('/\\ Model!Init', source)
        self.assertIn('/\\ Model!Next', source)
        self.assertIn('Safety == Model!SafetyInvariant', source)
        self.assertIn('currentFrame |-> -1', source)
        self.assertIn('currentFrame |-> 11', source)

    # Value: protects=bounded honest observer schema; fails_when=malformed observations silently become model states;
    # why_new=TLC cannot distinguish invented projection defaults from observations; seam=none
    def test_malformed_observations_rejected(self):
        controls = []
        for field, value in [('capacity', True), ('transcript', [[0, 1, 0]]), ('observations', [])]:
            trace = self.trace()
            trace[field] = value
            controls.append(trace)
        for field, value in [('current', True), ('received', 12), ('tags', [-1]), ('inputs', [[0, 2], [0, 0]])]:
            trace = self.trace()
            trace['observations'][0][field] = value
            controls.append(trace)
        trace = self.trace()
        trace['transcript'][0][1] = False
        controls.append(trace)
        trace = self.trace()
        trace['observations'][0]['extra'] = 1
        controls.append(trace)
        for trace in controls:
            with self.subTest(trace=trace), self.assertRaises(ValueError):
                runtime.module(trace)

    # Value: protects=both advertised ring shapes run; fails_when=duplicate or reordered capacities hide a missing workload;
    # why_new=two records alone do not establish the required inventory; seam=none
    def test_complete_bundle_inventory(self):
        first = self.trace()
        second = self.trace()
        second['capacity'] = 3
        second['observations'][0].update(tags=[-1, -1, -1], inputs=[[0, 0], [0, 0], [0, 0]])
        second['observations'][-1].update(tags=[9, 10, 11], inputs=[[1, 0], [0, 0], [1, 0]])
        runtime.validate_bundle([first, second])
        for value in ([first, first], [second, first], [], [first], [first, None]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'inventory'):
                runtime.validate_bundle(value)

    # Value: protects=original callback bytes and order; fails_when=frame totals hide swapped actual rows;
    # why_new=ring snapshots alone do not observe simulation callback inputs; seam=none
    def test_temporal_callback_mutation_rejected(self):
        trace = self.trace()
        mutated = deepcopy(trace)
        mutated['transcript'][0], mutated['transcript'][1] = mutated['transcript'][1], mutated['transcript'][0]
        self.assertEqual(sum(row[1] for row in trace['transcript']), sum(row[1] for row in mutated['transcript']))
        runtime.module(trace)
        with self.assertRaisesRegex(ValueError, 'callbacks differ'):
            runtime.module(mutated)


if __name__ == '__main__':
    unittest.main()
