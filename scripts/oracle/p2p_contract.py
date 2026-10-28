"""Strict multiplayer observations and independent submitted-input canonical prefixes."""
from copy import deepcopy
import p2p_lifecycle as lifecycle
from contract import fields, integer, hex_bytes, checksum, initial_game_state, advance_game_state

REVISION = 'd124c89080004d96971a629bb0427056ee1805e3'
# Source delay refusals and the matching production Godot codes.
DELAY_ERRORS = {'InputDelayDecreaseUnsupported': 'UNSUPPORTED', 'FrameDelayTooLarge': 'INVALID_CONFIGURATION',
                'ConfigValueOutOfRange': 'INVALID_CONFIGURATION'}


def godot_max_delay(max_prediction):
    """FortressPeerSession.max_input_delay for the oracle's 128-slot queues."""
    return (128 - 2 * max_prediction - 2) // 2


def comparable_delay(delay, max_prediction):
    """Upstream accepts up to 127 - max_prediction; Godot's peer bound is lower. Only values outside that band compare."""
    return delay <= godot_max_delay(max_prediction) or 127 - max_prediction < delay <= 1000


def expected_delay_error(current, delay, max_prediction):
    if delay > godot_max_delay(max_prediction):
        return 'INVALID_CONFIGURATION'
    return 'UNSUPPORTED' if delay < current else None


def validate_scenario(value):
    if type(value) is not dict:
        raise ValueError('p2p scenario: invalid object')
    fields(value, 'format players input_delay max_prediction operations' + (' lifecycle' if 'lifecycle' in value else ''), 'p2p scenario')
    integer(value['format'], 1, 1, 'format')
    integer(value['players'], 2, 8, 'players')
    integer(value['input_delay'], 0, 2, 'delay')
    integer(value['max_prediction'], 2, 8, 'prediction')
    if 'lifecycle' in value:
        lifecycle.settings(value['lifecycle'], value['players'])
    if type(value['operations']) is not list or not 1 <= len(value['operations']) <= 10000:
        raise ValueError('operation inventory')
    previous = 0; stepped = set(); addressed = None
    for op in value['operations']:
        if type(op) is not dict or type(op.get('kind')) is not str:
            raise ValueError('operation kind')
        kind = op['kind']
        fields(op, {'step': 'kind peer now_us bytes', 'poll': 'kind peer now_us', 'deliver': 'kind packet now_us',
                    'delay': 'kind peer delay'}.get(kind, ''), 'operation')
        if kind == 'delay':
            # A delay change reuses the previous operation's clock; Godot's API takes no time.
            integer(op['peer'], 0, value['players'] - 1, 'peer'); integer(op['delay'], 0, 1000, 'delay change')
            if op['peer'] not in stepped:
                raise ValueError('delay change precedes first step')
            # Source time is shared and Godot's is per peer; they agree after a step/poll/delay on this peer.
            if addressed != op['peer']:
                raise ValueError('delay change must follow a step, poll or delay on its peer')
            if not comparable_delay(op['delay'], value['max_prediction']):
                raise ValueError('delay change outside comparable profile')
            continue
        integer(op['now_us'], previous, 10000000, 'time'); previous = op['now_us']
        if kind == 'deliver':
            integer(op['packet'], 0, 100000, 'packet')
        elif kind in {'step', 'poll'}:
            integer(op['peer'], 0, value['players'] - 1, 'peer')
            if kind == 'step':
                hex_bytes(op['bytes'], 4, 'input'); stepped.add(op['peer'])
        else:
            raise ValueError('unknown kind')
        addressed = op.get('peer')
    return value


