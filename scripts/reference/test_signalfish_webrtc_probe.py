"""Value: reject partial browser meshes, missing rollback evidence and unaudited channel claims."""
import ast
import copy
import inspect
from unittest.mock import patch
from browser import webrtc_runner
import unittest
from pathlib import Path
import tempfile

import signalfish_webrtc_probe as probe


def evidence(faults):
    records = []
    for count in (2, 4, 8):
        peers = []
        for _ in range(count):
            channels = []
            for _ in range(count - 1):
                for channel_id in (1, 2, 3):
                    channels.append({'id': channel_id, 'ordered': channel_id == 1, 'negotiated': True,
                                     'maxPacketLifeTime': 1 if channel_id == 3 else None, 'maxRetransmits': None,
                                     'sent': 40 if channel_id == 3 else 0, 'received': 40 if channel_id == 3 else 0})
            peers.append({'result': {'passed': True, 'binary_receives': 0, 'records': [
                {'players': count, 'frames_submitted': 40, 'canonical_comparisons': 38, 'minimum_confirmed': 38,
                 'direct': {'sent': 40, 'received': 40}, 'rollback_loads': 20, 'active_comparisons': 37}]},
                'rtc': {'teardown': {'channels': 3 * (count - 1), 'connections': count - 1, 'connections_created': count - 1}, 'channels': channels, 'sent': 40, 'received': 40,
                        'dropped': 2 if faults else 0, 'reordered': 1 if faults else 0}})
        records.append({'players': count, 'peers': peers})
    return {'passed': True, 'browser': 'Chromium', 'version': '141', 'browser_instances': 2, 'faults': faults, 'corrupt': False, 'records': records, 'errors': []}


