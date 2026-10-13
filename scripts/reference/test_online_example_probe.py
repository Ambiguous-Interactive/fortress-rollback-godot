"""Value: fail closed on fake channel claims and temporally wrong original-input prefixes."""
import copy
import unittest

from online_example_probe import expected_states, validate_result


def evidence():
    histories = [[0, 0] + [2] * 45 + [8] * 70, [0, 0] + [4] * 45 + [1] * 70]
    states = expected_states(histories, 110)
    peers = []
    for slot in range(2):
        channels = [{'id': index, 'sent': 40 if index == 3 else 0, 'received': 40 if index == 3 else 0,
                     'ordered': index != 3, 'negotiated': True, 'maxPacketLifeTime': 1, 'maxRetransmits': None} for index in (1, 2, 3)]
        peers.append({'slot': slot, 'page_index': slot, 'inputs': histories[slot], 'restores': 1, 'confirmed': 110, 'frame': 110,
                      'state': 'playing', 'room': 'ROOM01', 'session_id': '01' * 16,
                      'failure': '', 'snapshots': {str(frame): state for frame, state in states.items()},
                      'rtc': {'channels': channels}, 'delayed': 25})
    rounds = [{'room': room, 'peers': copy.deepcopy(peers), 'teardown': [
        {'channels': 3 * (index + 1), 'channels_closed': 3 * (index + 1), 'connections': index + 1,
         'connections_closed': index + 1} for _ in range(2)]} for index, room in enumerate(('ROOM01', 'ROOM02'))]
    for index, record in enumerate(rounds):
        for peer in record['peers']:
            peer['room'] = record['room']
            peer['session_id'] = ('01' if index == 0 else '02') * 16
    rounds[0]['terminal'] = {'state': 'failed', 'message': 'Leave and create a fresh room.', 'frame_before': 110, 'frame_after': 110}
    return {'passed': True, 'corrupt': False, 'browser_instances': 2, 'errors': [], 'teardown': True, 'rounds': rounds}


class OnlineExampleEvidenceTests(unittest.TestCase):
    def test_complete_evidence_and_missing_or_wrong_transport_contracts(self):
        original = evidence()
        self.assertIs(validate_result(original), original)
        for key, value in [('maxPacketLifeTime', 0), ('ordered', True), ('maxRetransmits', 0), ('sent', False)]:
            changed = copy.deepcopy(original)
            changed['rounds'][0]['peers'][0]['rtc']['channels'][2][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_result(changed)
        for key, value in [('restores', 0), ('confirmed', True), ('inputs', [0] * 117), ('snapshots', {})]:
            changed = copy.deepcopy(original)
            changed['rounds'][0]['peers'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_result(changed)

    def test_temporal_mutation_preserves_final_state_but_rejects_intermediate_prefix(self):
        original = evidence()
        changed = copy.deepcopy(original)
        inputs = changed['rounds'][0]['peers'][0]['inputs']
        inputs[20], inputs[60] = inputs[60], inputs[20]
        before = expected_states([peer['inputs'] for peer in original['rounds'][0]['peers']], 110)
        after = expected_states([peer['inputs'] for peer in changed['rounds'][0]['peers']], 110)
        self.assertEqual(before[109], after[109])
        self.assertNotEqual(before[21], after[21])
        with self.assertRaisesRegex(ValueError, 'canonical prefix mismatch at frame 21'):
            validate_result(changed)

    def test_corruption_cannot_hide_later_invalid_peer_or_unclosed_transport(self):
        changed = evidence()
        changed['corrupt'] = True
        changed['rounds'] = changed['rounds'][:1]
        snapshot = changed['rounds'][0]['peers'][0]['snapshots']['3']
        changed['rounds'][0]['peers'][0]['snapshots']['3'] = '00' + snapshot[2:]
        with self.assertRaisesRegex(ValueError, 'canonical prefix mismatch at frame 3'):
            validate_result(changed, corrupt=True)
        changed['rounds'][0]['peers'][1]['rtc']['channels'][2]['maxPacketLifeTime'] = 0
        with self.assertRaisesRegex(ValueError, 'physical unreliable channel contract missing'):
            validate_result(changed, corrupt=True)
        changed['rounds'][0]['teardown'][1]['channels_closed'] = 2
        with self.assertRaisesRegex(ValueError, 'retained physical channels'):
            validate_result(changed, corrupt=True)

    def test_terminal_reporting_rejects_synthetic_zero_lost_frontier_and_post_failure_advance(self):
        for before, after in [(0, 0), (109, 109), (110, 111)]:
            changed = evidence()
            changed['rounds'][0]['terminal'].update(frame_before=before, frame_after=after)
            with self.subTest(before=before, after=after), self.assertRaises(ValueError):
                validate_result(changed)
