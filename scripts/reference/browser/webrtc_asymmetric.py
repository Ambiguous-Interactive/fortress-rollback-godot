"""Validate asymmetric Chromium steps, physical relay holds and original recordings."""

from copy import deepcopy
import re
import struct

from browser.webrtc_recording import _addressed_payload, validate_pressure, validate_pressure_teardown
from wire import decode_relay_carrier, original_sample, validate_original_input

MODES = ('changing', 'neutral', 'withheld')
PHASES = ((144, 151, 0), (192, 195, 1))
PREDICTION_WINDOW = 8
MAX_CALLBACKS = 2048
FRAMES = 257
UUID = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'


def _advance(values, samples):
    return tuple((value * 33 + sample) & 0xffffffff for value, sample in zip(values, samples))


def _state(frame, values):
    return struct.pack('<III', frame, *values).hex()


def _original_history(neutral):
    values = (0, 0)
    history = [_state(0, values)]
    for frame in range(FRAMES):
        values = _advance(values, [original_sample(frame, slot, neutral) for slot in range(2)])
        history.append(_state(frame + 1, values))
    return history


def _callback_history(base, limit, remote_slot, original, neutral, *, predicting=False, correcting=False, stalls=False):
    values = struct.unpack('<III', bytes.fromhex(original[base]))[1:]
    result = [['load', base, original[base]]] if correcting else []
    for frame in range(base, limit):
        if not correcting or frame > base:
            result.append(['save', frame, _state(frame, values)])
        samples = [original_sample(frame, slot, neutral) for slot in range(2)]
        statuses = [1, 1]
        if predicting:
            samples[remote_slot] = original_sample(base - 1, remote_slot, neutral)
            statuses[remote_slot] = 2
        values = _advance(values, samples)
        result.append(['advance', frame, [list(row) for row in zip(samples, statuses)], _state(frame + 1, values)])
    final = _state(limit, values)
    if correcting or stalls:
        result.append(['save', limit, final])
    return result, final


def _callback_slice(events, span):
    if (type(span) is list and len(span) == 2 and all(type(index) is int for index in span)
            and 0 <= span[0] <= span[1] <= len(events)):
        return events[span[0]:span[1]]
    return None


def _validate_callback_stream(row, local_slot, schedule, original, mode, source):
    events = row.get('callbacks')
    if type(events) is not list or not 1 <= len(events) <= MAX_CALLBACKS:
        raise ValueError('asymmetric complete callback inventory missing')
    neutral = mode == 'neutral'
    prediction = {frame: base - 1 for base, limit, receiver in schedule if receiver == source for frame in range(base, limit)}
    frame = forward = loads = 0
    values = (0, 0)
    saved = {}
    history = {}
    previous = ''
    limit = schedule[-1][1] if mode == 'withheld' else FRAMES
    phase_boundaries = {frame for base, stop, _ in schedule for frame in (base, stop)}
    consecutive_saves = 0
    for event in events:
        if type(event) is not list or len(event) < 3 or type(event[1]) is not int or not 0 <= event[1] <= FRAMES:
            raise ValueError('asymmetric complete callback inventory invalid')
        kind, requested = event[:2]
        consecutive_saves = consecutive_saves + 1 if kind == 'save' else 0
        if consecutive_saves > 2 or (consecutive_saves == 2 and frame not in phase_boundaries | {FRAMES}):
            raise ValueError(f'asymmetric callback has an extra save at boundary {requested}')
        if kind == 'load' and len(event) == 3 and 0 < frame - requested <= PREDICTION_WINDOW and requested in saved:
            frame, values = requested, saved[requested]
            loads += 1
        elif kind == 'save' and len(event) == 3 and requested == frame:
            saved[frame] = values
        elif kind == 'advance' and len(event) == 4 and requested == frame and previous in ('save', 'load'):
            samples = [original_sample(frame, slot, neutral) for slot in range(2)]
            statuses = [1, 1]
            remote = 1 - local_slot
            inputs = event[2]
            if type(inputs) is list and len(inputs) == 2 and type(inputs[remote]) is list and len(inputs[remote]) == 2 and inputs[remote][1] == 2:
                prior = prediction.get(frame, frame - 1) if frame == forward else frame - 1
                samples[remote] = original_sample(prior, remote, neutral) if prior >= 0 else 0
                statuses[remote] = 2
            if (inputs != [list(item) for item in zip(samples, statuses)]
                    or any(type(value) is not int for sample in inputs for value in sample)):
                raise ValueError(f'asymmetric callback original input/status mismatch at frame {frame}')
            values = _advance(values, samples)
            frame += 1
            forward = max(forward, frame)
            history[frame] = _state(frame, values)
        else:
            raise ValueError(f'asymmetric complete callback order differs at frame {requested}')
        if event[-1] != _state(frame, values):
            raise ValueError(f'asymmetric callback state differs at boundary {frame}')
        previous = kind
    terminal_saves = {'changing': 2, 'neutral': 1, 'withheld': int(source == schedule[0][2])}[mode]
    if consecutive_saves != terminal_saves:
        raise ValueError('asymmetric callback terminal save inventory differs from the recording boundary')
    finalized = schedule[0][0] if mode == 'withheld' and source == schedule[0][2] else limit
    if frame != limit or forward != limit or loads != row.get('rollback_loads') or any(history.get(index) != original[index] for index in range(1, finalized + 1)):
        raise ValueError('asymmetric complete callback history lacks the original finalized prefix')
    return events


