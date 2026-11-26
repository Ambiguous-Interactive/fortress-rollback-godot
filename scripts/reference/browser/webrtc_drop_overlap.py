"""Check packet and lifecycle receipts for one live four-peer drop overlap."""
from copy import deepcopy
import re
import struct

from .webrtc_drop import _peer_id, _room_physical


def _require(condition, detail):
    if not condition:
        raise ValueError(f'peer-drop overlap {detail}')


def _digest(data):
    digest = 0x14650fb0739d0383
    for byte in data:
        digest = ((digest ^ byte) * 1099511628211) & 0x3fffffffffffffff
    return digest or 1


def _sample(frame, slot):
    return (frame * 17 + slot * 31 + 1) & 255


def _prefix(last_frame):
    values = [0] * 4
    states = []
    for frame in range(last_frame + 1):
        values = [(value * 33 + _sample(frame, slot)) & 0xffffffff for slot, value in enumerate(values)]
        states.append(struct.pack('<5I', frame + 1, *values).hex())
    return states


def _route(trace, kind, peer):
    _require((kind, peer) in trace, f'ordering missing {kind} for {peer}')
    return trace[kind, peer]


def _index(trace, kind, peer):
    return _route(trace, kind, peer)[0]


def _order(trace, *routes):
    indices = [_index(trace, *route) for route in routes]
    _require(all(before < after for before, after in zip(indices, indices[1:])),
             'ordering differs for ' + ', '.join(kind for kind, _ in routes))


def _trace(row, roster):
    events = row.get('trace')
    _require(isinstance(events, list) and 0 < len(events) <= 50, 'trace inventory invalid')
    result = {}
    last_time = -1
    for index, event in enumerate(events):
        kind, peer, at = (event.get(field) for field in ('kind', 'peer', 'us'))
        _require(isinstance(kind, str) and peer in roster and type(at) is int and at >= last_time,
                 'trace order or attribution invalid')
        _require((kind, peer) not in result and isinstance(event.get('detail'), dict), 'trace entry invalid')
        result[kind, peer] = (index, event)
        last_time = at
    return result


def _raw(trace, kind, peer):
    return _route(trace, kind, peer)[1]['bytes']


def _packet(raw, source, kind, length):
    _require(isinstance(raw, str) and re.fullmatch(r'[0-9a-f]+', raw) and len(raw) == length * 2,
             'raw packet bytes invalid')
    data = bytes.fromhex(raw)
    _require(data[:8] == b'FRGP\x03\x00' + bytes((kind, 0))
             and data[8:24].hex() == source['session_id'] and data[24:32].hex() == _peer_id(source['uuid'])
             and data[32:40].hex() == source['connection'] and struct.unpack_from('<I', data, 40)[0] == length - 44,
             'raw packet header differs from the frozen room')
    return data


def _barrier_packet(raw, source, phase, stage, target, coordinator, roster):
    data = _packet(raw, source, 12, 120 if stage == 2 else 109)
    reason = 4 if phase == 5 else 0
    coordinator_generation = int(coordinator['connection'][:4], 16)
    target_generation = int(target['connection'][:4], 16)
    target_bytes = struct.pack('<BH', target['slot'], target_generation)
    survivors = [uuid for uuid in roster if uuid != target['uuid']]
    participant_digest = _digest(''.join(map(_peer_id, survivors)).encode('ascii'))
    cut, bound, through, digest, chunk_index, chunk_count, witnessed, reserved, target_size = struct.unpack_from('<iiiQHHBBI', data, 64)
    report = struct.pack('<IBBBii', 11, 1, 1, target['slot'], 0, 6) if stage == 2 else bytes(4)
    _require(data[44:48] == bytes((phase, stage, reason, 0))
             and struct.unpack_from('<HHIQ', data, 48) == (
                 coordinator['slot'], coordinator_generation, target_generation + 1, _digest(target_bytes))
             and cut == 6 and 0 <= bound <= cut <= through and chunk_index == 0 and 0 <= chunk_count <= 64
             and witnessed == int(stage == 2) and reserved == 0 and target_size == len(target_bytes)
             and digest == (0 if phase == 5 else _digest(bytes([_sample(cut, target['slot'])])))
             and data[94:-8] == target_bytes + report and struct.unpack_from('<Q', data, len(data) - 8)[0] == participant_digest,
             'raw barrier fields differ from the certified operation')


def _detail(trace, kind, peer):
    return _route(trace, kind, peer)[1]['detail']