def packet(value, players, source):
    fields(value, 'id from to semantic raw' if source else 'id from to semantic', 'packet')
    integer(value['id'], 0, 100000, 'packet id')
    for key in ('from', 'to'):
        integer(value[key], 0, players - 1, key)
    if value['from'] == value['to']:
        raise ValueError('self packet')
    body = value['semantic']
    if type(body) is not dict or type(body.get('kind')) is not str:
        raise ValueError('semantic packet')
    if body['kind'] in {'quality_report', 'quality_reply', 'checksum_report', 'keep_alive', 'goodbye'}:
        if source:
            _raw_header(value['raw'])
        lifecycle.control(value, source)
        return
    fields(body, 'kind ack_frame' if body['kind'] == 'input_ack' else 'kind start_frame ack_frame statuses players frames', 'semantic body')
    integer(body['ack_frame'], -1, 10000, 'ack')
    if body['kind'] == 'input':
        integer(body['start_frame'], 0, 10000, 'start')
        if type(body['frames']) is not list or not 1 <= len(body['frames']) <= 128:
            raise ValueError('frames')
        for data in body['frames']:
            hex_bytes(data, 4, 'frame input')
        if type(body['players']) is not list or len(body['players']) != 1:
            raise ValueError('sender players')
        integer(body['players'][0], value['from'], value['from'], 'sender slot')
        if type(body['statuses']) is not list or len(body['statuses']) != players:
            raise ValueError('status inventory')
        for status in body['statuses']:
            fields(status, 'disconnected epoch last_frame', 'status')
            if type(status['disconnected']) is not bool or status['disconnected']:
                raise ValueError('disconnected outside scoped scenario')
            integer(status['epoch'], 0, 0, 'epoch')
            integer(status['last_frame'], -1, 10000, 'last frame')
    elif body['kind'] != 'input_ack':
        raise ValueError('unsupported packet')
    if source:
        raw = value['raw']; _raw_header(raw)
        kind = 'Input' if body['kind'] == 'input' else 'InputAck'
        fields(raw['body'], kind, 'raw body')
        raw_body = raw['body'][kind]
        fields(raw_body, 'ack_frame start_frame peer_connect_status bytes' if kind == 'Input' else 'ack_frame', 'raw input')
        integer(raw_body['ack_frame'], -1, 10000, 'raw ack')
        if raw_body['ack_frame'] != body['ack_frame']:
            raise ValueError('raw semantic ack')
        if kind == 'Input':
            integer(raw_body['start_frame'], 0, 10000, 'raw start')
            if raw_body['start_frame'] != body['start_frame'] or raw_body['peer_connect_status'] != body['statuses']:
                raise ValueError('raw semantic fields')
            # Independently validate nested raw statuses before Python equality.
            alias = dict(value, semantic=dict(body, statuses=raw_body['peer_connect_status']))
            packet({k: v for k, v in alias.items() if k != 'raw'}, players, False)
            if type(raw_body['bytes']) is not list or not 1 <= len(raw_body['bytes']) <= 4096:
                raise ValueError('compressed bytes')
            for byte in raw_body['bytes']:
                integer(byte, 0, 255, 'compressed byte')


def _raw_header(raw):
    fields(raw, 'header body', 'raw packet')
    header = raw['header']; fields(header, 'conn_id flags protocol_version sentinel', 'header')
    integer(header['conn_id'], 1, 4294967295, 'connection')
    integer(header['flags'], 0, 0, 'flags'); integer(header['protocol_version'], 2, 2, 'protocol version')
    if type(header['sentinel']) is not list or len(header['sentinel']) != 2:
        raise ValueError('sentinel')
    for actual, expected in zip(header['sentinel'], [245, 82]):
        integer(actual, expected, expected, 'sentinel byte')