def _validate_phase(phase, events, base, limit, receiver, remote_slot, original, mode):
    if type(phase) is not dict or phase.get('base') != base or phase.get('limit') != limit or phase.get('receiver') is not receiver:
        raise ValueError('asymmetric phase inventory differs from schedule')
    held, after = phase.get('held'), phase.get('after')
    neutral = mode == 'neutral'
    stalls = receiver and base == PHASES[0][0]
    if phase.get('stalls') != ([{'code': 3, 'before': limit, 'after': limit}] if stalls else []):
        raise ValueError('asymmetric prediction stall differs from declared bound')
    expected_callbacks, expected_state = _callback_history(base, limit, remote_slot, original, neutral, predicting=receiver, stalls=stalls)
    if (type(held) is not dict or held.get('frame') != limit or held.get('received') != (base - 1 if receiver else limit - 1)
            or any(type(held.get(key)) is not int for key in ('confirmed', 'acked', 'loads', 'turn', 'binary'))
            or not base - 1 <= held['confirmed'] <= limit - 1 or (receiver and held['confirmed'] != base - 1)
            or not base - 1 <= held['acked'] <= limit - 1 or min(held['turn'], held['binary']) < 1
            or held['loads'] < 0 or (neutral and held['loads'] != 0)):
        raise ValueError('asymmetric held original prefix or service inventory differs from schedule')
    if _callback_slice(events, held.get('callbacks')) != expected_callbacks or held.get('canonical') != expected_state:
        raise ValueError('asymmetric held callback order or original input/status differs')
    if held['loads'] != sum(event[0] == 'load' for event in events[:held['callbacks'][1]]):
        raise ValueError('asymmetric held LOAD count differs from the callback prefix')
    if mode == 'withheld':
        if type(after) is not dict or after != {key: value for key, value in held.items() if key != 'callbacks'}:
            raise ValueError('asymmetric withheld delivery advanced or recovered')
        return
    repaired = receiver and not neutral
    callbacks = _callback_history(base, limit, remote_slot, original, neutral, correcting=True)[0] if repaired else []
    if (type(after) is not dict or after.get('frame') != limit or after.get('received') != limit - 1
            or after.get('loads') != held['loads'] + int(repaired)
            or any(type(after.get(key)) is not int for key in ('turn', 'binary', 'acked', 'confirmed'))
            or not held['acked'] <= after['acked'] <= limit - 1 or not held['confirmed'] <= after['confirmed'] <= limit - 1
            or after['turn'] < held['turn'] or after['binary'] < held['binary']
            or (receiver and (after['turn'] <= held['turn'] or after['binary'] <= held['binary']))):
        raise ValueError('asymmetric recovery changed boundary or lacks original receipt/correction')
    if (_callback_slice(events, after.get('callbacks')) != callbacks or after['callbacks'][0] != held['callbacks'][1]
            or after.get('canonical') != original[limit]):
        raise ValueError('asymmetric recovery callback order or original canonical state differs')
    if after['loads'] != sum(event[0] == 'load' for event in events[:after['callbacks'][1]]):
        raise ValueError('asymmetric recovery LOAD count differs from the callback prefix')


