"""Validate coordinated-drop browser evidence separately from ordinary fixed meshes."""
import re
import hashlib


_UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
# The barrier window is 4 s and RETRY_US is 50 ms, which bounds commit
# re-emissions at one per interval. The transport observes each poll on its own
# clock sample, so the retry delay floor allows one service round of jitter.
MAX_COMMIT_RETRIES = 80
MIN_COMMIT_RETRY_DELAY_US = 40000


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
            and type(row.get('final_frame')) is int and row['final_frame'] == row['fence_frame']
            and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 0
            and row.get('room_fenced') is True
            and row.get('fence_route') == 'restart_required'
            and type(row.get('fence_error')) is int and row['fence_error'] == 2
            and type(row.get('fence_lifetime_revision')) is int and row['fence_lifetime_revision'] >= 0
            and row.get('player_left_events') == [departed_uuid]
            and row.get('roster') == roster and row.get('frozen_roster') == roster
            and type(row.get('departed_slot')) is int and row['departed_slot'] == departed_slot
            and row.get('departed_uuid') == departed_uuid
            and isinstance(live, list) and sorted(live) == sorted(survivor_uuids)
            and type(row.get('drop_events')) is int and row['drop_events'] == 0
            and type(row.get('drop_pending_events')) is int and row['drop_pending_events'] == 0
            and row.get('barrier_open') is False
            and isinstance(row.get('session_id'), str) and re.fullmatch(r'[0-9a-f]{32}', row['session_id'])
            and row.get('session_id') == session)


def _room_continue_row(row):
    return (isinstance(row, dict)
            and row.get('departed') is False and row.get('room_fenced') is True
            and type(row.get('fence_frame')) is int and row['fence_frame'] == 7
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 8
            and type(row.get('final_frame')) is int and row['final_frame'] == 8
            and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 1
            and type(row.get('continue_code')) is int and row['continue_code'] == 0)


def _room_departing_kind(row, roster, session, kind):
    return (row.get('departed') is True
            and type(row.get('departure_sequence')) is int and row['departure_sequence'] == 1
            and row.get('departure_kind') == kind
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 7
            and isinstance(row.get('uuid'), str) and row['uuid'] in roster
            and type(row.get('slot')) is int and 0 <= row['slot'] < 3 and roster[row['slot']] == row['uuid']
            and row.get('roster') == roster
            and isinstance(row.get('room_code_before'), str) and row['room_code_before']
            and row.get('room_code_after') == ''
            and row.get('room_left') is True
            and row.get('connected') is True and row.get('authenticated') is True
            and row.get('session_id') == session)


def _roster_and_session(departed):
    roster = departed.get('roster')
    if (not isinstance(roster, list) or len(roster) != 3
            or any(not isinstance(uuid, str) or not _UUID.fullmatch(uuid) for uuid in roster)
            or roster != sorted(roster) or len(set(roster)) != 3):
        raise ValueError('room-departure frozen roster invalid')
    session = departed.get('session_id')
    if not isinstance(session, str) or not re.fullmatch(r'[0-9a-f]{32}', session):
        raise ValueError('room-departure session identity invalid')
    return roster, session


def _process_survivor_row(row, roster, departed_uuid, departed_slot, session):
    live = row.get('room_roster_after')
    survivors = [uuid for slot, uuid in enumerate(roster) if slot != departed_slot]
    return (row.get('departed') is False
            and type(row.get('slot')) is int and 0 <= row['slot'] < 3
            and isinstance(row.get('uuid'), str) and row.get('uuid') == row.get('local_uuid')
            and row['uuid'] in roster and roster[row['slot']] == row['uuid']
            and row['uuid'] != departed_uuid
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 7
            and type(row.get('fence_frame')) is int and row['fence_frame'] == 7
            and type(row.get('final_frame')) is int and row['final_frame'] == 7
            and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 0
            and row.get('room_fenced') is True
            and row.get('fence_route') == 'restart_required'
            and type(row.get('fence_error')) is int and row['fence_error'] == 2
            and type(row.get('fence_lifetime_revision')) is int and row['fence_lifetime_revision'] >= 0
            and row.get('player_left_events') == [departed_uuid]
            and row.get('roster') == roster and row.get('frozen_roster') == roster
            and type(row.get('departed_slot')) is int and row['departed_slot'] == departed_slot
            and row.get('departed_uuid') == departed_uuid
            and isinstance(live, list) and sorted(live) == sorted(survivors)
            and type(row.get('drop_events')) is int and row['drop_events'] == 0
            and type(row.get('drop_pending_events')) is int and row['drop_pending_events'] == 0
            and row.get('barrier_open') is False
            and row.get('session_id') == session)


