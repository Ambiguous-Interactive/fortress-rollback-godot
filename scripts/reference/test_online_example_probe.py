"""Value: fail closed on fake channel claims and temporally wrong original-input prefixes."""
import ast
import copy
import inspect
import hashlib
import struct
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
                      'uuid': f'00000000-0000-0000-0000-{slot + 1:012}', 'direct_rejected': 0,
                      'room_id': '00000000-0000-0000-0000-000000000001', 'failure': '',
                      'snapshots': {str(frame): state for frame, state in states.items()},
                      'rtc': {'channels': channels}, 'delayed': 25})
    rounds = [{'room': room, 'peers': copy.deepcopy(peers), 'teardown': [
        {'channels': 3 * (index + 1), 'channels_closed': 3 * (index + 1), 'connections': index + 1,
         'connections_closed': index + 1, 'ice_closed': index + 1, 'websockets': index + 1,
         'websockets_closed': index + 1} for _ in range(2)]} for index, room in enumerate(('ROOM01', 'ROOM02', 'ROOM03', 'ROOM04', 'ROOM05'))]
    for index, record in enumerate(rounds):
        for peer in record['peers']:
            peer['room'] = record['room']
            peer['session_id'] = f'{index + 1:02}' * 16
            peer['room_id'] = f'00000000-0000-0000-0000-{index + 1:012}'
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
    payloads = []
    for peer in peers:
        body = (struct.pack('<iiH', 100, 99, 1) + bytes([1, peer['slot'], 2])
                + struct.pack('<BiH', 0, 99, 0) * 2 + struct.pack('<I', 1) + bytes([peer['inputs'][100]]))
        payloads.append((b'FRGP\x01\x00\x03\x00' + bytes.fromhex('04' * 16)
                         + hashlib.sha256(peer['uuid'].encode('ascii')).digest()[:8] + bytes([1]) + bytes(7)
                         + struct.pack('<I', len(body)) + body).hex())
    rounds[3]['server_restart'] = {
        'stopped': {'kind': 'stop', 'method': 'sigkill', 'pid': 123, 'exit_code': -9, 'terminal': True},
        'started': {'kind': 'start', 'pid': 124, 'previous_pid': 123, 'live': True, 'ready': True,
                    'port': 12345, 'binary_sha256': 'ab' * 32, 'config_sha256': 'cd' * 32},
        'held_elapsed_us': 750000, 'restarted_elapsed_us': 250000, 'before_user_leave': True,
        'boundary': [{'frame': 110, 'session_id': '04' * 16, 'pending': 1, 'relay_pending': 1,
                      'inputs': peer['inputs'],
                      'fault': {'armed': True, 'pressure': True, 'pending': 1, 'reads': 1, 'held': [payloads[index]]}}
                     for index, peer in enumerate(peers)],
        'terminal': [{'state': 'failed', 'message': 'Leave and create a fresh room.', 'first_message': 'Leave and create a fresh room.',
                      'frame_before': 110, 'frame_after': 110, 'session_before': '04' * 16, 'session_after': '04' * 16,
                      'pending': 0, 'relay_pending': 0, 'delayed_pending': 0, 'delayed_dropped': 1} for _ in range(2)],
        'resources': copy.deepcopy(rounds[3]['teardown'])}
    rounds[4]['stale_sent'] = payloads
    rounds[4]['stale_received'] = [1, 1]
    for peer in rounds[4]['peers']:
        peer['direct_rejected'] = 1
        boundary = {'state': 'playing', 'failure': '', 'has_readied': True, 'all_ready': True, 'session_id': peer['session_id'],
                    'room_id': peer['room_id'], 'frame': 45, 'message': 'fresh game', 'info_id': '1234', 'canonical': states[45]}
        peer['stale_callbacks'] = {'calls': 4, 'kinds': ['protocol_info', 'room_joined', 'lobby_state_changed', 'protocol_error'],
                                   'before': boundary, 'after': copy.deepcopy(boundary)}
    return {'passed': True, 'corrupt': False, 'browser_instances': 2, 'errors': [], 'teardown': True, 'rounds': rounds}