def _route(physical, received, identity, destination, source, slot, mode):
    if (type(physical) is not list or not 1 <= len(physical) <= 128 or type(received) is not list or len(received) > 512
            or any(type(wire) is not str for wire in received) or len(set(received)) != len(received)):
        raise ValueError('asymmetric physical binary delivery inventory incomplete')
    route = {}
    previous_turn = 1
    for entry in physical:
        if type(entry) is not dict or type(entry.get('turn')) is not int or entry['turn'] < previous_turn:
            raise ValueError('asymmetric physical send inventory invalid')
        wire = entry.get('wire')
        payload = _addressed_payload(wire, identity, destination, 'asymmetric physical send')
        start = validate_original_input(payload, 2, identity, slot, source, FRAMES, (129, FRAMES), 'asymmetric physical send', mode == 'neutral')
        ack, frames = struct.unpack_from('<iH', payload, 48)
        end = start + frames
        if wire in route or not any(base < end <= limit for base, limit, _ in PHASES):
            raise ValueError('asymmetric physical send range invalid')
        previous_turn = entry['turn']
        route[wire] = (start, end, ack, previous_turn, wire in received)
    return route


def _hex_bytes(value, minimum, maximum):
    if (type(value) is not str or not 2 * minimum <= len(value) <= 2 * maximum
            or len(value) % 2 or not re.fullmatch('[0-9a-f]+', value)):
        raise ValueError('asymmetric physical byte inventory invalid')
    return bytes.fromhex(value)


def _deliveries(rtc, route, received):
    messages = rtc.get('recordingPhaseMessages')
    if rtc.get('captureError') is not False or type(messages) is not list or len(messages) > 128:
        raise ValueError('asymmetric browser message inventory incomplete')
    admitted = set()
    stamps = set()
    deliveries = {}
    for index, message in enumerate(messages, 1):
        carrier = message.get('carrier') if type(message) is dict else None
        sender, envelope, epoch, seq = decode_relay_carrier(_hex_bytes(carrier, 134, 2048))
        if (envelope != message.get('wire') or envelope not in route or sender != envelope[42:74] or (epoch, seq) in stamps):
            raise ValueError('asymmetric browser carrier lacks the original send or unique server stamp')
        stamps.add((epoch, seq))
        admission = message.get('admission')
        if admission is not None:
            if (type(admission) is not dict or admission.get('ordinal') != index
                    or type(admission.get('turn')) is not int or admission['turn'] < 1
                    or admission.get('release') not in (None, 144, 192)):
                raise ValueError('asymmetric SDK admissions violate the physical message order')
            admitted.add(envelope)
        deliveries[carrier] = (envelope, admission)
    if admitted != set(received).intersection(route):
        raise ValueError('asymmetric browser message and SDK inventories disagree')
    return deliveries


def _validate_completion(chunk, event, carrier, last_completion):
    header = _hex_bytes(event.get('header'), 2, 10)
    length = header[1]
    if length == 126 and len(header) == 4:
        length = int.from_bytes(header[2:], 'big')
        if length < 126:
            raise ValueError('asymmetric held WebSocket frame length is noncanonical')
    elif length >= 126 or len(header) != 2:
        raise ValueError('asymmetric held WebSocket frame length is invalid')
    end, tail, chunk_offset, frame_offset = (event.get(key) for key in ('end', 'tail_bytes', 'chunk_offset', 'frame_offset'))
    if (header[0] not in (0x80, 0x82) or not 1 <= length <= len(carrier) or (header[0] == 0x82 and length != len(carrier))
            or any(type(value) is not int for value in (end, tail, chunk_offset, frame_offset))
            or min(chunk_offset, frame_offset) < 0 or not last_completion < end <= len(chunk)
            or end != frame_offset + len(header) + length - chunk_offset
            or tail != min(end, length) or chunk[end - tail:end] != carrier[-tail:]):
        raise ValueError('asymmetric held TCP bytes do not complete the original carrier')
    header_end = end - length
    if header_end > 0:
        header_bytes = min(header_end, len(header))
        if chunk[header_end - header_bytes:header_end] != header[-header_bytes:]:
            raise ValueError('asymmetric held TCP bytes do not contain the recorded WebSocket header')
    return end


