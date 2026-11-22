"""Value: reject apparent peer-drop success without agreement, continuation or real exports."""
import copy
import hashlib
import unittest

from browser.webrtc_drop import validate_drop_browser


def evidence(corrupt=False, freeze=6):
    peers = []
    roster = [f'00000000-0000-0000-0000-{index:012x}' for index in range(3)]
    for index in range(3):
        row = {'players': 3, 'departed': index == 2, 'frames_submitted': 7 if index == 2 else 40, 'slot': index, 'uuid': roster[index], 'roster': roster}
        if index == 2:
            row['departure_sequence'] = 1
        if index < 2:
            row.update(state='committed', drop_events=1, canonical_comparisons=38, active_comparisons=30,
                       prediction_gap=7 - freeze, freeze_frame=freeze, departing_slot=2, minimum_confirmed=38, rollback_loads=1,
                       frozen_value=bytes([(freeze * 17 + 2 * 31 + 1) & 255]).hex(),
                       role=1 - index, certified=index == 1, certificates=1 - index)
        if index < 2:
            other_id = hashlib.sha256(roster[1 - index].encode('ascii')).digest()[:8].hex()
            digest = ((0x14650fb0739d0383 ^ int(row['frozen_value'], 16)) * 1099511628211) & 0x3fffffffffffffff
            row.update(participants=[other_id], digest=f'{digest:016x}',
                       certificate_rows=[{'peer': other_id, 'cut': freeze, 'digest': f'{digest:016x}'}] if index == 0 else [])
        result = {'passed': True, 'records': [row]}
        if corrupt and index < 2:
            result = {'passed': False, 'failure': {'stage': 'peer_drop_gameplay', 'errors': ['peer_drop_canonical_8']}}
        channels = [{'id': channel_id, 'ordered': False, 'negotiated': True, 'maxPacketLifeTime': 1,
                     'maxRetransmits': None, 'sent': 20, 'received': 20}
                    for unused in range(2) for channel_id in (1, 2, 3)]
        peers.append({'result': result, 'rtc': {'sent': 20, 'received': 20, 'channels': channels,
                      'teardown': {'channels': 6, 'connections_created': 2, 'connections': 2,
                                   'websockets_created': 1, 'websockets': 1}}})
    return {'passed': True, 'peerDrop': True, 'dropCorrupt': corrupt, 'errors': [], 'browser_instances': 2,
            'records': [{'players': 3, 'peers': peers}]}


class PeerDropEvidence(unittest.TestCase):
    def test_agreement_continuation_and_physical_delivery_are_required(self):
        original = evidence()
        self.assertIs(validate_drop_browser(original), original)
        mutations = [
            lambda value: value.update(passed=False),
            lambda value: value['records'][0].update(players=2),
            lambda value: value['records'][0]['peers'].pop(),
            lambda value: value['records'][0]['peers'][0]['rtc'].update(received=0),
            lambda value: value['records'][0]['peers'][0]['rtc']['channels'][2].update(ordered=True),
            lambda value: value['records'][0]['peers'][0]['rtc']['teardown'].update(connections=1),
            lambda value: value['records'][0]['peers'][0]['rtc']['teardown'].update(websockets=0),
            lambda value: value['records'][0]['peers'][0]['rtc']['teardown'].update(websockets_created=0),
            lambda value: value['records'][0]['peers'][0]['rtc']['teardown'].pop('websockets'),
            lambda value: value['records'][0]['peers'][0]['rtc']['teardown'].pop('websockets_created'),
            lambda value: value['records'][0]['peers'][1].update(result=None),
            lambda value: value['records'][0]['peers'][1]['result'].pop('records'),
            lambda value: value['records'][0]['peers'][1].update(rtc=None),
        ]
        for field, replacement in [('drop_events', 2), ('canonical_comparisons', 0), ('active_comparisons', 0),
                                   ('freeze_frame', -1), ('frozen_value', '00'), ('minimum_confirmed', 0),
                                   ('rollback_loads', 0), ('certificates', 0), ('state', 'failed'), ('role', 0)]:
            mutations.append(lambda value, field=field, replacement=replacement:
                             value['records'][0]['peers'][0]['result']['records'][0].update({field: replacement}))
        for field, replacement in [('peer', '00' * 8), ('cut', 4), ('cut', True), ('digest', '00' * 8)]:
            mutations.append(lambda value, field=field, replacement=replacement:
                             value['records'][0]['peers'][0]['result']['records'][0]['certificate_rows'][0].update({field: replacement}))
        mutations.append(lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(participants=['00' * 8]))
        for replacement in (3.0, True):
            mutations.append(lambda value, replacement=replacement: value['records'][0].update(players=replacement))
        for key in ('channels', 'connections', 'connections_created', 'websockets', 'websockets_created'):
            for replacement in (6.0 if key == 'channels' else 2.0, True):
                mutations.append(lambda value, key=key, replacement=replacement:
                                 value['records'][0]['peers'][0]['rtc']['teardown'].update({key: replacement}))
        for replacement in (1.0, True):
            mutations.append(lambda value, replacement=replacement:
                             value['records'][0]['peers'][0]['rtc']['channels'][0].update(id=replacement))
        for replacement in (7.0, True):
            mutations.append(lambda value, replacement=replacement:
                             value['records'][0]['peers'][2]['result']['records'][0].update(frames_submitted=replacement))
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                value = copy.deepcopy(original)
                mutate(value)
                with self.assertRaises(ValueError):
                    validate_drop_browser(value)

    def test_physical_departure_requires_closed_connections_before_continuation(self):
        original = evidence()
        original['dropClose'] = True
        departure = {'frame': 6, 'survivor_frames': [6, 6], 'connections_created': 2, 'connections_closed': 2,
                     'channels_created': 6, 'channels_closed': 6}
        original['records'][0]['peers'][2]['rtc']['departure'] = departure
        for peer in original['records'][0]['peers'][:2]:
            peer['rtc']['channels'][2].update(restoredSent=10, postDropReceived=10)
            peer['rtc']['binarySent'] = 3
            peer['rtc']['maximumRelayBuffered'] = 1024
            peer['result']['records'][0]['mixed'] = {'switched': True, 'relay_peers': 1, 'caller_pending': 0,
                                                   'maximum_pending': 2, 'maximum_relay_pending': 0, 'maximum_relay_received': 0,
                                                   'route_budget': 8, 'send_budget': 32, 'receive_budget': 32}
        self.assertIs(validate_drop_browser(original, physical_close=True), original)
        for field in departure:
            for replacement in (None, True, 1.0, -1):
                value = copy.deepcopy(original)
                value['records'][0]['peers'][2]['rtc']['departure'][field] = replacement
                with self.subTest(field=field, replacement=replacement), self.assertRaisesRegex(ValueError, 'physical departure'):
                    validate_drop_browser(value, physical_close=True)
        for field, replacement in [('switched', False), ('relay_peers', 0), ('relay_peers', True), ('caller_pending', 1)]:
            value = copy.deepcopy(original)
            value['records'][0]['peers'][0]['result']['records'][0]['mixed'][field] = replacement
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'bounded fallback'):
                validate_drop_browser(value, physical_close=True)
        for field in ('restoredSent', 'postDropReceived'):
            for replacement in (0, True, 1.0):
                value = copy.deepcopy(original)
                value['records'][0]['peers'][0]['rtc']['channels'][2][field] = replacement
                with self.assertRaisesRegex(ValueError, 'surviving direct link'):
                    validate_drop_browser(value, physical_close=True)
        for field in ('maximum_pending', 'maximum_relay_pending', 'maximum_relay_received', 'route_budget', 'send_budget', 'receive_budget'):
            for replacement in (True, -1, 129):
                value = copy.deepcopy(original)
                value['records'][0]['peers'][0]['result']['records'][0]['mixed'][field] = replacement
                with self.subTest(field=field, replacement=replacement), self.assertRaises(ValueError):
                    validate_drop_browser(value, physical_close=True)
        for replacement in (True, -1, 262145):
            value = copy.deepcopy(original)
            value['records'][0]['peers'][0]['rtc']['maximumRelayBuffered'] = replacement
            with self.assertRaisesRegex(ValueError, 'socket exceeded'):
                validate_drop_browser(value, physical_close=True)
        for replacement in (0, True, 1.0):
            value = copy.deepcopy(original)
            value['records'][0]['peers'][0]['rtc']['binarySent'] = replacement
            with self.assertRaisesRegex(ValueError, 'bounded fallback'):
                validate_drop_browser(value, physical_close=True)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(original)

    def test_corruption_must_fail_post_drop_canonical_comparison(self):
        original = evidence(True)
        self.assertIs(validate_drop_browser(original, True), original)
        changes = [('stage', 'handshake'), ('errors', ['peer_drop_unconfirmed']),
                   ('errors', []), ('errors', ['peer_drop_canonical_8', 'other'])]
        changes += [('errors', ['peer_drop_canonical_' + frame]) for frame in ('1', '7', '38', '1000000')]
        for field, replacement in changes:
            value = copy.deepcopy(original)
            value['records'][0]['peers'][0]['result']['failure'][field] = replacement
            with self.subTest(field=field, replacement=replacement), self.assertRaises(ValueError):
                validate_drop_browser(value, True)

    def test_corrupt_control_requires_signaling_teardown_too(self):
        value = evidence(True)
        value['records'][0]['peers'][0]['rtc']['teardown']['websockets'] = 0
        with self.assertRaisesRegex(ValueError, 'resources survived teardown'):
            validate_drop_browser(value, True)