class BrowserWebRtcEvidenceControls(unittest.TestCase):
    def test_engine_pin_rejects_appended_bytes_despite_unchanged_version_text(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / "godot"
            engine.write_bytes(b"pinned editor executable version4.3")
            expected = probe.digest(engine)
            probe.validate_engine(engine, expected)
            engine.write_bytes(engine.read_bytes() + b"appended mutant")
            with self.assertRaisesRegex(ValueError, "differs from pinned editor archive"):
                probe.validate_engine(engine, expected)

    def test_import_metadata_is_frozen_while_authored_file_mutations_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, icon, metadata = root / 'game.gd', root / 'icon.png', root / 'icon.png.import'
            script.write_text('extends Node\n')
            icon.write_bytes(b'original asset')
            metadata.write_text('old editor metadata')
            paths = {'addon': root}
            before = probe.inventory(paths)
            metadata.write_text('new editor metadata')
            (root / 'game.gd.uid').write_text('uid://generated')
            frozen = probe.freeze_after_import(paths, before)
            self.assertIn('addon/game.gd.uid', frozen)
            self.assertNotEqual(before['addon/icon.png.import'], frozen['addon/icon.png.import'])
            script.write_text('extends RefCounted\n')
            with self.assertRaisesRegex(ValueError, 'authored Web source changed'):
                probe.freeze_after_import(paths, before)
            script.write_text('extends Node\n')
            (root / 'unowned.gd.uid').write_text('uid://orphan')
            with self.assertRaisesRegex(ValueError, 'unexpected editor-generated Web file'):
                probe.freeze_after_import(paths, before)

    def test_missing_gameplay_or_transport_evidence_is_rejected(self):
        for faults in (False, True):
            original = evidence(faults)
            self.assertEqual(probe.validate_browser(original, faults), original)
            mutants = []
            for field, value in [('canonical_comparisons', 37), ('minimum_confirmed', 37), ('frames_submitted', 39),
                                 ('rollback_loads', 0), ('active_comparisons', 0), ('players', True)]:
                changed = copy.deepcopy(original)
                changed['records'][0]['peers'][0]['result']['records'][0][field] = value
                mutants.append((field, changed))
            for field, value in [('sent', 0), ('received', 0), ('dropped', 0 if faults else 1), ('reordered', 0 if faults else 1)]:
                changed = copy.deepcopy(original)
                changed['records'][0]['peers'][0]['rtc'][field] = value
                mutants.append(('rtc_' + field, changed))
            for field, value in [('ordered', True), ('maxPacketLifeTime', 0), ('maxRetransmits', 0), ('id', 1), ('negotiated', False)]:
                changed = copy.deepcopy(original)
                changed['records'][0]['peers'][0]['rtc']['channels'][2][field] = value
                mutants.append(('channel_' + field, changed))
            for field, value in [('binary_receives', 1), ('passed', False)]:
                changed = copy.deepcopy(original)
                changed['records'][0]['peers'][0]['result'][field] = value
                mutants.append(('result_' + field, changed))
            changed = copy.deepcopy(original)
            del changed['records'][0]['peers'][0]['rtc']['channels'][2]['maxRetransmits']
            mutants.append(('missing_max_retransmits', changed))
            changed = copy.deepcopy(original)
            changed['records'][0]['peers'][0]['rtc']['teardown']['connections_created'] += 1
            mutants.append(('orphan_connection', changed))
            changed = copy.deepcopy(original)
            changed['records'][2]['peers'].pop()
            mutants.append(('missing_peer', changed))
            changed = copy.deepcopy(original)
            changed['records'].pop()
            mutants.append(('missing_count', changed))
            for label, changed in mutants:
                with self.subTest(faults=faults, mutation=label), self.assertRaises(ValueError):
                    probe.validate_browser(changed, faults)

    def test_restore_control_rejects_an_unrelated_failure(self):
        result = {'passed': True, 'corrupt': True, 'defaultFactory': False, 'faults': False, 'browser_instances': 2, 'errors': [],
                  'records': [{'players': 2, 'peers': [{'result': {'passed': False,
                      'failure': {'stage': 'gameplay', 'errors': ['canonical_prefix_frame_1']}}} for _ in range(2)]}]}
        self.assertEqual(probe.validate_restore_control(result), result)
        for stage, errors in [('configure_rollback', ['configure_direct_1']), ('gameplay', []), ('gameplay', ['protocol_error'])]:
            changed = copy.deepcopy(result)
            changed['records'][0]['peers'][0]['result']['failure'].update(stage=stage, errors=errors)
            with self.subTest(stage=stage, errors=errors), self.assertRaises(ValueError):
                probe.validate_restore_control(changed)

    def test_default_factory_control_still_requires_exact_handshake_error(self):
        result = {'passed': True, 'corrupt': False, 'defaultFactory': True, 'faults': False, 'browser_instances': 2, 'errors': [],
                  'records': [{'players': 2, 'peers': [{'result': {'passed': False,
                      'failure': {'stage': 'handshake', 'errors': ['direct_poll_3_peer_0']}}} for _ in range(2)]}]}
        self.assertEqual(probe.validate_restore_control(result, 'default'), result)
        for stage, errors in [('connect_mesh', ['direct_poll_3_peer_0']), ('handshake', ['wait_timeout_handshake']), ('handshake', [])]:
            changed = copy.deepcopy(result)
            changed['records'][0]['peers'][0]['result']['failure'].update(stage=stage, errors=errors)
            with self.subTest(stage=stage, errors=errors), self.assertRaises(ValueError):
                probe.validate_restore_control(changed, 'default')

    def test_actual_browser_call_uses_room_count_budget_and_routes_capture_timeout(self):
        source = ast.parse(inspect.getsource(probe.main))
        calls = [node for node in ast.walk(source) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == 'run_browser']
        self.assertEqual(len(calls), 1)
        arguments = [keyword.value for keyword in calls[0].keywords if keyword.arg == 'rooms']
        self.assertEqual(len(arguments), 1, 'actual launcher must supply the room budget')
        expression = compile(ast.Expression(arguments[0]), 'actual_launcher_budget', 'eval')
        for label, expected in [('clean', 1500), ('faults', 1500), ('corrupt', 540), ('default', 540)]:
            rooms = eval(expression, {'label': label})
            with self.subTest(label=label), patch.object(webrtc_runner, 'capture', return_value=(0, 'ok')) as capture:
                self.assertEqual(webrtc_runner.run_browser(['node', label], {}, Path('owned.log'), rooms), 'ok')
                capture.assert_called_once_with(['node', label], {}, Path('owned.log'), timeout=expected)
        with patch.object(webrtc_runner, 'capture') as capture:
            with self.assertRaises(ValueError):
                webrtc_runner.run_browser(['node'], {}, Path('owned.log'), True)
            capture.assert_not_called()


if __name__ == '__main__':
    unittest.main()
