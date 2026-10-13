"""Value: fail closed on fake channel claims and temporally wrong original-input prefixes."""
import ast
import copy
import inspect
from pathlib import Path
from unittest.mock import patch
import unittest

from browser import webrtc_runner
from online_example_probe import expected_states, run_online, validate_result


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
         'connections_closed': index + 1, 'ice_closed': index + 1, 'websockets': index + 1,
         'websockets_closed': index + 1} for _ in range(2)]} for index, room in enumerate(('ROOM01', 'ROOM02', 'ROOM03', 'ROOM04'))]
    for index, record in enumerate(rounds):
        for peer in record['peers']:
            peer['room'] = record['room']
            peer['session_id'] = f'{index + 1:02}' * 16
        if index >= 2:
            continue
        expired = index == 1
        duration, label = (2500, 'expired') if expired else (750, 'short')
        record['suspension'] = {'label': label, 'method': 'cdp-debugger-pause', 'requested_ms': duration, 'frozen_elapsed_us': duration * 1000, 'peers': [
            {'label': label, 'session_id': peer['session_id'], 'epoch_us': 100, 'host_before_us': 1000100,
             'host_after_us': 1000100 + duration * 1000, 'gap_us': duration * 1000,
             'protocol_before_us': 1000000, 'protocol_after_us': 1000000 + duration * 1000,
             'frame_before': 110 if expired else 45, 'frame_after': 110 if expired else 46,
             'state': 'failed' if expired else 'playing', 'message': 'Leave and create a fresh room.'} for peer in record['peers']]}
        if expired:
            record['failure_resources'] = copy.deepcopy(record['teardown'])
            record['frozen_frames'] = [{'before': 110, 'after': 110, 'state': 'failed'} for _ in range(2)]
    rounds[0]['terminal'] = {'state': 'failed', 'message': 'Leave and create a fresh room.', 'frame_before': 110, 'frame_after': 110}
    rounds[2]['socket_loss'] = {'kind': 'signaling-websocket-socket-loss', 'method': 'tls-proxy-destroy-both-pairs',
        'proxy_pairs_before': 2, 'destroyed_pairs': 2, 'proxy_pairs_after': 0, 'open_websockets_before': [1, 1],
        'upgrades_refused': True, 'refused_upgrade_attempts': 1, 'held_elapsed_us': 750000, 'reopened_elapsed_us': 250000, 'reopened': True, 'before_user_leave': True,
        'resources': copy.deepcopy(rounds[2]['teardown']), 'terminal': [
            {'state': 'failed', 'message': 'Leave and create a fresh room.', 'frame_before': 110, 'frame_after': 110,
             'session_before': '03' * 16, 'session_after': '03' * 16} for _ in range(2)]}
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

    def test_suspension_requires_elapsed_protocol_clock_recovery_and_actual_frozen_frontier(self):
        original = evidence()
        mutations = [(0, 'gap_us', 0), (0, 'protocol_after_us', 1000000), (0, 'frame_after', 60), (0, 'state', 'failed'),
                     (1, 'state', 'playing'), (1, 'frame_before', 109), (1, 'frame_after', 111), (1, 'session_id', '01' * 16),
                     (1, 'host_after_us', True)]
        for index, key, value in mutations:
            changed = copy.deepcopy(original)
            changed['rounds'][index]['suspension']['peers'][0][key] = value
            with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                validate_result(changed)
        for key, value in [('frozen_elapsed_us', 0), ('requested_ms', True), ('peers', [])]:
            changed = copy.deepcopy(original)
            changed['rounds'][1]['suspension'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_result(changed)
        changed = copy.deepcopy(original)
        changed['rounds'][1]['frozen_frames'][0]['after'] += 1
        with self.assertRaisesRegex(ValueError, 'lost its frozen frontier'):
            validate_result(changed)


    def test_socket_loss_rejects_false_loss_and_partial_or_missing_closure_before_leave(self):
        mutations = [('kind', 'server-restart'), ('method', 'synthetic-close'), ('proxy_pairs_before', True),
                     ('destroyed_pairs', 1), ('proxy_pairs_after', 1), ('open_websockets_before', [True, 1]),
                     ('upgrades_refused', False), ('refused_upgrade_attempts', 0), ('reopened', False),
                     ('before_user_leave', False), ('held_elapsed_us', 0), ('reopened_elapsed_us', True)]
        for key, value in mutations:
            changed = evidence()
            changed['rounds'][2]['socket_loss'][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'actual signaling socket loss missing'):
                validate_result(changed)
        for round_index, container in [(1, 'failure_resources'), (2, 'socket_loss')]:
            for field in ('channels_closed', 'connections_closed', 'ice_closed', 'websockets_closed', 'websockets'):
                changed = evidence()
                resources = changed['rounds'][round_index][container]
                if round_index == 2:
                    resources = resources['resources']
                resources[0][field] -= 1
                with self.subTest(round=round_index, field=field), self.assertRaisesRegex(ValueError, 'retained physical'):
                    validate_result(changed)
            changed = evidence()
            if round_index == 2:
                del changed['rounds'][round_index][container]['resources']
            else:
                del changed['rounds'][round_index][container]
            with self.assertRaisesRegex(ValueError, 'physical teardown missing'):
                validate_result(changed)

    def test_socket_loss_preserves_both_failed_frontiers_and_fresh_recovery_room(self):
        for key, value in [('state', 'playing'), ('message', 'Disconnected.'), ('frame_before', 109),
                           ('frame_after', 111), ('session_after', '04' * 16), ('frame_after', True)]:
            changed = evidence()
            changed['rounds'][2]['socket_loss']['terminal'][1][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'socket loss advanced or revived gameplay'):
                validate_result(changed)
        changed = evidence()
        changed['rounds'].pop()
        with self.assertRaisesRegex(ValueError, 'did not restart in a fresh room'):
            validate_result(changed)
        for field in ('room', 'session_id'):
            changed = evidence()
            for peer in changed['rounds'][3]['peers']:
                peer[field] = changed['rounds'][2]['peers'][0][field]
            if field == 'room':
                changed['rounds'][3]['room'] = changed['rounds'][2]['room']
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'reused room'):
                validate_result(changed)


    def test_four_room_browser_flow_has_its_full_watchdog_budget(self):
        calls = [node for node in ast.walk(ast.parse(inspect.getsource(run_online)))
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'run_browser']
        calls.sort(key=lambda node: node.lineno)
        self.assertEqual([next(keyword.value.value for keyword in call.keywords if keyword.arg == 'rooms') for call in calls], [4, 1])
        with patch.object(webrtc_runner, 'capture', return_value=(0, 'ok')) as capture:
            self.assertEqual(webrtc_runner.run_browser(['node', 'online'], {}, Path('owned.log'), 4), 'ok')
            capture.assert_called_once_with(['node', 'online'], {}, Path('owned.log'), timeout=1980)
        for rooms in (True, 2, 5):
            with self.subTest(rooms=rooms), patch.object(webrtc_runner, 'capture') as capture:
                with self.assertRaises(ValueError):
                    webrtc_runner.run_browser(['node'], {}, Path('owned.log'), rooms)
                capture.assert_not_called()
