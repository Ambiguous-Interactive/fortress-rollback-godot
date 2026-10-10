"""Strict version-one scenario and actual runtime trace boundaries."""
import re
import struct

REVISION = 'f13cd5c0f2815926785a395947e18da0dbea0dd8'


def fields(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected.split()):
        raise ValueError(f'{label}: unknown or missing fields')


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{label}: invalid integer')


def hex_bytes(value, length, label):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{' + str(length * 2) + '}', value):
        raise ValueError(f'{label}: invalid canonical hex')
    return bytes.fromhex(value)


def checksum(data):
    low = 14695981039346656037
    for byte in data:
        low = ((low ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return f'{low ^ ((1 << 64) - 1):016x}{low:016x}'


def validate_scenario(value):
    fields(value, 'format upstream_revision players input_width check_distance input_delay operations', 'scenario')
    integer(value['format'], 1, 1, 'scenario version')
    if value['upstream_revision'] != REVISION:
        raise ValueError('scenario: stale upstream revision')
    integer(value['players'], 2, 8, 'players')
    integer(value['input_width'], 4, 4, 'input width')
    integer(value['check_distance'], 0, 7, 'check distance')
    integer(value['input_delay'], 0, 7, 'input delay')
    operations = value['operations']
    if not isinstance(operations, list) or not 1 <= len(operations) <= 10000:
        raise ValueError('scenario: empty or oversized operations')
    for operation in operations:
        if not isinstance(operation, dict):
            raise ValueError('scenario: invalid operation')
        kind = operation.get('kind')
        if kind == 'input':
            fields(operation, 'kind player bytes', 'input')
            integer(operation['player'], 0, 255, 'player handle')
            hex_bytes(operation['bytes'], 4, 'input')
        elif kind in ('advance', 'events'):
            fields(operation, 'kind', kind)
        else:
            raise ValueError('scenario: unknown operation')
    return value


def state(value, players, frame_key='frame', bytes_key='bytes'):
    integer(value[frame_key], 0, 2147483647, 'state frame')
    data = hex_bytes(value[bytes_key], 4 * (players + 1), 'state bytes')
    if struct.unpack_from('<i', data)[0] != value[frame_key]:
        raise ValueError('state: frame differs from bytes')
    hex_bytes(value['checksum'], 16, 'checksum')
    if value['checksum'] != checksum(data):
        raise ValueError('state: checksum differs from bytes')
    return data


def validate_trace(value, scenario):
    validate_scenario(scenario)
    fields(value, 'format upstream_revision scenario operations final_state', 'trace')
    validate_scenario(value['scenario'])
    integer(value['format'], 1, 1, 'trace version')
    if value['upstream_revision'] != REVISION or value['scenario'] != scenario:
        raise ValueError('trace: stale revision or mismatched scenario')
    operations = value['operations']
    if not isinstance(operations, list) or len(operations) != len(scenario['operations']):
        raise ValueError('trace: missing or extra operations')
    frame = 0
    game_frame = 0
    game_bytes = bytes(4 * (scenario['players'] + 1))
    snapshots = {}
    for index, (operation, source) in enumerate(zip(operations, scenario['operations'])):
        fields(operation, 'index kind result error frame_before frame_after confirmed_frame requests events', 'operation')
        integer(operation['index'], index, index, 'operation index')
        if operation['kind'] != source['kind'] or operation['frame_before'] != frame:
            raise ValueError('trace: operation identity or frame chain mismatch')
        integer(operation['frame_before'], 0, 2147483647, 'frame before')
        integer(operation['frame_after'], 0, 2147483647, 'frame after')
        if operation['confirmed_frame'] is not None:
            raise ValueError('trace: confirmation is unavailable in sync-test API')
        result = operation['result']
        if result not in ('ok', 'error'):
            raise ValueError('trace: unknown result')
        if (result == 'ok' and operation['error'] is not None) or (
                result == 'error' and (not isinstance(operation['error'], str) or not operation['error'])):
            raise ValueError('trace: result contradicts error')
        requests, events = operation['requests'], operation['events']
        if not isinstance(requests, list) or not isinstance(events, list):
            raise ValueError('trace: invalid request/event list')
        # The public sync-test event drain is empty in this pinned release.
        if events or (source['kind'] != 'advance' and requests) or (result == 'error' and requests):
            raise ValueError('trace: unexpected request/event payload')
        expected_after = frame + int(source['kind'] == 'advance' and result == 'ok')
        if operation['frame_after'] != expected_after:
            raise ValueError('trace: impossible exposed frame transition')
        if source['kind'] == 'advance' and result == 'ok' and not requests:
            raise ValueError('trace: successful advance missing requests')
        for request in requests:
            fields(request, 'kind frame state_bytes checksum inputs', 'request')
            kind = request['kind']
            integer(request['frame'], 0, 2147483646, 'request frame')
            inputs = request['inputs']
            if not isinstance(inputs, list):
                raise ValueError('request: invalid inputs')
            if kind in ('save', 'load'):
                if inputs:
                    raise ValueError('request: snapshot has inputs')
                data = state(request, scenario['players'], bytes_key='state_bytes')
                if kind == 'save':
                    if request['frame'] != game_frame or data != game_bytes:
                        raise ValueError('request: save state differs from current game')
                    snapshots[game_frame] = data
                else:
                    if snapshots.get(request['frame']) != data:
                        raise ValueError('request: load lacks matching saved state')
                    game_frame, game_bytes = request['frame'], data
            elif kind == 'advance':
                if request['frame'] != game_frame or len(inputs) != scenario['players']:
                    raise ValueError('request: advance frame or input count mismatch')
                totals = list(struct.unpack('<' + 'I' * scenario['players'], game_bytes[4:]))
                for player, item in enumerate(inputs):
                    fields(item, 'player bytes status', 'frame input')
                    integer(item['player'], player, player, 'input slot')
                    if item['status'] not in ('confirmed', 'predicted', 'disconnected'):
                        raise ValueError('request: unknown input status')
                    incoming = struct.unpack('<I', hex_bytes(item['bytes'], 4, 'frame input'))[0]
                    totals[player] = (totals[player] + incoming) & 0xffffffff
                game_frame += 1
                game_bytes = struct.pack('<i' + 'I' * scenario['players'], game_frame, *totals)
                after = dict(request, frame=game_frame)
                if state(after, scenario['players'], bytes_key='state_bytes') != game_bytes:
                    raise ValueError('request: advance canonical state mismatch')
            else:
                raise ValueError('request: unknown kind')
        if game_frame != expected_after:
            raise ValueError('trace: requests do not reach exposed frame')
        frame = expected_after
    fields(value['final_state'], 'frame bytes checksum', 'final state')
    if state(value['final_state'], scenario['players']) != game_bytes or value['final_state']['frame'] != frame:
        raise ValueError('trace: final state mismatch')
    return value
