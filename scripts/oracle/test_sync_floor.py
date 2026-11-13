"""Value: rejects false floor parity; schedule mutations and the canonical-bundle gate."""
import copy
import unittest

from contract import checksum
from sync_floor_contract import (
    compare_records,
    first_acceptance_divergence,
    validate_confirmed_history,
    validate_records,
)
from sync_floor_corpus import ADVANCE_FRAMES, baseline_states, bundle, validate_bundle


class SyncFloorCorpusTests(unittest.TestCase):
    def setUp(self):
        self.bundle = bundle()
        self.scenario = self.bundle['scenario']
        self.baseline = [bytes.fromhex(state) for state in self.bundle['baseline']]

    def test_schedule_shape_and_flags(self):
        self.assertEqual(validate_bundle(self.bundle), self.bundle)
        kinds = [operation['kind'] for operation in self.scenario['operations']]
        self.assertEqual(kinds.count('advance'), ADVANCE_FRAMES)
        self.assertEqual(kinds.count('observe'), 2 * ADVANCE_FRAMES)
        refused = [operation for operation in self.scenario['operations']
                   if operation['kind'] == 'receive' and operation['accepted'] is False]
        # One above-floor refusal per late frame plus the stale floor after each advance.
        self.assertEqual(len(refused), 2 * (ADVANCE_FRAMES - 12))
        delay = next(operation for operation in self.scenario['operations'] if operation['kind'] == 'delay')
        self.assertEqual((delay['player'], delay['value']), (0, 2))
        for mutation in [
                lambda data: data['scenario'].update(players=4),
                lambda data: data['scenario']['operations'][0].update(frame=-1),
                lambda data: data['scenario']['operations'][0].update(accepted=not data['scenario']['operations'][0]['accepted']),
                lambda data: data['baseline'].__setitem__(3, '00' * 16),
                lambda data: data.pop('baseline')]:
            bad = copy.deepcopy(self.bundle)
            mutation(bad)
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError):
                    validate_bundle(bad)

    def test_confirmed_history_validation(self):
        complete = {'format': 1, 'operations': [
            {'index': frame, 'kind': 'advance', 'advanced': True, 'confirmed_frame': frame, 'requests': [
                {'kind': 'advance', 'frame': frame, 'state_bytes': state.hex(), 'checksum': checksum(state), 'inputs': []}]}
            for frame, state in enumerate(self.baseline[1:])]}
        validate_confirmed_history(complete, self.baseline)
        bad = copy.deepcopy(complete)
        bad['operations'][7]['requests'][0]['state_bytes'] = '00' * 16
        with self.assertRaisesRegex(ValueError, 'confirmed frame 7'):
            validate_confirmed_history(bad, self.baseline)
        truncated = copy.deepcopy(complete)
        truncated['operations'].pop()
        with self.assertRaisesRegex(ValueError, 'confirmed frame 39'):
            validate_confirmed_history(truncated, self.baseline)

    def test_record_validation_and_comparison(self):
        full = self._synthetic_trace()
        validate_records(full, self.scenario, complete=False)
        compare_records(full, copy.deepcopy(full), self.scenario)
        for mutate in [
                lambda records: records[0].update(accepted=not records[0]['accepted']),
                lambda records: records[0].update(scheduled=records[0]['scheduled'] + 1),
                lambda records: records[1].update(floor=records[1]['floor'] + 1),
                lambda records: records[1]['players'][0].update(range=[2, 1]),
                lambda records: records[1]['players'][1].update(confirmed_floor='ffff'),
                lambda records: records[2]['requests'][0].update(state_bytes='00' * 16),
                lambda records: records[2]['requests'][0].update(checksum='00' * 32),
                lambda records: records[2]['requests'][1].update(inputs=[]),
                lambda records: records[2].update(confirmed_frame=records[2]['confirmed_frame'] + 1),
                lambda records: records.append(dict(records[-1]))]:
            bad = copy.deepcopy(full)
            mutate(bad['operations'])
            with self.subTest(mutation=mutate):
                with self.assertRaises(ValueError):
                    validate_records(bad, self.scenario, complete=False)

    def test_first_acceptance_divergence(self):
        clean = [{'index': 0, 'kind': 'receive', 'accepted': False}, {'index': 1, 'kind': 'advance'}]
        mutant = [dict(clean[0], accepted=True), {'index': 1, 'kind': 'advance'}]
        self.assertEqual(first_acceptance_divergence({'operations': clean}, {'operations': mutant}), 0)
        self.assertIsNone(first_acceptance_divergence({'operations': clean}, {'operations': clean}))

    def _synthetic_trace(self):
        """A well-formed prefix: one submit, one observe, one advance."""
        states = self.baseline
        operations = self.scenario['operations']
        self.assertEqual(operations[0]['kind'], 'submit')
        self.assertEqual(operations[1]['kind'], 'observe')
        self.assertEqual(operations[2]['kind'], 'advance')
        records = [
            {'index': 0, 'kind': 'submit', 'player': 0, 'frame': 0, 'bytes': operations[0]['bytes'],
             'accepted': True, 'scheduled': 0},
            {'index': 1, 'kind': 'observe', 'floor': 0, 'players': [
                {'range': None, 'confirmed_floor': None, 'retained_floor': None} for _ in range(3)]},
            {'index': 2, 'kind': 'advance', 'advanced': True, 'confirmed_frame': -1, 'requests': [
                {'kind': 'save', 'frame': 0, 'state_bytes': states[0].hex(), 'checksum': checksum(states[0]), 'inputs': []},
                {'kind': 'advance', 'frame': 0, 'state_bytes': states[1].hex(), 'checksum': checksum(states[1]),
                 'inputs': [{'player': player, 'bytes': '01', 'status': 'predicted'} for player in range(3)]}]},
        ]
        return {'format': 1, 'operations': records}


if __name__ == '__main__':
    unittest.main()