def _validate_process_evidence(result):
    peers = result['records'][0]['peers']
    held = result['records'][0].get('processHeld')
    if result['records'][0].get('processClosed') is not True:
        raise ValueError('process-death witness did not close the departing browser context')
    if (not isinstance(held, dict) or held.get('witness') is not None or held.get('teardown') is not None
            or held.get('go') is not False or held.get('frame') != '6'
            or held.get('healthy') is not True or held.get('connected') is not True
            or held.get('authenticated') is not True or not isinstance(held.get('room'), str) or not held['room']
            or type(held.get('errors')) is not int or held['errors'] != 0):
        raise ValueError('process-death departing page was not still healthy before the close')
    if len(peers) != 2:
        raise ValueError('process-death witness must retain exactly two survivors')
    departed_uuid = result['records'][0].get('departedUuid')
    if not isinstance(departed_uuid, str) or not _UUID.fullmatch(departed_uuid):
        raise ValueError('process-death departed identity is missing from the Node harness')
    rows = []
    for peer in peers:
        _room_physical(peer)
        witness = peer.get('result')
        if not isinstance(witness, dict) or witness.get('passed') is not True:
            raise ValueError('process-death survivor witness did not complete')
        records = witness.get('records')
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError('process-death survivor record missing')
        rows.append(records[0])
    departed_rows = [row for row in rows if row.get('departed') is True]
    if departed_rows:
        raise ValueError('process-death departed page published a row')
    roster = rows[0].get('roster')
    session = rows[0].get('session_id') if rows else None
    if (not isinstance(roster, list) or len(roster) != 3
            or any(not isinstance(uuid, str) or not _UUID.fullmatch(uuid) for uuid in roster)
            or roster != sorted(roster) or len(set(roster)) != 3):
        raise ValueError('process-death frozen roster invalid')
    if departed_uuid not in roster:
        raise ValueError('process-death departed identity left the frozen roster')
    departed_slot = roster.index(departed_uuid)
    if not isinstance(session, str) or not re.fullmatch(r'[0-9a-f]{32}', session):
        raise ValueError('process-death session identity invalid')
    for row in rows:
        if not _process_survivor_row(row, roster, departed_uuid, departed_slot, session):
            raise ValueError('process-death survivor fence invalid')
    if sorted(slot for slot in range(3) if slot != departed_slot) != sorted(row.get('slot') for row in rows):
        raise ValueError('process-death survivor slots changed')
    return result