def _validate_hold(hold, base, limit, receiver, routes, deliveries, phases, mode):
    if (type(hold) is not dict or hold.get('base') != base or hold.get('receiver') != receiver or hold.get('paused') is not True
            or hold.get('action') != ('withheld' if mode == 'withheld' else 'released')
            or type(hold.get('pending_bytes')) is not int or type(hold.get('events')) is not list or not 1 <= len(hold['events']) <= 32):
        raise ValueError('asymmetric physical relay hold missing')
    chunk = _hex_bytes(hold.get('chunk'), 1, 65536)
    if hold['pending_bytes'] != len(chunk):
        raise ValueError('asymmetric physical relay hold byte count differs from the pending TCP chunk')
    sender = 1 - receiver
    route = routes[sender]
    last_completion = 0
    held_ordinals = []
    for event in hold['events']:
        carrier = event.get('carrier') if type(event) is dict else None
        raw = _hex_bytes(carrier, 134, 2048)
        source, envelope, _, _ = decode_relay_carrier(raw)
        if envelope != event.get('envelope') or envelope not in route or source != envelope[42:74]:
            raise ValueError('asymmetric physical relay hold lacks matching original send')
        last_completion = _validate_completion(chunk, event, raw, last_completion)
        if event['chunk_offset'] != hold['events'][0]['chunk_offset']:
            raise ValueError('asymmetric held carrier completions belong to different TCP chunks')
        _, end, ack, turn, delivered = route[envelope]
        if not base < end <= limit or ack != limit - 1 or turn > phases[sender]['held']['turn'] or delivered is (mode == 'withheld'):
            raise ValueError('asymmetric held original delivery does not match release')
        observed = deliveries[receiver]
        eligible = [wire for wire, _ in observed.values() if wire == envelope]
        if mode == 'withheld':
            if eligible:
                raise ValueError('asymmetric withheld carrier reached the browser')
        else:
            _, admission = observed.get(carrier, (None, None))
            receiver_phase = phases[receiver]
            if (len(eligible) != 1 or admission is None or admission['release'] != base
                    or not receiver_phase['held']['turn'] <= admission['turn'] <= receiver_phase['after']['turn']):
                raise ValueError('asymmetric held server stamp lacks its unique browser message and SDK admission')
            held_ordinals.append(admission['ordinal'])
    if held_ordinals:
        _validate_released_prefix(deliveries[receiver], route, base, limit, phases[receiver]['after']['turn'], held_ordinals)
    for source, route in enumerate(routes):
        actual = {frame for start, end, _, _, delivered in route.values() if base < end <= limit and delivered
                  for frame in range(max(start, base), end)}
        wanted = set() if source == sender and mode == 'withheld' else set(range(base, limit))
        if actual != wanted:
            raise ValueError('asymmetric phase original delivery coverage differs from schedule')
    acknowledged = {frame for start, end, ack, turn, delivered in routes[receiver].values()
                    if base < end <= limit and delivered and ack == base - 1 and turn <= phases[receiver]['held']['turn']
                    for frame in range(max(start, base), end)}
    if acknowledged != set(range(base, limit)):
        raise ValueError('asymmetric sender delivery lacks the original receiver acknowledgement frontier')


def _validate_released_prefix(deliveries, route, base, limit, recovery_turn, held_ordinals):
    if any(left >= right for left, right in zip(held_ordinals, held_ordinals[1:])):
        raise ValueError('asymmetric browser admissions are reordered relative to held TCP completions')
    first_supplier = {}
    for wire, admission in deliveries.values():
        start, end, _, _, _ = route[wire]
        if admission is not None and base < end <= limit and admission['turn'] <= recovery_turn:
            for frame in range(max(start, base), end):
                first_supplier.setdefault(frame, admission['ordinal'])
    if first_supplier.keys() != set(range(base, limit)):
        raise ValueError('asymmetric SDK admissions lack the required prefix at recovery')
    # The first needed row on this socket must arrive in the released chunk.
    if min(first_supplier.values()) != held_ordinals[0]:
        raise ValueError('asymmetric required original input arrived ahead of the held chunk')