class RelayDropEvidence(unittest.TestCase):
    def test_relay_agreement_requires_closed_direct_paths_and_attributed_barrier_receipts(self):
        original = evidence()
        original['dropRelay'] = True
        for index, peer in enumerate(original['records'][0]['peers']):
            peer['rtc']['departure'] = {'frame': 6, 'survivor_frames': [6, 6], 'connections_created': 2,
                                      'connections_closed': 2, 'channels_created': 6, 'channels_closed': 6}
            if index == 2:
                continue
            row = peer['result']['records'][0]
            row.update(operation=9, coordinator=0, coordinator_generation=1, target_set_digest='0000000000000007',
                       session_id='01' * 16, target_generation=1)
            peer['rtc'].update(binarySent=5, maximumRelayBuffered=1024)
            for channel in peer['rtc']['channels']:
                channel.update(restoredSent=0, postDropReceived=0)
            row['mixed'] = {'switched': True, 'relay_peers': 2, 'caller_pending': 0, 'maximum_pending': 2,
                            'maximum_relay_pending': 0, 'maximum_relay_received': 1, 'route_budget': 8,
                            'send_budget': 32, 'receive_budget': 32, 'accepted_binary': 5}
            packet = bytearray(109)
            packet[:8] = b'FRGP\x03\x00\x0c\x00'
            packet[8:24] = bytes([1] * 16)
            other = original['records'][0]['peers'][1 - index]['result']['records'][0]
            packet[24:32] = hashlib.sha256(other['uuid'].encode('ascii')).digest()[:8]
            packet[40:44] = (65).to_bytes(4, 'little')
            packet[44:46] = bytes([2, 2] if index == 0 else [4, 0])
            packet[50:52] = (1).to_bytes(2, 'little')
            packet[52:56] = (9).to_bytes(4, 'little')
            packet[56:64] = (7).to_bytes(8, 'little')
            packet[64:68] = row['freeze_frame'].to_bytes(4, 'little', signed=True)
            packet[76:84] = int(row['digest'], 16).to_bytes(8, 'little')
            packet[90:94] = (3).to_bytes(4, 'little')
            packet[94:97] = bytes([2, 1, 0])
            row['relay_barriers'] = [packet.hex()]
        self.assertIs(validate_drop_browser(original, relay_only=True), original)
        mutations = [
            lambda peer: peer['rtc']['departure'].update(channels_closed=5),
            lambda peer: peer['rtc']['channels'][2].update(postDropReceived=1),
            lambda peer: peer['rtc'].update(binarySent=0),
            lambda peer: peer['result']['records'][0].update(relay_barriers=[]),
            lambda peer: peer['result']['records'][0].update(relay_barriers=['00' * 109]),
            lambda peer: peer['result']['records'][0].update(operation=8),
            lambda peer: peer['result']['records'][0]['mixed'].update(accepted_binary=0),
        ]
        for mutate in mutations:
            value = copy.deepcopy(original)
            mutate(value['records'][0]['peers'][0])
            with self.subTest(mutate=mutate), self.assertRaisesRegex(ValueError, 'relay'):
                validate_drop_browser(value, relay_only=True)
        for byte in (8, 24, 44, 45, 48, 50, 52, 56, 64, 76, 90, 95, 98):
            value = copy.deepcopy(original)
            row = value['records'][0]['peers'][0]['result']['records'][0]
            changed = bytearray.fromhex(row['relay_barriers'][0])
            changed[byte] ^= 1
            row['relay_barriers'] = [changed.hex()]
            with self.subTest(byte=byte), self.assertRaisesRegex(ValueError, 'relay'):
                validate_drop_browser(value, relay_only=True)