class OnlineExampleEvidenceTests(unittest.TestCase):
    def test_corruption_control_reaches_canonical_comparison_after_an_intended_desync(self):
        changed = evidence()
        changed['corrupt'] = True
        changed['rounds'] = changed['rounds'][:1]
        peer = changed['rounds'][0]['peers'][1]
        peer.update(state='failed', failure='Game stopped (18). Leave and create a new room.', terminal_reason=18)
        snapshot = peer['snapshots']['3']
        peer['snapshots']['3'] = '00' + snapshot[2:]
        with self.assertRaisesRegex(ValueError, 'canonical prefix mismatch at frame 3'):
            validate_result(changed, corrupt=True)
        for reason in (0, 14, 23, True, 18.0, None):
            unrelated = copy.deepcopy(changed)
            unrelated['rounds'][0]['peers'][1]['terminal_reason'] = reason
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, 'rollback or confirmation missing'):
                validate_result(unrelated, corrupt=True)
        # CI run 38512087955: a desynced peer stops capturing at termination. At frame 107 with delay 2 it may confirm
        # through 109, never 110. A playing peer's capture must cover its confirmation.
        accepted = 'canonical prefix mismatch at frame 3'
        missing = 'rollback or confirmation missing'
        for slot, confirmed, message in ((1, 108, accepted), (1, 109, accepted), (1, 110, missing), (0, 108, missing)):
            early = copy.deepcopy(changed)
            failed = early['rounds'][0]['peers'][1]
            failed.update(inputs=failed['inputs'][:108], frame=107, confirmed=107)
            peer = early['rounds'][0]['peers'][slot]
            peer.update(inputs=peer['inputs'][:108], frame=107, confirmed=confirmed)
            for peer in early['rounds'][0]['peers']:
                peer['snapshots'] = {frame: state for frame, state in peer['snapshots'].items() if int(frame) < 107}
            with self.subTest(slot=slot, confirmed=confirmed), self.assertRaisesRegex(ValueError, message):
                validate_result(early, corrupt=True)
        clean = evidence()
        clean['rounds'][0]['peers'][1].update(state='failed', failure='desync', terminal_reason=18)
        with self.assertRaisesRegex(ValueError, 'rollback or confirmation missing'):
            validate_result(clean)

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
            for peer in changed['rounds'][4]['peers']:
                peer[field] = changed['rounds'][2]['peers'][0][field]
                if field == 'session_id':
                    for side in ('before', 'after'):
                        peer['stale_callbacks'][side]['session_id'] = peer[field]
            if field == 'room':
                changed['rounds'][4]['room'] = changed['rounds'][2]['room']
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'reused room'):
                validate_result(changed)


    def test_five_room_browser_flow_has_its_full_watchdog_budget(self):
        calls = [node for node in ast.walk(ast.parse(inspect.getsource(run_online)))
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'run_browser']
        calls.sort(key=lambda node: node.lineno)
        self.assertEqual([next(keyword.value.value for keyword in call.keywords if keyword.arg == 'rooms') for call in calls], [5, 1])
        with patch.object(webrtc_runner, 'capture', return_value=(0, 'ok')) as capture:
            self.assertEqual(webrtc_runner.run_browser(['node', 'online'], {}, Path('owned.log'), 5), 'ok')
            capture.assert_called_once_with(['node', 'online'], {}, Path('owned.log'), timeout=2460)
        for rooms in (True, 2, 6):
            with self.subTest(rooms=rooms), patch.object(webrtc_runner, 'capture') as capture:
                with self.assertRaises(ValueError):
                    webrtc_runner.run_browser(['node'], {}, Path('owned.log'), rooms)
                capture.assert_not_called()

    def test_restart_requires_process_death_readiness_pressure_and_unchanged_failed_frontiers(self):
        mutations = [
            (('stopped', 'exit_code'), 0), (('stopped', 'exit_code'), True), (('stopped', 'terminal'), False),
            (('started', 'pid'), 123), (('started', 'previous_pid'), 125), (('started', 'live'), False),
            (('started', 'ready'), False), (('started', 'binary_sha256'), ''), (('started', 'config_sha256'), 'xyz'),
            (('before_user_leave',), False), (('held_elapsed_us',), 749999), (('restarted_elapsed_us',), True),
            (('boundary', 0, 'relay_pending'), 0), (('boundary', 0, 'frame'), 109),
            (('boundary', 0, 'fault', 'pending'), 0), (('boundary', 0, 'fault', 'reads'), 0),
            (('boundary', 0, 'fault', 'held'), []), (('boundary', 0, 'fault', 'pressure'), False),
            (('terminal', 0, 'frame_after'), 111), (('terminal', 0, 'session_after'), '05' * 16),
            (('terminal', 0, 'first_message'), 'Original failure was overwritten.'),
            (('terminal', 0, 'state'), 'playing'), (('terminal', 0, 'pending'), 1),
            (('terminal', 0, 'relay_pending'), 1), (('terminal', 0, 'delayed_dropped'), 0),
            (('resources', 1, 'websockets_closed'), 3), (('resources', 0, 'ice_closed'), 3),
        ]
        for fields, value in mutations:
            changed = evidence()
            target = changed['rounds'][3]['server_restart']
            for field in fields[:-1]:
                target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                validate_result(changed)
        for key in ('server_restart',):
            changed = evidence()
            del changed['rounds'][3][key]
            with self.assertRaisesRegex(ValueError, 'owned server restart missing'):
                validate_result(changed)

    def test_fresh_game_needs_old_input_receipt_rejection_and_new_room_uuid(self):
        for key, value in [('stale_sent', []), ('stale_received', [0, 1]), ('stale_received', [True, 1])]:
            changed = evidence()
            changed['rounds'][4][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'omitted old-room input delivery'):
                validate_result(changed)
        changed = evidence()
        changed['rounds'][4]['peers'][1]['direct_rejected'] = 0
        with self.assertRaisesRegex(ValueError, 'omitted old-room input delivery'):
            validate_result(changed)
        changed = evidence()
        for peer in changed['rounds'][4]['peers']:
            peer['room_id'] = changed['rounds'][3]['peers'][0]['room_id']
            for side in ('before', 'after'):
                peer['stale_callbacks'][side]['room_id'] = peer['room_id']
        with self.assertRaisesRegex(ValueError, 'reused room'):
            validate_result(changed)

    def test_stale_callback_proof_requires_delivery_and_strict_unchanged_fresh_state(self):
        for fields, value in [
                (('calls',), 0), (('calls',), True), (('before', 'frame'), 44),
                (('before', 'canonical'), '00' * 136), (('before', 'info_id'), ''),
                (('after', 'state'), 'failed'), (('after', 'message'), 'old failure'),
                (('after', 'all_ready'), False), (('after', 'has_readied'), 1),
                (('after', 'frame'), 45.0), (('after', 'room_id'), '00000000-0000-0000-0000-000000000004'),
                (('after', 'info_id'), '5678'), (('after', 'session_id'), '04' * 16)]:
            changed = evidence()
            target = changed['rounds'][4]['peers'][0]['stale_callbacks']
            for field in fields[:-1]:
                target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, 'old SDK callback'):
                validate_result(changed)

    def test_delayed_packet_must_contain_the_original_sender_input_and_complete_wire_body(self):
        for position, value in [(24, 0), (32, 0), (44, 255), (55, 1), (56, 3), (57, 1), (71, 0), (75, 15)]:
            changed = evidence()
            boundary = changed['rounds'][3]['server_restart']['boundary'][0]
            raw = bytearray.fromhex(boundary['fault']['held'][0])
            if position == 32:
                raw[32:40] = bytes(8)
            else:
                raw[position] = value
            boundary['fault']['held'][0] = raw.hex()
            changed['rounds'][4]['stale_sent'][0] = raw.hex()
            with self.subTest(position=position), self.assertRaisesRegex(ValueError, 'delayed'):
                validate_result(changed)