def _validate_process_missing(result):
    peers = result['records'][0]['peers']
    departed_uuid = result['records'][0].get('departedUuid')
    survivor_uuids = result['records'][0].get('survivorUuids')
    if not isinstance(departed_uuid, str) or not _UUID.fullmatch(departed_uuid):
        raise ValueError('process-death missing-event control has no departing identity')
    if (not isinstance(survivor_uuids, list) or len(survivor_uuids) != 2
            or any(not isinstance(uuid, str) or not _UUID.fullmatch(uuid) for uuid in survivor_uuids)
            or len(set(survivor_uuids)) != 2 or departed_uuid in survivor_uuids):
        raise ValueError('process-death missing-event control has no survivor identities')
    if len(peers) != 3:
        raise ValueError('process-death missing-event control requires three peers')
    by_index = {}
    for peer in peers:
        _room_physical(peer)
        witness = peer.get('result')
        if not isinstance(witness, dict) or witness.get('passed') is not False:
            raise ValueError('process-death missing-event control did not fail')
        failure = witness.get('failure', {})
        index = failure.get('local_index')
        if type(index) is not int or index not in (0, 1, 2) or index in by_index:
            raise ValueError('process-death missing-event failure identity invalid')
        records = failure.get('records')
        errors = failure.get('errors')
        expected = 'peer_drop_room_gate' if index == 2 else 'peer_drop_room_fence'
        stage_ok = failure.get('stage') == ('handshake' if index == 2 else 'peer_drop_room_fence')
        identity = failure.get('uuid')
        identity_ok = (identity == departed_uuid) if index == 2 else (
            index in (0, 1) and identity == survivor_uuids[index])
        if (not isinstance(errors, list) or errors != [expected]
                or not isinstance(records, list) or records != []
                or not stage_ok or not identity_ok):
            raise ValueError('process-death missing-event control failed outside the fence wait')
        if index == 2 and (type(failure.get('hold_ms')) is not int or failure['hold_ms'] < 0):
            raise ValueError('process-death missing-event hold was not released by the Node')
        by_index[index] = failure
    if set(by_index) != {0, 1, 2}:
        raise ValueError('process-death missing-event control did not exercise every peer')
    return result


def _validate_before_drop(result):
    peers = result['records'][0]['peers']
    if len(peers) != 3:
        raise ValueError('pre-commit room event requires three real exported peers')
    rows = []
    for peer in peers:
        _room_physical(peer)
        witness = peer.get('result')
        if not isinstance(witness, dict) or witness.get('passed') is not True:
            raise ValueError('pre-commit room witness did not complete')
        records = witness.get('records')
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError('pre-commit room witness record missing')
        rows.append(records[0])
    departed_rows = [row for row in rows if row.get('departed') is True]
    if len(departed_rows) != 1:
        raise ValueError('pre-commit room event must name exactly one departing page')
    departed = departed_rows[0]
    roster, session = _roster_and_session(departed)
    if not _room_departing_kind(departed, roster, session, 'room_left_before_drop'):
        raise ValueError('pre-commit departing page evidence invalid')
    survivors = [row for row in rows if row is not departed]
    if len(survivors) != 2:
        raise ValueError('pre-commit survivor evidence missing')
    departed_slot, departed_uuid = departed['slot'], departed['uuid']
    live = sorted(uuid for slot, uuid in enumerate(roster) if slot != departed_slot)
    for row in survivors:
        if not (row.get('departed') is False
                and type(row.get('slot')) is int and 0 <= row['slot'] < 3
                and row.get('uuid') == row.get('local_uuid') and row['uuid'] in roster
                and roster[row['slot']] == row['uuid']
                and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 7
                and type(row.get('fence_frame')) is int and row['fence_frame'] == 7
                and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 0
                and type(row.get('final_frame')) is int and row['final_frame'] == row['fence_frame'] + row['frames_after_fence']
                and row.get('room_fenced') is True
                and row.get('fence_route') == 'restart_required'
                and type(row.get('fence_error')) is int and row['fence_error'] == 2
                and row.get('player_left_events') == [departed_uuid]
                and row.get('frozen_roster') == roster
                and type(row.get('departed_slot')) is int and row['departed_slot'] == departed_slot
                and row.get('departed_uuid') == departed_uuid
                and isinstance(row.get('room_roster_after'), list)
                and sorted(row['room_roster_after']) == live
                and type(row.get('drop_events')) is int and row['drop_events'] == 0
                and type(row.get('drop_pending_events')) is int and row['drop_pending_events'] == 1
                and row.get('barrier_open') is True
                and row.get('barrier_state') == 'pending'
                and row.get('barrier_certified') is False
                and row.get('barrier_value') == ''
                and type(row.get('freeze_frame')) is int and row['freeze_frame'] == -1
                and type(row.get('canonical_comparisons')) is int and row['canonical_comparisons'] == 6
                and row.get('canonical_unchanged') is True
                and row.get('session_id') == session):
            raise ValueError('pre-commit survivor fence or unchanged history invalid')
    if sorted([departed_slot] + [row['slot'] for row in survivors]) != [0, 1, 2]:
        raise ValueError('pre-commit roster slots changed')
    if len({row['fence_frame'] for row in survivors}) != 1:
        raise ValueError('pre-commit survivors disagreed on the fence')
    return result


