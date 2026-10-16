"""Validate public diagnostic downloads against independent browser callback observations."""
import json
import re

COUNTERS = {'rollback_count', 'resimulated_frames', 'advanced_frames', 'prediction_stalls', 'last_rollback_depth', 'max_rollback_depth'}
PEER_FIELDS = {'index', 'state', 'pending_frames', 'last_received_frame', 'last_acked_frame', 'round_trip_time_ms', 'average_frame_advantage'}
REPORT_FIELDS = {'schema', 'engine', 'transport', 'current_frame', 'confirmed_frame', 'lifecycle', 'reason', 'failure_frame',
                 'pending_rollback_frame', 'frames_ahead', 'statistics', 'peers', 'failure'}


def integer(value, lower=0, upper=2**63 - 1):
    if type(value) is not int or not lower <= value <= upper:
        raise ValueError('diagnostic integer outside domain')


def event(value, peers, depth=0):
    if not isinstance(value, dict) or value.keys() - {'kind', 'frame', 'reason', 'field', 'peer_index', 'local_checksum', 'remote_checksum', 'terminal_cause'}:
        raise ValueError('diagnostic event contains unapproved fields')
    if not value:
        return
    if not isinstance(value.get('kind'), str) or not 1 <= len(value['kind']) <= 64:
        raise ValueError('diagnostic event kind missing')
    if 'field' in value and (not isinstance(value['field'], str) or not 1 <= len(value['field']) <= 64):
        raise ValueError('diagnostic mismatch field invalid')
    if 'frame' in value:
        integer(value['frame'], -1, 2**31 - 1)
    if 'peer_index' in value:
        integer(value['peer_index'], -1, peers - 1)
    if 'reason' in value and not (type(value['reason']) is int or isinstance(value['reason'], str) and len(value['reason']) <= 64):
        raise ValueError('diagnostic event reason invalid')
    for field in ('local_checksum', 'remote_checksum'):
        if field in value and (not isinstance(value[field], str) or len(value[field]) != 32
                               or any(char not in '0123456789abcdef' for char in value[field])):
            raise ValueError('diagnostic checksum invalid')
    if 'terminal_cause' in value:
        if depth >= 2 or not isinstance(value['terminal_cause'], list) or len(value['terminal_cause']) > peers + 1:
            raise ValueError('diagnostic terminal causes exceed bounds')
        for cause in value['terminal_cause']:
            event(cause, peers, depth + 1)


def validate_download(value, trace_enabled=False):
    if not isinstance(value, dict) or value.get('filename') != 'fortress-diagnostics.json':
        raise ValueError('missing real diagnostic download')
    report = value.get('report')
    fields = REPORT_FIELDS | ({'trace'} if trace_enabled else set())
    if not isinstance(report, dict) or report.keys() != fields or report['schema'] != 'fortress-peer-diagnostics-v1':
        raise ValueError('diagnostic schema or privacy fields differ')
    if len(json.dumps(report).encode('utf-8')) > 32768 + (198752 if trace_enabled else 0):
        raise ValueError('diagnostic download exceeds byte bound')
    if not isinstance(report['engine'], str) or not 1 <= len(report['engine']) <= 128:
        raise ValueError('diagnostic engine identity missing')
    for field in ('current_frame', 'confirmed_frame', 'failure_frame', 'pending_rollback_frame', 'frames_ahead'):
        integer(report[field], -2**31, 2**31 - 1)
    for field in ('lifecycle', 'reason'):
        integer(report[field], 0, 255)
    counts = report['statistics']
    if not isinstance(counts, dict) or counts.keys() != COUNTERS:
        raise ValueError('diagnostic counters missing')
    for count in counts.values():
        integer(count)
    if counts['advanced_frames'] != report['current_frame'] or counts['last_rollback_depth'] > counts['max_rollback_depth']:
        raise ValueError('diagnostic completed work inconsistent')
    peers = report['peers']
    if not isinstance(peers, list) or not 1 <= len(peers) <= 7:
        raise ValueError('diagnostic peer inventory missing')
    for index, peer in enumerate(peers):
        if not isinstance(peer, dict) or peer.keys() != PEER_FIELDS or peer['index'] != index:
            raise ValueError('diagnostic peer privacy fields differ')
        if peer['state'] not in ('initializing', 'synchronizing', 'running', 'terminated', 'failed'):
            raise ValueError('diagnostic peer state invalid')
        integer(peer['index'], 0, len(peers) - 1)
        for field in PEER_FIELDS - {'index', 'state'}:
            integer(peer[field], -2**31)
    transport = report['transport']
    if not isinstance(transport, dict) or transport.keys() != {'relay_links', 'pending_packets', 'pending_bytes'}:
        raise ValueError('diagnostic transport privacy fields differ')
    for count in transport.values():
        integer(count)
    event(report['failure'], len(peers))
    before, after = value.get('before'), value.get('after')
    if not isinstance(before, dict) or not isinstance(after, dict) or after.get('storage_calls') != 0:
        raise ValueError('diagnostic export used unavailable browser storage')
    integer(after.get('storage_calls'))
    for observation in (before, after):
        integer(observation.get('restores'))
        integer(observation.get('frame'))
    if not before['restores'] <= counts['rollback_count'] <= after['restores']:
        raise ValueError('diagnostic rollback count differs from real game callbacks')
    if not before['frame'] <= report['current_frame'] <= after['frame']:
        raise ValueError('diagnostic frame differs from game observation')
    if trace_enabled:
        validate_trace(report['trace'], report['current_frame'])


