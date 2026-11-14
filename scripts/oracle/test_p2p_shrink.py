"""Shrinking core contracts protect minimal failing P2P scenarios."""
import unittest

from p2p_contract import validate_scenario
from p2p_shrink import DEFAULT_BUDGET, candidate, divergence_op, minimize, producer_op, rewrite, schedule_signature, with_cascades


def stub_counts(scenario):
    """Outgoing packet counts of the stub world: every non-delivery operation produces one packet."""
    return [0 if op['kind'] == 'deliver' else 1 for op in scenario['operations']]


def make_probe(bug_time, require_delivery=False):
    """Stub probe: the operation at now_us == bug_time diverges; deliveries must reference produced packets."""
    def probe(scenario):
        try:
            validate_scenario(scenario)
        except ValueError:
            return None
        produced = 0
        delivered = False
        for op in scenario['operations']:
            if op['kind'] == 'deliver':
                if op['packet'] >= produced:
                    return None  # unknown observed packet: the candidate cannot execute
                delivered = True
            else:
                produced += 1
        if not any(op.get('now_us') == bug_time for op in scenario['operations']):
            return None  # the divergence trigger left the schedule: both sides agree
        if require_delivery and not delivered:
            return None  # the injected disagreement needs a delivered packet to surface
        index = next(i for i, op in enumerate(scenario['operations']) if op.get('now_us') == bug_time)
        return f'operation {index}: state mismatch'
    return probe


def make_scenario(times, deliveries=()):
    """players=2 schedule from poll times plus (position, packet id) deliveries."""
    ops = [{'kind': 'poll', 'peer': 0, 'now_us': time} for time in times]
    for position, packet in reversed(deliveries):
        ops.insert(position, {'kind': 'deliver', 'packet': packet, 'now_us': ops[position - 1]['now_us'] if position else 0})
    return {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'operations': ops}


class ProducerResolutionTests(unittest.TestCase):
    # Value: protects=delivery anchoring and truncation planning; fails_when=packet ids resolve to the wrong producer or unmatched messages truncate blindly;
    # why_new=shared pure helper; seam=none
    def test_divergence_messages_resolve_to_operations(self):
        cases = [(producer_op(0, [1, 1, 0]), 0), (producer_op(1, [1, 1, 0]), 1), (producer_op(5, [1, 1, 0]), None),
                 (divergence_op('operation 4: requests mismatch', [0]), 4),
                 (divergence_op('packet 1: semantic mismatch {} != {}', [1, 1, 0]), 1),
                 (divergence_op('packet count mismatch', [1, 1]), None),
                 (divergence_op('game/session after frame', [1]), None)]
        for actual, expected in cases:
            self.assertEqual(actual, expected)


class CascadeAndRewriteTests(unittest.TestCase):
    # Value: protects=orphaned deliveries and re-ranked ids; fails_when=a removal leaves a delivery referencing a dropped producer or shifts surviving ids;
    # why_new=shared pure helper; seam=none
    def test_cascades_and_rewrites(self):
        ops = make_scenario([1, 2, 3], deliveries=[(1, 0), (2, 1)])['operations']
        counts = stub_counts({'operations': ops})
        self.assertEqual(counts, [1, 0, 1, 0, 1])
        self.assertEqual(with_cascades(ops, counts, {0}), {0, 1})  # packet 0's delivery loses its producer
        self.assertEqual(with_cascades(ops, counts, {3}), {3})  # a delivery produces nothing in this world
        self.assertEqual(rewrite(ops, counts, {3, 4}), ops[:3])
        rewritten = rewrite(ops, counts, {0, 1})  # cascade of {0}: the surviving packet re-ranks to 0
        self.assertEqual([op['packet'] for op in rewritten if op['kind'] == 'deliver'], [0])
        self.assertIsNone(rewrite(ops, counts, {0, 3}))  # surviving delivery without its producer stays None

    # Value: protects=candidate construction; fails_when=candidates mutate shared operations or drop the wrong ops; why_new=shared pure helper; seam=none
    def test_candidate_preserves_shared_operations(self):
        scenario = make_scenario([1, 2, 3])
        trial = candidate(scenario, stub_counts(scenario), {0})
        self.assertEqual(trial['operations'][0], scenario['operations'][1])
        self.assertEqual(len(trial['operations']), 2)
        self.assertEqual(scenario['operations'][0]['now_us'], 1)  # the base schedule is untouched