def _validate_after_drop(result, survivors):
    peers = result['records'][0]['peers']
    departed = peers[2]['result']['records'][0]
    roster, session = _roster_and_session(departed)
    if not _room_departing_kind(departed, roster, session, 'room_left_after_drop'):
        raise ValueError('post-drop departing page evidence invalid')
    departed_slot, departed_uuid = departed['slot'], departed['uuid']
    live = sorted(uuid for slot, uuid in enumerate(roster) if slot != departed_slot)
    for row in survivors:
        if not (type(row.get('fence_frame')) is int and row['fence_frame'] == row.get('frames_submitted')
                and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 40
                and type(row.get('frames_after_fence')) is int and row['frames_after_fence'] == 0
                and type(row.get('final_frame')) is int and row['final_frame'] == row['fence_frame'] + row['frames_after_fence']
                and row.get('room_fenced') is True
                and row.get('fence_route') == 'restart_required'
                and type(row.get('fence_error')) is int and row['fence_error'] == 2
                and row.get('player_left_events') == [departed_uuid]
                and row.get('frozen_roster') == roster
                and type(row.get('departed_slot')) is int and row['departed_slot'] == departed_slot
                and row.get('departed_uuid') == departed_uuid
                and row.get('local_uuid') == row.get('uuid')
                and isinstance(row.get('room_roster_after'), list)
                and sorted(row['room_roster_after']) == live
                and type(row.get('drop_events')) is int and row['drop_events'] == 1
                and row.get('barrier_committed') is True
                and row.get('barrier_open') is True
                and type(row.get('fence_history_comparisons')) is int and row['fence_history_comparisons'] == 38
                and row.get('session_id') == session):
            raise ValueError('post-drop certified freeze or terminal fence invalid')
    if sorted([departed_slot] + [row['slot'] for row in survivors]) != [0, 1, 2]:
        raise ValueError('post-drop roster slots changed')
    if len({(row['fence_frame'], row['departed_slot'], row['departed_uuid']) for row in survivors}) != 1:
        raise ValueError('post-drop survivors disagreed on the fence')
    return result


