"""Value: binds real browser claims to selected process versions and alternating peer ownership."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from browser.webrtc_matrix import PAIRS, validate_identity
from fetch import load_manifest
import signalfish_webrtc_probe as probe


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


class BrowserArgumentReceipts(unittest.TestCase):
    # Value: malformed browser invocations must not retain a previous green receipt or erase the sibling mode's evidence.
    def test_parse_and_post_parse_failures_invalidate_only_selected_mode(self):
        cases = [
            (['--browser-pair', 'webkit'], False, False),
            (['--unknown-option'], False, False),
            (['--help=bogus'], False, False),
            (['-hbogus'], False, False),
            (['--browser-pair', 'webkit', '--help'], False, False),
            ([], False, True),
            (['--version', 'not-pinned'], False, False),
            (['--godot', 'unused'], False, False),
            (['--godot', 'unused', '--version', '4.3', '--version', '4.7.2'], False, False),
            (['--browser-pair', 'firefox'], True, False),
            (['--browser-pair', 'webkit'], True, False),
            (['--unknown-option'], True, False),
            (['--help=bogus'], True, False),
            (['-hbogus'], True, False),
            ([], True, True),
            (['--version', 'not-pinned'], True, False),
            (['--godot', 'unused'], True, False),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            for flags, online, missing in cases:
                original = '{"passed": true, "marker": "original"}\n'
                for name in ('online-example.json', 'signalfish-webrtc.json'):
                    (output / name).write_text(original)
                command = [sys.executable, probe.__file__, '--output', str(output)]
                if not missing:
                    command.extend(['--server', 'unused', '--server-source', 'unused', '--build-receipt', 'unused'])
                if online:
                    command.append('--online-example')
                result = subprocess.run(command + flags, capture_output=True, encoding='utf-8', timeout=10)
                chosen = output / ('online-example.json' if online else 'signalfish-webrtc.json')
                sibling = output / ('signalfish-webrtc.json' if online else 'online-example.json')
                with self.subTest(flags=flags, online=online, missing=missing):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIs(json.loads(chosen.read_text())['passed'], False)
                    self.assertEqual(sibling.read_text(), original)

    def test_help_is_read_only_before_and_after_invalid_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            original = '{"passed": true}\n'
            for flags in (['--help'], ['--help', '--browser-pair', 'webkit'], ['--online-example', '--help'], ['-h']):
                for name in ('online-example.json', 'signalfish-webrtc.json'):
                    (output / name).write_text(original)
                result = subprocess.run([sys.executable, probe.__file__, '--output', str(output)] + flags,
                                        capture_output=True, encoding='utf-8', timeout=10)
                self.assertEqual(result.returncode, 0)
                self.assertIn('--browser-pair', result.stdout)
                for name in ('online-example.json', 'signalfish-webrtc.json'):
                    self.assertEqual((output / name).read_text(), original)

    def test_output_preview_matches_full_parser_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, last = root / 'first', root / 'last'
            for flags, target, online in [
                    (['--output', str(first), '--output', str(last), '--unknown'], last, False),
                    (['--output=' + str(last), '--online-example', '--unknown'], last, True),
                    (['--unknown', '--output', str(last)], last, False),
                    (['--output', '--output', str(last)], last, False),
                    (['--output', str(last), '--output'], last, False)]:
                target.mkdir(exist_ok=True)
                name = 'online-example.json' if online else 'signalfish-webrtc.json'
                (target / name).write_text('{"passed":true}\n')
                result = subprocess.run([sys.executable, probe.__file__] + flags,
                                        capture_output=True, encoding='utf-8', timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIs(json.loads((target / name).read_text())['passed'], False)


if __name__ == '__main__':
    unittest.main()