def _validate_room(room, mode, result, expected_engine):
    if type(room) is not dict or type(room.get('players')) is not int or room['players'] != 2 or room.get('recordingMode') != mode:
        raise ValueError('asymmetric browser room inventory differs from schedule')
    peers = room.get('peers')
    if (type(peers) is not list or len(peers) != 2 or any(type(peer) is not dict or peer.get('browser') != 'chromium'
            or type(peer.get('result')) is not dict or peer['result'].get('passed') is not True
            or type(peer['result'].get('records')) is not list or len(peer['result']['records']) != 1 for peer in peers)):
        raise ValueError('asymmetric browser peer inventory incomplete')
    rows = [peer['result']['records'][0] for peer in peers]
    if any(type(row) is not dict or type(row.get('mixed')) is not dict for row in rows):
        raise ValueError('asymmetric browser peer inventory incomplete')
    identities = [row.get('mixed', {}).get('uuid') for row in rows]
    if any(type(uuid) is not str or not re.fullmatch(UUID, uuid) for uuid in identities) or len(set(identities)) != 2:
        raise ValueError('asymmetric peer identity invalid')
    if mode != 'withheld':
        validate_pressure({**result, 'records': [room]}, expected_engine, neutral=mode == 'neutral')
    else:
        for peer in peers:
            validate_pressure_teardown(peer.get('rtc', {}))
        if any(row.get('frames_submitted') != 151 or 'recording' in row or 'history' in row for row in rows):
            raise ValueError('asymmetric withheld control advanced beyond the stall or exported')
    schedule = PHASES[:1] if mode == 'withheld' else PHASES
    holds = room.get('recordingHolds')
    if type(holds) is not list or len(holds) != len(schedule) or any(type(row.get('asymmetric')) is not list
            or len(row['asymmetric']) != len(schedule) for row in rows):
        raise ValueError('asymmetric held/recovered phase inventory incomplete')
    original = _original_history(mode == 'neutral')
    slots = [sorted(identities).index(identity) for identity in identities]
    routes = [_route(peer.get('rtc', {}).get('recordingPhaseSends'), rows[1 - source]['mixed'].get('received_inputs'),
                     identities[source], identities[1 - source], source, slots[source], mode) for source, peer in enumerate(peers)]
    deliveries = [_deliveries(peer['rtc'], routes[1 - receiver], rows[receiver]['mixed']['received_inputs'])
                  for receiver, peer in enumerate(peers)]
    streams = [_validate_callback_stream(row, slots[source], schedule, original, mode, source) for source, row in enumerate(rows)]
    for index, (hold, (base, limit, receiver)) in enumerate(zip(holds, schedule)):
        phases = [row['asymmetric'][index] for row in rows]
        for source, phase in enumerate(phases):
            _validate_phase(phase, streams[source], base, limit, source == receiver, slots[1 - source], original, mode)
        _validate_hold(hold, base, limit, receiver, routes, deliveries, phases, mode)
    if mode != 'withheld':
        for row in rows:
            if row.get('history') != original[1:]:
                raise ValueError('asymmetric original canonical history differs')


def validate_asymmetric(result, expected_engine=None):
    if (type(result) is not dict or result.get('passed') is not True or result.get('errors') != []
            or result.get('browser') != 'chromium/chromium' or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2
            or result.get('recordingAsymmetric') is not True or result.get('recordingPressure') is not True
            or result.get('mixed') is not True or result.get('faults') is not False or result.get('corrupt') is not False
            or type(result.get('records')) is not list or len(result['records']) != len(MODES)):
        raise ValueError('asymmetric Chromium execution incomplete')
    for room, mode in zip(result['records'], MODES):
        _validate_room(room, mode, result, expected_engine)
    return result