def missing_evidence():
    value = evidence()
    value['dropMissing'] = True
    value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'] = {
        'dropped': 3, 'from': 4, 'through': 6, 'frames': [4, 5, 6], 'overlaps': 0, 'slot': 2, 'unsupported': 0}
    proposer = value['records'][0]['peers'][0]['result']['records'][0]
    follower = value['records'][0]['peers'][1]['result']['records'][0]
    proposer.update(history_donor=follower['slot'], history_first=4, history_cut=proposer['freeze_frame'], history_installed=True,
                    history_dropped=0)
    follower.update(history_donor=follower['slot'], history_first=4, history_cut=follower['freeze_frame'], history_installed=False,
                    history_dropped=1)
    return value


class MissingHistoryEvidence(unittest.TestCase):
    def test_live_missing_history_requires_withholding_and_transfer(self):
        original = missing_evidence()
        self.assertIs(validate_drop_browser(original, missing_history=True), original)
        mutations = [
            lambda value: value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'].update(dropped=0),
            lambda value: value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'].update(**{'from': 3}),
            lambda value: value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'].update(through=7),
            lambda value: value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'].update(frames=[3, 4, 5, 6]),
            lambda value: value['records'][0]['peers'][2]['result']['records'][0]['missing_inputs'].update(overlaps=1),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_installed=False),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_donor=0),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_first=5),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_cut=4),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_cut=3),
            lambda value: value['records'][0]['peers'][1]['result']['records'][0].update(history_dropped=0),
            lambda value: value['records'][0]['peers'][1]['result']['records'][0].update(history_dropped=2),
            lambda value: value['records'][0]['peers'][1]['result']['records'][0].update(history_dropped=True),
            lambda value: value['records'][0]['peers'][1]['result']['records'][0].pop('history_dropped'),
            lambda value: value['records'][0]['peers'][0]['result']['records'][0].update(history_dropped=1),
        ]
        for mutation in mutations:
            value = copy.deepcopy(original)
            mutation(value)
            with self.subTest(mutation=mutations.index(mutation)), self.assertRaisesRegex(ValueError, 'missing-history|withholding'):
                validate_drop_browser(value, missing_history=True)
        for replacement in (False, 1, None):
            value = copy.deepcopy(original)
            value['dropMissing'] = replacement
            with self.subTest(flag=replacement), self.assertRaisesRegex(ValueError, 'incomplete'):
                validate_drop_browser(value, missing_history=True)


def second_evidence():
    value = evidence()
    value['dropSecond'] = True
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    first_id = hashlib.sha256(roster[2].encode('ascii')).digest()[:8].hex()
    second_id = hashlib.sha256(roster[1].encode('ascii')).digest()[:8].hex()
    first = value['records'][0]['peers'][2]['result']['records'][0]
    first['departure_sequence'] = 1
    second = value['records'][0]['peers'][1]['result']['records'][0]
    second.update(departed=True, departure_sequence=2, frames_submitted=12, canonical_comparisons=10,
                  active_comparisons=2, minimum_confirmed=10, drop_events=1, pending_events=1,
                  drop_frames={first_id: 6}, commit_ack_peers=[], acknowledged_peers=[second_id])
    last = value['records'][0]['peers'][0]['result']['records'][0]
    last.update(drop_events=2, second_slot=1, second_freeze_frame=11, second_frontier=11, pending_events=1,
                drop_frames={first_id: 6, second_id: 11}, commit_ack_peers=[second_id], acknowledged_peers=[],
                second_frozen_value=bytes([(11 * 17 + 1 * 31 + 1) & 255]).hex())
    return value