def validate_drop_overlap(result):
    modes = ('dropCorrupt', 'dropClose', 'dropAnswer', 'dropRelay', 'dropMissing', 'dropHistoryLost', 'dropCommit',
             'dropSecond', 'dropRollback', 'dropForeign', 'dropRoom', 'dropRoomContinue', 'dropProcess',
             'dropProcessMissing', 'dropRoomAfterDrop', 'dropRoomBeforeDrop', 'recordingPressure')
    _require(result.get('passed') is True and result.get('peerDrop') is True and result.get('dropOverlap') is True
             and result.get('errors') == [] and result.get('browser_instances') == 2
             and all(result.get(mode, False) is False for mode in modes), 'browser run incomplete')
    records = result.get('records')
    _require(isinstance(records, list) and len(records) == 1, 'expected one fixed room')
    match = records[0]
    _require(match.get('players') == 4 and len(match.get('peers', [])) == 4, 'expected four real exported peers')
    peers = []
    for page in match['peers']:
        rtc, witness = _room_physical(page, 4)
        rows = witness.get('records')
        _require(witness.get('passed') is True and witness.get('binary_receives') == 0
                 and isinstance(rows, list) and len(rows) == 1, 'direct result missing')
        row = rows[0]
        _require(type(row.get('sent_at_end')) is int and row['sent_at_end'] == rtc['sent'],
                 'endpoint traffic continued after the recorded end')
        peers.append(row)
    roster = peers[0].get('roster')
    _require(isinstance(roster, list) and len(roster) == 4 and len(set(roster)) == 4, 'frozen roster invalid')
    _require({row.get('uuid') for row in peers} == set(roster), 'exported peers do not match the frozen roster')
    room, session = peers[0].get('room'), peers[0].get('session_id')
    _require(isinstance(room, str) and room and isinstance(session, str) and re.fullmatch(r'[0-9a-f]{32}', session),
             'room identity invalid')
    history = _prefix(6)
    for row in peers:
        _peer_id(row['uuid'])
        _require(row.get('roster') == roster and row.get('room') == room and row.get('session_id') == session
                 and type(row.get('slot')) is int and 0 <= row['slot'] < 4 and roster[row['slot']] == row['uuid']
                 and isinstance(row.get('connection'), str) and re.fullmatch(r'[0-9a-f]{16}', row['connection'])
                 and int(row['connection'], 16) != 0, 'fixed room or peer identity changed')
        _require(row.get('confirmed_prefix') == 6 and row.get('original') == history and row.get('final') == history,
                 'confirmed prefix differs from the original inputs')
    first = peers[2]
    by_uuid = {row['uuid']: row for row in peers}
    coordinator, pending, second = [by_uuid[uuid] for uuid in roster if uuid != first['uuid']]
    a, c, p, s = (row['uuid'] for row in (first, coordinator, pending, second))
    ft, ct, pt, st = (_trace(row, roster) for row in (first, coordinator, pending, second))
    _require(list(ft) == [('silent', a)] and first.get('frame') == 7 and first.get('freeze_frame') == -1,
             'first target did not stop servicing at the agreed frame')
    for row, trace in ((coordinator, ct), (pending, pt), (second, st)):
        _require(row.get('frame') == 8 and _detail(trace, 'disconnected', a).get('reason') == 'timeout',
                 'initial target silence was not observed as a peer timeout')
    _order(ct, ('disconnected', a), ('ready_received', p), ('certified', a), ('frozen', a), ('commit_withheld', p), ('commit_sent', s), ('terminated', c))
    _order(ct, ('ready_received', s), ('certified', a))
    _order(pt, ('disconnected', a), ('certified', a), ('ready_sent', c), ('peer_drop_unconfirmed', a), ('terminated', p))
    _order(st, ('disconnected', a), ('certified', a), ('ready_sent', c), ('commit_at_cutoff', c), ('goodbye_sent', c), ('silent', s))
    _order(st, ('commit_at_cutoff', c), ('goodbye_sent', p), ('silent', s))
    cutoff_sent = _detail(st, 'commit_at_cutoff', c).get('sent')
    goodbyes = second.get('goodbyes_sent')
    _require(type(cutoff_sent) is int and cutoff_sent > 0 and isinstance(goodbyes, dict) and set(goodbyes) == {c, p}
             and all(type(count) is int and count >= 1 for count in goodbyes.values())
             and second['sent_at_end'] - cutoff_sent == sum(goodbyes.values()),
             'second endpoint sent traffic beyond its addressed GOODBYEs')
    certified = {'cut': 6, 'digest': f'{_digest(bytes([_sample(6, first["slot"])])):016x}'}
    for trace in (ct, pt, st):
        metadata = _detail(trace, 'certified', a)
        _require(all(metadata.get(field) == value for field, value in certified.items()), 'certificate value differs')
    _require(set(_detail(ct, 'certified', a).get('certificates', [])) == {_peer_id(p), _peer_id(s)},
             'coordinator did not certify both READY reports')
    for row, uuid, trace in ((pending, p, pt), (second, s, st)):
        ready = _raw(trace, 'ready_sent', c)
        _require(ready == _raw(ct, 'ready_received', uuid), 'READY send does not match the coordinator receipt')
        _barrier_packet(ready, row, 2, 2, first, coordinator, roster)
    commit = _raw(ct, 'commit_withheld', p)
    _require(commit == _raw(ct, 'commit_sent', s) == _raw(st, 'commit_at_cutoff', c),
             'withheld COMMIT differs from the original transmitted COMMIT')
    _barrier_packet(commit, coordinator, 4, 0, first, coordinator, roster)
    _require(type(coordinator.get('withheld')) is int and coordinator['withheld'] >= 1
             and all(row.get('withheld') == 0 for row in (first, pending, second))
             and ('commit_sent', p) not in ct and ('commit_received', c) not in pt
             and ('commit_received', c) not in st and not any(kind.startswith('ack_') for kind, _ in (*ct, *pt, *st))
             and coordinator.get('acknowledged') == [], 'COMMIT withholding or ACK suppression evidence differs')
    saw_goodbye = False
    for row, trace, other, other_trace in ((coordinator, ct, pending, pt), (pending, pt, coordinator, ct)):
        uuid = row['uuid']
        goodbye = _raw(st, 'goodbye_sent', uuid)
        _require(_packet(goodbye, second, 9, 45)[44] == 42, 'second endpoint GOODBYE reason differs')
        if ('goodbye_received', s) in trace:
            saw_goodbye = True
            _require(_raw(trace, 'goodbye_received', s) == goodbye
                     and _detail(trace, 'disconnected', s).get('reason') == 42,
                     'second endpoint departure did not match its sent GOODBYE')
            loss = ('goodbye_received', s)
        else:
            peer = other['uuid']
            abort = _raw(trace, 'abort_received', peer)
            _require(abort == _raw(other_trace, 'abort_sent', uuid), 'participant loss signal was not sent by the observing survivor')
            _barrier_packet(abort, other, 5, 0, first, coordinator, roster)
            _order(other_trace, ('goodbye_received', s), ('abort_sent', uuid))
            loss = ('abort_received', peer)
        baseline = ('commit_sent', s) if uuid == c else ('ready_sent', c)
        _order(trace, baseline, loss, ('peer_drop_unconfirmed', a), ('terminated', uuid))
        _require(_detail(trace, 'peer_drop_unconfirmed', a).get('reason') == 'participant_lost'
                 and row.get('reason') == 'protocol failure' and row.get('state') == 'failed',
                 'survivor did not end for participant loss')
    _require(saw_goodbye, 'no survivor observed the second endpoint departure')
    value = f'{_sample(6, first["slot"]):02x}'
    _require(coordinator.get('freeze_frame') == 6 and coordinator.get('frozen_value') == value
             and _detail(ct, 'frozen', a) == {'cut': 6, 'value': value}
             and _detail(ct, 'peer_dropped', a).get('frame') == 6,
             'committed survivor lost its certified freeze')
    _require(all(row.get('freeze_frame') == -1 and row.get('frozen_value') == '' for row in (first, pending, second))
             and all(all(kind not in ('frozen', 'peer_dropped') for kind, _ in trace) for trace in (pt, st))
             and second.get('reason') == 'terminated' and second.get('state') == 'pending', 'uncommitted survivor applied a freeze')
    return result


