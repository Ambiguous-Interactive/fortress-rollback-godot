"""Value: binds real browser claims to selected process versions and alternating peer ownership."""
import copy
import unittest

from browser.webrtc_matrix import PAIRS, validate_identity
from fetch import load_manifest


class BrowserMatrixIdentity(unittest.TestCase):
    def test_selected_pair_requires_both_pinned_processes_and_each_peer_assignment(self):
        pins = load_manifest()
        for pair in PAIRS.values():
            preferences = {'webgl.force-enabled': True, 'webgl.disabled': False} if 'firefox' in pair else None
            original = {'browser': '/'.join(pair), 'firefox_preferences': preferences, 'version': pins['browser'][pair[0] + '_version'],
                        'browsers': [{'name': name, 'version': pins['browser'][name + '_version']} for name in pair],
                        'records': [{'peers': [{'browser': pair[index % 2], 'display': {'x': index * 80, 'y': 0, 'width': 1280,
                            'height': 720, 'screen_width': 1280, 'screen_height': 1024} if pair[index % 2] == 'firefox' else None}
                            for index in range(count)]} for count in (2, 4, 8)]}
            validate_identity(original, pair, pins)
            for field in ('browser', 'version', 'browsers', *(['firefox_preferences'] if preferences else [])):
                changed = copy.deepcopy(original)
                changed[field] = None
                with self.subTest(pair=pair, field=field), self.assertRaises(ValueError):
                    validate_identity(changed, pair, pins)
            changed = copy.deepcopy(original)
            changed['browsers'][1]['version'] = 'unverified'
            with self.assertRaisesRegex(ValueError, 'process identities'):
                validate_identity(changed, pair, pins)
            for room in range(3):
                changed = copy.deepcopy(original)
                changed['records'][room]['peers'][-1]['browser'] = 'webkit'
                with self.subTest(pair=pair, room=room), self.assertRaisesRegex(ValueError, 'peer browser'):
                    validate_identity(changed, pair, pins)


if __name__ == '__main__':
    unittest.main()
