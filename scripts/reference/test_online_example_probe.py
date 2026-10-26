"""Value: fail closed on fake channel claims and temporally wrong original-input prefixes."""
import ast
import copy
import inspect
import hashlib
import json
import struct
import tempfile
from pathlib import Path
from unittest.mock import patch
import unittest

from browser import webrtc_runner
from online_example_probe import (StepTimings, browser_step_durations, expected_states, run_online,
                                  validate_result as observe_result,
                                  validate_replay_download as observe_replay, validate_viewer, validate_diagnostic_playback, validate_diagnostic_viewer)
from online_diagnostics import game_checksum, validate_trace_history
from test_online_diagnostics import diagnostic_download, trace_evidence
from online_install import ROOT, create_project, install_sdk, server_config
from signalfish_probe import inventory
from wire import INPUT_HEADER


ENGINE_IDENTITY = '4.3.0.stable 77dcf97d8'

# Every step the online probe runs, in the order it runs them.
ONLINE_STEPS = ['install', 'engine_version', 'no_sdk_import', 'no_sdk_check', 'install_sdk', 'sdk_import',
                'documented_export', 'import', 'export', 'browser_flow', 'diagnostic_reproduction', 'corrupt_control']


def measures_a_step(expression):
    return (isinstance(expression, ast.Call) and isinstance(expression.func, ast.Attribute)
            and expression.func.attr == 'measure' and isinstance(expression.func.value, ast.Name)
            and expression.func.value.id == 'timings' and len(expression.args) == 1
            and isinstance(expression.args[0], ast.Constant) and isinstance(expression.args[0].value, str))


def measured_steps(source):
    """The measured step names of a probe body and the run calls that no measured step covers."""
    tree = ast.parse(source)
    measured, covered = [], set()
    for node in ast.walk(tree):
        if isinstance(node, ast.With) and node.items and all(measures_a_step(item.context_expr) for item in node.items):
            for item in node.items:
                measured.append((item.context_expr.lineno, item.context_expr.args[0].value))
            for statement in node.body:
                covered.update(id(child) for child in ast.walk(statement))
    unmeasured = []
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ('run', 'run_browser')
                and id(node) not in covered):
            unmeasured.append(node.func.id)
    return [name for _, name in sorted(measured)], unmeasured


def publishes_measured_steps(source):
    """The record the probe returns must publish the measured durations."""
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Return) and isinstance(node.value, ast.Tuple) and node.value.elts:
            record = node.value.elts[0]
            if isinstance(record, ast.Dict):
                for key, value in zip(record.keys, record.values):
                    if isinstance(key, ast.Constant) and key.value == 'steps':
                        return isinstance(value, ast.Call) and isinstance(value.func, ast.Attribute) and value.func.attr == 'summary'
    return False


def validate_result(value, corrupt=False):
    return observe_result(value, corrupt, expected_engine=ENGINE_IDENTITY)


def validate_replay_download(value):
    return observe_replay(value, ENGINE_IDENTITY, evidence()['rounds'][0])


def replay_download(histories):
    frames = 110
    states = expected_states([history[:frames] + [0] for history in histories], frames + 1)
    texts = ['4.3.0.stable 77dcf97d8', '0.1.0', 'fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8',
             '1701', 'fortress-online-integer-v1']
    raw = b'FRRP' + struct.pack('<HBIIIHBB', 6, 2, 1, frames, 0, 2, 8, 0) + bytes(1)
    raw += b''.join(bytes([len(text)]) + text.encode('ascii') for text in texts)
    raw += b''.join(bytes([histories[0][frame], histories[1][frame], 1, 1, 1]) + bytes.fromhex(game_checksum(states[frame]))
                    + hashlib.sha256(bytes([histories[0][frame], histories[1][frame], 1, 1])).digest()[:16] for frame in range(frames))
    raw += bytes.fromhex(game_checksum(states[frames]))
    return {'filename': 'fortress-online.frrp', 'hex': raw.hex(), 'disabled_peer': True,
            'before': {'state': 'failed', 'frame': frames, 'restores': 1}, 'after': {'state': 'failed', 'frame': frames, 'restores': 1},
            'peers': [{'slot': slot, 'inputs': history} for slot, history in enumerate(histories)],
            'playback': {'decode_code': 0, 'code': 16, 'frames': frames, 'failure_frame': -1, 'canonical': states[frames]}}