def _check_rejection(control, expected):
    try:
        validate_drop_overlap(control)
    except ValueError as error:
        if str(error) == expected:
            return str(error)
        raise
    raise ValueError('peer-drop overlap accepted a receipt that violates the packet order')


def check_overlap_order_controls(result):
    control = deepcopy(result)
    peers = control['records'][0]['peers']
    for page in peers:
        trace = page['result']['records'][0]['trace']
        withheld = next((entry for entry in trace if entry['kind'] == 'commit_withheld'), None)
        if withheld is not None:
            index = trace.index(withheld)
            trace.remove(withheld)
            break
    else:
        raise ValueError('peer-drop overlap negative control could not remove the withholding receipt')
    diagnostic = _check_rejection(control, f"peer-drop overlap ordering missing commit_withheld for {withheld['peer']}")
    trace.insert(index, withheld)

    first = peers[2]['result']['records'][0]['uuid']
    timeout = next(entry for entry in trace if entry['kind'] == 'disconnected' and entry['peer'] == first)
    trace.remove(timeout)
    timeout['us'] = trace[-1]['us']
    trace.append(timeout)
    late_timeout = _check_rejection(
        control, 'peer-drop overlap ordering differs for disconnected, ready_received, certified, frozen, commit_withheld, commit_sent, terminated')
    return {'removed': withheld, 'diagnostic': diagnostic, 'late_initial_timeout': late_timeout}