def validate(value, scenario, source=False):
    validate_scenario(scenario)
    fields(value, 'format complete upstream_revision scenario records packets', 'p2p trace')
    integer(value['format'], 1, 1, 'trace format')
    if value['complete'] is not True or value['upstream_revision'] != REVISION:
        raise ValueError('incomplete/revision')
    validate_scenario(value['scenario'])
    if value['scenario'] != scenario:
        raise ValueError('embedded scenario mismatch')
    if type(value['records']) is not list or len(value['records']) != len(scenario['operations']):
        raise ValueError('record inventory')
    if type(value['packets']) is not list or len(value['packets']) > 100000:
        raise ValueError('packet inventory')
    for index, outgoing in enumerate(value['packets']):
        packet(outgoing, scenario['players'], source)
        if 'lifecycle' not in scenario and outgoing['semantic']['kind'] not in {'input', 'input_ack'}:
            raise ValueError('lifecycle packet outside explicit profile')
        if outgoing['id'] != index:
            raise ValueError('packet position')
    states = [initial_game_state(scenario['players'], 2) for _ in range(scenario['players'])]
    divergent = scenario.get('lifecycle', {}).get('divergent_peer', -1)
    if divergent >= 0:
        states[divergent] = states[divergent][:4] + (1).to_bytes(4, 'little') + states[divergent][8:]
    snapshots = [{} for _ in states]; samples = [{} for _ in states]; next_packet = 0
    delays = [scenario['input_delay']] * len(states); scheduled = [-1] * len(states)
    for index, record in enumerate(value['records']):
        fields(record, 'index peer frame_before frame_after confirmed_frame error requests events outgoing state'
               + ('' if source else ' extension_events') + (' metrics pre_state pre_confirmed' if 'lifecycle' in scenario else ''), 'record')
        integer(record['index'], index, index, 'record index')
        op = scenario['operations'][index]
        peer = op.get('peer')
        if op['kind'] == 'deliver':
            if op['packet'] >= next_packet:
                raise ValueError('delivery precedes observed packet')
            peer = value['packets'][op['packet']]['to']
        integer(record['peer'], peer, peer, 'record peer')
        for key in ('frame_before', 'frame_after'):
            integer(record[key], 0, 10000, key)
        integer(record['confirmed_frame'], -1, 10000, 'confirmed frame')
        if record['frame_before'] != int.from_bytes(states[peer][:4], 'little'):
            raise ValueError('game/session before frame')
        if op['kind'] == 'step':
            frame = record['frame_before'] + delays[peer]
            samples[peer].setdefault(frame, op['bytes']); scheduled[peer] = max(scheduled[peer], frame)
            if samples[peer][frame] != op['bytes']:
                raise ValueError('changing stalled local sample')
        if op['kind'] == 'delay':
            allowed = set(DELAY_ERRORS) if source else set(DELAY_ERRORS.values())
            if record['error'] is not None and (type(record['error']) is not str or record['error'] not in allowed):
                raise ValueError(f'operation {index}: unrecognized delay error')
            error = DELAY_ERRORS[record['error']] if source and record['error'] is not None else record['error']
            if error != expected_delay_error(delays[peer], op['delay'], scenario['max_prediction']):
                raise ValueError(f'operation {index}: delay change outcome')
            if record['requests'] or record['frame_before'] != record['frame_after']:
                raise ValueError(f'operation {index}: delay change advanced')
            if error is None:
                # Added frames repeat the latest scheduled sample; no earlier frame changes meaning.
                for frame in range(scheduled[peer] + 1, scheduled[peer] + 1 + op['delay'] - delays[peer]):
                    samples[peer][frame] = samples[peer][scheduled[peer]]
                scheduled[peer] += max(0, op['delay'] - delays[peer]); delays[peer] = op['delay']
        elif record['error'] is not None and (type(record['error']) is not str or record['error'] not in {
                'PredictionThreshold', 'PREDICTION_STALL', 'DESYNC'}):
            raise ValueError('unrecognized error')
        if 'lifecycle' in scenario:
            hex_bytes(record['pre_state'], 4 * (scenario['players'] + 3), 'pre state')
            integer(record['pre_confirmed'], -1, 10000, 'pre confirmed')
            if bytes.fromhex(record['pre_state']) != states[peer]:
                raise ValueError('lifecycle pre state')
            lifecycle.events(record['events'], scenario['players'])
            lifecycle.metrics(record['metrics'], peer, scenario['players'])
        elif type(record['events']) is not list or record['events']:
            raise ValueError('unmodeled event')
        if not source:
            if type(record['extension_events']) is not list:
                raise ValueError('extension event inventory')
            for event in record['extension_events']:
                if type(event) is not dict:
                    raise ValueError('extension event: invalid object')
                if event.get('kind') == 'disconnected' and event.get('reason') == 255:
                    fields(event, 'kind peer reason', 'terminal extension')
                    integer(event['peer'], 0, scenario['players'] - 1, 'terminal extension peer')
                    integer(event['reason'], 255, 255, 'terminal extension reason')
                    if (index != len(value['records']) - 1 or event['peer'] == peer
                            or not any(e['kind'] == 'desync_detected' for e in record['events'])):
                        raise ValueError('terminal extension outside final desync policy')
                    continue
                fields(event, 'kind start_frame frame_count peer', 'extension event')
                if event['kind'] != 'inputs_received' or op['kind'] != 'deliver':
                    raise ValueError('unmodeled extension event')
                integer(event['peer'], value['packets'][op['packet']]['from'], value['packets'][op['packet']]['from'], 'event peer')
                integer(event['start_frame'], 0, 10000, 'event start')
                integer(event['frame_count'], 1, 128, 'event frames')
        if type(record['requests']) is not list or len(record['requests']) > 260:
            raise ValueError('requests inventory')
        for request in record['requests']:
            fields(request, 'kind frame state_bytes checksum inputs', 'request')
            integer(request['frame'], 0, 10000, 'request frame')
            hex_bytes(request['state_bytes'], 4 * (scenario['players'] + 3), 'request state')
            hex_bytes(request['checksum'], 16, 'checksum')
            if request['checksum'] != checksum(bytes.fromhex(request['state_bytes'])):
                raise ValueError('request checksum')
            if type(request['inputs']) is not list:
                raise ValueError('inputs')
            frame = request['frame']
            if request['kind'] == 'save':
                if request['inputs'] or frame != int.from_bytes(states[peer][:4], 'little'):
                    raise ValueError('save boundary')
                snapshots[peer][frame] = states[peer]
            elif request['kind'] == 'load':
                if request['inputs'] or frame not in snapshots[peer]:
                    raise ValueError('load boundary')
                states[peer] = snapshots[peer][frame]
            elif request['kind'] == 'advance':
                if frame != int.from_bytes(states[peer][:4], 'little') or len(request['inputs']) != scenario['players']:
                    raise ValueError('advance boundary')
                incoming = []
                for slot, entry in enumerate(request['inputs']):
                    fields(entry, 'player bytes status', 'slot')
                    integer(entry['player'], slot, slot, 'slot position'); hex_bytes(entry['bytes'], 4, 'slot bytes')
                    if type(entry['status']) is not str or entry['status'] not in {'confirmed', 'predicted'}:
                        raise ValueError('input status')
                    if entry['status'] == 'confirmed':
                        expected = '00000000' if frame < scenario['input_delay'] else samples[slot].get(frame)
                        if expected is None or expected != entry['bytes']:
                            raise ValueError(f'operation {index}: submitted confirmed prefix frame {frame} slot {slot}')
                    incoming.append(int.from_bytes(bytes.fromhex(entry['bytes']), 'little'))
                states[peer] = advance_game_state(states[peer], incoming, 2)
            else:
                raise ValueError('request kind')
            if bytes.fromhex(request['state_bytes']) != states[peer]:
                raise ValueError(f'operation {index}: canonical callback state')
        hex_bytes(record['state'], 4 * (scenario['players'] + 3), 'state')
        if bytes.fromhex(record['state']) != states[peer] or record['frame_after'] != int.from_bytes(states[peer][:4], 'little'):
            raise ValueError('game/session after frame')
        if type(record['outgoing']) is not list:
            raise ValueError('outgoing inventory')
        for packet_id in record['outgoing']:
            integer(packet_id, next_packet, next_packet, 'outgoing id'); next_packet += 1
            if packet_id >= len(value['packets']):
                raise ValueError('outgoing packet inventory')
            if value['packets'][packet_id]['semantic']['kind'] == 'goodbye':
                if source or index != len(value['records']) - 1 or not any(e['kind'] in {'disconnected', 'desync_detected'} for e in record['events']):
                    raise ValueError('goodbye outside final terminal policy')
            if value['packets'][packet_id]['from'] != peer:
                raise ValueError('outgoing sender')
    if next_packet != len(value['packets']):
        raise ValueError('unconsumed packet')
    if not source and 'lifecycle' in scenario:
        lifecycle.terminal_notifications(value, scenario)
    return value