class SecondDepartureEvidence(unittest.TestCase):
    def test_second_browser_departure_requires_two_publications_and_the_last_frontier(self):
        original = second_evidence()
        self.assertIs(validate_drop_browser(original, second_departure=True), original)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(original)
        second = lambda value: value['records'][0]['peers'][1]['result']['records'][0]
        last = lambda value: value['records'][0]['peers'][0]['result']['records'][0]
        first = lambda value: value['records'][0]['peers'][2]['result']['records'][0]
        def without_second(value):
            row = last(value)
            first_id = hashlib.sha256(row['roster'][2].encode('ascii')).digest()[:8].hex()
            row['drop_frames'] = {first_id: 6}
        def retarget_first(value):
            row = first(value)
            row['slot'] = 1
            row['uuid'] = row['roster'][1]
        def non_ascii_first(value):
            row = first(value)
            row['uuid'] = row['roster'][2] = 'departed-\u00e9'
        def retarget_second(value):
            row = second(value)
            row['roster'] = list(row['roster'])
            row['uuid'] = row['roster'][1] = row['roster'][0]
            target = last(value)
            target['drop_frames'][hashlib.sha256(row['uuid'].encode('ascii')).digest()[:8].hex()] = target['second_freeze_frame']
        with self.assertRaisesRegex(ValueError, 'first departure evidence'):
            missing_first = copy.deepcopy(original)
            first(missing_first).pop('departure_sequence')
            validate_drop_browser(missing_first, second_departure=True)
        mutations = [
            (lambda value: value.update(dropSecond=False), 'incomplete'),
            (lambda value: second(value).update(departed=False), 'second departure evidence'),
            (lambda value: second(value).update(departure_sequence=1), 'second departure evidence'),
            (lambda value: second(value).update(frames_submitted=40), 'second departure evidence'),
            (lambda value: second(value).update(canonical_comparisons=11), 'second departure evidence'),
            (lambda value: second(value).update(drop_events=2), 'second departure evidence'),
            (lambda value: second(value).update(drop_events=True), 'second departure evidence'),
            (lambda value: second(value).update(active_comparisons=1), 'active comparisons'),
            (lambda value: second(value).update(minimum_confirmed=9), 'confirmation'),
            (lambda value: first(value).update(departure_sequence=2), 'first departure evidence'),
            (lambda value: first(value).update(departure_sequence=True), 'first departure evidence'),
            (lambda value: first(value).update(frames_submitted=40), 'first departure evidence'),
            (lambda value: first(value).update(uuid=second(value)['uuid']), 'first departure evidence'),
            (lambda value: first(value).pop('uuid'), 'first departure evidence'),
            (lambda value: first(value).update(slot=0), 'first departure evidence'),
            (lambda value: first(value).update(roster=['00'] * 3), 'first departure evidence'),
            (retarget_first, 'first departure identity'),
            (lambda value: last(value).update(departed=0), 'agreement or canonical'),
            (lambda value: second(value).pop('uuid'), 'second departure evidence'),
            (lambda value: second(value).update(uuid=first(value)['uuid']), 'second departure evidence'),
            (lambda value: second(value).update(slot=0), 'second departure evidence'),
            (lambda value: last(value).update(drop_events=1), 'agreement or canonical'),
            (lambda value: last(value).update(drop_events=3), 'agreement or canonical'),
            (lambda value: last(value).update(active_comparisons=29), 'agreement or canonical'),
            (lambda value: last(value).update(canonical_comparisons=0), 'agreement or canonical'),
            (lambda value: last(value).update(frames_submitted=13), 'agreement or canonical'),
            (lambda value: last(value).update(departed='yes'), 'agreement or canonical'),
            (lambda value: last(value).update(drop_frames={}), 'publication frame'),
            (lambda value: last(value).update(pending_events=0), 'publication frame'),
            (without_second, 'second departure freeze'),
            (lambda value: last(value).update(commit_ack_peers=[], acknowledged_peers=[]), 'first commit unconfirmed'),
            (lambda value: last(value).update(commit_ack_peers=[['x']]), 'first commit unconfirmed'),
            (lambda value: last(value).update(pending_events=2), 'publication frame'),
            (lambda value: second(value).update(drop_frames={}), 'publication frame'),
            (lambda value: second(value).update(pending_events=0), 'publication frame'),
            (lambda value: second(value).update(pending_events=2), 'publication frame'),
            (non_ascii_first, 'original identities invalid'),
            (retarget_second, 'second departure freeze'),
            (lambda value: last(value).update(second_slot=2), 'second departure freeze'),
            (lambda value: last(value).update(second_slot=0), 'second departure freeze'),
            (lambda value: last(value).update(second_slot='1'), 'second departure freeze'),
            (lambda value: last(value).update(second_freeze_frame=9), 'second departure freeze'),
            (lambda value: last(value).update(second_freeze_frame=12), 'second departure freeze'),
            (lambda value: last(value).update(second_frontier=10), 'second departure freeze'),
            (lambda value: last(value).update(second_frozen_value='00'), 'second departure freeze'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, second_departure=True)


class LostAnswerEvidence(unittest.TestCase):
    def test_lost_answer_requires_one_follower_drop_and_exact_retry(self):
        original = evidence()
        original['dropAnswer'] = True
        packet = bytearray(104)
        packet[:8] = b'FRGP\x03\x00\x0c\x00'
        packet[24:32] = hashlib.sha256(original['records'][0]['peers'][1]['result']['records'][0]['uuid'].encode('ascii')).digest()[:8]
        packet[40] = 60
        packet[44:46] = b'\x02\x01'
        for index, peer in enumerate(original['records'][0]['peers']):
            peer['rtc']['answerLoss'] = {'dropped': int(index == 1), 'retries': int(index == 1),
                                         'packet': packet.hex() if index == 1 else None}
        self.assertIs(validate_drop_browser(original, lost_answer=True), original)
        for field, replacement in [('dropped', 0), ('dropped', True), ('retries', 0), ('retries', True),
                                   ('packet', None), ('packet', '00' * 104), ('packet', packet[:45].hex())]:
            value = copy.deepcopy(original)
            value['records'][0]['peers'][1]['rtc']['answerLoss'][field] = replacement
            with self.subTest(field=field, replacement=replacement), self.assertRaisesRegex(ValueError, 'lost answer'):
                validate_drop_browser(value, lost_answer=True)
        for replacement in (False, 1, None):
            value = copy.deepcopy(original)
            value['dropAnswer'] = replacement
            with self.subTest(flag=replacement), self.assertRaisesRegex(ValueError, 'incomplete'):
                validate_drop_browser(value, lost_answer=True)
        value = copy.deepcopy(original)
        value['records'][0]['peers'][0]['rtc']['answerLoss'] = value['records'][0]['peers'][1]['rtc']['answerLoss']
        with self.assertRaisesRegex(ValueError, 'lost answer'):
            validate_drop_browser(value, lost_answer=True)


class RollbackDepartureEvidence(unittest.TestCase):
    def test_rollback_departure_requires_a_pending_correction_at_the_held_cut(self):
        original = evidence(freeze=7)
        original['dropRollback'] = True
        original['records'][0]['peers'][2]['result']['records'][0].update(
            frames_submitted=8, held_packets=1, sent_packets=1)
        for peer in original['records'][0]['peers'][:2]:
            peer['result']['records'][0].update(pending_at_detection=7)
        self.assertIs(validate_drop_browser(original, rollback_departure=True), original)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(original)
        cut_six = evidence(freeze=6)
        cut_six['dropRollback'] = True
        cut_six['records'][0]['peers'][2]['result']['records'][0].update(
            frames_submitted=8, held_packets=1, sent_packets=1)
        for peer in cut_six['records'][0]['peers'][:2]:
            peer['result']['records'][0].update(pending_at_detection=7)
        with self.assertRaisesRegex(ValueError, 'frozen boundary'):
            validate_drop_browser(cut_six, rollback_departure=True)
        both = copy.deepcopy(original)
        both['dropSecond'] = True
        with self.assertRaisesRegex(ValueError, 'exclusive'):
            validate_drop_browser(both, second_departure=True, rollback_departure=True)
        survivor = lambda value: value['records'][0]['peers'][0]['result']['records'][0]
        disrupted = lambda value: value['records'][0]['peers'][1]['result']['records'][0]
        departed = lambda value: value['records'][0]['peers'][2]['result']['records'][0]
        mutations = [
            (lambda value: value.update(dropRollback=False), 'incomplete'),
            (lambda value: value.update(dropRollback=1), 'incomplete'),
            (lambda value: departed(value).update(frames_submitted=7), 'departure or continued input'),
            (lambda value: departed(value).update(departure_sequence=2), 'departure or continued input'),
            (lambda value: departed(value).update(departure_sequence=99), 'departure or continued input missing'),
            (lambda value: departed(value).update(held_packets=0), 'held packet'),
            (lambda value: departed(value).update(sent_packets=0), 'held packet'),
            (lambda value: departed(value).update(held_packets=2, sent_packets=1), 'held packet'),
            (lambda value: departed(value).update(sent_packets=21), 'held packet'),
            (lambda value: survivor(value).update(pending_at_detection=6), 'rollback correction'),
            (lambda value: survivor(value).update(pending_at_detection=8), 'rollback correction'),
            (lambda value: survivor(value).update(pending_at_detection=True), 'rollback correction'),
            (lambda value: survivor(value).update(pending_at_detection=7.0), 'rollback correction'),
            (lambda value: survivor(value).update(freeze_frame=6), 'frozen boundary'),
            (lambda value: survivor(value).update(prediction_gap=1), 'frozen boundary'),
            (lambda value: disrupted(value).update(pending_at_detection=6), 'rollback correction'),
            (lambda value: survivor(value).update(rollback_loads=0), 'frozen boundary'),
            (lambda value: survivor(value).update(prediction_gap=-1), 'frozen boundary'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, rollback_departure=True)


class ForeignProposalEvidence(unittest.TestCase):
    def test_foreign_proposal_requires_delivery_and_no_agreement_change(self):
        original = evidence()
        original['dropForeign'] = True
        for index, peer in enumerate(original['records'][0]['peers'][:2]):
            peer['result']['records'][0].update(
                foreign_sent=1 if index == 1 else 0, foreign_received=1 if index == 0 else 0,
                foreign_cut=2, foreign_digest=999,
                foreign_reason='coordinator' if index == 0 else '')
        self.assertIs(validate_drop_browser(original, foreign_proposal=True), original)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(original)
        for mode in ('corrupt', 'physical_close', 'lost_answer', 'relay_only', 'missing_history',
                     'second_departure', 'rollback_departure'):
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'exclusive'):
                validate_drop_browser(original, foreign_proposal=True, **{mode: True})
        follower = lambda value: value['records'][0]['peers'][1]['result']['records'][0]
        proposer = lambda value: value['records'][0]['peers'][0]['result']['records'][0]

        def forged_cut(value):
            frozen = bytes([(2 * 17 + 2 * 31 + 1) & 255]).hex()
            digest = ((0x14650fb0739d0383 ^ int(frozen, 16)) * 1099511628211) & 0x3fffffffffffffff
            for peer in value['records'][0]['peers'][:2]:
                row = peer['result']['records'][0]
                row.update(freeze_frame=2, frozen_value=frozen, prediction_gap=5, digest=f'{digest:016x}')
                if row['role'] == 1:
                    row['certificate_rows'][0].update(cut=2, digest=f'{digest:016x}')
        mutations = [
            (lambda value: value.update(dropForeign=False), 'incomplete'),
            (lambda value: value.update(dropForeign=1), 'incomplete'),
            (lambda value: value.update(dropForeign=None), 'incomplete'),
            (lambda value: follower(value).update(foreign_sent=0), 'foreign proposal evidence missing'),
            (lambda value: follower(value).update(foreign_sent=4), 'foreign proposal evidence missing'),
            (lambda value: follower(value).update(foreign_sent=True), 'foreign proposal evidence missing'),
            (lambda value: follower(value).update(foreign_sent='1'), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_received=0), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_received=4), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_received=True), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_received=2), 'foreign proposal evidence missing'),
            (lambda value: follower(value).update(foreign_received=1), 'foreign proposal evidence missing'),
            (lambda value: follower(value).update(foreign_received=False), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_sent=1), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_sent=False), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_cut=3), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_cut=-1), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_cut=True), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_digest=998), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_digest=True), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_reason='identity'), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_reason=''), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_reason=False), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(foreign_reason=['coordinator']), 'foreign proposal evidence missing'),
            (lambda value: proposer(value).update(frozen_value='00'), 'frozen sample'),
            (forged_cut, 'foreign proposal evidence missing'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, foreign_proposal=True)
        unflagged = evidence()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(unflagged, foreign_proposal=True)
        empty = copy.deepcopy(original)
        for peer in empty['records'][0]['peers'][:2]:
            peer['result']['records'][0].pop('foreign_sent', None)
            peer['result']['records'][0].pop('foreign_received', None)
        with self.assertRaisesRegex(ValueError, 'foreign proposal evidence missing'):
            validate_drop_browser(empty, foreign_proposal=True)