def diagnostic_viewer_evidence(trace, histories):
    rows = trace['frames']
    states = expected_states(histories, rows[-1]['frame'] + 2)
    status = {'loaded': True, 'playing': False, 'code': 0, 'first_boundary': rows[0]['frame'], 'last_boundary': rows[-1]['frame'],
              'next_boundary': rows[0]['frame'], 'rows_consumed': 0, 'row_count': len(rows), 'game_frame': 0,
              'seed': trace['seed'], 'application_version': trace['application_version'], 'capture_failure': {},
              'complete': False, 'validated_states': 0, 'advanced_frames': 0, 'failure': {}}
    initial = {'status': status, 'state': states[0], 'message': 'Ready.'}
    value = {label: copy.deepcopy(initial) for label in ('initial', 'stepped', 'restarted', 'rejected', 'completed', 'diverged')}
    value['rejected']['message'] = 'This viewer needs a fortress-online-integer-v1 canonical capture.'
    value['stepped']['status'].update(rows_consumed=1, validated_states=1, advanced_frames=1,
                                       next_boundary=rows[1]['frame'], game_frame=rows[0]['frame'] + 1)
    value['stepped']['state'] = states[rows[0]['frame'] + 1]
    final_frame = rows[-1]['frame'] + bool(rows[-1]['inputs'])
    value['completed']['status'].update(complete=True, rows_consumed=len(rows), next_boundary=-1, game_frame=final_frame,
        validated_states=sum(row['state_available'] for row in rows), advanced_frames=sum(bool(row['inputs']) for row in rows))
    value['completed']['state'] = states[final_frame]
    changed = next(row for row in rows[1:] if row['state_available'])
    changed_index = rows.index(changed)
    value['diverged']['status'].update(code=18, rows_consumed=changed_index, next_boundary=changed['frame'], game_frame=changed['frame'],
        validated_states=sum(row['state_available'] for row in rows[:changed_index]),
        advanced_frames=sum(bool(row['inputs']) for row in rows[:changed_index]), failure={'frame': changed['frame'], 'kind': 'state', 'byte': 24,
                                                       'expected_bytes': 136, 'actual_bytes': 136})
    value['diverged']['state'] = states[changed['frame']]
    return value


