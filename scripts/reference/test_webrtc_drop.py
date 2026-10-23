"""Value: reject apparent peer-drop success without agreement, continuation or real exports."""
import copy
import hashlib
import unittest

from browser.webrtc_drop import validate_drop_browser


def evidence(corrupt=False):
    peers = []
    roster = [f'00000000-0000-0000-0000-{index:012x}' for index in range(3)]
    for index in range(3):
        row = {'players': 3, 'departed': index == 2, 'frames_submitted': 7 if index == 2 else 40, 'slot': index, 'uuid': roster[index], 'roster': roster}
        if index < 2:
            row.update(state='committed', drop_events=1, canonical_comparisons=38, active_comparisons=30,
                       prediction_gap=2, freeze_frame=5, departing_slot=2, minimum_confirmed=38, rollback_loads=1,
                       frozen_value=bytes([(5 * 17 + 2 * 31 + 1) & 255]).hex(),
                       role=1 - index, certified=index == 1, certificates=1 - index)
        if index < 2:
            other_id = hashlib.sha256(roster[1 - index].encode('ascii')).digest()[:8].hex()
            digest = ((0x14650fb0739d0383 ^ int(row['frozen_value'], 16)) * 1099511628211) & 0x3fffffffffffffff
            row.update(participants=[other_id], digest=f'{digest:016x}',
                       certificate_rows=[{'peer': other_id, 'cut': 5, 'digest': f'{digest:016x}'}] if index == 0 else [])
        result = {'passed': True, 'records': [row]}
        if corrupt and index < 2:
            result = {'passed': False, 'failure': {'stage': 'peer_drop_gameplay', 'errors': ['peer_drop_canonical_8']}}
        channels = [{'id': channel_id, 'ordered': False, 'negotiated': True, 'maxPacketLifeTime': 1,
                     'maxRetransmits': None, 'sent': 20, 'received': 20}
                    for unused in range(2) for channel_id in (1, 2, 3)]
        peers.append({'result': result, 'rtc': {'sent': 20, 'received': 20, 'channels': channels,
                      'teardown': {'channels': 6, 'connections_created': 2, 'connections': 2}}})
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
        for key in ('channels', 'connections', 'connections_created'):
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


if __name__ == '__main__':
    unittest.main()