def room_evidence(control=False):
    value = evidence()
    value['dropRoom'] = not control
    value['dropRoomContinue'] = control
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    departed_uuid, departed_slot = roster[2], 2
    session = 'ab' * 16
    for index in range(2):
        row = value['records'][0]['peers'][index]['result']['records'][0]
        for key in list(row):
            if key not in ('players', 'departed', 'slot', 'uuid', 'roster'):
                del row[key]
        row.update(frames_submitted=7, fence_frame=7, final_frame=7, frames_after_fence=0, room_fenced=True,
                   fence_route='restart_required', fence_error=2, fence_lifetime_revision=3,
                   player_left_events=[departed_uuid], departed_slot=departed_slot,
                   departed_uuid=departed_uuid, frozen_roster=roster,
                   room_roster_after=sorted([roster[0], roster[1]]), local_uuid=roster[index],
                   session_id=session, drop_events=0, drop_pending_events=0, barrier_open=False)
    departed = value['records'][0]['peers'][2]['result']['records'][0]
    departed.update(departure_kind='room_left', room_code_before='ROOM-CODE', room_code_after='',
                    room_left=True, connected=True, authenticated=True, session_id=session)
    if control:
        for index in range(2):
            survivor = value['records'][0]['peers'][index]['result']['records'][0]
            row = dict(survivor)
            row.update(frames_submitted=8, final_frame=8, frames_after_fence=1, continue_code=0)
            value['records'][0]['peers'][index]['result'] = {
                'passed': False, 'failure': {'stage': 'peer_drop_room', 'errors': ['peer_drop_room_continued'],
                    'records': [row]}}
    return value