def evidence():
    histories = [[0, 0] + [2] * 45 + [8] * 70, [0, 0] + [4] * 45 + [1] * 70]
    states = expected_states(histories, 110)
    peers = []
    for slot in range(2):
        channels = [{'id': index, 'sent': 40 if index == 3 else 0, 'received': 40 if index == 3 else 0,
                     'ordered': index != 3, 'negotiated': True, 'maxPacketLifeTime': 1, 'maxRetransmits': None} for index in (1, 2, 3)]
        peers.append({'slot': slot, 'page_index': slot, 'inputs': histories[slot], 'restores': 1, 'confirmed': 110, 'frame': 110,
                      'predicted_frame': 2, 'state': 'playing', 'room': 'ROOM01', 'session_id': '01' * 16, 'terminal_reason': 0, 'corrupt': False,
                      'uuid': f'00000000-0000-0000-0000-{slot + 1:012}', 'direct_rejected': 0,
                      'room_id': '00000000-0000-0000-0000-000000000001', 'failure': '',
                      'snapshots': {str(frame): state for frame, state in states.items()},
                      'rtc': {'channels': channels}, 'delayed': 25,
                      'scheduling': {'turns': 240, 'ticks_per_second': 60, 'max_gap_us': 50000,
                                     'max_gap_turns': 3, 'max_gap_transport_us': 50000,
                                     'confirmation_max_gap_us': 33334, 'confirmation_max_gap_turns': 2,
                                     'confirmed_frames': 110}})
    rounds = [{'room': room, 'peers': copy.deepcopy(peers), 'identity': [
        {'page_index': slot, 'room': room, 'room_id': f'00000000-0000-0000-0000-{index + 1:012}',
         'uuid': f'00000000-0000-0000-0000-{slot + 1:012}'} for slot in range(2)], 'teardown': [
        {'channels': 3 * (index + 1), 'channels_closed': 3 * (index + 1), 'connections': index + 1,
         'connections_closed': index + 1, 'ice_closed': index + 1, 'websockets': index + 1,
         'websockets_closed': index + 1} for _ in range(2)]} for index, room in enumerate(('ROOM01', 'ROOM02', 'ROOM03', 'ROOM04', 'ROOM05'))]
    for record in rounds:
        record['prediction'] = [{'page_index': page, 'frame': 2,
            'before': {'active': True, 'pending': 3, 'bytes': 300, 'released': 0, 'releases': 0, 'failure': ''},
            'after': {'active': False, 'pending': 0, 'bytes': 0, 'released': 3, 'releases': 1, 'failure': ''}} for page in range(2)]
    for index, record in enumerate(rounds):
        for peer in record['peers']:
            peer['room'] = record['room']
            peer['session_id'] = f'{index + 1:02}' * 16
            peer['room_id'] = f'00000000-0000-0000-0000-{index + 1:012}'
            peer['game_lifetime'] = index + 1
            peer['predicted_lifetime'] = index + 1
            for boundary in ('before', 'after'):
                record['prediction'][peer['page_index']][boundary].update(
                    {key: peer[key] for key in ('room', 'room_id', 'session_id', 'game_lifetime')})
        record['diagnostics'] = [diagnostic_download(), diagnostic_download()]
        if index == 0:
            record['diagnostics'][0]['report']['trace'] = trace_evidence(states, histories)
        for download in record['diagnostics']:
            download['before']['state'] = 'offline'
            download['after']['state'] = 'offline'
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
    rounds[0]['replay_download'] = replay_download(histories)
    rounds[0]['replay_capture'] = {'before': {'frame': 110, 'restores': 1}, 'frame': 110, 'code': 0, 'captured': True}
    initial = {'frame': 0, 'frames': 110, 'playing': False, 'message': 'Ready.', 'state': states[0]}
    viewer = {key: dict(initial) for key in ('initial', 'stepped', 'paused', 'restarted', 'rejected', 'completed', 'forward', 'backward')}
    viewer['forward'].update(frame=12, state=states[12])
    viewer['backward'].update(frame=6, state=states[6])
    viewer['stepped'].update(frame=1, state=states[1])
    viewer['paused'].update(frame=4, state=states[4])
    viewer['rejected']['message'] = 'Could not open replay (file code 1).'
    viewer['completed'].update(frame=110, state=rounds[0]['replay_download']['playback']['canonical'], message='Replay complete.')

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
        payloads.append((INPUT_HEADER + bytes.fromhex('04' * 16)
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
    return {'passed': True, 'corrupt': False, 'browser_instances': 2, 'errors': [], 'teardown': True, 'rounds': rounds, 'viewer': viewer,
            'diagnostic_viewer': diagnostic_viewer_evidence(rounds[0]['diagnostics'][0]['report']['trace'], histories)}


def corrupt_evidence():
    """The corrupt control evidence: the joiner corrupts its restored state and both peers restore."""
    changed = evidence()
    changed['corrupt'] = True
    changed['rounds'][0]['diagnostics'][0]['report'].pop('trace')
    changed['rounds'] = changed['rounds'][:1]
    peers = changed['rounds'][0]['peers']
    for peer in peers:
        peer['corrupt'] = peer['page_index'] == 1
    corrupt = next(peer for peer in peers if peer['page_index'] == 1)
    corrupt.update(state='failed', failure='Game stopped (18). Leave and create a new room.', terminal_reason=18)
    ordered = sorted(peers, key=lambda peer: peer['page_index'])
    changed['rounds'][0]['corrupt_control'] = {'corrupt_page': 1, 'desync_page': 1, 'desync_reason': 18,
                                               'restores': [peer['restores'] for peer in ordered]}
    return changed


def corrupt_snapshot(changed, page_index, frame='3'):
    peer = next(peer for peer in changed['rounds'][0]['peers'] if peer['page_index'] == page_index)
    peer['snapshots'][frame] = '00' + peer['snapshots'][frame][2:]
    return changed


class OnlineExampleEvidenceTests(unittest.TestCase):
    def test_diagnostic_playback_requires_all_captured_boundaries(self):
        trace = evidence()['rounds'][0]['diagnostics'][0]['report']['trace']
        report = {'code': 16, 'complete': True, 'failure': {},
                  'validated_states': sum(row['state_available'] for row in trace['frames']),
                  'advanced_frames': sum(bool(row['inputs']) for row in trace['frames'])}
        prefix = 'FORTRESS_DIAGNOSTIC_RESULT '
        line = prefix + json.dumps(report)
        self.assertEqual(validate_diagnostic_playback(line, trace), report)
        for field, invalid in [('code', 18), ('complete', False), ('failure', {'frame': 1}),
                               ('validated_states', 1), ('advanced_frames', 0), ('complete', 1), ('code', 16.0)]:
            changed = dict(report, **{field: invalid})
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_diagnostic_playback(prefix + json.dumps(changed), trace)
        for output in ('', line + '\n' + line):
            with self.assertRaises(ValueError):
                validate_diagnostic_playback(output, trace)


    def test_diagnostic_viewer_requires_actual_window_controls_and_rejects_corruption(self):
        source = evidence()
        trace = source['rounds'][0]['diagnostics'][0]['report']['trace']
        histories = [peer['inputs'] for peer in source['rounds'][0]['peers']]
        original = source['diagnostic_viewer']
        validate_diagnostic_viewer(original, trace, histories)
        final_frame = trace['frames'][-1]['frame'] + bool(trace['frames'][-1]['inputs'])
        validate_diagnostic_viewer(original, trace, [history[:final_frame] for history in histories])
        mutations = [('initial', 'rows_consumed', 1), ('stepped', 'validated_states', 0), ('restarted', 'game_frame', 1),
                     ('rejected', 'row_count', 0), ('completed', 'complete', False), ('completed', 'advanced_frames', True),
                     ('completed', 'seed', 'other'), ('diverged', 'failure', {}), ('diverged', 'playing', True),
                     ('stepped', 'game_frame', 999999), ('stepped', 'next_boundary', -1), ('stepped', 'complete', True),
                     ('stepped', 'failure', {'frame': 0}), ('diverged', 'rows_consumed', 0), ('diverged', 'validated_states', -1),
                     ('diverged', 'advanced_frames', -1), ('diverged', 'next_boundary', -1)]
        for label, field, invalid in mutations:
            changed = copy.deepcopy(original)
            changed[label]['status'][field] = invalid
            with self.subTest(label=label, field=field), self.assertRaises(ValueError):
                validate_diagnostic_viewer(changed, trace, histories)
        for field in ('frame', 'byte', 'expected_bytes', 'actual_bytes'):
            changed = copy.deepcopy(original)
            changed['diverged']['status']['failure'][field] = float(changed['diverged']['status']['failure'][field])
            with self.subTest(failure_field=field), self.assertRaises(ValueError):
                validate_diagnostic_viewer(changed, trace, histories)
        changed = copy.deepcopy(original)
        changed['diverged']['status']['failure']['frame'] = True
        with self.assertRaises(ValueError):
            validate_diagnostic_viewer(changed, trace, histories)
        for label in original:
            changed = copy.deepcopy(original)
            changed[label]['state'] = '00' * 136
            with self.subTest(label=label), self.assertRaises(ValueError):
                validate_diagnostic_viewer(changed, trace, histories)
        with self.assertRaises(ValueError):
            validate_diagnostic_viewer(None, trace, histories)

    def test_diagnostic_viewer_reproduces_applied_prediction_beyond_original_inputs(self):
        # Value: protects=speculative diagnostic playback; fails_when=sender history bounds predictions; why_new=existing traces are confirmed; seam=none
        source = evidence()
        histories = [peer['inputs'] for peer in source['rounds'][0]['peers']]
        trace = source['rounds'][0]['diagnostics'][0]['report']['trace']
        validate_diagnostic_viewer(source['diagnostic_viewer'], trace, histories)
        applied = copy.deepcopy(histories)
        applied[1][105:110] = [2] * 5
        trace = trace_evidence(expected_states(applied, 110), applied)
        for row in trace['frames'][105:]:
            row['inputs'][1]['status'] = 2
        viewer = diagnostic_viewer_evidence(trace, applied)
        for original in ([histories[0], histories[1][:105]], histories):
            validate_diagnostic_viewer(viewer, trace, original)
        report = copy.deepcopy(source['rounds'][0]['diagnostics'][0]['report'])
        report['trace'] = trace
        states = expected_states(histories, 110)
        with self.assertRaisesRegex(ValueError, 'differs from original confirmed history'):
            validate_trace_history(report, states, histories)
        report['confirmed_frame'] = 105
        validate_trace_history(report, states, histories)
        changed = copy.deepcopy(viewer)
        changed['completed']['state'] = source['diagnostic_viewer']['completed']['state']
        with self.assertRaisesRegex(ValueError, 'controls differ'):
            validate_diagnostic_viewer(changed, trace, histories)

    def test_viewer_receipt_requires_controls_and_original_gameplay(self):
        original = evidence()
        replay = original['rounds'][0]['replay_download']
        validate_viewer(original['viewer'], replay)
        for label, field, invalid in [('completed', 'state', '00' * 136), ('stepped', 'frame', 0),
                                      ('paused', 'playing', True), ('restarted', 'frame', 1), ('rejected', 'message', 'Ready.'),
                                      ('forward', 'frame', 11), ('backward', 'state', '00' * 136)]:
            changed = copy.deepcopy(original['viewer'])
            changed[label][field] = invalid
            with self.subTest(label=label, field=field), self.assertRaises(ValueError):
                validate_viewer(changed, replay)
        with self.assertRaises(ValueError):
            validate_viewer(None, replay)


    def test_replay_must_belong_to_the_witnessed_round_and_engine(self):
        for label in ('unrelated recording', 'wrong engine'):
            changed = evidence()
            if label == 'unrelated recording':
                changed['rounds'][0]['replay_download'] = replay_download([[0] * 117, [0] * 117])
            else:
                download = changed['rounds'][0]['replay_download']
                download['hex'] = bytes.fromhex(download['hex']).replace(b'4.3.0.stable 77dcf97d8', b'4.7.9.stable 000000000').hex()
            with self.subTest(label=label), self.assertRaises(ValueError):
                validate_result(changed)

    # Value: protects=downloaded replay equals original history; fails_when=export or player silently corrupts bytes; seam=none
    def test_replay_download_rejects_corruption_and_fake_playback(self):
        original = evidence()['rounds'][0]['replay_download']
        self.assertEqual(validate_replay_download(original), 110)
        for mutate in (lambda v: v.update(hex=v['hex'][:-2]),
                       lambda v: v.update(hex=v['hex'] + '00'),
                       lambda v: v.update(hex=v['hex'][:-2] + 'ff'),
                       lambda v: v.update(disabled_peer=False),
                       lambda v: v['peers'][0]['inputs'].__setitem__(4, 15),
                       lambda v: v['playback'].update(canonical='00' * 136),
                       lambda v: v['playback'].update(decode_code=False),
                       lambda v: v['after'].update(frame=110.0),
                       lambda v: v['after'].update(state='playing')):
            changed = copy.deepcopy(original)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                validate_replay_download(changed)

    # Value: protects=independent terminal-file evidence; fails_when=the final checksum or exact suffix is unchecked; seam=none
    # Value: protects=both-peer original delivery ordering; fails_when=gate is bypassed despite natural rollback; seam=receipt mutations
    def test_prediction_barrier_rejects_missing_or_fabricated_evidence(self):
        validate_result(evidence())
        mutations = [
            ('old-callback', lambda record: record['peers'][1].update(predicted_lifetime=0)),
            ('old-room', lambda record: record['prediction'][1]['before'].update(room='OLD')),
            ('old-session', lambda record: record['prediction'][1]['after'].update(session_id='ff' * 16)),
            ('old-lifetime', lambda record: record['prediction'][1]['after'].update(game_lifetime=99)),
            ('bool-lifetime', lambda record: record['prediction'][1]['before'].update(game_lifetime=True)),
            ('missing', lambda record: record.pop('prediction')),
            ('one-page', lambda record: record['prediction'].pop()),
            ('false-frame', lambda record: record['prediction'][1].update(frame=False)),
            ('early-frame', lambda record: record['prediction'][1].update(frame=1)),
            ('float-frame', lambda record: record['prediction'][1].update(frame=2.0)),
            ('no-prediction', lambda record: record['peers'][1].update(predicted_frame=-1)),
            ('bool-pending', lambda record: record['prediction'][1]['before'].update(pending=True)),
            ('zero-held', lambda record: record['prediction'][1]['before'].update(pending=0)),
            ('zero-bytes', lambda record: record['prediction'][1]['before'].update(bytes=0)),
            ('overflow', lambda record: record['prediction'][1]['before'].update(bytes=262145)),
            ('inactive', lambda record: record['prediction'][1]['before'].update(active=False)),
            ('active-int', lambda record: record['prediction'][1]['before'].update(active=1)),
            ('already-released', lambda record: record['prediction'][1]['before'].update(released=1)),
            ('release-omitted', lambda record: record['prediction'][1]['after'].update(releases=0)),
            ('release-duplicated', lambda record: record['prediction'][1]['after'].update(releases=2)),
            ('release-bool', lambda record: record['prediction'][1]['after'].update(releases=True)),
            ('lost-original', lambda record: record['prediction'][1]['after'].update(released=2)),
            ('failure', lambda record: record['prediction'][1]['after'].update(failure='capacity')),
        ]
        for name, mutate in mutations:
            with self.subTest(name=name):
                value = evidence()
                mutate(value['rounds'][0])
                with self.assertRaisesRegex(ValueError, 'online example prediction barrier'):
                    validate_result(value)

    def test_online_replay_terminal_boundary(self):
        original = evidence()['rounds'][0]['replay_download']
        raw = bytearray.fromhex(original['hex'])
        original['hex'] = raw.hex()
        self.assertEqual(validate_replay_download(original), 110)
        for suffix in (raw[:-1], raw + bytes(1), raw[:-1] + bytes([raw[-1] ^ 1])):
            changed = copy.deepcopy(original)
            changed['hex'] = suffix.hex()
            with self.subTest(suffix=suffix[-16:].hex()), self.assertRaises(ValueError):
                validate_replay_download(changed)

    def test_online_requires_actual_final_capture(self):
        original = evidence()
        validate_result(original)
        for mutate in (lambda v: v['rounds'][0].pop('replay_capture'),
                       lambda v: v['rounds'][0]['replay_capture'].update(code=False),
                       lambda v: v['rounds'][0]['replay_capture'].update(captured=False),
                       lambda v: v['rounds'][0]['replay_capture'].update(frame=109),
                       lambda v: v['rounds'][0]['replay_download'].update(
                           hex=v['rounds'][0]['replay_download']['hex'][:8] + '0500' + v['rounds'][0]['replay_download']['hex'][12:-32])):
            changed = copy.deepcopy(original)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                validate_result(changed)

    def test_online_replay_statuses_are_independently_checked(self):
        original = evidence()['rounds'][0]['replay_download']
        raw = bytes.fromhex(original['hex'])
        cursor = 24
        for _ in range(5):
            cursor += 1 + raw[cursor]
        for status in (0, 2, 3, 255):
            changed = copy.deepcopy(original)
            malformed = bytearray(raw)
            malformed[cursor + 2] = status
            changed['hex'] = malformed.hex()
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'player statuses'):
                validate_replay_download(changed)

    # Value: protects=bounded fault timing during slow downloads; fails_when=exports run live or advance stopped matches; why_new=CI reached289; seam=none
    def test_downloads_observe_only_a_frozen_offline_match(self):
        original = evidence()
        self.assertIs(validate_result(original), original)
        for boundary in ('before', 'after'):
            for state in ('playing', 'failed', None):
                changed = evidence()
                changed['rounds'][0]['diagnostics'][0][boundary]['state'] = state
                with self.subTest(boundary=boundary, state=state), self.assertRaisesRegex(ValueError, 'diagnostic export crossed offline boundary'):
                    validate_result(changed)
        for field, value in (('frame', 111), ('restores', 2)):
            changed = evidence()
            changed['rounds'][0]['diagnostics'][0]['after'][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'diagnostic export crossed offline boundary'):
                validate_result(changed)
        changed = evidence()
        changed['rounds'][0]['diagnostics'][0]['before']['frame'] = 109
        with self.assertRaisesRegex(ValueError, 'diagnostic export crossed offline boundary'):
            validate_result(changed)
        for downloads in ([], [diagnostic_download()], [diagnostic_download()] * 3):
            changed = evidence()
            changed['rounds'][0]['diagnostics'] = downloads
            with self.subTest(count=len(downloads)), self.assertRaisesRegex(ValueError, 'missing real diagnostic downloads'):
                validate_result(changed)

    # Value: protects=published host scheduling gaps; fails_when=a room omits or fakes the cadence; why_new=#147 needs the stall evidence
    def test_scheduling_summary_is_required_and_consistent(self):
        original = evidence()
        self.assertIs(validate_result(original), original)
        for label, mutate in (
                ('missing', lambda summary: summary.pop('max_gap_us')),
                ('empty', lambda summary: summary.clear()),
                ('not a dict', lambda summary: None),
                ('negative gap', lambda summary: summary.update(max_gap_us=-1)),
                ('no turns', lambda summary: summary.update(turns=0)),
                ('fractional turn', lambda summary: summary.update(turns=1.5)),
                ('inconsistent turns', lambda summary: summary.update(max_gap_turns=99)),
                ('inconsistent confirmation turns', lambda summary: summary.update(confirmation_max_gap_turns=99)),
                ('more confirmations than the room observed', lambda summary: summary.update(confirmed_frames=1000))):
            changed = evidence()
            summary = changed['rounds'][0]['peers'][0]['scheduling']
            if label == 'not a dict':
                changed['rounds'][0]['peers'][0]['scheduling'] = None
            else:
                mutate(summary)
            reasons = ('scheduling summary missing or malformed|disagrees with its nominal turn count'
                       '|claims more confirmations than the room observed')
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, reasons):
                validate_result(changed)

    # Value: protects=standalone runtime-only install; fails_when=missing licenses/files or overwrites; why_new=browser staging was handwritten; seam=none
    def test_clean_installer_copies_complete_runtime_and_licenses_without_repository_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / 'game'
            create_project(project)
            expected = {}
            for directory in ('addons/fortress_rollback', 'examples/offline', 'examples/online'):
                expected.update(inventory({directory: ROOT / directory}))
            expected.update(inventory({'LICENSE': ROOT / 'LICENSE'}))
            actual = inventory({'project': project})
            self.assertEqual(set(actual), {'project/' + name for name in expected} | {'project/project.godot', 'project/export_presets.cfg'})
            for name, value in expected.items():
                self.assertEqual(actual['project/' + name], value)
            self.assertNotIn('res://icon.svg', (project / 'project.godot').read_text())
            before = inventory({'project': project})
            with self.assertRaisesRegex(ValueError, 'empty directory'):
                create_project(project)
            self.assertEqual(inventory({'project': project}), before)
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                install_sdk(project, Path(temporary) / 'absent')
            self.assertFalse((project / 'addons/signal_fish').exists())

    def test_local_server_configuration_matches_the_online_application_and_has_no_external_ice(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            config = {'session': {}, 'turn': {}, 'security': {'allowed_apps': [{}]}}
            (source / 'config.example.json').write_text(json.dumps(config))
            result = server_config(source, 8080)
            self.assertEqual(result['port'], 8080)
            self.assertEqual(result['security']['allowed_apps'][0]['app_id'], 'fortress-live-webrtc')
            self.assertEqual(result['security']['allowed_apps'][0]['max_players_per_room'], 2)
            self.assertEqual(result['session']['ice_servers'], [])
            self.assertFalse(result['session']['enable_direct'])
            self.assertFalse(result['turn']['enabled'])
            for port in (True, 0, 65536):
                with self.subTest(port=port), self.assertRaises(ValueError):
                    server_config(source, port)

    def test_corruption_control_reaches_canonical_comparison_after_an_intended_desync(self):
        changed = corrupt_evidence()
        corrupt_snapshot(changed, 1)
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
            failed['scheduling'] = dict(failed['scheduling'], confirmed_frames=108)
            peer = early['rounds'][0]['peers'][slot]
            peer.update(inputs=peer['inputs'][:108], frame=107, confirmed=confirmed)
            peer['scheduling'] = dict(peer['scheduling'], confirmed_frames=confirmed + 1)
            for peer in early['rounds'][0]['peers']:
                peer['snapshots'] = {frame: state for frame, state in peer['snapshots'].items() if int(frame) < 107}
            with self.subTest(slot=slot, confirmed=confirmed), self.assertRaisesRegex(ValueError, message):
                validate_result(early, corrupt=True)
        clean = evidence()
        clean['rounds'][0]['peers'][1].update(state='failed', failure='desync', terminal_reason=18)
        with self.assertRaisesRegex(ValueError, 'rollback or confirmation missing'):
            validate_result(clean)

    # Value: cleared terminal lobby fields retain frozen prediction identity; foreign rooms still fail before canonical validation.
    def test_prediction_receipt_survives_cleared_failed_room_without_accepting_foreign_identity(self):
        changed = corrupt_snapshot(corrupt_evidence(), 1)
        failed = changed['rounds'][0]['peers'][1]
        failed.update(room='', room_id='')
        with self.assertRaisesRegex(ValueError, 'canonical prefix mismatch at frame 3'):
            validate_result(changed, corrupt=True)
        for key, foreign in (('room', 'FOREIGN'), ('room_id', '00000000-0000-0000-0000-000000000099'),
                             ('session_id', 'ff' * 16), ('game_lifetime', 99)):
            forged = copy.deepcopy(changed)
            for boundary in ('before', 'after'):
                forged['rounds'][0]['prediction'][1][boundary][key] = foreign
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'prediction barrier'):
                validate_result(forged, corrupt=True)
        foreign_live = copy.deepcopy(changed)
        foreign_live['rounds'][0]['peers'][1]['room'] = 'FOREIGN'
        with self.assertRaisesRegex(ValueError, 'prediction barrier'):
            validate_result(foreign_live, corrupt=True)

    def test_corrupt_control_requires_the_restore_it_waited_for_and_the_desync_reason(self):
        corrupt_snapshot(corrupt_evidence(), 1)
        # The control that removes the corruption keeps every canonical prefix and must fail.
        uncorrupted = corrupt_evidence()
        with self.assertRaisesRegex(ValueError, 'corruption did not reach the canonical state'):
            validate_result(uncorrupted, corrupt=True)
        # The control that removes the desync detection leaves the peer playing and must fail.
        undetected = corrupt_evidence()
        corrupt_snapshot(undetected, 1)
        undetected['rounds'][0]['peers'][1].update(state='playing', terminal_reason=0)
        with self.assertRaisesRegex(ValueError, 'rollback or confirmation missing'):
            validate_result(undetected, corrupt=True)
        # The healthy peer keeps its own confirmed history.
        unhealthy = corrupt_evidence()
        corrupt_snapshot(unhealthy, 1)
        corrupt_snapshot(unhealthy, 0)
        with self.assertRaisesRegex(ValueError, 'healthy peer lost its canonical history'):
            validate_result(unhealthy, corrupt=True)
        mutations = [('corrupt_page', 0), ('restores', [1, 0]),
                     ('restores', [2, 1]), ('restores', '11')]
        for key, value in mutations:
            broken = corrupt_evidence()
            corrupt_snapshot(broken, 1)
            broken['rounds'][0]['corrupt_control'][key] = value
            with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, 'corrupt control evidence missing'):
                validate_result(broken, corrupt=True)
        for key in ('corrupt_control', 'corrupt_page', 'restores'):
            broken = corrupt_evidence()
            corrupt_snapshot(broken, 1)
            if key == 'corrupt_control':
                broken['rounds'][0].pop(key)
            else:
                broken['rounds'][0]['corrupt_control'].pop(key)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'corrupt control evidence missing'):
                validate_result(broken, corrupt=True)
        both = corrupt_evidence()
        corrupt_snapshot(both, 1)
        both['rounds'][0]['peers'][0]['corrupt'] = True
        with self.assertRaisesRegex(ValueError, 'corrupt control evidence missing'):
            validate_result(both, corrupt=True)
        # The control that removes the desync detection leaves the corrupted peer running and must fail.
        undetected = corrupt_evidence()
        corrupt_snapshot(undetected, 1)
        undetected['rounds'][0]['peers'][1].update(state='playing', failure='', terminal_reason=0)
        with self.assertRaisesRegex(ValueError, 'corrupt control observed no desync'):
            validate_result(undetected, corrupt=True)
        lost = corrupt_evidence()
        corrupt_snapshot(lost, 1)
        lost['rounds'][0]['peers'][0].update(terminal_reason=23)
        with self.assertRaisesRegex(ValueError, 'corrupt control lost the healthy peer'):
            validate_result(lost, corrupt=True)

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
        changed = corrupt_evidence()
        corrupt_snapshot(changed, 1)
        with self.assertRaisesRegex(ValueError, 'canonical prefix mismatch at frame 3'):
            validate_result(changed, corrupt=True)
        changed['rounds'][0]['peers'][1]['rtc']['channels'][2]['maxPacketLifeTime'] = 0
        with self.assertRaisesRegex(ValueError, 'physical unreliable channel contract missing'):
            validate_result(changed, corrupt=True)
        changed = corrupt_evidence()
        corrupt_snapshot(changed, 1)
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
                for boundary in ('before', 'after'):
                    changed['rounds'][4]['prediction'][peer['page_index']][boundary][field] = peer[field]
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
            for boundary in ('before', 'after'):
                changed['rounds'][4]['prediction'][peer['page_index']][boundary]['room_id'] = peer['room_id']
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