def _validate_room_evidence(result, room_departure, room_continue):
    peers = result['records'][0]['peers']
    rows = []
    failures = []
    for peer in peers:
        _room_physical(peer)
        witness = peer.get('result')
        if room_continue and witness.get('passed') is False:
            failure = witness.get('failure', {})
            control_rows = failure.get('records')
            if (failure.get('stage') != 'peer_drop_room'
                    or failure.get('errors') != ['peer_drop_room_continued']
                    or not isinstance(control_rows, list) or len(control_rows) != 1
                    or not _room_continue_row(control_rows[0])):
                raise ValueError('room-departure continuation control did not fail at the fence')
            failures.append(control_rows[0])
            rows.append(None)
            continue
        if witness.get('passed') is not True:
            raise ValueError('room-departure witness did not complete')
        records = witness.get('records')
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError('room-departure witness record missing')
        rows.append(records[0])
    if room_continue and len(failures) != 2:
        raise ValueError('room-departure continuation control did not fail at the fence')
    departed_rows = [row for row in rows if row is not None and row.get('departed') is True]
    if len(departed_rows) != 1:
        raise ValueError('room-departure must name exactly one departing page')
    departed = departed_rows[0]
    roster = departed.get('roster')
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
        survivor_slots = sorted(slot for slot in range(3) if slot != departed['slot'])
        if sorted(row.get('slot') for row in failures) != survivor_slots:
            raise ValueError('room-departure control does not identify the two survivors')
        for row in failures:
            slot = row.get('slot')
            if (type(slot) is not int or not 0 <= slot < 3
                    or row.get('uuid') != roster[slot]
                    or row.get('local_uuid') != row.get('uuid')
                    or row.get('departed_uuid') != departed['uuid']
                    or row.get('departed_slot') != departed['slot']
                    or row.get('frozen_roster') != roster):
                raise ValueError('room-departure control survivor identity invalid')
        return result
    survivor_rows = [row for row in rows if row is not None and row is not departed]
    if len(survivor_rows) != 2:
        raise ValueError('room-departure survivor evidence missing')
    departed_slot, departed_uuid = departed['slot'], departed['uuid']
    for row in survivor_rows:
        if not _room_survivor_row(row, roster, departed_uuid, departed_slot, session):
            raise ValueError('room-departure survivor fence invalid')
    if sorted([departed_slot] + [row['slot'] for row in survivor_rows]) != [0, 1, 2]:
        raise ValueError('room-departure roster slots changed')
    if len({(row['fence_frame'], row['departed_slot'], row['departed_uuid']) for row in survivor_rows}) != 1:
        raise ValueError('room-departure survivors disagreed on the fence')
    return result


def _lost_history_row(row, role, slot, departing_slot, first, through):
    roster = row.get('roster')
    return (row.get('departed') is False
            and type(row.get('slot')) is int and row['slot'] == slot
            and isinstance(row.get('uuid'), str)
            and isinstance(roster, list) and len(roster) == 3 and roster[slot] == row['uuid']
            and type(row.get('departing_slot')) is int and row['departing_slot'] == departing_slot
            and isinstance(row.get('target_slots'), list) and all(type(slot) is int for slot in row['target_slots'])
            and departing_slot in row['target_slots']
            and type(row.get('frames_submitted')) is int and row['frames_submitted'] == 8
            and type(row.get('final_frame')) is int and row['final_frame'] == 8
            and type(row.get('frames_after_terminal')) is int and row['frames_after_terminal'] == 0
            and type(row.get('post_terminal_code')) is int and row['post_terminal_code'] > 0
            and type(row.get('barrier_cut')) is int and 0 <= row['barrier_cut'] <= through
            and type(row.get('prediction_gap')) is int
            and row['prediction_gap'] == row['final_frame'] - row['barrier_cut'] - 1
            and row.get('state') == 'failed' and row.get('failed') is True
            and row.get('failure_reason') == 'timeout'
            and row.get('lifecycle') == 'terminated'
            and type(row.get('freeze_frame')) is int and row['freeze_frame'] == -1
            and type(row.get('role')) is int and row['role'] == role
            and row.get('certified') is False
            and type(row.get('certificates')) is int and row['certificates'] == 0
            and type(row.get('terminal_peer_code')) is int and row['terminal_peer_code'] in (0, 7)
            and type(row.get('terminal_transport_code')) is int and row['terminal_transport_code'] in (0, 9, 12)
            and type(row.get('terminal_enqueue_code')) is int and row['terminal_enqueue_code'] in (0, 9)
            and type(row.get('drop_events')) is int and row['drop_events'] == 0
            and row.get('drop_frames') == {}
            and type(row.get('pending_events')) is int and row['pending_events'] == 1
            and type(row.get('history_first')) is int and row['history_first'] == first
            and type(row.get('history_cut')) is int and row['history_cut'] == through
            and row.get('history_installed') is False
            and type(row.get('history_dropped')) is int and type(row.get('history_resends')) is int
            and type(row.get('history_drop_chunk')) is int and type(row.get('history_drop_operation')) is int
            and type(row.get('history_drop_count')) is int
            and isinstance(row.get('history_drop_chunks'), list)
            and all(type(count) is int and count >= 0 for count in row['history_drop_chunks'])
            and len(row['history_drop_chunks']) == row['history_drop_count']
            and type(row.get('minimum_confirmed')) is int and 0 <= row['minimum_confirmed'] <= through
            and type(row.get('confirmed_prefix')) is int and 1 <= row['confirmed_prefix'] <= first - 1
            and type(row.get('canonical_comparisons')) is int
            and row['canonical_comparisons'] == row['confirmed_prefix']
            and type(row.get('rollback_loads')) is int
            and isinstance(row.get('direct'), dict)
            and type(row['direct'].get('sent')) is int and row['direct']['sent'] >= 1
            and type(row['direct'].get('received')) is int and row['direct']['received'] >= 1
            and isinstance(row.get('session_id'), str) and re.fullmatch(r'[0-9a-f]{32}', row['session_id'])
            and type(row.get('target_generation')) is int
            and type(row.get('operation')) is int
            and type(row.get('coordinator')) is int and type(row.get('coordinator_generation')) is int
            and isinstance(row.get('target_set_digest'), str) and re.fullmatch(r'[0-9a-f]{16}', row['target_set_digest']))


