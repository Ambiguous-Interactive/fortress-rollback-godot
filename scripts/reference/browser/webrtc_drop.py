"""Validate coordinated-drop browser evidence separately from ordinary fixed meshes."""
import re
import hashlib


_UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')


def _peer_id(uuid):
    if not isinstance(uuid, str) or not _UUID.fullmatch(uuid):
        raise ValueError('peer-drop original identities invalid')
    return hashlib.sha256(uuid.encode('ascii')).digest()[:8].hex()


def _departing_row(row, sequence, frames):
    roster = row.get('roster')
    slot = row.get('slot')
    return (row.get('departed') is True
            and type(row.get('departure_sequence')) is int and row['departure_sequence'] == sequence
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == frames
            and isinstance(row.get('uuid'), str)
            and type(slot) is int and 0 <= slot < 3
            and isinstance(roster, list) and len(roster) == 3 and roster[slot] == row['uuid'])


def _room_physical(peer):
    rtc = peer.get('rtc')
    if not isinstance(rtc, dict) or any(type(rtc.get(field)) is not int or rtc[field] < 1 for field in ('sent', 'received')):
        raise ValueError('room-departure physical packet evidence missing')
    witness = peer.get('result')
    if not isinstance(witness, dict):
        raise ValueError('room-departure gameplay result missing')
    channels = rtc.get('channels')
    if not isinstance(channels, list) or len(channels) != 6:
        raise ValueError('room-departure channel inventory incomplete')
    if any(type(channel.get('id')) is not int for channel in channels):
        raise ValueError('room-departure channel identity is not an integer')
    if any(sum(channel.get('id') == channel_id for channel in channels) != 2 for channel_id in (1, 2, 3)):
        raise ValueError('room-departure channel IDs incomplete')
    for channel in channels:
        if channel.get('id') != 3: continue
        if (channel.get('ordered') is not False or channel.get('negotiated') is not True
                or type(channel.get('maxPacketLifeTime')) is not int or channel['maxPacketLifeTime'] != 1
                or channel.get('maxRetransmits', False) is not None
                or any(type(channel.get(field)) is not int or channel[field] < 1 for field in ('sent', 'received'))):
            raise ValueError('room-departure unreliable physical delivery missing')
    teardown = rtc.get('teardown', {})
    if (type(teardown.get('channels')) is not int or teardown['channels'] != 6 or type(teardown.get('connections_created')) is not int
            or teardown['connections_created'] < 2 or type(teardown.get('connections')) is not int
            or teardown['connections'] != teardown['connections_created']
            or type(teardown.get('websockets_created')) is not int or teardown['websockets_created'] < 1
            or type(teardown.get('websockets')) is not int or teardown['websockets'] != teardown['websockets_created']):
        raise ValueError('room-departure browser resources survived teardown')
    return rtc, witness


def _room_departing_row(row, roster, session):
    return (row.get('departed') is True
            and type(row.get('departure_sequence')) is int and row['departure_sequence'] == 1
            and row.get('departure_kind') == 'room_left'
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 7
            and isinstance(row.get('uuid'), str) and row['uuid'] in roster
            and type(row.get('slot')) is int and 0 <= row['slot'] < 3 and roster[row['slot']] == row['uuid']
            and row.get('roster') == roster
            and isinstance(row.get('room_code_before'), str) and row['room_code_before']
            and row.get('room_code_after') == ''
            and row.get('room_left') is True
            and row.get('connected') is True and row.get('authenticated') is True
            and row.get('session_id') == session)


