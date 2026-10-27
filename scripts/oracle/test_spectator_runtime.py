"""Offline controls for the production spectator-to-pinned-model projection."""
from copy import deepcopy
import unittest

import spectator_runtime as runtime


class SpectatorRuntimeTests(unittest.TestCase):
    @staticmethod
    def trace():
        return {'capacity': 2, 'preplay': True, 'speed': 2, 'observations': [
            {'current': -1, 'received': -1, 'tags': [-1, -1], 'inputs': [[0, 0], [0, 0]], 'backlog': 0, 'advice': 0, 'catchup': False},
            {'current': 11, 'received': 11, 'tags': [10, 11], 'inputs': [[0, 0], [1, 0]], 'backlog': 0, 'advice': 0, 'catchup': False}],
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
        started = []
        for trace in (first, second):
            other = deepcopy(trace)
            other.update(preplay=False, speed=1)
            received = deepcopy(other['observations'][0])
            received.update(received=0, tags=[0] + [-1] * (other['capacity'] - 1), backlog=1, advice=1)
            played = deepcopy(received)
            played.update(current=0, backlog=0, advice=0)
            other['observations'][1:1] = [received, played]
            started.append(other)
        bundle = []
        for trace in [first, second, *started]:
            for speed in (1, 2):
                item = deepcopy(trace)
                item['speed'] = speed
                bundle.append(item)
        runtime.validate_bundle(bundle)
        for value in ([bundle[0], bundle[0], *bundle[2:]], [bundle[1], bundle[0], *bundle[2:]], [], bundle[:-1], [*bundle[:-1], None]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'inventory'):
                runtime.validate_bundle(value)

    # Value: protects=real preplay catchup remains visible; fails_when=NULL sentinel normalization hides live backlog;
    # why_new=the original projection synthesized the pinned model's zero backlog; seam=none
    def test_preplay_backlog_is_not_normalized(self):
        observation = {'current': -1, 'received': 1, 'tags': [0, 1], 'inputs': [[0, 0], [1, 0]],
                       'backlog': 2, 'advice': 2, 'catchup': True}
        projected = runtime.state(observation, 2)
        self.assertIn('framesBehind |-> 2, inCatchupMode |-> TRUE', projected)

    # Value: protects=the full preplay divergence cannot be relabeled as conformant startup;
    # fails_when=bootstrap silently consumes actual active catchup; why_new=the original projection hid that mode; seam=none
    def test_conformant_bootstrap_cannot_hide_original_prefill(self):
        trace = self.trace()
        trace.update(preplay=False, speed=1)
        received = deepcopy(trace['observations'][0])
        received.update(received=0, tags=[0, -1], backlog=1, advice=1)
        filled = deepcopy(received)
        filled.update(received=1, tags=[0, 1], inputs=[[0, 0], [1, 0]], backlog=2, catchup=True)
        played = deepcopy(filled)
        played.update(current=0, backlog=1, advice=1, catchup=False)
        trace['observations'][1:1] = [received, filled, played]
        with self.assertRaisesRegex(ValueError, 'first frame before ring fill'):
            runtime.module(trace)

    # Value: protects=negative control reaches actual suffix; fails_when=only synthetic startup transitions are attacked;
    # why_new=the original mutation left every actual Next relation unchecked; seam=none
    def test_illegal_advance_targets_actual_poststartup_observation(self):
        trace = self.trace()
        trace.update(preplay=False, speed=1)
        received = deepcopy(trace['observations'][0])
        received.update(received=0, tags=[0, -1], backlog=1, advice=1)
        played = deepcopy(received)
        played.update(current=0, backlog=0, advice=0)
        trace['observations'][1:1] = [received, played, deepcopy(played)]
        mutant, target, cursor = runtime.illegal_advance(trace)
        self.assertEqual(target, 3)
        self.assertEqual(cursor, 5)
        self.assertEqual(mutant['observations'][:target], trace['observations'][:target])
        self.assertEqual(mutant['observations'][target + 1:], trace['observations'][target + 1:])
        self.assertGreater(mutant['observations'][target]['current'], mutant['observations'][target]['received'])
        self.assertNotEqual(runtime.module(mutant), runtime.module(trace))

    # Value: protects=all retained startup observations are strictly typed before bootstrap;
    # fails_when=Python numeric equality hides malformed raw startup tokens; why_new=synthetic states replaced initial observations; seam=none
    def test_started_prefix_numeric_aliases_rejected(self):
        trace = self.trace()
        trace.update(preplay=False, speed=1)
        received = deepcopy(trace['observations'][0])
        received.update(received=0, tags=[0, -1], backlog=1, advice=1)
        played = deepcopy(received)
        played.update(current=0, backlog=0, advice=0)
        trace['observations'][1:1] = [received, played]
        runtime.module(trace)
        for index, field, value in [
                (0, 'current', -1.0), (0, 'received', -1.0), (0, 'tags', [-1.0, -1]),
                (0, 'inputs', [[False, 0], [0, 0]]), (0, 'catchup', 0),
                (1, 'current', -1.0), (1, 'backlog', 1.0), (1, 'advice', True), (1, 'catchup', 0)]:
            mutant = deepcopy(trace)
            mutant['observations'][index][field] = value
            with self.subTest(index=index, field=field, value=value), self.assertRaises(ValueError):
                runtime.module(mutant)

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

    # Value: protects=actual startup states remain in aligned projection; fails_when=synthetic bootstrap masks backlog;
    # why_new=poststartup projection intentionally replaces startup for the immutable original model; seam=none
    def test_aligned_projection_keeps_initial_received_state(self):
        trace = self.trace()
        trace.update(preplay=False, speed=2)
        received = deepcopy(trace['observations'][0])
        received.update(received=0, tags=[0, -1], backlog=1, advice=1)
        trace['observations'].insert(1, received)
        projected = runtime.module(trace, aligned=True)
        self.assertIn('framesBehind |-> 1, inCatchupMode |-> FALSE', projected)
        self.assertNotIn('Synthetic model startup', projected)
        self.assertIn('CATCHUP_SPEED <- 1', projected)

    # Value: protects=anchored model changes only reviewed startup predicates; fails_when=pin drift broadens repair;
    # why_new=the immutable pinned-model gate cannot cover a derived runtime relation; seam=none
    def test_runtime_model_repair_is_narrow_and_anchor_checked(self):
        from spectator_startup import repair_model, ANCHORS
        original = '\n'.join(ANCHORS)
        repaired = repair_model(original)
        self.assertEqual(repaired, "IF lastRecvFrame = NULL_FRAME\nIF lastRecvFrame' = NULL_FRAME")
        for invalid in (original + '\n' + ANCHORS[0], original.replace(ANCHORS[0], 'FALSE')):
            with self.assertRaisesRegex(ValueError, 'reviewed anchor'):
                repair_model(invalid)

    # Value: protects=first startup/catchup differential boundaries; fails_when=observer accepts lost backlog or short first batch;
    # why_new=full callback totals cannot distinguish service pacing; seam=none
    def test_executed_startup_controls_and_strict_types(self):
        from spectator_startup import negative_controls
        from replay_launch import compare
        observed = {'format': 1, 'traces': [
            {'observations': [{'backlog': 0}, {'backlog': 1}]},
            {'cycles': [{'steps': 2}]}]}
        self.assertEqual([item['name'] for item in negative_controls(observed, deepcopy(observed))],
                         ['hidden-startup', 'first-catchup'])
        for value in (True, 1.0):
            mutant = deepcopy(observed)
            mutant['traces'][0]['observations'][1]['backlog'] = value
            with self.assertRaisesRegex(ValueError, 'backlog: type mismatch'):
                compare(mutant, observed)


class SpectatorDelayTests(unittest.TestCase):
    @staticmethod
    def bundle(mutate_input=False):
        bundle = []
        for preplay in (True, False):
            for capacity in (4, 5):
                for speed in (1, 2):
                    delay = 1 if preplay else capacity - 1
                    current, received = -1, -1
                    tags, inputs = [-1] * capacity, [[0, 0] for _ in range(capacity)]

                    def observation():
                        backlog = received - current
                        available = max(0, backlog - delay)
                        return {'current': current, 'received': received, 'tags': tags[:], 'inputs': deepcopy(inputs),
                                'backlog': backlog, 'advice': min(available, speed), 'catchup': available > 1}

                    def policy():
                        value = observation()
                        return {field: value[field] for field in ('current', 'backlog', 'advice', 'catchup')}

                    observations, services, cycles = [observation()], [policy()], []
                    for received in range(12):
                        tags[received % capacity] = received
                        sample = (1 - received % 2) if mutate_input and received < 2 else received % 2
                        inputs[received % capacity] = [sample, 0]
                        observations.append(observation())
                        services.append(policy())
                        if received - current == capacity or received == 11:
                            while received - current > delay:
                                before = policy()
                                for _ in range(before['advice']):
                                    current += 1
                                    observations.append(observation())
                                cycles.append({'before': before, 'steps': before['advice'], 'after': policy()})
                            services.append(policy())
                            observations.append(observation())
                    transcript = [[frame, 1 - frame % 2 if mutate_input and frame < 2 else frame % 2, 0]
                                  for frame in range(12 - delay)]
                    bundle.append({'capacity': capacity, 'preplay': preplay, 'speed': speed, 'delay': delay,
                                   'observations': observations, 'service_observations': services, 'cycles': cycles, 'transcript': transcript})
        return bundle

    # Value: protects=every delivered and simulated ring state is retained; fails_when=startup copies replace the observed history;
    # why_new=service projections do not inspect detailed ring snapshots; seam=none
    def test_delay_ring_history_cannot_be_omitted_or_detached(self):
        from spectator_startup import validate_delay_bundle
        for mutate_input in (False, True):
            bundle = self.bundle(mutate_input)
            validate_delay_bundle(bundle, mutate_input=mutate_input)
            controls = []
            omitted = deepcopy(bundle)
            for trace in omitted:
                trace['observations'] = [deepcopy(trace['observations'][0]) for _ in range(14)]
            controls.append(omitted)
            missing = deepcopy(bundle)
            del missing[0]['observations'][5]
            controls.append(missing)
            for field, index, value in [('tags', 0, 4), ('inputs', 0, [0 if mutate_input else 1, 0])]:
                malformed = deepcopy(bundle)
                malformed[0]['observations'][1][field][index] = value
                controls.append(malformed)
            for index, value in enumerate(controls):
                with self.subTest(mutate_input=mutate_input, control=index), self.assertRaisesRegex(ValueError, 'delayed spectator observations'):
                    validate_delay_bundle(value, mutate_input=mutate_input)

    # Value: protects=negative execution validates every service cycle before accepting its intended transcript mismatch;
    # fails_when=an earlier expected difference hides later omitted or reordered service records; why_new=ring checks exclude policy projections; seam=none
    def test_delay_service_history_cannot_hide_behind_temporal_control(self):
        from spectator_startup import validate_delay_bundle
        for mutate_input in (False, True):
            bundle = self.bundle(mutate_input)
            validate_delay_bundle(bundle, mutate_input=mutate_input)
            for index in range(8):
                for field in ('service_observations', 'cycles'):
                    mutant = deepcopy(bundle)
                    sequence = mutant[index][field]
                    if field == 'service_observations':
                        sequence[1], sequence[2] = sequence[2], sequence[1]
                    else:
                        sequence.pop()
                    diagnostic = 'delayed spectator services' if field == 'service_observations' else 'delayed spectator cycles'
                    with self.subTest(mutate_input=mutate_input, trace=index, field=field), self.assertRaisesRegex(ValueError, diagnostic):
                        validate_delay_bundle(mutant, mutate_input=mutate_input)

    # Value: protects=nonzero delay source gate and exact temporal order; fails_when=observer ignores delay or swaps inputs;
    # why_new=the existing runtime corpus explicitly excludes stream delay; seam=none
    def test_delay_controls_reject_real_policy_and_temporal_mutations(self):
        from spectator_startup import delay_controls
        value = {'format': 1, 'traces': [{'observations': [
            {'advice': 0}, {'advice': 0}, {}, {}, {}, {'catchup': False}], 'transcript': [[0, 0, 0], [1, 1, 0]]}]}
        self.assertEqual([item['name'] for item in delay_controls(value, deepcopy(value))],
                         ['delay-bypass', 'raw-backlog-catchup', 'temporal-input'])

    # Value: protects=effective backlog policy typing; fails_when=raw host distance triggers catchup or numeric aliases pass;
    # why_new=no-delay model cannot distinguish raw and viewable backlog; seam=none
    def test_delay_policy_checks_effective_backlog_and_strict_types(self):
        from spectator_startup import _delay_policy
        item = {'current': 0, 'backlog': 3, 'advice': 1, 'catchup': False}
        _delay_policy(item, 5, 2, 2)
        for field, value in [('current', False), ('backlog', 3.0), ('advice', True), ('catchup', 0), ('advice', 2), ('catchup', True)]:
            mutant = deepcopy(item)
            mutant[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                _delay_policy(mutant, 5, 2, 2)

    # Value: protects=declared delay workloads cannot silently shrink; fails_when=one short transcript is presented as complete;
    # why_new=exact comparison alone can match two incomplete outputs; seam=none
    def test_delay_inventory_rejects_missing_and_malformed_workloads(self):
        from spectator_startup import validate_delay_bundle
        for value in [[], [None] * 8, [{}] * 8, [self.trace()] * 8]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_delay_bundle(value)

    @staticmethod
    def trace():
        return {'capacity': True, 'preplay': True, 'speed': 1, 'delay': 1, 'observations': [],
                'transcript': [], 'service_observations': [], 'cycles': []}


if __name__ == '__main__':
    unittest.main()
