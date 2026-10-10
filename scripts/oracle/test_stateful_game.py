"""Value: protects=versioned PRNG/pending snapshots; fails_when=state is omitted; seam=none."""
import copy
import unittest

import contract


class StatefulGameTests(unittest.TestCase):
    def test_independent_known_answer_and_restore_fields(self):
        # LCG seed 8173; one neutral tick: rng=1733165160, low byte=104.
        source = {'format': 2, 'upstream_revision': contract.REVISION, 'players': 2,
                  'input_width': 4, 'check_distance': 2, 'input_delay': 0,
                  'operations': [{'kind': 'advance'}]}
        contract.validate_scenario(source)
        before = bytes.fromhex('000000000000000000000000ed1f000000000000')
        after = bytes.fromhex('0100000068000000d000000068004e6700000000')
        self.assertEqual(contract.initial_game_state(2, 2), before)
        self.assertEqual(contract.advance_game_state(before, [0, 0], 2), after)
        # Pending input is a next-frame event; both fields affect future gameplay.
        state = contract.advance_game_state(before, [3, 5], 2)
        self.assertEqual(int.from_bytes(state[-4:], 'little'), 13)
        next_state = contract.advance_game_state(state, [0, 0], 2)
        for offset in (-8, -4):
            changed = bytearray(state)
            changed[offset:offset + 4 if offset + 4 else None] = bytes(4)
            self.assertNotEqual(contract.advance_game_state(changed, [0, 0], 2), next_state)

    def test_stateful_trace_rejects_omitted_or_forged_state(self):
        source = {'format': 2, 'upstream_revision': contract.REVISION, 'players': 2,
                  'input_width': 4, 'check_distance': 2, 'input_delay': 0,
                  'operations': [{'kind': 'advance'}]}
        before = bytes.fromhex('000000000000000000000000ed1f000000000000')
        after = bytes.fromhex('010000006b000000d500000068004e670d000000')
        requests = [
            {'kind': 'save', 'frame': 0, 'state_bytes': before.hex(),
             'checksum': contract.checksum(before), 'inputs': []},
            {'kind': 'advance', 'frame': 0, 'state_bytes': after.hex(),
             'checksum': contract.checksum(after), 'inputs': [
                 {'player': 0, 'bytes': '03000000', 'status': 'confirmed'},
                 {'player': 1, 'bytes': '05000000', 'status': 'confirmed'}]}]
        trace = {'format': 2, 'upstream_revision': contract.REVISION, 'scenario': source,
                 'operations': [{'index': 0, 'kind': 'advance', 'result': 'ok', 'error': None,
                                 'frame_before': 0, 'frame_after': 1, 'confirmed_frame': None,
                                 'requests': requests, 'events': []}],
                 'final_state': {'frame': 1, 'bytes': after.hex(), 'checksum': contract.checksum(after)}}
        contract.validate_trace(trace, source)
        for name, data, diagnostic in [('old_width', after[:-8], 'invalid canonical hex'),
                                       ('rng', after[:-8] + bytes(4) + after[-4:], 'canonical state mismatch'),
                                       ('pending', after[:-4] + bytes(4), 'canonical state mismatch')]:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, diagnostic):
                changed = copy.deepcopy(trace)
                changed['operations'][0]['requests'][1].update(state_bytes=data.hex(), checksum=contract.checksum(data))
                contract.validate_trace(changed, source)
        changed = copy.deepcopy(trace)
        changed['format'] = 1
        with self.assertRaisesRegex(ValueError, 'trace version'):
            contract.validate_trace(changed, source)


if __name__ == '__main__':
    unittest.main()
