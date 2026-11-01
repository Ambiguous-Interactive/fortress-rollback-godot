"""Value: reject partial browser meshes, missing rollback evidence and unaudited channel claims."""
import ast
import copy
import inspect
import json
import hashlib
import struct
from unittest.mock import patch
from browser import webrtc_runner
import unittest
from pathlib import Path
import tempfile

import signalfish_webrtc_probe as probe
from wire import INPUT_HEADER, VERSION
from test_webrtc_recording import recording


def gameplay_diagnostic():
    samples = [{'elapsed_ms': 19900, 'frame': frame, 'done': False,
                'progress': {'confirmed': frame - 1, 'received': [frame - 1], 'acked': [frame - 2]}} for frame in (5, 4)]
    return {'round_started_ms': 20000, 'elapsed_ms': 20000, 'deadline_ms': 20000,
            'peers': [{'frame': frame, 'changed_ms': 0, 'final_ms': None, 'frontier': None, 'done': False} for frame in (5, 4)],
            'evaluations': copy.deepcopy(samples), 'last_samples': samples,
            'attempts': [{'started_ms': 19800, 'completed_ms': 19900} for unused in range(2)]}


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
    return {'passed': True, 'browser': 'chromium/chromium', 'version': '141', 'browser_instances': 2, 'faults': faults, 'corrupt': False, 'records': records, 'errors': []}


def mixed_evidence():
    result = evidence(False)
    result['mixed'] = True
    for record in result['records']:
        count = record['players']
        body = struct.pack('<iiH', 2, 1, 1) + bytes([1, 0, count]) + struct.pack('<BiH', 0, 1, 0) * count + struct.pack('<I', 1) + bytes([35])
        payload = (INPUT_HEADER + bytes([count]) * 16
                   + hashlib.sha256(b'00000000-0000-0000-0000-000000000000').digest()[:8]
                   + bytes([1]) + bytes(7) + struct.pack('<I', len(body)) + body).hex()
        for index, peer in enumerate(record['peers']):
            peer['result']['records'][0]['recording'] = recording(count)
            peer['result']['binary_receives'] = 5 if index != 0 else 0
            peer['result']['records'][0]['mixed'] = {
                'switched': index == 0, 'restored': index == 0, 'relay_peers': 0, 'maximum_pending': 7,
                'maximum_relay_pending': 7, 'maximum_relay_received': 7, 'accepted_binary': 5 if index == 1 else 0,
                'overlap_packets': 1 if index == 0 else 0, 'caller_pending': 0, 'route_budget': 8,
                'send_budget': 32, 'receive_budget': 32, 'uuid': f'00000000-0000-0000-0000-{index:012x}',
                'relay_payloads': [payload] if index == 1 else [],
                'overlap': {'recipient': '00000000-0000-0000-0000-000000000001', 'payload': payload} if index == 0 else {}}
            peer['rtc']['binarySent'] = 5 if index == 0 else 0
            peer['rtc']['maximumRelayBuffered'] = 100
            peer['rtc']['captureError'] = False
            for slot, channel in enumerate(channel for channel in peer['rtc']['channels'] if channel['id'] == 3):
                blocked = index == 0 and slot == 0
                channel.update(blockedLink=blocked, blockedReads=5 if blocked else 0,
                               mixedSent=0 if blocked else 5, restoredSent=5, maximumBuffered=100,
                               earlySent=[payload] if index == 0 else [], earlyReceived=[payload] if index == 1 else [])
    return result


