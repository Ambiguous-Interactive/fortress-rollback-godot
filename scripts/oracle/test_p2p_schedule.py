"""A schedule hint can supply only observations already emitted on this upstream run."""
import unittest
from unittest.mock import Mock

from p2p_schedule import builder_observer


class ScheduleHintTests(unittest.TestCase):
    def test_prefix_excludes_later_outputs_and_divergent_operations_use_real_oracle(self):
        ops = [{'n': n} for n in range(3)]
        hint = {'players': 2, 'operations': ops}
        trace = {'records': [{'outgoing': [0, 1]}, {'outgoing': []}, {'outgoing': [2]}], 'packets': ['a', 'b', 'c']}
        observe = Mock(side_effect=[trace, 'changed operation', 'changed settings', 'other executable'])
        lookup = builder_observer('binary', hint, observe)
        for length in (1, 2, 3):
            partial = {**hint, 'operations': ops[:length]}
            actual = lookup('binary', partial)
            self.assertEqual(actual['records'], trace['records'][:length])
            self.assertEqual(actual['packets'], ['a', 'b'] if length < 3 else trace['packets'])
            self.assertEqual(actual['scenario'], partial)
        observe.assert_called_once_with('binary', hint)
        self.assertEqual(lookup('binary', {**hint, 'operations': [{'n': 9}]}), 'changed operation')
        self.assertEqual(lookup('binary', {**hint, 'players': 3}), 'changed settings')
        self.assertEqual(lookup('other', hint), 'other executable')
        self.assertIs(builder_observer('binary', None, observe), observe)