class MinimizeTests(unittest.TestCase):
    # Value: protects=memo injectivity; fails_when=distinct delay values or bytes share a memo slot and a never-probed candidate is skipped;
    # why_new=the shipped corpus raises repeated delay changes on one peer; seam=p2p_shrink.schedule_signature
    def test_signature_distinguishes_delay_values_and_bytes(self):
        first = [{'kind': 'step', 'peer': 0, 'now_us': 1, 'bytes': '01000000'}, {'kind': 'delay', 'peer': 0, 'delay': 4}]
        second = [{'kind': 'step', 'peer': 0, 'now_us': 1, 'bytes': '01000000'}, {'kind': 'delay', 'peer': 0, 'delay': 5}]
        self.assertNotEqual(schedule_signature(first), schedule_signature(second))
        third = [{'kind': 'step', 'peer': 0, 'now_us': 1, 'bytes': '02000000'}, {'kind': 'delay', 'peer': 0, 'delay': 4}]
        self.assertNotEqual(schedule_signature(first), schedule_signature(third))
        self.assertNotIn(None, schedule_signature(second))  # every field renders into the signature

    # Value: protects=minimal convergence on repeated delays; fails_when=a delay op keeps its sibling delay alive or drops the step the delays need;
    # why_new=reviewer scenario with two consecutive raises; seam=p2p_shrink.minimize probe
    def test_consecutive_delay_ops_shrink_independently(self):
        ops = [{'kind': 'step', 'peer': 0, 'now_us': 1, 'bytes': '01000000'},
               {'kind': 'delay', 'peer': 0, 'delay': 4},
               {'kind': 'delay', 'peer': 0, 'delay': 5},
               {'kind': 'poll', 'peer': 0, 'now_us': 3}]
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'operations': ops}

        def probe(candidate_scenario):
            outcome = make_probe(bug_time=3)(candidate_scenario)
            if outcome is None:
                return None
            if not any(op.get('delay') == 5 for op in candidate_scenario['operations']):
                return None  # the injected disagreement only manifests under the delay-5 raise
            return outcome

        best, _, stats = minimize(scenario, stub_counts(scenario), 'operation 3: state mismatch', probe)
        schedule = best['operations']
        self.assertEqual([(op['kind'], op.get('delay')) for op in schedule], [('step', None), ('delay', 5), ('poll', None)])
        validate_scenario(best)
        self.assertFalse(stats['budget_exhausted'])

    # Value: protects=prefix truncation and convergence; fails_when=the shrinker keeps operations after the named divergence or stops before the minimal schedule;
    # why_new=stub world avoids engines; seam=p2p_shrink.minimize probe
    def test_truncates_then_converges_to_minimal(self):
        scenario = make_scenario(range(1, 13))
        best, message, stats = minimize(scenario, stub_counts(scenario), 'operation 4: state mismatch',
                                        make_probe(bug_time=5))
        self.assertEqual([op['now_us'] for op in best['operations']], [5])
        self.assertEqual(message, 'operation 0: state mismatch')
        self.assertEqual(stats['final_operations'], 1)
        self.assertEqual(stats['removed'], 11)
        self.assertEqual(stats['probes'], 6)  # the memoized sweep never re-probes a rejected schedule
        self.assertFalse(stats['budget_exhausted'])
        validate_scenario(best)

    # Value: protects=delivery re-ranking under removal; fails_when=the surviving delivery references a stale id or its producer is dropped;
    # why_new=require_delivery world forces a delivery to survive; seam=p2p_shrink.minimize probe
    def test_surviving_delivery_is_reranked_with_its_producer(self):
        times = [1, 2, 3, 4, 5]
        scenario = make_scenario(times, deliveries=[(2, 0), (3, 1)])
        best, message, stats = minimize(scenario, stub_counts(scenario), 'operation 4: state mismatch',
                                        make_probe(bug_time=4, require_delivery=True))
        schedule = best['operations']
        self.assertEqual([op['kind'] for op in schedule], ['poll', 'deliver', 'poll'])
        self.assertEqual(schedule[0]['now_us'], 2)  # the producing step survived
        self.assertEqual(schedule[1]['packet'], 0)  # original id 1 re-ranked against the shortened schedule
        self.assertEqual(schedule[2]['now_us'], 4)
        self.assertEqual(message, 'operation 2: state mismatch')
        self.assertEqual(stats['final_operations'], 3)
        validate_scenario(best)

    # Value: protects=budget bounds; fails_when=shrinking runs past its probe budget or returns a non-reproducing best;
    # why_new=stub world avoids engines; seam=p2p_shrink.minimize probe
    def test_budget_stops_the_sweep_but_keeps_a_reproducing_best(self):
        scenario = make_scenario(range(1, 13))
        probe = make_probe(bug_time=5)
        best, _, stats = minimize(scenario, stub_counts(scenario), 'operation 4: state mismatch', probe, budget=2)
        self.assertTrue(stats['budget_exhausted'])
        self.assertEqual(stats['probes'], 2)
        self.assertNotEqual(stats['final_operations'], 12)
        self.assertIsNotNone(probe(best))

    # Value: protects=budget accounting of the truncation probe; fails_when=the truncation probe bypasses the budget or budget zero still probes;
    # why_new=reviewer found budget+1 probes; seam=p2p_shrink.minimize probe
    def test_budget_zero_and_one_gate_every_probe(self):
        scenario = make_scenario(range(1, 13))
        probe = make_probe(bug_time=5)
        best, _, stats = minimize(scenario, stub_counts(scenario), 'operation 4: state mismatch', probe, budget=0)
        self.assertEqual(stats['probes'], 0)
        self.assertTrue(stats['budget_exhausted'])
        self.assertEqual(stats['final_operations'], 12)
        self.assertIsNotNone(probe(best))
        best, _, stats = minimize(scenario, stub_counts(scenario), 'operation 4: state mismatch', probe, budget=1)
        self.assertEqual(stats['probes'], 1)  # the budget gates the truncation probe too
        self.assertTrue(stats['budget_exhausted'])
        self.assertEqual(stats['final_operations'], 5)
        self.assertIsNotNone(probe(best))

    # Value: protects=conservative validity handling; fails_when=an invalid candidate is adopted or a required step or delay is dropped;
    # why_new=real validate_scenario rejects delay without a prior step; seam=p2p_shrink.minimize probe
    def test_invalid_candidates_are_rejected_and_required_steps_survive(self):
        ops = [{'kind': 'step', 'peer': 0, 'now_us': 1, 'bytes': '01020304'},
               {'kind': 'delay', 'peer': 0, 'delay': 2},
               {'kind': 'poll', 'peer': 0, 'now_us': 3},
               {'kind': 'poll', 'peer': 1, 'now_us': 4}]
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'operations': ops}

        def probe(candidate_scenario):
            outcome = make_probe(bug_time=3)(candidate_scenario)
            if outcome is None:
                return None
            if not any(op['kind'] == 'delay' for op in candidate_scenario['operations']):
                return None  # the injected disagreement only manifests under the runtime delay raise
            return outcome

        best, _, stats = minimize(scenario, stub_counts(scenario), 'operation 2: events mismatch', probe)
        schedule = best['operations']
        self.assertEqual([op['kind'] for op in schedule], ['step', 'delay', 'poll'])
        self.assertEqual(schedule[0]['bytes'], '01020304')  # the delay would be invalid without this step
        validate_scenario(best)
        self.assertFalse(stats['budget_exhausted'])
        self.assertEqual(stats['probes'], 4)

    # Value: protects=the no-index fallback; fails_when=a message without an operation index truncates the schedule;
    # why_new=stub world avoids engines; seam=p2p_shrink.minimize probe
    def test_message_without_index_keeps_the_tail(self):
        scenario = make_scenario([1, 2, 3])
        best, _, stats = minimize(scenario, stub_counts(scenario), 'packet count mismatch', make_probe(bug_time=3),
                                  budget=DEFAULT_BUDGET)
        self.assertEqual([op['now_us'] for op in best['operations']], [3])
        self.assertEqual(stats['probes'], 3)
        self.assertEqual(stats['final_operations'], 1)


if __name__ == '__main__':
    unittest.main()