class RoomDepartureEvidence(unittest.TestCase):
    def test_room_departure_fences_survivors_and_keeps_the_frozen_identity(self):
        original = room_evidence()
        self.assertIs(validate_drop_browser(original, room_departure=True), original)
        control = room_evidence(control=True)
        self.assertIs(validate_drop_browser(control, room_continue=True), control)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(original)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            validate_drop_browser(control, room_departure=True)
        for mode in ('corrupt', 'physical_close', 'lost_answer', 'relay_only', 'missing_history',
                     'second_departure', 'rollback_departure'):
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'exclusive'):
                validate_drop_browser(original, room_departure=True, **{mode: True})
        with self.assertRaisesRegex(ValueError, 'exclusive'):
            validate_drop_browser(original, room_departure=True, room_continue=True)
        with self.assertRaisesRegex(ValueError, 'exclusive'):
            validate_drop_browser(original, room_departure=True, foreign_proposal=True)
        with self.assertRaisesRegex(ValueError, 'exclusive'):
            validate_drop_browser(original, room_continue=True, foreign_proposal=True)
        survivor = lambda value: value['records'][0]['peers'][0]['result']['records'][0]
        second = lambda value: value['records'][0]['peers'][1]['result']['records'][0]
        departed = lambda value: value['records'][0]['peers'][2]['result']['records'][0]
        roster = original['records'][0]['peers'][0]['result']['records'][0]['roster']
        departed_uuid = roster[2]
        mutations = [
            (lambda value: value.update(dropRoom=False), 'incomplete'),
            (lambda value: value.update(dropRoomContinue=True), 'incomplete'),
            (lambda value: departed(value).update(frames_submitted=8), 'departing page'),
            (lambda value: departed(value).update(departure_sequence=2), 'departing page'),
            (lambda value: departed(value).update(departure_kind='close'), 'departing page'),
            (lambda value: departed(value).update(room_left=False), 'departing page'),
            (lambda value: departed(value).update(room_code_after='ROOM-CODE'), 'departing page'),
            (lambda value: departed(value).update(connected=False), 'departing page'),
            (lambda value: departed(value).update(session_id='not-hex'), 'session identity'),
            (lambda value: departed(value).update(roster=list(reversed(roster))), 'frozen roster'),
            (lambda value: departed(value).update(uuid=roster[1]), 'departing page'),
            (lambda value: survivor(value).update(room_fenced=False), 'survivor fence'),
            (lambda value: survivor(value).update(fence_route='mesh'), 'survivor fence'),
            (lambda value: survivor(value).update(fence_error=0), 'survivor fence'),
            (lambda value: survivor(value).update(fence_error=19), 'survivor fence'),
            (lambda value: survivor(value).update(fence_frame=6), 'survivor fence'),
            (lambda value: survivor(value).update(fence_frame=8), 'survivor fence'),
            (lambda value: survivor(value).update(final_frame=8), 'survivor fence'),
            (lambda value: survivor(value).update(final_frame=True), 'survivor fence'),
            (lambda value: survivor(value).update(frames_after_fence=1), 'survivor fence'),
            (lambda value: survivor(value).update(frames_submitted=8), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=[]), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=[roster[0]]), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=['not-a-uuid']), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=[departed_uuid, departed_uuid]), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=[roster[0], departed_uuid]), 'survivor fence'),
            (lambda value: survivor(value).update(frozen_roster=[roster[0], roster[1], roster[0]]), 'survivor fence'),
            (lambda value: survivor(value).update(departed_slot=1), 'survivor fence'),
            (lambda value: survivor(value).update(departed_uuid=roster[0]), 'survivor fence'),
            (lambda value: survivor(value).update(room_roster_after=roster), 'survivor fence'),
            (lambda value: survivor(value).update(room_roster_after=[]), 'survivor fence'),
            (lambda value: survivor(value).update(local_uuid=roster[2]), 'survivor fence'),
            (lambda value: survivor(value).update(uuid=roster[2]), 'survivor fence'),
            (lambda value: survivor(value).update(drop_events=1), 'survivor fence'),
            (lambda value: survivor(value).update(drop_events=False), 'survivor fence'),
            (lambda value: survivor(value).update(drop_pending_events=1), 'survivor fence'),
            (lambda value: survivor(value).update(drop_pending_events=0.0), 'survivor fence'),
            (lambda value: survivor(value).update(barrier_open=True), 'survivor fence'),
            (lambda value: survivor(value).update(session_id='cd' * 16), 'survivor fence'),
            (lambda value: survivor(value).update(slot=2), 'survivor fence'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, room_departure=True)
        control_mutations = [
            (lambda value: value['records'][0]['peers'][0]['result'].update(passed=True), 'witness record missing'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(stage='peer_drop_gameplay'), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(errors=[]), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(errors=['peer_drop_room_continued', 'x']), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].pop('records'), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(records=[]), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(records=[None]), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(records=['x']), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure'].update(
                records=value['records'][0]['peers'][0]['result']['failure']['records'] * 2), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(continue_code=1), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(frames_after_fence=0), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(frames_submitted=7), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(final_frame=7), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(room_fenced=False), 'continuation control'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(slot=2, uuid=roster[2], local_uuid=roster[2]), 'does not identify'),
            (lambda value: value['records'][0]['peers'][1]['result']['failure']['records'][0].update(slot=0, uuid=roster[0], local_uuid=roster[0]), 'does not identify'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(departed_uuid=roster[0]), 'survivor identity'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(frozen_roster=[roster[0], roster[1], roster[0]]), 'survivor identity'),
            (lambda value: value['records'][0]['peers'][0]['result']['failure']['records'][0].update(local_uuid=roster[1]), 'survivor identity'),
        ]
        for index, (mutate, message) in enumerate(control_mutations):
            value = copy.deepcopy(control)
            mutate(value)
            with self.subTest(control=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, room_continue=True)
        # The survivors may be any two pages; identity checks follow the
        # departed row instead of the page index.
        swapped = copy.deepcopy(original)
        swapped['records'][0]['peers'][0], swapped['records'][0]['peers'][1] = (
            swapped['records'][0]['peers'][1], swapped['records'][0]['peers'][0])
        self.assertIs(validate_drop_browser(swapped, room_departure=True), swapped)
        reordered = copy.deepcopy(original)
        peers = reordered['records'][0]['peers']
        peers.insert(0, peers.pop(2))
        self.assertIs(validate_drop_browser(reordered, room_departure=True), reordered)
        reordered_control = copy.deepcopy(control)
        peers = reordered_control['records'][0]['peers']
        peers.insert(0, peers.pop(2))
        self.assertIs(validate_drop_browser(reordered_control, room_continue=True), reordered_control)


def process_evidence():
    value = evidence()
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    session = 'ab' * 16
    value['dropProcess'] = True
    value['dropRoom'] = False
    value['records'][0]['departedUuid'] = roster[2]
    value['records'][0]['processClosed'] = True
    value['records'][0]['processHeld'] = {
        'witness': None, 'teardown': None, 'go': False, 'frame': '6',
        'healthy': True, 'connected': True, 'authenticated': True, 'room': 'ROOM-CODE', 'errors': 0}
    value['records'][0]['peers'] = value['records'][0]['peers'][:2]
    for index, peer in enumerate(value['records'][0]['peers']):
        row = peer['result']['records'][0]
        for key in list(row):
            if key not in ('players', 'departed', 'slot', 'uuid', 'roster'):
                del row[key]
        row.update(frames_submitted=7, fence_frame=7, final_frame=7, frames_after_fence=0, room_fenced=True,
                   fence_route='restart_required', fence_error=2, fence_lifetime_revision=3,
                   player_left_events=[roster[2]], departed_slot=2, departed_uuid=roster[2],
                   frozen_roster=roster, room_roster_after=[roster[0], roster[1]], local_uuid=roster[index],
                   session_id=session, drop_events=0, drop_pending_events=0, barrier_open=False)
    return value