def _room_survivor_row(row, roster, departed_uuid, departed_slot, session):
    live = row.get('room_roster_after')
    survivor_uuids = [uuid for slot, uuid in enumerate(roster) if slot != departed_slot]
    return (row.get('departed') is False
            and type(row.get('slot')) is int and 0 <= row['slot'] < 3
            and isinstance(row.get('uuid'), str) and row.get('uuid') == row.get('local_uuid')
            and row['uuid'] in roster and roster[row['slot']] == row['uuid']
            and row['uuid'] != departed_uuid
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 7
            and type(row.get('fence_frame')) is int and row['fence_frame'] == 7
            and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 0
            and row.get('room_fenced') is True
            and row.get('fence_route') == 'restart_required'
            and type(row.get('fence_error')) is int and row['fence_error'] != 0
            and type(row.get('fence_lifetime_revision')) is int and row['fence_lifetime_revision'] >= 0
            and isinstance(row.get('player_left_events'), list)
            and departed_uuid in row['player_left_events']
            and all(isinstance(item, str) and _UUID.fullmatch(item) for item in row['player_left_events'])
            and row.get('roster') == roster and row.get('frozen_roster') == roster
            and type(row.get('departed_slot')) is int and row['departed_slot'] == departed_slot
            and row.get('departed_uuid') == departed_uuid
            and isinstance(live, list) and sorted(live) == sorted(survivor_uuids)
            and row.get('drop_events') == 0 and row.get('drop_pending_events') == 0
            and row.get('barrier_open') is False
            and isinstance(row.get('session_id'), str) and re.fullmatch(r'[0-9a-f]{32}', row['session_id'])
            and row.get('session_id') == session)


def _validate_room_evidence(result, room_departure, room_continue):
    peers = result['records'][0]['peers']
    rows = []
    for index, peer in enumerate(peers):
        _room_physical(peer)
        witness = peer.get('result')
        if room_continue and index < 2:
            failure = witness.get('failure', {})
            if (witness.get('passed') is not False or failure.get('stage') != 'peer_drop_room'
                    or failure.get('errors') != ['peer_drop_room_continued']):
                raise ValueError('room-departure continuation control did not fail at the fence')
            rows.append(None)
            continue
        if witness.get('passed') is not True:
            raise ValueError('room-departure witness did not complete')
        records = witness.get('records')
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError('room-departure witness record missing')
        rows.append(records[0])
    departed = rows[2]
    roster = departed.get('roster') if isinstance(departed, dict) else None
    if (not isinstance(roster, list) or len(roster) != 3
            or any(not isinstance(uuid, str) or not _UUID.fullmatch(uuid) for uuid in roster)
            or roster != sorted(roster) or len(set(roster)) != 3):
        raise ValueError('room-departure frozen roster invalid')
    session = departed.get('session_id')
    if not isinstance(session, str) or not re.fullmatch(r'[0-9a-f]{32}', session):
        raise ValueError('room-departure session identity invalid')
    if not _room_departing_row(departed, roster, session):
        raise ValueError('room-departure departing page evidence invalid')
    if room_continue:
        return result
    departed_slot, departed_uuid = departed['slot'], departed['uuid']
    for row in rows[:2]:
        if not _room_survivor_row(row, roster, departed_uuid, departed_slot, session):
            raise ValueError('room-departure survivor fence invalid')
    if sorted([departed_slot, rows[0]['slot'], rows[1]['slot']]) != [0, 1, 2]:
        raise ValueError('room-departure roster slots changed')
    if len({(row['fence_frame'], row['departed_slot'], row['departed_uuid']) for row in rows[:2]}) != 1:
        raise ValueError('room-departure survivors disagreed on the fence')
    return result