def game_checksum(state):
    lanes = []
    for lane in range(4):
        value = 2166136261 + lane
        for byte in bytes.fromhex(state):
            value = ((value ^ byte) * 16777619) & 0xffffffff
        lanes.append(value.to_bytes(4, 'little'))
    return b''.join(lanes).hex()


def validate_trace(trace, current_frame):
    fields = {'schema', 'seed', 'application_version', 'replay_command', 'max_frames', 'max_payload_bytes',
              'max_export_bytes', 'retained_payload_bytes', 'first_divergence', 'frames'}
    if (not isinstance(trace, dict) or trace.keys() != fields or trace['schema'] != 'fortress-canonical-trace-v1'
            or trace['seed'] != '1701' or trace['application_version'] != 'fortress-online-integer-v1'
            or trace['replay_command'] != '' or trace['first_divergence'] != {}):
        raise ValueError('online trace schema or metadata differs')
    for field, expected in [('max_frames', 120), ('max_payload_bytes', 18480), ('max_export_bytes', 198752)]:
        integer(trace[field], expected, expected)
    frames = trace['frames']
    if not isinstance(frames, list) or not frames or len(frames) != min(current_frame, 120):
        raise ValueError('online trace window missing or unbounded')
    last, payload = -1, 0
    for row in frames:
        if not isinstance(row, dict) or row.keys() != {'frame', 'state', 'state_available', 'checksum', 'inputs'}:
            raise ValueError('online trace row privacy fields differ')
        expected_frame = max(0, current_frame - 120) if last < 0 else last + 1
        integer(row['frame'], expected_frame, expected_frame)
        last = row['frame']
        if (row['state_available'] is not True or not isinstance(row['state'], str)
                or not re.fullmatch('[0-9a-f]{272}', row['state']) or row['checksum'] != game_checksum(row['state'])):
            raise ValueError('online trace canonical snapshot or checksum invalid')
        inputs = row['inputs']
        if not isinstance(inputs, list) or len(inputs) != 2:
            raise ValueError('online trace applied inputs missing')
        for player, sample in enumerate(inputs):
            if not isinstance(sample, dict) or sample.keys() != {'player', 'bytes', 'status'}:
                raise ValueError('online trace input privacy fields differ')
            integer(sample['player'], player, player)
            integer(sample['status'], 1, 2)
            if not isinstance(sample['bytes'], str) or not re.fullmatch('0[0-9a-f]', sample['bytes']):
                raise ValueError('online trace input bytes invalid')
        payload += 154
    integer(trace['retained_payload_bytes'], payload, payload)
    if len(json.dumps(trace, separators=(',', ':')).encode('utf-8')) > trace['max_export_bytes']:
        raise ValueError('online trace exceeds compact export bound')


def validate_trace_history(report, expected, histories):
    limit = min(report['confirmed_frame'], report['current_frame'], min(map(len, histories)))
    if report['pending_rollback_frame'] >= 0:
        limit = min(limit, report['pending_rollback_frame'])
    compared = 0
    for row in report['trace']['frames']:
        frame = row['frame']
        if frame >= limit:
            continue
        if row['state'] != expected[frame] or any(sample['bytes'] != bytes([histories[player][frame]]).hex()
                for player, sample in enumerate(row['inputs'])):
            raise ValueError('online trace differs from original confirmed history')
        compared += 1
    if compared < 50:
        raise ValueError('online trace confirmed history coverage incomplete')