def process_missing_evidence():
    value = evidence()
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    value['dropProcessMissing'] = True
    value['records'][0]['departedUuid'] = roster[2]
    value['records'][0]['survivorUuids'] = [roster[0], roster[1]]
    for index, peer in enumerate(value['records'][0]['peers']):
        expected = 'peer_drop_room_gate' if index == 2 else 'peer_drop_room_fence'
        peer['result'] = {'passed': False, 'failure': {
            'stage': 'handshake' if index == 2 else 'peer_drop_room_fence',
            'errors': [expected], 'local_index': index, 'records': [],
            'uuid': roster[2] if index == 2 else roster[index],
            'hold_ms': 1234 if index == 2 else -1}}
    return value


def before_drop_evidence():
    value = room_evidence()
    value['dropRoom'] = False
    value['dropRoomBeforeDrop'] = True
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    for peer in value['records'][0]['peers'][:2]:
        peer['result']['records'][0].update(drop_pending_events=1, canonical_comparisons=6,
                                            barrier_state='pending', barrier_certified=False,
                                            barrier_value='', freeze_frame=-1, canonical_unchanged=True,
                                            barrier_open=True)
    value['records'][0]['peers'][2]['result']['records'][0]['departure_kind'] = 'room_left_before_drop'
    return value


def after_drop_evidence():
    value = evidence()
    value['dropRoomAfterDrop'] = True
    roster = value['records'][0]['peers'][0]['result']['records'][0]['roster']
    session = 'ab' * 16
    for index, peer in enumerate(value['records'][0]['peers'][:2]):
        peer['result']['records'][0].update(fence_frame=40, final_frame=40, frames_after_fence=0, room_fenced=True,
                                            fence_route='restart_required', fence_error=2, fence_lifetime_revision=3,
                                            player_left_events=[roster[2]], frozen_roster=roster,
                                            room_roster_after=[roster[0], roster[1]], departed_slot=2,
                                            departed_uuid=roster[2], local_uuid=roster[index], session_id=session,
                                            barrier_committed=True, barrier_open=True, fence_history_comparisons=38)
    value['records'][0]['peers'][2]['result']['records'][0].update(
        departure_kind='room_left_after_drop', room_code_before='ROOM-CODE', room_code_after='',
        room_left=True, connected=True, authenticated=True, session_id=session)
    return value


