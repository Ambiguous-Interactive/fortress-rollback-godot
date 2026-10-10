"""Value: oracle receipts reject stale provenance, missing operations and malformed traces."""
import copy
import unittest

import contract
import corpus


def scenario():
    return {'format': 1, 'upstream_revision': contract.REVISION, 'players': 2,
            'input_width': 4, 'check_distance': 2, 'input_delay': 0,
            'operations': [{'kind': 'input', 'player': 0, 'bytes': 'ffffffff'},
                           {'kind': 'input', 'player': 1, 'bytes': '01000000'},
                           {'kind': 'advance'}]}


def trace():
    source = scenario()
    operations = []
    for index, operation in enumerate(source['operations']):
        operations.append({'index': index, 'kind': operation['kind'], 'result': 'ok',
                           'error': None, 'frame_before': 0, 'frame_after': int(index == 2),
                           'confirmed_frame': None, 'requests': [], 'events': []})
    operations[2]['requests'] = [
        {'kind': 'save', 'frame': 0, 'state_bytes': '00' * 12,
         'checksum': contract.checksum(bytes(12)), 'inputs': []},
        {'kind': 'advance', 'frame': 0, 'state_bytes': '01000000ffffffff01000000',
         'checksum': contract.checksum(bytes.fromhex('01000000ffffffff01000000')),
         'inputs': [{'player': p, 'bytes': b, 'status': 'confirmed'}
                    for p, b in enumerate(['ffffffff', '01000000'])]}]
    return {'format': 1, 'upstream_revision': contract.REVISION, 'scenario': source,
            'operations': operations, 'final_state': {'frame': 1,
            'bytes': '01000000ffffffff01000000',
            'checksum': contract.checksum(bytes.fromhex('01000000ffffffff01000000'))}}


class ContractTests(unittest.TestCase):
    def test_valid_runtime_trace(self):
        self.assertEqual(contract.validate_trace(trace(), scenario())['final_state']['frame'], 1)

    def test_scenario_mutations(self):
        mutations = {
            'version': lambda x: x.update(format=3),
            'revision': lambda x: x.update(upstream_revision='0' * 40),
            'empty': lambda x: x.update(operations=[]),
            'unknown': lambda x: x.update(ignored=True),
            'bool_players': lambda x: x.update(players=True),
            'width': lambda x: x.update(input_width=0),
            'bytes': lambda x: x['operations'][0].update(bytes=''),
            'player': lambda x: x['operations'][0].update(player=256),
            'unknown_operation': lambda x: x['operations'][0].update(kind='poll'),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                value = scenario()
                mutate(value)
                with self.assertRaises(ValueError):
                    contract.validate_scenario(value)

    def test_trace_mutations(self):
        mutations = {
            'missing_operation': lambda x: x['operations'].pop(),
            'stale_revision': lambda x: x.update(upstream_revision='0' * 40),
            'wrong_scenario': lambda x: x['scenario'].update(input_delay=1),
            'float_scenario': lambda x: x['scenario'].update(players=2.0),
            'false_index': lambda x: x['operations'][1].update(index=0),
            'error_contradiction': lambda x: x['operations'][0].update(error='failed'),
            'invented_confirmation': lambda x: x['operations'][0].update(confirmed_frame=0),
            'unknown_request': lambda x: x['operations'][2]['requests'][0].update(kind='skip'),
            'checksum': lambda x: x['final_state'].update(checksum='0' * 32),
            'state_frame': lambda x: x['final_state'].update(frame=2),
            'frame_chain': lambda x: x['operations'][1].update(frame_before=1),
            'request_order': lambda x: x['operations'][2]['requests'].reverse(),
            'input_slot': lambda x: x['operations'][2]['requests'][1]['inputs'][0].update(player=1),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                value = copy.deepcopy(trace())
                mutate(value)
                with self.assertRaises(ValueError):
                    contract.validate_trace(value, scenario())

    def test_temporal_common_error(self):
        source = scenario()
        source['check_distance'] = 0
        source['operations'] = []
        history = []
        for frame in range(20):
            inputs = []
            for player in range(2):
                incoming = (frame + player + 1).to_bytes(4, 'little').hex()
                source['operations'].append({'kind': 'input', 'player': player, 'bytes': incoming})
                inputs.append({'player': player, 'bytes': incoming, 'status': 'confirmed'})
            source['operations'].append({'kind': 'advance'})
            history.append(inputs)
        history[0], history[1] = history[1], history[0]
        operations, totals = [], [0, 0]
        frame = 0
        for index, operation in enumerate(source['operations']):
            requests = []
            before = frame
            if operation['kind'] == 'advance':
                inputs = history[frame]
                totals = [(value + int.from_bytes(bytes.fromhex(item['bytes']), 'little')) & 0xffffffff
                          for value, item in zip(totals, inputs)]
                frame += 1
                data = frame.to_bytes(4, 'little') + b''.join(value.to_bytes(4, 'little') for value in totals)
                requests = [{'kind': 'advance', 'frame': before, 'state_bytes': data.hex(),
                             'checksum': contract.checksum(data), 'inputs': inputs}]
            operations.append({'index': index, 'kind': operation['kind'], 'result': 'ok', 'error': None,
                               'frame_before': before, 'frame_after': frame,
                               'confirmed_frame': None, 'requests': requests, 'events': []})
        value = {'format': 1, 'upstream_revision': contract.REVISION, 'scenario': source,
                 'operations': operations, 'final_state': {'frame': frame, 'bytes': data.hex(),
                 'checksum': contract.checksum(data)}}
        contract.validate_trace(value, source)
        self.assertEqual(value['final_state']['bytes'], corpus.expected_final(source))
        with self.assertRaisesRegex(ValueError, 'submitted history'):
            corpus.validate_history(value, source)


if __name__ == '__main__':
    unittest.main()