def _validate_lost_history(result, survivors):
    departed = result['records'][0]['peers'][2]['result']['records'][0]
    report = departed.get('missing_inputs')
    if (not isinstance(report, dict) or set(report) != {'dropped', 'from', 'through', 'frames', 'overlaps', 'slot', 'unsupported'}
            or report.get('dropped') != 3
            or report.get('from') != 4 or report.get('through') != 6
            or report.get('frames') != [4, 5, 6] or report.get('overlaps') != 0
            or report.get('unsupported') != 0 or report.get('slot') != departed.get('slot')):
        raise ValueError('peer-drop lost-history withholding evidence missing')
    if len(survivors) != 2:
        raise ValueError('peer-drop lost-history survivor rows missing')
    proposer = next((row for row in survivors if row.get('role') == 1), None)
    follower = next((row for row in survivors if row.get('role') == 0), None)
    if proposer is None or follower is None or proposer is follower:
        raise ValueError('peer-drop lost-history roles missing')
    slots = (proposer.get('slot'), follower.get('slot'))
    if any(type(slot) is not int for slot in slots) or slots[0] >= slots[1]:
        raise ValueError('peer-drop lost-history coordinator differs from lowest surviving slot')
    if not _lost_history_row(proposer, 1, slots[0], report['slot'], report['from'], report['through']) \
            or not _lost_history_row(follower, 0, slots[1], report['slot'], report['from'], report['through']):
        raise ValueError('peer-drop lost-history terminal row incomplete')
    other_id = hashlib.sha256(follower['uuid'].encode('ascii')).digest()[:8].hex()
    other = hashlib.sha256(proposer['uuid'].encode('ascii')).digest()[:8].hex()
    if proposer.get('participants') != [other_id] or follower.get('participants') != [other]:
        raise ValueError('peer-drop lost-history certificate participant differs from original survivor')
    if (proposer.get('coordinator') != slots[0] or follower.get('coordinator') != slots[0]
            or proposer.get('coordinator_generation') != follower.get('coordinator_generation')
            or proposer.get('target_generation') != follower.get('target_generation')
            or proposer.get('target_set_digest') != follower.get('target_set_digest')
            or proposer.get('target_slots') != follower.get('target_slots')):
        raise ValueError('peer-drop lost-history operation identity differs')
    if (type(proposer.get('history_donor')) is not int or proposer['history_donor'] != follower['slot']
            or type(follower.get('history_donor')) is not int or follower['history_donor'] != follower['slot']):
        raise ValueError('peer-drop lost-history donor identity differs')
    if (type(proposer.get('history_dropped')) is not int or proposer['history_dropped'] != 0
            or type(proposer.get('history_drop_count')) is not int or proposer['history_drop_count'] != 0
            or proposer.get('history_drop_chunks') != []
            or type(proposer.get('history_drop_chunk')) is not int or proposer['history_drop_chunk'] != -1):
        raise ValueError('peer-drop lost-history recipient withheld donor bytes')
    if (type(follower.get('history_dropped')) is not int or follower['history_dropped'] < 2
            or type(follower.get('history_drop_count')) is not int or follower['history_drop_count'] < 1
            or len(follower['history_drop_chunks']) != follower['history_drop_count']
            or any(count < 2 for count in follower['history_drop_chunks'])
            or type(follower.get('history_drop_chunk')) is not int
            or not 0 <= follower['history_drop_chunk'] < follower['history_drop_count']
            or follower['history_dropped'] < 2 * follower['history_drop_count']
            or type(follower.get('history_drop_operation')) is not int
            or type(follower.get('operation')) is not int
            or follower['history_drop_operation'] != follower['operation']
            or proposer.get('operation') != follower['operation']):
        raise ValueError('peer-drop lost-history donation evidence missing')
    if proposer.get('session_id') != follower.get('session_id'):
        raise ValueError('peer-drop lost-history session identity differs')
    return result