class ProcessDeathEvidence(unittest.TestCase):
    def test_process_death_requires_two_survivors_and_the_node_identity(self):
        original = process_evidence()
        self.assertIs(validate_drop_browser(original, process_death=True), original)
        survivor = lambda value, index=0: value['records'][0]['peers'][index]['result']['records'][0]
        mutations = [
            (lambda value: value.update(dropProcess=False), 'incomplete'),
            (lambda value: value.update(dropProcessMissing=True), 'incomplete'),
            (lambda value: value['records'][0].pop('departedUuid'), 'departed identity'),
            (lambda value: value['records'][0].update(processClosed=False), 'did not close'),
            (lambda value: value['records'][0].pop('processClosed'), 'did not close'),
            (lambda value: value['records'][0].update(processHeld={'witness': '{}', 'teardown': None, 'go': False, 'frame': '6'}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={'witness': None, 'teardown': 'true', 'go': False, 'frame': '6'}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={'witness': None, 'teardown': None, 'go': True, 'frame': '6'}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={'witness': None, 'teardown': None, 'go': False, 'frame': '7'}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'healthy': False}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'connected': False}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'authenticated': False}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'room': ''}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'errors': 1}), 'not still healthy'),
            (lambda value: value['records'][0].update(processHeld={**value['records'][0]['processHeld'], 'errors': True}), 'not still healthy'),
            (lambda value: value['records'][0].pop('processHeld'), 'not still healthy'),
            (lambda value: value['records'][0].update(departedUuid='not-a-uuid'), 'departed identity'),
            (lambda value: value['records'][0].update(departedUuid=None), 'departed identity'),
            (lambda value: value['records'][0]['peers'].append(copy.deepcopy(value['records'][0]['peers'][0])), 'expected real exported peers'),
            (lambda value: survivor(value).update(departed=True), 'published a row'),
            (lambda value: survivor(value).update(frames_submitted=8), 'survivor fence'),
            (lambda value: survivor(value).update(fence_frame=8), 'survivor fence'),
            (lambda value: survivor(value).update(final_frame=8), 'survivor fence'),
            (lambda value: survivor(value).update(frames_after_fence=1), 'survivor fence'),
            (lambda value: survivor(value).update(room_fenced=False), 'survivor fence'),
            (lambda value: survivor(value).update(fence_route='mesh'), 'survivor fence'),
            (lambda value: survivor(value).update(fence_error=0), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=[]), 'survivor fence'),
            (lambda value: survivor(value).update(player_left_events=['00000000-0000-0000-0000-000000000000']), 'survivor fence'),
            (lambda value: survivor(value).update(room_roster_after=roster_of(value)), 'survivor fence'),
            (lambda value: survivor(value).update(room_roster_after=[]), 'survivor fence'),
            (lambda value: survivor(value).update(departed_slot=1), 'survivor fence'),
            (lambda value: survivor(value).update(departed_uuid='00000000-0000-0000-0000-000000000000'), 'survivor fence'),
            (lambda value: survivor(value).update(local_uuid=roster_of(value)[1]), 'survivor fence'),
            (lambda value: survivor(value).update(drop_events=1), 'survivor fence'),
            (lambda value: survivor(value).update(drop_pending_events=1), 'survivor fence'),
            (lambda value: survivor(value).update(barrier_open=True), 'survivor fence'),
            (lambda value: survivor(value).update(session_id='cd' * 16), 'survivor fence'),
            (lambda value: survivor(value, 1).update(slot=0, uuid=roster_of(value)[0], local_uuid=roster_of(value)[0]), 'survivor slots'),
            (lambda value: survivor(value).update(roster=list(reversed(roster_of(value)))), 'frozen roster'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, process_death=True)

    def test_missing_server_event_fails_the_fence_wait(self):
        original = process_missing_evidence()
        self.assertIs(validate_drop_browser(original, process_missing=True), original)
        failure = lambda value, index=0: value['records'][0]['peers'][index]['result']['failure']
        mutations = [
            (lambda value: value.update(dropProcessMissing=False), 'incomplete'),
            (lambda value: value.update(dropProcess=True), 'incomplete'),
            (lambda value: failure(value).update(errors=[]), 'outside the fence wait'),
            (lambda value: failure(value).update(errors=['peer_drop_room_fence', 'x']), 'outside the fence wait'),
            (lambda value: failure(value).update(records=[{'departed': False}]), 'outside the fence wait'),
            (lambda value: failure(value).update(local_index=True), 'failure identity'),
            (lambda value: failure(value).update(local_index=3), 'failure identity'),
            (lambda value: failure(value, 2).update(local_index=1), 'failure identity'),
            (lambda value: failure(value, 2).update(errors=['peer_drop_room_fence']), 'outside the fence wait'),
            (lambda value: failure(value, 1).update(errors=['peer_drop_room_gate']), 'outside the fence wait'),
            (lambda value: failure(value, 2).update(stage='peer_drop_room_fence'), 'outside the fence wait'),
            (lambda value: failure(value, 2).update(stage='gameplay'), 'outside the fence wait'),
            (lambda value: failure(value).update(stage='handshake'), 'outside the fence wait'),
            (lambda value: failure(value, 2).update(hold_ms=-1), 'hold was not released'),
            (lambda value: failure(value, 2).update(hold_ms=True), 'hold was not released'),
            (lambda value: failure(value, 2).update(uuid='00000000-0000-0000-0000-000000000000'), 'outside the fence wait'),
            (lambda value: value['records'][0].update(survivorUuids=[value['records'][0]['survivorUuids'][0]] * 2), 'survivor identities'),
            (lambda value: value['records'][0].update(survivorUuids=[value['records'][0]['survivorUuids'][0]]), 'survivor identities'),
            (lambda value: value['records'][0].pop('survivorUuids'), 'survivor identities'),
            (lambda value: failure(value, 0).update(uuid=value['records'][0]['survivorUuids'][1]), 'outside the fence wait'),
            (lambda value: failure(value, 1).update(uuid=value['records'][0]['departedUuid']), 'outside the fence wait'),
            (lambda value: value['records'][0]['peers'][0]['result'].update(passed=True), 'did not fail'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, process_missing=True)


def roster_of(value):
    return value['records'][0]['peers'][0]['result']['records'][0]['roster']


class RoomAfterDropEvidence(unittest.TestCase):
    def test_post_drop_room_event_keeps_the_certified_history_and_fences(self):
        original = after_drop_evidence()
        self.assertIs(validate_drop_browser(original, room_after_drop=True), original)
        survivor = lambda value, index=0: value['records'][0]['peers'][index]['result']['records'][0]
        mutations = [
            (lambda value: value.update(dropRoomAfterDrop=False), 'incomplete'),
            (lambda value: survivor(value).update(fence_frame=39), 'terminal fence'),
            (lambda value: survivor(value).update(final_frame=39), 'terminal fence'),
            (lambda value: survivor(value).update(frames_after_fence=1), 'terminal fence'),
            (lambda value: survivor(value).pop('frames_after_fence'), 'terminal fence'),
            (lambda value: survivor(value).update(frames_after_fence='0'), 'terminal fence'),
            (lambda value: survivor(value).update(room_fenced=False), 'terminal fence'),
            (lambda value: survivor(value).update(fence_route='mesh'), 'terminal fence'),
            (lambda value: survivor(value).update(fence_error=0), 'terminal fence'),
            (lambda value: survivor(value).update(player_left_events=[]), 'terminal fence'),
            (lambda value: survivor(value).update(frozen_roster=[]), 'terminal fence'),
            (lambda value: survivor(value).update(room_roster_after=roster_of(value)), 'terminal fence'),
            (lambda value: survivor(value).update(departed_slot=1), 'terminal fence'),
            (lambda value: survivor(value).update(departed_uuid='00000000-0000-0000-0000-000000000000'), 'terminal fence'),
            (lambda value: survivor(value).update(drop_events=0), 'canonical history'),
            (lambda value: survivor(value).update(barrier_committed=False), 'terminal fence'),
            (lambda value: survivor(value).update(fence_history_comparisons=37), 'terminal fence'),
            (lambda value: survivor(value).update(session_id='cd' * 16), 'terminal fence'),
            (lambda value: survivor(value).update(freeze_frame=4), 'frozen sample'),
            (lambda value: value['records'][0]['peers'][2]['result']['records'][0].update(
                departure_kind='room_left'), 'post-drop departing page'),
            (lambda value: value['records'][0]['peers'][2]['result']['records'][0].update(
                frames_submitted=40), 'departure or continued input'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, room_after_drop=True)


class RoomBeforeDropEvidence(unittest.TestCase):
    def test_room_event_before_commit_fences_with_unchanged_history(self):
        original = before_drop_evidence()
        self.assertIs(validate_drop_browser(original, room_before_drop=True), original)
        survivor = lambda value, index=0: value['records'][0]['peers'][index]['result']['records'][0]
        mutations = [
            (lambda value: value.update(dropRoomBeforeDrop=False), 'incomplete'),
            (lambda value: survivor(value).update(canonical_unchanged=False), 'unchanged history'),
            (lambda value: survivor(value).update(canonical_comparisons=5), 'unchanged history'),
            (lambda value: survivor(value).update(barrier_state='committed'), 'unchanged history'),
            (lambda value: survivor(value).update(barrier_certified=True), 'unchanged history'),
            (lambda value: survivor(value).update(barrier_value='67'), 'unchanged history'),
            (lambda value: survivor(value).update(freeze_frame=6), 'unchanged history'),
            (lambda value: survivor(value).update(drop_pending_events=0), 'unchanged history'),
            (lambda value: survivor(value).update(drop_events=1), 'unchanged history'),
            (lambda value: survivor(value).update(barrier_open=False), 'unchanged history'),
            (lambda value: survivor(value).update(frames_after_fence=1), 'unchanged history'),
            (lambda value: survivor(value).pop('frames_after_fence'), 'unchanged history'),
            (lambda value: survivor(value).update(frames_after_fence='0'), 'unchanged history'),
            (lambda value: value['records'][0]['peers'][2]['result']['records'][0].update(
                departure_kind='room_left'), 'pre-commit departing page'),
            (lambda value: value['records'][0]['peers'][2]['result']['records'][0].update(
                frames_submitted=40), 'pre-commit departing page'),
        ]
        for index, (mutate, message) in enumerate(mutations):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=index), self.assertRaisesRegex(ValueError, message):
                validate_drop_browser(value, room_before_drop=True)


if __name__ == '__main__':
    unittest.main()
