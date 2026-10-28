"""Independent handshake harness rejects corrupt, partial and ambiguous evidence."""
import unittest
from copy import deepcopy
from handshake_contract import compare, packet, version, wide, project, raw_negative_controls
from handshake_launch import scenarios
from handshake_formal import validate_begin


class HandshakeContractTests(unittest.TestCase):
    # Value: protects=strict cross-language evidence; fails_when=bool/float substitute integers; why_new=JSON equality aliases numbers; seam=none
    def test_wide_integer_types(self):
        for value in (True, 1.0, -1, 1 << 64):
            with self.assertRaises(ValueError):
                wide(value, 8)
        self.assertEqual(wide(0xfedcba9876543210, 8), '1032547698badcfe')

    def test_explicit_semantic_profile(self):
        self.assertEqual(version(2), 1)
        self.assertEqual(version(3), 2)
        for value in (True, 2.0, 0, 1, 4, 255):
            with self.assertRaises(ValueError):
                version(value)

    def test_packet_rejects_missing_unknown_numeric_alias(self):
        original = {'header': {'conn_id': 77, 'flags': 0, 'protocol_version': 2, 'sentinel': [245, 82]},
                    'body': {'SyncRequest': {'random_request': 42, 'min_compat_version': 2, 'features': 0, 'config_digest': 7,
                             'config': {'num_players': 2, 'input_bytes_per_player': 4, 'fps': 60, 'max_prediction': 8, 'desync_interval': 60}}}}
        self.assertEqual(packet(original)['token'], '2a000000000000000000000000000000')
        for mutate in (lambda p: p['body']['SyncRequest']['config'].update(fps=True),
                       lambda p: p['body']['SyncRequest'].update(features=0.0),
                       lambda p: p['header'].update(extra=1),
                       lambda p: p['header'].update(flags=1),
                       lambda p: p['header'].update(protocol_version=3),
                       lambda p: p['header'].update(sentinel=[245, 83]),
                       lambda p: p['body']['SyncRequest'].update(random_request=1 << 32),
                       lambda p: p['header'].update(conn_id=1 << 32),
                       lambda p: p['body']['SyncRequest'].pop('config_digest')):
            corrupted = deepcopy(original); mutate(corrupted)
            with self.assertRaises(ValueError):
                packet(corrupted)

    def test_partial_and_empty_output(self):
        expected = [{'code': 0, 'transitions': [], 'events': [], 'packets': []}]
        valid = {'format': 1, 'complete': True, 'records': deepcopy(expected)}
        self.assertTrue(compare(valid, expected))
        for corrupted in ({'format': True, 'complete': True, 'records': expected},
                          {'format': 1, 'complete': True, 'records': []},
                          {'format': 1, 'complete': False, 'records': expected}):
            with self.assertRaises(ValueError):
                compare(corrupted, expected)

    def test_nonzero_success_code(self):
        expected = [{'code': 0, 'transitions': [], 'events': [], 'packets': []}]
        actual = {'format': 1, 'complete': True, 'records': [{'code': 7, 'transitions': [], 'events': [], 'packets': []}]}
        with self.assertRaisesRegex(ValueError, 'operation 0'):
            compare(actual, expected)

    @staticmethod
    def raw_fixture():
        packet_value = {'header': {'conn_id': 77, 'flags': 0, 'protocol_version': 2, 'sentinel': [245, 82]},
                        'body': {'SyncRequest': {'random_request': 42, 'min_compat_version': 2, 'features': 0, 'config_digest': 7,
                                 'config': {'num_players': 2, 'input_bytes_per_player': 4, 'fps': 60, 'max_prediction': 8, 'desync_interval': 60}}}}
        activated = {'action': 'activated', 'token': None, 'disposition': None, 'state': 'initializing', 'remaining': 2,
                     'outstanding': 0, 'remote_connection': None, 'timeout_sent': False, 'mismatch': {}, 'elapsed_ms': -1}
        begin = dict(activated, action='begin', state='synchronizing')
        send = dict(begin, action='send_request', token='2a000000000000000000000000000000', disposition='fresh', outstanding=1)
        return {'format': 1, 'complete': True, 'upstream_revision': 'd124c89080004d96971a629bb0427056ee1805e3', 'records': [
            {'operation': None, 'packets': [packet_value], 'transitions': [activated, begin, send], 'events': []},
            {'operation': 0, 'packets': [], 'transitions': [], 'events': []}]}

    # Value: protects=raw recorder evidence survives strict parsing; fails_when=False aliases null or activation disappears; why_new=review reproduced erased corruptions; seam=none
    def test_raw_transition_corruptions(self):
        raw = self.raw_fixture(); scenario = {'format': 1, 'operations': [{'kind': 'poll', 'now_us': 0}]}
        project(raw, scenario)
        self.assertEqual(len(raw_negative_controls(raw, scenario)), 7)
        for field, value in [('token', False), ('disposition', False), ('remote_connection', False), ('action', 'unknown'),
                             ('state', False), ('remaining', True), ('remaining', 2.0), ('mismatch', []), ('elapsed_ms', -1.0)]:
            corrupted = deepcopy(raw); corrupted['records'][0]['transitions'][1][field] = value
            with self.assertRaises(ValueError, msg=field):
                project(corrupted, scenario)
        corrupted = deepcopy(raw); corrupted['records'][1]['transitions'].append(deepcopy(raw['records'][0]['transitions'][0]))
        with self.assertRaisesRegex(ValueError, 'position'):
            project(corrupted, scenario)

    # Value: protects=model initial state is actual endpoint state; fails_when=projection drops invalid begin snapshot; why_new=review reproduced real TLC acceptance; seam=none
    def test_formal_begin_preserved(self):
        valid = {'action': 'begin_synchronization', 'token': '', 'disposition': '', 'state': 'synchronizing', 'remaining': 2,
                 'outstanding_request_count': 0, 'remote_connection': '', 'timeout_sent': False, 'mismatch': {}, 'elapsed_ms': -1}
        validate_begin(valid)
        for changes in ({'remaining': 0, 'state': 'running'}, {'remaining': True}, {'remaining': 2.0}, {'outstanding_request_count': 1}):
            with self.assertRaisesRegex(ValueError, 'formal begin'):
                validate_begin(dict(valid, **changes))


if __name__ == '__main__':
    unittest.main()