class OnlineProbeStepTimingTests(unittest.TestCase):
    # Value: protects=the elapsed time of every online probe step; fails_when=a step runs without a duration; seam=source shape
    def test_every_online_probe_step_records_its_elapsed_time(self):
        source = inspect.getsource(run_online)
        steps, unmeasured = measured_steps(source)
        self.assertEqual(unmeasured, [])
        self.assertEqual(steps, ONLINE_STEPS)
        self.assertTrue(publishes_measured_steps(source))
        # The mutant drops the duration recording, so no step covers the work it runs.
        mutant = source.replace('timings.measure(', 'unmeasured.measure(')
        mutant_steps, mutant_unmeasured = measured_steps(mutant)
        self.assertEqual(mutant_steps, [])
        self.assertNotEqual(mutant_unmeasured, [])

    # Value: protects=the rejected run names the step that failed; fails_when=a failed step loses its measurement; seam=StepTimings
    def test_a_failing_step_still_reports_its_elapsed_time(self):
        timings = StepTimings()
        with self.assertRaises(RuntimeError) as caught:
            with timings.measure('install'):
                raise RuntimeError('the installer failed')
        error = caught.exception
        self.assertEqual(error.failed_step, 'install')
        self.assertIn('online example step install failed after', str(error))
        self.assertIn('the installer failed', str(error))
        self.assertEqual(len(error.step_durations), 1)
        self.assertEqual(error.step_durations[0]['step'], 'install')
        self.assertIs(error.step_durations[0]['failed'], True)
        self.assertGreaterEqual(error.step_durations[0]['elapsed_us'], 0)
        self.assertEqual(timings.failed()['step'], 'install')
        self.assertEqual(json.loads(json.dumps(timings.summary())), timings.summary())
        with timings.measure('export'):
            pass
        self.assertEqual([step['step'] for step in timings.summary()], ['install', 'export'])
        self.assertIs(timings.summary()[1]['failed'], False)

    # Value: protects=the browser sub-step durations in the receipt; fails_when=a duration is missing or malformed; seam=browser result
    def test_the_browser_sub_step_durations_join_the_receipt_steps(self):
        self.assertEqual(browser_step_durations({'timings': {'replay_import_us': 12, 'replay_playback_us': 34,
                                                             'diagnostic_viewer_us': 5}}),
                         [('browser.diagnostic_viewer', 5), ('browser.replay_import', 12), ('browser.replay_playback', 34)])
        for value in ({}, {'timings': None}, {'timings': []}, {'timings': {'replay_import_us': -1}},
                      {'timings': {'replay_import_us': 1.5}}, {'timings': {'replay_import_us': True}},
                      {'timings': {'replay_import_us': '12'}}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                browser_step_durations(value)

    # Value: protects=pure JSON on the browser stdout; fails_when=the probe cannot parse the browser result; seam=script source
    def test_the_browser_script_prints_one_json_result_and_names_its_sub_steps(self):
        source = (Path(__file__).resolve().parent / 'browser' / 'online.cjs').read_text(encoding='utf-8')
        printed = [line for line in source.splitlines() if 'console.log(' in line]
        self.assertEqual(len(printed), 1)
        self.assertIn('JSON.stringify(', printed[0])
        self.assertIn('timings', printed[0])
        for name in ('replay_import_us', 'replay_playback_us', 'diagnostic_viewer_us'):
            self.assertIn(name, source)
        self.assertIn('process.hrtime.bigint()', source)