def validate_drop_browser(result, corrupt=False, physical_close=False, lost_answer=False, relay_only=False,
                           missing_history=False, second_departure=False, rollback_departure=False, foreign_proposal=False,
                           room_departure=False, room_continue=False):
    if (second_departure and rollback_departure) or (room_departure and room_continue) or (
            (room_departure or room_continue) and (
                corrupt or physical_close or lost_answer or relay_only or missing_history or second_departure or rollback_departure)) or (
            foreign_proposal and (
                corrupt or physical_close or lost_answer or relay_only or missing_history or second_departure or rollback_departure)):
        raise ValueError('peer-drop modes are exclusive')
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('peerDrop') is not True
            or result.get('dropCorrupt') is not corrupt or result.get('dropAnswer', False) is not lost_answer
            or result.get('dropRelay', False) is not relay_only or result.get('dropClose', False) is not physical_close
            or result.get('dropMissing', False) is not missing_history
            or result.get('dropSecond', False) is not second_departure or result.get('dropRollback', False) is not rollback_departure
            or result.get('dropForeign', False) is not foreign_proposal
            or result.get('dropRoom', False) is not room_departure
            or result.get('dropRoomContinue', False) is not room_continue
            or result.get('errors') != []
            or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2):
        raise ValueError('peer-drop browser run incomplete')
    records = result.get('records')
    if (not isinstance(records, list) or len(records) != 1 or type(records[0].get('players')) is not int
            or records[0]['players'] != 3 or len(records[0].get('peers', [])) != 3):
        raise ValueError('peer-drop requires three real exported peers')
    if room_departure or room_continue:
        return _validate_room_evidence(result, room_departure, room_continue)
    survivors = []
    for index, peer in enumerate(records[0]['peers']):
        rtc = peer.get('rtc')
        if not isinstance(rtc, dict) or any(type(rtc.get(field)) is not int or rtc[field] < 1 for field in ('sent', 'received')):
            raise ValueError('peer-drop physical packet evidence missing')
        witness = peer.get('result')
        if not isinstance(witness, dict):
            raise ValueError('peer-drop gameplay result missing')
        channels = rtc.get('channels')
        if not isinstance(channels, list) or len(channels) != 6:
            raise ValueError('peer-drop channel inventory incomplete')
        if any(type(channel.get('id')) is not int for channel in channels):
            raise ValueError('peer-drop channel identity is not an integer')
        if any(sum(channel.get('id') == channel_id for channel in channels) != 2 for channel_id in (1, 2, 3)):
            raise ValueError('peer-drop channel IDs incomplete')
        for channel in channels:
            if channel.get('id') != 3: continue
            if (channel.get('ordered') is not False or channel.get('negotiated') is not True
                    or type(channel.get('maxPacketLifeTime')) is not int or channel['maxPacketLifeTime'] != 1
                    or channel.get('maxRetransmits', False) is not None
                    or any(type(channel.get(field)) is not int or channel[field] < 1 for field in ('sent', 'received'))):
                raise ValueError('peer-drop unreliable physical delivery missing')
        teardown = rtc.get('teardown', {})
        if (type(teardown.get('channels')) is not int or teardown['channels'] != 6 or type(teardown.get('connections_created')) is not int
                or teardown['connections_created'] < 2 or type(teardown.get('connections')) is not int
                or teardown['connections'] != teardown['connections_created']
                or type(teardown.get('websockets_created')) is not int or teardown['websockets_created'] < 1
                or type(teardown.get('websockets')) is not int or teardown['websockets'] != teardown['websockets_created']):
            raise ValueError('peer-drop browser resources survived teardown')
        if corrupt and index < 2:
            failure = witness.get('failure', {})
            errors = failure.get('errors')
            if (witness.get('passed') is not False or failure.get('stage') != 'peer_drop_gameplay'
                    or not isinstance(errors, list) or len(errors) != 1 or not isinstance(errors[0], str)
                    or not re.fullmatch(r'peer_drop_canonical_(?:[89]|[12][0-9]|3[0-7])', errors[0])):
                raise ValueError('peer-drop corruption missed canonical continuation gate')
            continue
        rows = witness.get('records')
        if witness.get('passed') is not True or not isinstance(rows, list) or len(rows) != 1:
            raise ValueError('peer-drop gameplay result missing')
        row = rows[0]
        if second_departure and index == 2:
            if not _departing_row(row, 1, 7):
                raise ValueError('peer-drop first departure evidence missing')
            continue
        if not second_departure:
            if index == 2:
                if not _departing_row(row, 1, 8 if rollback_departure else 7):
                    raise ValueError('peer-drop departure or continued input missing')
                if rollback_departure and (type(row.get('held_packets')) is not int or row['held_packets'] < 1
                                           or type(row.get('sent_packets')) is not int or row['sent_packets'] < 1
                                           or row['sent_packets'] < row['held_packets']
                                           or row['sent_packets'] > rtc['sent']):
                    raise ValueError('peer-drop rollback held packet was not sent')
                if physical_close or relay_only:
                    departure = rtc.get('departure', {})
                    for field, expected in [('frame', 6), ('channels_created', 6), ('channels_closed', 6)]:
                        if type(departure.get(field)) is not int or departure[field] != expected:
                            raise ValueError('peer-drop physical departure incomplete')
                    if (departure.get('survivor_frames') != [6, 6] or any(type(frame) is not int for frame in departure['survivor_frames'])
                            or type(departure.get('connections_created')) is not int or departure['connections_created'] < 2
                            or type(departure.get('connections_closed')) is not int
                            or departure['connections_closed'] != departure['connections_created']):
                        raise ValueError('peer-drop physical departure incomplete')
                continue
            if (row.get('departed') is not False or type(row.get('frames_submitted')) is not int
                    or row['frames_submitted'] != 40):
                raise ValueError('peer-drop departure or continued input missing')
        elif index == 1:
            if (not _departing_row(row, 2, 12)
                    or type(row.get('canonical_comparisons')) is not int or row['canonical_comparisons'] != 10
                    or type(row.get('drop_events')) is not int or row['drop_events'] != 1):
                raise ValueError('peer-drop second departure evidence missing')
        if physical_close or relay_only:
            mixed = row.get('mixed', {})
            continuing = [channel for channel in channels if channel.get('id') == 3 and type(channel.get('restoredSent')) is int
                          and channel['restoredSent'] > 0 and type(channel.get('postDropReceived')) is int and channel['postDropReceived'] > 0]
            if not relay_only and len(continuing) != 1:
                raise ValueError('peer-drop surviving direct link did not continue physical delivery')
            if (type(rtc.get('binarySent')) is not int or rtc['binarySent'] < 1
                    or mixed.get('switched') is not True or type(mixed.get('relay_peers')) is not int or mixed['relay_peers'] != (2 if relay_only else 1)
                    or type(mixed.get('caller_pending')) is not int or mixed['caller_pending'] != 0):
                raise ValueError('peer-drop physical outage did not use bounded fallback relay')
            for field in ('maximum_pending', 'maximum_relay_pending', 'maximum_relay_received'):
                if type(mixed.get(field)) is not int or not 0 <= mixed[field] <= 128:
                    raise ValueError('peer-drop fallback queue exceeded its bound')
            for field, expected in [('route_budget', 8), ('send_budget', 32), ('receive_budget', 32)]:
                if type(mixed.get(field)) is not int or mixed[field] != expected:
                    raise ValueError('peer-drop fallback work budget changed')
            if type(rtc.get('maximumRelayBuffered')) is not int or not 0 <= rtc['maximumRelayBuffered'] <= 262144:
                raise ValueError('peer-drop relay socket exceeded its bound')
        required = [('players', 3), ('state', 'committed')]
        if second_departure and index == 0:
            required += [('drop_events', 2), ('active_comparisons', 30), ('canonical_comparisons', 38),
                         ('frames_submitted', 40), ('departed', False)]
        elif second_departure:
            if type(row.get('active_comparisons')) is not int or row['active_comparisons'] < 2:
                raise ValueError('peer-drop second departure active comparisons missing')
            if type(row.get('minimum_confirmed')) is not int or row['minimum_confirmed'] < 10:
                raise ValueError('peer-drop second departure confirmation missing')
        else:
            required += [('drop_events', 1), ('canonical_comparisons', 38), ('active_comparisons', 30)]
        for field, expected in required:
            if (row.get(field) != expected or (type(expected) is int and type(row.get(field)) is not int)
                    or (type(expected) is bool and type(row.get(field)) is not bool)):
                raise ValueError('peer-drop agreement or canonical history incomplete')
        minimum_confirmed = 10 if second_departure and index == 1 else 38
        if (type(row.get('slot')) is not int or not 0 <= row['slot'] < 3
                or type(row.get('freeze_frame')) is not int
                or (row['freeze_frame'] != 7 if rollback_departure else not 0 <= row['freeze_frame'] <= 6)
                or type(row.get('departing_slot')) is not int or not 0 <= row['departing_slot'] < 3
                or type(row.get('minimum_confirmed')) is not int or row['minimum_confirmed'] < minimum_confirmed
                or type(row.get('rollback_loads')) is not int or row['rollback_loads'] < 1
                or type(row.get('prediction_gap')) is not int
                or (row['prediction_gap'] != 0 if rollback_departure else row['prediction_gap'] < 1)):
            raise ValueError('peer-drop frozen boundary or confirmation invalid')
        if rollback_departure and (type(row.get('pending_at_detection')) is not int or row['pending_at_detection'] != 7
                                   or type(row.get('freeze_frame')) is not int or row['freeze_frame'] != 7
                                   or row['pending_at_detection'] < row['freeze_frame']):
            raise ValueError('peer-drop rollback correction was not pending at the agreed cut')
        if second_departure:
            roster = row.get('roster')
            slot = row.get('departing_slot')
            if not isinstance(roster, list) or type(slot) is not int or not 0 <= slot < len(roster):
                raise ValueError('peer-drop publication frame missing')
            first_id = _peer_id(roster[slot])
            frames = row.get('drop_frames')
            if (not isinstance(frames, dict) or type(frames.get(first_id)) is not int
                    or frames[first_id] != row['freeze_frame']
                    or type(row.get('pending_events')) is not int or row['pending_events'] != 1
                    or not isinstance(row.get('commit_ack_peers'), list) or not isinstance(row.get('acknowledged_peers'), list)):
                raise ValueError('peer-drop publication frame missing')
        expected_value = bytes([(row['freeze_frame'] * 17 + row['departing_slot'] * 31 + 1) & 255]).hex()
        if row.get('frozen_value') != expected_value:
            raise ValueError('peer-drop frozen sample differs from original input')
        if (type(row.get('role')) is not int or row['role'] not in (0, 1)
                or row.get('certified') is not (row['role'] == 0)
                or type(row.get('certificates')) is not int or row['certificates'] != row['role']):
            raise ValueError('peer-drop all-survivor certificate missing')
        survivors.append(row)
    if second_departure:
        last = next((row for row in survivors if row.get('departed') is False), None)
        proposer = next((row for row in survivors if row.get('role') == 1), None)
        departed_second = records[0]['peers'][1]['result']['records'][0]
        second_id = _peer_id(departed_second.get('uuid'))
        if last is None or proposer is None:
            raise ValueError('peer-drop second departure survivor missing')
        first_row = records[0]['peers'][2]['result']['records'][0]
        roster = last.get('roster')
        first_slot = last.get('departing_slot')
        if (not isinstance(roster, list) or type(first_slot) is not int or not 0 <= first_slot < len(roster)
                or first_row.get('slot') != first_slot or first_row.get('uuid') != roster[first_slot]
                or proposer.get('departing_slot') != first_slot):
            raise ValueError('peer-drop first departure identity missing')
        second_slot = last.get('second_slot')
        second_frame = last.get('second_freeze_frame')
        frames = last.get('drop_frames')
        if (type(second_slot) is not int or not 0 <= second_slot < 3
                or type(second_frame) is not int or not 10 <= second_frame <= 11
                or type(last.get('second_frontier')) is not int or last['second_frontier'] != second_frame
                or not isinstance(roster, list) or len(roster) != 3
                or departed_second.get('uuid') != roster[second_slot]
                or second_slot != departed_second.get('slot')
                or second_slot == last.get('departing_slot')
                or not isinstance(frames, dict) or type(frames.get(second_id)) is not int or frames[second_id] != second_frame
                or last.get('second_frozen_value') != bytes([(second_frame * 17 + second_slot * 31 + 1) & 255]).hex()):
            raise ValueError('peer-drop second departure freeze missing')
        acknowledgements = proposer.get('commit_ack_peers')
        acknowledged = proposer.get('acknowledged_peers')
        participants = proposer.get('participants')
        if (not isinstance(acknowledgements, list) or not isinstance(acknowledged, list)
                or not isinstance(participants, list) or not participants
                or any(not isinstance(item, str) for item in acknowledgements + acknowledged + participants)):
            raise ValueError('peer-drop first commit unconfirmed')
        closed = set(acknowledgements) | set(acknowledged)
        if not all(identity in closed for identity in participants):
            raise ValueError('peer-drop first commit unconfirmed')
    if lost_answer:
        lost = []
        for index, peer in enumerate(records[0]['peers']):
            loss = peer.get('rtc', {}).get('answerLoss', {})
            if (type(loss.get('dropped')) is not int or loss['dropped'] not in (0, 1)
                    or type(loss.get('retries')) is not int or loss['retries'] < 0):
                raise ValueError('peer-drop lost answer evidence missing')
            if loss['dropped'] == 0:
                if loss.get('packet', 'missing') is not None or loss['retries'] != 0:
                    raise ValueError('peer-drop lost answer evidence inconsistent')
                continue
            packet = loss.get('packet')
            row = peer['result']['records'][0]
            if (index == 2 or row.get('role') != 0 or loss['retries'] < 1 or not isinstance(packet, str)
                    or not re.fullmatch(r'[0-9a-f]{200,2048}', packet) or len(packet) % 2):
                raise ValueError('peer-drop lost answer did not retry on the follower')
            data = bytes.fromhex(packet)
            sender = hashlib.sha256(row['uuid'].encode('ascii')).digest()[:8]
            if (data[:8] != b'FRGP\x03\x00\x0c\x00' or data[24:32] != sender
                    or int.from_bytes(data[40:44], 'little') != len(data) - 44 or data[44:46] != b'\x02\x01'):
                raise ValueError('peer-drop lost answer packet is not the follower inventory')
            lost.append(loss)
        if len(lost) != 1:
            raise ValueError('peer-drop lost answer must affect exactly one follower')
    if not corrupt:
        all_rows = [peer['result']['records'][0] for peer in records[0]['peers']]
        uuids = [row.get('uuid') for row in all_rows]
        if (any(not isinstance(uuid, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', uuid) for uuid in uuids)
                or len(set(uuids)) != 3):
            raise ValueError('peer-drop original identities invalid')
        roster = sorted(uuids)
        for row in all_rows:
            if row.get('roster') != roster or type(row.get('slot')) is not int or row['slot'] != roster.index(row['uuid']):
                raise ValueError('peer-drop frozen roster changed')
        if missing_history:
            departed = records[0]['peers'][2]['result']['records'][0]
            report = departed.get('missing_inputs')
            if (not isinstance(report, dict) or set(report) != {'dropped', 'from', 'through', 'frames', 'overlaps', 'slot', 'unsupported'}
                    or report.get('dropped') != 3
                    or report.get('from') != 4 or report.get('through') != 6
                    or report.get('frames') != [4, 5, 6] or report.get('overlaps') != 0
                    or report.get('unsupported') != 0 or report.get('slot') != departed.get('slot')):
                raise ValueError('peer-drop missing input withholding evidence missing')
            proposer = next(row for row in survivors if row['role'] == 1)
            follower = next(row for row in survivors if row['role'] == 0)
            if (proposer.get('history_installed') is not True
                    or type(proposer.get('history_first')) is not int or not 0 <= proposer['history_first'] <= 4
                    or type(proposer.get('history_cut')) is not int or proposer['history_cut'] < 6
                    or proposer.get('history_cut') != proposer.get('freeze_frame')
                    or proposer.get('history_donor') != follower.get('slot')
                    or follower.get('history_donor') != follower.get('slot')):
                raise ValueError('peer-drop live missing-history transfer incomplete')
        proposer_slot = min(row['slot'] for row in survivors)
        for row in survivors:
            if row['role'] != int(row['slot'] == proposer_slot):
                raise ValueError('peer-drop coordinator differs from lowest surviving slot')
            other = next(item for item in survivors if item is not row)
            other_id = hashlib.sha256(other['uuid'].encode('ascii')).digest()[:8].hex()
            if row.get('participants') != [other_id]:
                raise ValueError('peer-drop certificate participant differs from original survivor')
            digest = 0x14650fb0739d0383
            for byte in bytes.fromhex(row['frozen_value']):
                digest = ((digest ^ byte) * 1099511628211) & 0x3fffffffffffffff
            digest_hex = f'{digest or 1:016x}'
            if row.get('digest') != digest_hex:
                raise ValueError('peer-drop digest differs from original frozen sample')
            expected = [{'peer': other_id, 'cut': row['freeze_frame'], 'digest': digest_hex}] if row['role'] == 1 else []
            certificate_rows = row.get('certificate_rows')
            if (certificate_rows != expected or not isinstance(certificate_rows, list)
                    or any(type(item.get('cut')) is not int for item in certificate_rows)):
                raise ValueError('peer-drop participant certificate differs from agreed frame or value')
        if relay_only:
            for index, row in enumerate(survivors):
                peer = records[0]['peers'][index]
                rtc = peer['rtc']
                departure = rtc.get('departure', {})
                if (departure.get('frame') != 6 or type(departure.get('frame')) is not int
                        or departure.get('survivor_frames') != [6, 6]
                        or any(type(frame) is not int for frame in departure['survivor_frames'])
                        or any(type(departure.get(field)) is not int for field in
                               ('connections_created', 'connections_closed', 'channels_created', 'channels_closed'))
                        or departure['connections_created'] < 2 or departure['connections_closed'] != departure['connections_created']
                        or departure['channels_created'] != 6 or departure['channels_closed'] != 6):
                    raise ValueError('peer-drop relay direct paths were not closed before agreement')
                if any(type(channel.get(field)) is not int or channel[field] != 0
                       for channel in rtc['channels'] for field in ('restoredSent', 'postDropReceived')):
                    raise ValueError('peer-drop relay continued direct delivery')
                packets = row.get('relay_barriers')
                accepted = row['mixed'].get('accepted_binary')
                if (type(accepted) is not int or accepted < 1 or not isinstance(packets, list)
                        or not 1 <= len(packets) <= 128 or len(packets) > accepted):
                    raise ValueError('peer-drop relay barrier receipts missing')
                other = next(item for item in survivors if item is not row)
                sender = hashlib.sha256(other['uuid'].encode('ascii')).digest()[:8]
                required = (2, 2) if row['role'] == 1 else (4, 0)
                found = False
                for packet in packets:
                    if not isinstance(packet, str) or not re.fullmatch(r'[0-9a-f]{202,2048}', packet) or len(packet) % 2:
                        raise ValueError('peer-drop relay barrier packet malformed')
                    data = bytes.fromhex(packet)
                    targets = int.from_bytes(data[90:94], 'little')
                    if (data[:8] != b'FRGP\x03\x00\x0c\x00' or data[24:32] != sender
                            or data[8:24].hex() != row.get('session_id')
                            or int.from_bytes(data[40:44], 'little') != len(data) - 44
                            or targets != 3 or data[94] != row['departing_slot']
                            or type(row.get('target_generation')) is not int
                            or int.from_bytes(data[95:97], 'little') != row['target_generation']
                            or 98 + targets > len(data)
                            or int.from_bytes(data[94 + targets:98 + targets], 'little') != len(data) - 98 - targets - 8
                            or any(type(row.get(field)) is not int or int.from_bytes(data[start:end], 'little') != row[field]
                                   for field, start, end in [('coordinator', 48, 50), ('coordinator_generation', 50, 52), ('operation', 52, 56)])
                            or f"{int.from_bytes(data[56:64], 'little'):016x}" != row.get('target_set_digest')):
                        raise ValueError('peer-drop relay barrier identity differs from survivor operation')
                    if tuple(data[44:46]) == required:
                        if (int.from_bytes(data[64:68], 'little', signed=True) != row['freeze_frame']
                                or f"{int.from_bytes(data[76:84], 'little'):016x}" != row['digest']):
                            raise ValueError('peer-drop relay certificate differs from committed history')
                        found = True
                if not found:
                    raise ValueError('peer-drop relay all-survivor certificate or commit missing')
        departed = records[0]['peers'][2]['result']['records'][0]
        if (type(departed.get('slot')) is not int or not 0 <= departed['slot'] < 3
                or any(row['departing_slot'] != departed['slot'] for row in survivors)
                or sorted([departed['slot']] + [row.get('slot', -1) for row in survivors]) != [0, 1, 2]):
            raise ValueError('peer-drop roster slots changed')
        if (sorted(row['role'] for row in survivors) != [0, 1]
                or len({(row['freeze_frame'], row['frozen_value'], row['departing_slot']) for row in survivors}) != 1):
            raise ValueError('peer-drop survivors disagreed')
        if foreign_proposal:
            follower = next(row for row in survivors if row['role'] == 0)
            proposer = next(row for row in survivors if row['role'] == 1)
            sent = follower.get('foreign_sent')
            received = proposer.get('foreign_received')
            cut = proposer.get('foreign_cut')
            digest = proposer.get('foreign_digest')
            reason = proposer.get('foreign_reason')
            if (type(sent) is not int or not 1 <= sent <= 3
                    or type(received) is not int or not 1 <= received <= sent
                    or type(cut) is not int or cut != 2
                    or type(digest) is not int or digest != 999
                    or type(reason) is not str or reason != 'coordinator'
                    or type(follower.get('foreign_received')) is not int or follower['foreign_received'] != 0
                    or type(proposer.get('foreign_sent')) is not int or proposer['foreign_sent'] != 0
                    or follower.get('freeze_frame') == 2 or proposer.get('freeze_frame') == 2):
                raise ValueError('peer-drop foreign proposal evidence missing')
    return result
