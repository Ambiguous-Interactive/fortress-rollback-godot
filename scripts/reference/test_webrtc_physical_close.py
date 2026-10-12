"""Value: physical channel closure must prove relay continuation, healthy links and exact ownership."""
import copy
import unittest

import signalfish_webrtc_probe as probe
from test_signalfish_webrtc_probe import mixed_evidence


def close_evidence():
    result = mixed_evidence()
    result['physicalClose'] = True
    for record in result['records']:
        for index, peer in enumerate(record['peers']):
            affected = index in (0, 1)
            state = peer['result']['records'][0]['mixed']
            state.update(switched=affected, restored=False, relay_peers=int(affected))
            peer['rtc']['binarySent'] = 5 if affected else 0
            peer['result']['binary_receives'] = 5 if affected else 0
            state['accepted_binary'] = 5 if affected else 0
            for slot, channel in enumerate(channel for channel in peer['rtc']['channels'] if channel['id'] == 3):
                closed = affected and slot == 0
                channel.update(blockedReads=0, closeInitiatedFrame=4 if index == 0 and closed else None,
                               physicalCloseFrame=4 if closed else None, restoredSent=0 if closed else 5)
    return result


class PhysicalCloseEvidenceControls(unittest.TestCase):
    def test_physical_close_requires_exact_link_and_continued_gameplay(self):
        original = close_evidence()
        self.assertEqual(probe.validate_browser(original, False, mixed=True, physical_close=True), original)
        changes = [
            (0, ('rtc', 'channels', 2, 'closeInitiatedFrame'), None),
            (0, ('rtc', 'channels', 2, 'closeInitiatedFrame'), True),
            (0, ('rtc', 'channels', 2, 'physicalCloseFrame'), 39),
            (0, ('rtc', 'channels', 2, 'physicalCloseFrame'), 3),
            (0, ('rtc', 'channels', 2, 'physicalCloseFrame'), None),
            (1, ('rtc', 'channels', 2, 'physicalCloseFrame'), None),
            (1, ('rtc', 'channels', 2, 'closeInitiatedFrame'), 4),
            (2, ('rtc', 'channels', 2, 'physicalCloseFrame'), 4),
            (0, ('rtc', 'channels', 2, 'restoredSent'), 1),
            (0, ('rtc', 'channels', 5, 'restoredSent'), 0),
            (0, ('rtc', 'channels', 2, 'earlySent'), []),
            (1, ('rtc', 'channels', 2, 'earlyReceived'), []),
            (0, ('rtc', 'binarySent'), 0),
            (1, ('rtc', 'binarySent'), 0),
            (0, ('result', 'records', 0, 'mixed', 'relay_peers'), 0),
            (1, ('result', 'records', 0, 'mixed', 'switched'), False),
            (0, ('result', 'records', 0, 'mixed', 'restored'), True),
            (1, ('result', 'records', 0, 'mixed', 'accepted_binary'), 0),
            (0, ('result', 'records', 0, 'minimum_confirmed'), 37),
        ]
        for index, fields, value in changes:
            changed = copy.deepcopy(original)
            target = changed['records'][1]['peers'][index]
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(index=index, fields=fields), self.assertRaises(ValueError):
                probe.validate_browser(changed, False, mixed=True, physical_close=True)

    def test_pressure_and_close_cannot_substitute_for_each_other(self):
        for result, close in [(mixed_evidence(), True), (close_evidence(), False)]:
            with self.subTest(close=close), self.assertRaises(ValueError):
                probe.validate_browser(result, False, mixed=True, physical_close=close)


if __name__ == '__main__':
    unittest.main()
