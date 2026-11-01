"""Validate coordinated-drop browser evidence separately from ordinary fixed meshes."""
import re
import hashlib

def validate_drop_browser(result, corrupt=False, physical_close=False, lost_answer=False, relay_only=False):
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('peerDrop') is not True
            or result.get('dropCorrupt') is not corrupt or result.get('dropAnswer', False) is not lost_answer
            or result.get('dropRelay', False) is not relay_only or result.get('dropClose', False) is not physical_close or result.get('errors') != []
            or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2):
        raise ValueError('peer-drop browser run incomplete')
    records = result.get('records')
    if not isinstance(records, list) or len(records) != 1 or type(records[0].get('players')) is not int or records[0]['players'] != 3 or len(records[0].get('peers', [])) != 3:
        raise ValueError('peer-drop requires three real exported peers')
    survivors = []
    for index, peer in enumerate(records[0]['peers']):
        witness = peer.get('result', {})
        rtc = peer.get('rtc', {})
        if any(type(rtc.get(field)) is not int or rtc[field] < 1 for field in ('sent', 'received')):
            raise ValueError('peer-drop physical packet evidence missing')
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
        if (row.get('departed') is not (index == 2) or type(row.get('frames_submitted')) is not int
                or row['frames_submitted'] != (7 if index == 2 else 40)):
            raise ValueError('peer-drop departure or continued input missing')
        if index == 2:
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
        for field, expected in [('players', 3), ('state', 'committed'), ('drop_events', 1), ('canonical_comparisons', 38), ('active_comparisons', 30)]:
            if row.get(field) != expected or (type(expected) is int and type(row.get(field)) is not int):
                raise ValueError('peer-drop agreement or canonical history incomplete')
        if (type(row.get('slot')) is not int or not 0 <= row['slot'] < 3
                or type(row.get('freeze_frame')) is not int or not 0 <= row['freeze_frame'] <= 6
                or type(row.get('departing_slot')) is not int or not 0 <= row['departing_slot'] < 3
                or type(row.get('minimum_confirmed')) is not int or row['minimum_confirmed'] < 38
                or type(row.get('rollback_loads')) is not int or row['rollback_loads'] < 1
                or type(row.get('prediction_gap')) is not int or row['prediction_gap'] < 1):
            raise ValueError('peer-drop frozen boundary or confirmation invalid')
        expected_value = bytes([(row['freeze_frame'] * 17 + row['departing_slot'] * 31 + 1) & 255]).hex()
        if row.get('frozen_value') != expected_value:
            raise ValueError('peer-drop frozen sample differs from original input')
        if (type(row.get('role')) is not int or row['role'] not in (0, 1)
                or row.get('certified') is not (row['role'] == 0)
                or type(row.get('certificates')) is not int or row['certificates'] != row['role']):
            raise ValueError('peer-drop all-survivor certificate missing')
        survivors.append(row)
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
            if (data[:8] != b'FRGP\x02\x00\x0c\x00' or data[24:32] != sender
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
                    if (data[:8] != b'FRGP\x02\x00\x0c\x00' or data[24:32] != sender
                            or data[8:24].hex() != row.get('session_id')
                            or int.from_bytes(data[40:44], 'little') != len(data) - 44
                            or targets != 3 or data[94] != row['departing_slot']
                            or type(row.get('target_generation')) is not int
                            or int.from_bytes(data[95:97], 'little') != row['target_generation']
                            or 98 + targets > len(data)
                            or int.from_bytes(data[94 + targets:98 + targets], 'little') != len(data) - 98 - targets
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
    return result