class BrowserWebRtcEvidenceControls(unittest.TestCase):
    def test_mixed_delivery_requires_real_paths_restoration_healthy_links_and_bounded_ownership(self):
        original = mixed_evidence()
        self.assertEqual(probe.validate_browser(original, False, mixed=True), original)
        changes = [
            (('result', 'records', 0, 'recording'), None),
            (('result', 'records', 0, 'recording', 'after_frame'), 41),
            (('result', 'records', 0, 'mixed', 'switched'), False),
            (('result', 'records', 0, 'mixed', 'restored'), False),
            (('result', 'records', 0, 'mixed', 'route_budget'), True),
            (('result', 'records', 0, 'mixed', 'send_budget'), 8),
            (('result', 'records', 0, 'mixed', 'maximum_pending'), 129),
            (('result', 'records', 0, 'mixed', 'maximum_relay_pending'), -1),
            (('result', 'records', 0, 'mixed', 'maximum_relay_received'), 129),
            (('result', 'records', 0, 'mixed', 'caller_pending'), 1),
            (('result', 'records', 0, 'mixed', 'overlap_packets'), 0),
            (('result', 'records', 0, 'mixed', 'relay_peers'), 1),
            (('rtc', 'binarySent'), 0),
            (('rtc', 'channels', 2, 'blockedReads'), 0),
            (('rtc', 'channels', 2, 'mixedSent'), 1),
            (('rtc', 'channels', 2, 'restoredSent'), 0),
            (('rtc', 'channels', 5, 'mixedSent'), 0),
        ]
        for fields, value in changes:
            changed = copy.deepcopy(original)
            target = changed['records'][1]['peers'][0]
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                probe.validate_browser(changed, False, mixed=True)
        changed = copy.deepcopy(original)
        changed['records'][0]['peers'][1]['result']['records'][0]['mixed']['accepted_binary'] = 0
        changed['records'][0]['peers'][1]['result']['records'][0]['mixed']['relay_payloads'] = []
        with self.assertRaisesRegex(ValueError, 'addressed relay'):
            probe.validate_browser(changed, False, mixed=True)

    def test_mixed_addressed_receipts_need_remote_physical_delivery(self):
        original = mixed_evidence()
        for missing_physical in (True, False):
            changed = copy.deepcopy(original)
            for record in changed['records']:
                if missing_physical:
                    for peer in record['peers']: peer['result']['binary_receives'] = 0
                else:
                    for peer in record['peers']:
                        peer['result']['records'][0]['mixed']['accepted_binary'] = 0
                        peer['result']['records'][0]['mixed']['relay_payloads'] = []
                    record['peers'][0]['result']['binary_receives'] = 5
                    record['peers'][0]['result']['records'][0]['mixed']['accepted_binary'] = 5
            with self.subTest(missing_physical=missing_physical), self.assertRaisesRegex(ValueError, 'physical binary' if missing_physical else 'own broadcast'):
                probe.validate_browser(changed, False, mixed=True)

    def test_mixed_overlap_needs_the_same_bytes_on_both_physical_paths(self):
        original = mixed_evidence()
        for index, fields, value in [
                (0, ('rtc', 'channels', 2, 'earlySent'), []),
                (1, ('rtc', 'channels', 2, 'earlyReceived'), []),
                (1, ('result', 'records', 0, 'mixed', 'relay_payloads'), []),
                (1, ('result', 'records', 0, 'mixed', 'relay_payloads'), ['0304']),
                (0, ('result', 'records', 0, 'mixed', 'overlap', 'recipient'), 'unknown'),
                (0, ('result', 'records', 0, 'mixed', 'overlap', 'payload'), 'zz'),
                (0, ('rtc', 'maximumRelayBuffered'), 262145),
                (0, ('rtc', 'channels', 2, 'maximumBuffered'), 262145)]:
            changed = copy.deepcopy(original)
            target = changed['records'][0]['peers'][index]
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                probe.validate_browser(changed, False, mixed=True)

    def test_overlap_accepts_original_inputs_retransmitted_before_pressure(self):
        sender = '00000000-0000-0000-0000-000000000000'
        for start, end in [(0, 1), (1, 2), (0, 2), (2, 3), (0, 3)]:
            raw = bytes.fromhex(mixed_evidence()['records'][0]['peers'][0]['result']['records'][0]['mixed']['overlap']['payload'])
            body = (struct.pack('<iiH', start, 1, end - start) + raw[54:71]
                    + struct.pack('<I', end - start) + bytes((frame * 17 + 1) & 255 for frame in range(start, end)))
            packet = raw[:40] + struct.pack('<I', len(body)) + body
            with self.subTest(start=start, end=end):
                probe.validate_overlap_input(packet, 2, sender, 0)
                corrupted = packet[:-1] + bytes([packet[-1] ^ 1])
                with self.assertRaisesRegex(ValueError, 'original input bytes'):
                    probe.validate_overlap_input(corrupted, 2, sender, 0)

    def test_disabled_fallback_requires_observed_pressure_at_the_gameplay_stall(self):
        failed = {'failure': 'Error: page evaluation exceeded active progress deadline ' + json.dumps(gameplay_diagnostic()), 'errors': [], 'records': [],
                  'failed_rooms': [{'players': 2, 'peers': [
                      {'index': 0, 'frame': '5', 'rtc': {'channels': [
                          {'id': 3, 'blocked_reads': 10, 'buffered_amount': 262144}]}},
                      {'index': 1, 'frame': '4', 'rtc': {'channels': []}}]}]}
        output = json.dumps(failed) + '\nError: peer 1 gameplay stalled\n'
        self.assertEqual(probe.validate_disabled_control(1, output), failed)
        for code, text in [(0, output), (1, ''), (1, output + output), (True, output)]:
            with self.subTest(code=code), self.assertRaises(ValueError):
                probe.validate_disabled_control(code, text)
        for fields, value in [
                (('failure',), 'Error: setup timeout'),
                (('errors',), ['script error']),
                (('failed_rooms', 0, 'peers', 0, 'frame'), '16'),
                (('failed_rooms', 0, 'peers', 0, 'rtc', 'channels', 0, 'blocked_reads'), 0),
                (('failed_rooms', 0, 'peers', 0, 'rtc', 'channels', 0, 'buffered_amount'), 0)]:
            changed = copy.deepcopy(failed)
            target = changed
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                probe.validate_disabled_control(1, json.dumps(changed))

    # Value: protects=actual deadline evidence; fails_when=bare errors or impossible attempt records pass; why_new=old gate ignores attempts; seam=none.
    def test_disabled_control_reconciles_all_emitted_observation_fields(self):
        captured = [{'frame': '5'}, {'frame': '4'}]
        original = gameplay_diagnostic()
        probe.validate_gameplay_diagnostic(json.dumps(original), captured)
        pending = copy.deepcopy(original)
        pending['attempts'][0] = {'started_ms': 19950, 'completed_ms': None}
        pending['evaluations'][0] = None
        pending['round_started_ms'] = 19950
        probe.validate_gameplay_diagnostic(json.dumps(pending), captured)
        late = copy.deepcopy(original)
        late['attempts'][0] = {'started_ms': 19950, 'completed_ms': 20000}
        late['evaluations'][0] = {'elapsed_ms': 20000, 'frame': 39, 'done': True, 'progress': None}
        probe.validate_gameplay_diagnostic(json.dumps(late), captured, expired_peer=0)
        for fields, value in [(('round_started_ms',), 19949), (('evaluations', 0), original['evaluations'][0]),
                              (('attempts', 0, 'started_ms'), 19899)]:
            changed = copy.deepcopy(pending)
            target = changed
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(pending=fields), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_gameplay_diagnostic(json.dumps(changed), captured)
        mutations = [
            (('evaluations',), []), (('attempts',), []), (('round_started_ms',), -1),
            (('round_started_ms',), 20001), (('round_started_ms',), 19000),
            (('evaluations', 0, 'elapsed_ms'), -1), (('evaluations', 0, 'elapsed_ms'), 20001),
            (('evaluations', 0, 'frame'), 39), (('evaluations', 0, 'done'), True),
            (('evaluations', 0, 'progress', 'acked'), [40]), (('last_samples', 0, 'frame'), 5.0),
            (('last_samples', 0, 'progress', 'received'), [True]),
            (('attempts', 0, 'started_ms'), 20001), (('attempts', 0, 'started_ms'), 19901),
            (('attempts', 0, 'completed_ms'), 20001), (('attempts', 0, 'completed_ms'), None),
            (('attempts', 0, 'completed_ms'), 19899), (('attempts', 0, 'started_ms'), None),
        ]
        for fields, value in mutations:
            changed = copy.deepcopy(original)
            target = changed
            for field in fields[:-1]: target = target[field]
            target[fields[-1]] = value
            with self.subTest(fields=fields, value=value), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_gameplay_diagnostic(json.dumps(changed), captured)
        for fields in [('evaluations',), ('attempts',), ('round_started_ms',), ('attempts', 0, 'completed_ms')]:
            changed = copy.deepcopy(original)
            target = changed
            for field in fields[:-1]: target = target[field]
            del target[fields[-1]]
            with self.subTest(missing=fields), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_gameplay_diagnostic(json.dumps(changed), captured)
        failed = {'failure': 'Error: peer 1 gameplay stalled', 'errors': [], 'records': [],
                  'failed_rooms': [{'players': 2, 'peers': [
                      {'index': 0, 'frame': '5', 'rtc': {'channels': [{'id': 3, 'blocked_reads': 10, 'buffered_amount': 262144}]}},
                      {'index': 1, 'frame': '4'}]}]}
        with self.assertRaisesRegex(ValueError, 'gameplay watchdog'):
            probe.validate_disabled_control(1, json.dumps(failed))
        failed['failure'] = 'Error: peer 0 gameplay stalled ' + json.dumps(late)
        self.assertEqual(probe.validate_disabled_control(1, json.dumps(failed)), failed)
        for index in (0, 1):
            changed = copy.deepcopy(original)
            changed['peers'][index]['changed_ms'] = 100
            failed['failure'] = f'Error: peer {index} gameplay stalled ' + json.dumps(changed)
            with self.subTest(named=index), self.assertRaisesRegex(ValueError, 'named peer'):
                probe.validate_disabled_control(1, json.dumps(failed))

    # Value: protects=single failure ordering; fails_when=accepted expiry or two rejected siblings pass; why_new=old schema checks only bounds; seam=none.
    def test_disabled_diagnostic_requires_the_actual_timer_or_sample_failure_order(self):
        original = gameplay_diagnostic()
        captured = [{'frame': '5'}, {'frame': '4'}]
        timely = copy.deepcopy(original)
        timely['last_samples'][0]['elapsed_ms'] = 19999.999
        timely['evaluations'][0] = copy.deepcopy(timely['last_samples'][0])
        timely['attempts'][0]['completed_ms'] = 19999.999
        probe.validate_gameplay_diagnostic(json.dumps(timely), captured)
        asymmetric = copy.deepcopy(original)
        asymmetric['peers'][1]['changed_ms'] = 100
        asymmetric['last_samples'][1]['elapsed_ms'] = 20000
        asymmetric['evaluations'][1] = copy.deepcopy(asymmetric['last_samples'][1])
        asymmetric['attempts'][1]['completed_ms'] = 20000
        probe.validate_gameplay_diagnostic(json.dumps(asymmetric), captured)
        mutants = []
        for elapsed in (20000, 20001):
            changed = copy.deepcopy(original)
            changed['elapsed_ms'] = changed['round_started_ms'] = elapsed
            changed['last_samples'][0]['elapsed_ms'] = elapsed
            changed['evaluations'][0] = copy.deepcopy(changed['last_samples'][0])
            changed['attempts'][0]['completed_ms'] = elapsed
            mutants.append((f'accepted_{elapsed}', changed))
        changed = copy.deepcopy(original)
        changed['round_started_ms'] = 19950
        mutants.append(('stale_round', changed))
        late = copy.deepcopy(original)
        late['evaluations'][0] = {'elapsed_ms': 20000, 'frame': 39, 'done': True, 'progress': None}
        late['attempts'][0] = {'started_ms': 19950, 'completed_ms': 20000}
        mutants.append(('timer_after_sample_failure', late))
        both = copy.deepcopy(late)
        both['evaluations'][1] = copy.deepcopy(both['evaluations'][0])
        both['attempts'][1] = copy.deepcopy(both['attempts'][0])
        mutants.append(('two_failed_samples', both))
        older = copy.deepcopy(late)
        older['elapsed_ms'] = older['round_started_ms'] = 20001
        mutants.append(('sample_failure_then_later_diagnostic', older))
        rejected_pair = copy.deepcopy(late)
        rejected_pair['evaluations'][1] = copy.deepcopy(rejected_pair['evaluations'][0])
        rejected_pair['attempts'][1] = copy.deepcopy(rejected_pair['attempts'][0])
        with self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
            probe.validate_gameplay_diagnostic(json.dumps(rejected_pair), captured, expired_peer=0)
        with self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
            probe.validate_gameplay_diagnostic(json.dumps(older), captured, expired_peer=0)
        asymmetric['evaluations'][0] = copy.deepcopy(late['evaluations'][0])
        asymmetric['attempts'][0] = copy.deepcopy(late['attempts'][0])
        probe.validate_gameplay_diagnostic(json.dumps(asymmetric), captured, expired_peer=0)
        for label, changed in mutants:
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_gameplay_diagnostic(json.dumps(changed), captured)
        failed = {'failure': '', 'errors': [], 'records': [], 'failed_rooms': [{'players': 2, 'peers': [
            {'index': 0, 'frame': '5', 'rtc': {'channels': [{'id': 3, 'blocked_reads': 10, 'buffered_amount': 262144}]}},
            {'index': 1, 'frame': '4'}]}]}
        for label, changed, index in [('accepted_named_peer', original, 0), ('wrong_named_peer', late, 1),
                                      ('two_failed_samples', both, 0), ('late_diagnostic', older, 0)]:
            failed['failure'] = f'Error: peer {index} gameplay stalled ' + json.dumps(changed)
            with self.subTest(path=label), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_disabled_control(1, json.dumps(failed))
        absolute = copy.deepcopy(late)
        absolute['elapsed_ms'] = absolute['round_started_ms'] = 240000
        absolute['evaluations'][0]['elapsed_ms'] = absolute['attempts'][0]['completed_ms'] = 240000
        failed['failure'] = 'Error: peer 0 gameplay stalled ' + json.dumps(absolute)
        with self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
            probe.validate_disabled_control(1, json.dumps(failed))

    def test_correlated_overlap_rejects_malformed_protocol_and_changed_original_inputs(self):
        original = mixed_evidence()
        payload = original['records'][0]['peers'][0]['result']['records'][0]['mixed']['overlap']['payload']
        raw = bytes.fromhex(payload)
        mutants = [('truncated', b'\x00')]
        for offset, value in [(0, 0), (4, VERSION + 1), (6, 4), (7, 1), (32, 0), (33, 2), (40, 0), (len(raw) - 1, 0)]:
            changed = bytearray(raw)
            changed[offset] = value
            mutants.append((str(offset), bytes(changed)))
        for label, changed in mutants:
            result = copy.deepcopy(original)
            for peer in result['records'][0]['peers']:
                state = peer['result']['records'][0]['mixed']
                if state['overlap']: state['overlap']['payload'] = changed.hex()
                state['relay_payloads'] = [changed.hex() if value == payload else value for value in state['relay_payloads']]
                for channel in peer['rtc']['channels']:
                    for field in ('earlySent', 'earlyReceived'):
                        if field in channel:
                            channel[field] = [changed.hex() if value == payload else value for value in channel[field]]
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, 'overlap protocol|original input'):
                probe.validate_browser(result, False, mixed=True)

    def test_disabled_control_requires_a_real_gameplay_diagnostic_not_a_prefix(self):
        failure = {'failure': '', 'errors': [], 'records': [], 'failed_rooms': [{'players': 2, 'peers': [
            {'index': 0, 'frame': '5', 'rtc': {'channels': [{'id': 3, 'blocked_reads': 10, 'buffered_amount': 262144}]}},
            {'index': 1, 'frame': '4', 'rtc': {'channels': []}}]}]}
        for suffix in ['not-json', json.dumps({'peers': [{'frame': 39, 'final_ms': 10, 'done': False}]})]:
            failure['failure'] = 'Error: page evaluation exceeded active progress deadline ' + suffix
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, 'watchdog diagnostic'):
                probe.validate_disabled_control(1, json.dumps(failure))

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
        for label, expected in [('clean', 1500), ('faults', 1500), ('corrupt', 540), ('default', 540), ('peer-drop', 540), ('peer-drop-corrupt', 540),
                                ('peer-drop-close', 540), ('peer-drop-answer', 540), ('peer-drop-relay', 540), ('recording-pressure', 540)]:
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