def check_asymmetric_controls(result, engine):
    """Reject changes to the actual exported browser receipt at their first mismatch."""
    substitutions = (
        ('symmetric prefix', ('asymmetric', 0, 'held', 'received'), 150,
         'asymmetric held original prefix or service inventory differs from schedule'),
        ('skipped correction', ('asymmetric', 0, 'after', 'callbacks'), [],
         'asymmetric recovery callback order or original canonical state differs'),
        ('missing final receipt', ('recording_tail', 'receipt'), {},
         'recording pressure final addressed receipt missing after the hold'),
        ('altered decoded playback', ('recording', 'canonical'), '00',
         'mixed recording decoded playback lost the original final canonical state'),
    )
    rows = ('records', 0, 'peers', 0, 'result', 'records', 0)
    recording = result['records'][0]['peers'][0]['result']['records'][0]['recording']
    raw = bytearray.fromhex(recording['hex'])
    offset = 24
    for _ in range(5):
        offset += 1 + raw[offset]
    raw[offset + 129 * 37] ^= 1
    substitutions += (('altered post-wrap export', ('recording', 'hex'), raw.hex(), 'mixed recording original input mismatch at frame 129'),)
    controls = [(label, [(rows + path, replacement)], wanted) for label, path, replacement, wanted in substitutions]
    room = result['records'][0]
    row = room['peers'][0]['result']['records'][0]
    held, after = (row['asymmetric'][0][key] for key in ('held', 'after'))
    hold = room['recordingHolds'][0]
    event = hold['events'][0]
    hold_path = ('records', 0, 'recordingHolds', 0)
    changed_chunk = bytearray.fromhex(hold['chunk'])
    changed_chunk[event['end'] - 1] ^= 1
    carrier = bytearray.fromhex(event['carrier'])
    carrier[-1] ^= 0x40
    forged_chunk = bytearray.fromhex(hold['chunk'])
    if event['tail_bytes']:
        forged_chunk[event['end'] - 1] ^= 0x40
    messages_path = ('records', 0, 'peers', 0, 'rtc', 'recordingPhaseMessages')
    messages = room['peers'][0]['rtc']['recordingPhaseMessages']
    controls.extend((
        ('extra terminal save', [(rows + ('callbacks',), row['callbacks'] + [row['callbacks'][-1]])],
         'asymmetric callback has an extra save at boundary 257'),
        ('shifted phase loads', [(rows + ('asymmetric', 0, 'held', 'loads'), held['loads'] + 1),
                                 (rows + ('asymmetric', 0, 'after', 'loads'), after['loads'] + 1)],
         'asymmetric held LOAD count differs from the callback prefix'),
        ('out-of-range acknowledgement', [(rows + ('asymmetric', 0, 'after', 'acked'), 257)],
         'asymmetric recovery changed boundary or lacks original receipt/correction'),
        ('added pending byte', [(hold_path + ('pending_bytes',), hold['pending_bytes'] + 1)],
         'asymmetric physical relay hold byte count differs from the pending TCP chunk'),
        ('changed TCP completion', [(hold_path + ('chunk',), changed_chunk.hex())],
         'asymmetric held TCP bytes do not complete the original carrier'),
        ('forged carrier stamp', [(hold_path + ('events', 0, 'carrier'), carrier.hex()), (hold_path + ('chunk',), forged_chunk.hex())],
         'asymmetric held server stamp lacks its unique browser message and SDK admission'),
        ('ambiguous browser stamp', [(messages_path, messages + [{'carrier': carrier.hex(), 'wire': event['envelope'], 'admission': None}])],
         'asymmetric held server stamp lacks its unique browser message and SDK admission'),
        ('unclosed withheld WebSocket', [(('records', 2, 'peers', 0, 'rtc', 'teardown', 'websockets'), 0)],
         'recording pressure browser resources survived teardown'),
        ('empty completion fragment', [(hold_path + ('pending_bytes',), 1), (hold_path + ('chunk',), '00'),
                                       (hold_path + ('events', 0, 'end'), 1), (hold_path + ('events', 0, 'tail_bytes'), 0)],
         'asymmetric held TCP bytes do not complete the original carrier'),
    ))
    diagnostics = {}
    for label, changes, wanted in controls:
        value = deepcopy(result)
        for path, replacement in changes:
            target = value
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = replacement
        try:
            validate_asymmetric(value, engine)
        except ValueError as failure:
            if str(failure) != wanted:
                raise ValueError(f'{label} rejected outside its expected diagnostic: {failure}') from failure
            diagnostics[label] = str(failure)
        else:
            raise ValueError(f'{label} accepted a changed asymmetric recording receipt')
    return diagnostics