def normalize(value, source=False):
    result = deepcopy(value)
    for outgoing in result['packets']:
        outgoing.pop('raw', None)
    first_successes = set()
    for record in result['records']:
        record.pop('extension_events', None)
        if source and result['scenario']['operations'][record['index']]['kind'] == 'delay' and record['error'] is not None:
            record['error'] = DELAY_ERRORS[record['error']]
        if (source and record['error'] is None
                and result['scenario']['operations'][record['index']]['kind'] == 'step'
                and record['frame_before'] == record['frame_after']):
            record['error'] = 'PREDICTION_STALL'
        # Pinned upstream emits a duplicate identical initial SAVE callback.
        requests = record['requests']
        first_success = (source and record['peer'] not in first_successes
                         and result['scenario']['operations'][record['index']]['kind'] == 'step'
                         and record['error'] is None and record['frame_before'] == 0 and record['frame_after'] == 1)
        if first_success:
            first_successes.add(record['peer'])
            if (len(requests) >= 2 and requests[0]['kind'] == requests[1]['kind'] == 'save'
                    and requests[0]['frame'] == requests[1]['frame'] == 0 and requests[0] == requests[1]):
                requests.pop(0)
    return result


def compare(actual, expected, scenario):
    validate(expected, scenario, True); validate(actual, scenario)
    actual = normalize(actual); expected = normalize(expected, True)
    if 'lifecycle' in scenario:
        lifecycle.terminal_projection(actual, expected, scenario)
    for index, (left, right) in enumerate(zip(actual['records'], expected['records'])):
        for key in right:
            if left[key] != right[key]:
                raise ValueError(f'operation {index}: {key} mismatch')
    if actual['packets'] != expected['packets']:
        for index, (left, right) in enumerate(zip(actual['packets'], expected['packets'])):
            if left != right:
                raise ValueError(f'packet {index}: semantic mismatch {left} != {right}')
        raise ValueError('packet count mismatch')