def _validate_commit_loss(survivors):
    proposer = next((row for row in survivors if row.get('role') == 1), None)
    follower = next((row for row in survivors if row.get('role') == 0), None)
    if proposer is None or follower is None:
        raise ValueError('peer-drop lost-commit survivor rows missing')
    other = _peer_id(follower.get('uuid'))
    first = proposer.get('commit_first')
    retry = proposer.get('commit_retry')
    if (type(proposer.get('commit_dropped')) is not int or proposer['commit_dropped'] != 1
            or type(proposer.get('commit_resends')) is not int or not 1 <= proposer['commit_resends'] <= MAX_COMMIT_RETRIES
            or type(proposer.get('commit_operation')) is not int or proposer['commit_operation'] != proposer.get('operation')
            or type(proposer.get('commit_cut')) is not int or proposer['commit_cut'] != proposer.get('freeze_frame')
            or proposer.get('commit_digest') != proposer.get('digest')
            or type(proposer.get('commit_slot')) is not int or proposer['commit_slot'] != follower.get('slot')
            or type(proposer.get('commit_delay_us')) is not int
            or not MIN_COMMIT_RETRY_DELAY_US <= proposer['commit_delay_us'] <= 4000000
            or type(first) is not str or not re.fullmatch(r'[0-9a-f]{202,2048}', first) or len(first) % 2
            or type(retry) is not str or retry != first):
        raise ValueError('peer-drop lost-commit retry evidence missing')
    acknowledgements = proposer.get('acknowledged_peers')
    confirmations = proposer.get('commit_ack_peers')
    if not isinstance(acknowledgements, list) or not isinstance(confirmations, list) \
            or any(type(identity) is not str for identity in acknowledgements + confirmations):
        raise ValueError('peer-drop lost-commit acknowledgement missing')
    if other not in acknowledgements + confirmations:
        raise ValueError('peer-drop lost-commit acknowledgement missing')
    if (follower.get('commit_dropped') != 0 or follower.get('commit_resends') != 0
            or follower.get('commit_first') != '' or follower.get('commit_retry') != ''
            or follower.get('commit_operation') != -1 or follower.get('commit_cut') != -1
            or follower.get('commit_slot') != -1 or follower.get('commit_delay_us') != -1):
        raise ValueError('peer-drop lost-commit follower withheld bytes')
    return survivors


def validate_drop_browser(result, corrupt=False, physical_close=False, lost_answer=False, relay_only=False,
                           missing_history=False, history_lost=False, second_departure=False, rollback_departure=False,
                           foreign_proposal=False, room_departure=False, room_continue=False, process_death=False,
                           process_missing=False, room_after_drop=False, room_before_drop=False, commit_loss=False):
    if history_lost and not missing_history:
        raise ValueError('peer-drop lost-history mode requires the withholding schedule')
    new_modes = [process_death, process_missing, room_after_drop, room_before_drop, commit_loss]
    if any(new_modes) and (
            sum(bool(mode) for mode in new_modes) != 1
            or corrupt or physical_close or lost_answer or relay_only or missing_history
            or second_departure or rollback_departure or foreign_proposal or room_departure or room_continue):
        raise ValueError('peer-drop modes are exclusive')
    if (second_departure and rollback_departure) or (room_departure and room_continue) or (
            (room_departure or room_continue) and (
                corrupt or physical_close or lost_answer or relay_only or missing_history or second_departure
                or rollback_departure or foreign_proposal)) or (
            foreign_proposal and (
                corrupt or physical_close or lost_answer or relay_only or missing_history or second_departure
                or rollback_departure or room_departure or room_continue)):
        raise ValueError('peer-drop modes are exclusive')
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('peerDrop') is not True
            or result.get('dropCorrupt') is not corrupt or result.get('dropAnswer', False) is not lost_answer
            or result.get('dropRelay', False) is not relay_only or result.get('dropClose', False) is not physical_close
            or result.get('dropMissing', False) is not missing_history
            or result.get('dropHistoryLost', False) is not history_lost
            or result.get('dropSecond', False) is not second_departure or result.get('dropRollback', False) is not rollback_departure
            or result.get('dropForeign', False) is not foreign_proposal
            or result.get('dropRoom', False) is not room_departure
            or result.get('dropRoomContinue', False) is not room_continue
            or result.get('dropProcess', False) is not process_death
            or result.get('dropProcessMissing', False) is not process_missing
            or result.get('dropRoomAfterDrop', False) is not room_after_drop
            or result.get('dropRoomBeforeDrop', False) is not room_before_drop
            or result.get('dropCommit', False) is not commit_loss
            or result.get('errors') != []
            or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2):
        raise ValueError('peer-drop browser run incomplete')
    records = result.get('records')
    expected_peers = 2 if process_death else 3
    if (not isinstance(records, list) or len(records) != 1 or type(records[0].get('players')) is not int
            or records[0]['players'] != 3 or len(records[0].get('peers', [])) != expected_peers):
        raise ValueError('peer-drop requires the expected real exported peers')
    if process_death:
        return _validate_process_evidence(result)
    if process_missing:
        return _validate_process_missing(result)
    if room_before_drop:
        return _validate_before_drop(result)
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
        if history_lost and index < 2:
            # The terminal rows never commit or freeze; the lost-history
            # branch below owns their agreement and donor-evidence fields.
            survivors.append(row)
            continue
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
        if history_lost:
            return _validate_lost_history(result, survivors)
        if commit_loss:
            _validate_commit_loss(survivors)
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
            if (type(follower.get('history_dropped')) is not int or follower['history_dropped'] != 1
                    or type(proposer.get('history_dropped')) is not int or proposer['history_dropped'] != 0):
                raise ValueError('peer-drop live missing-history donor retry incomplete')
            if (type(follower.get('history_resends')) is not int or follower['history_resends'] < 1
                    or type(proposer.get('history_resends')) is not int or proposer['history_resends'] != 0
                    or type(follower.get('history_drop_chunk')) is not int or follower['history_drop_chunk'] != 0
                    or type(follower.get('history_drop_count')) is not int or follower['history_drop_count'] < 1
                    or type(follower.get('history_drop_operation')) is not int
                    or type(follower.get('operation')) is not int
                    or follower['history_drop_operation'] != follower['operation']
                    or proposer.get('operation') != follower['operation']):
                raise ValueError('peer-drop live missing-history donor retry incomplete')
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
        if room_after_drop:
            _validate_after_drop(result, survivors)
    return result
