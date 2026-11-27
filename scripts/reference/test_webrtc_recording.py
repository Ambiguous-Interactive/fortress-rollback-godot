"""Value: bind mixed-path recordings to original inputs and decoded canonical playback."""
import copy
import hashlib
import struct
import unittest

from browser.webrtc_recording import engine_identity, validate_recording, validate_pressure
from wire import INPUT_HEADER


ENGINE = 'test-engine'


def recording(count, frames=40):
    raw = bytearray(b'FRRP' + struct.pack('<HBIIIHBB', 6, count, 1, frames, 0, 0, 8, 0) + b'\0')
    for text in (ENGINE, '0.1.0', 'fortress-rollback d124c89080004d96971a629bb0427056ee1805e3', '0', 'fortress-webrtc-integer-v1'):
        encoded = text.encode('ascii')
        raw += bytes([len(encoded)]) + encoded
    values = [0] * count
    for frame in range(frames):
        state = struct.pack('<' + 'I' * (count + 1), frame, *values)
        samples = bytes((frame * 17 + slot * 31 + 1) & 255 for slot in range(count))
        row = samples + bytes([1] * count)
        raw += row + b'\1' + hashlib.sha256(state).digest()[:16] + hashlib.sha256(row).digest()[:16]
        values = [(value * 33 + sample) & 0xffffffff for value, sample in zip(values, samples)]
    final = struct.pack('<' + 'I' * (count + 1), frames, *values)
    raw += hashlib.sha256(final).digest()[:16]
    return {'hex': raw.hex(), 'before_frame': frames, 'after_frame': frames, 'recover_code': 0, 'capture_code': 0,
            'decode_code': 0, 'playback_code': 16, 'playback_frame': frames, 'failure_frame': -1,
            'canonical': final.hex(), 'checked_checksums': frames + 1}


def pressure_input(sender, recipient, index, start):
    body = struct.pack('<iiHBBB', start, start - 1, 1, 1, index, 2)
    body += struct.pack('<BiH', 0, start, 0) * 2 + struct.pack('<I', 1)
    body += bytes([(start * 17 + index * 31 + 1) & 255])
    protocol = INPUT_HEADER + bytes([2]) * 16 + hashlib.sha256(sender.encode('ascii')).digest()[:8]
    protocol += struct.pack('<QI', index + 1, len(body)) + body
    envelope = b'FSR1\x01' + bytes([2]) * 16
    envelope += bytes.fromhex((sender + recipient).replace('-', '')) + struct.pack('<I', len(protocol)) + protocol
    return envelope.hex()


class RecordingTests(unittest.TestCase):
    def test_native_engine_identity(self):
        for version in ('4.3', '4.7.2'):
            identity = '.'.join((version.split('.') + ['0'])[:3]) + '.stable ' + 'a' * 40
            cli = version + '.stable.official.' + 'a' * 9
            marker = 'WEBRTC_ENGINE_IDENTITY ' + identity
            self.assertEqual(engine_identity(marker, version, cli), identity)
            for output in ('', marker + '\n' + marker, marker.replace('a' * 40, 'b' * 40), marker.replace('stable', 'dev')):
                with self.assertRaisesRegex(ValueError, 'native engine identity'):
                    engine_identity(output, version, cli)

    def test_original_roster_sizes(self):
        for count in (2, 4, 8):
            self.assertEqual(validate_recording(recording(count), count, ENGINE), 40)

    def test_report_mutations(self):
        original = recording(2)
        for field, value in [('before_frame', 39), ('after_frame', 41), ('recover_code', 1), ('capture_code', 1),
                             ('decode_code', 1), ('playback_code', 0), ('playback_frame', 39), ('failure_frame', 0),
                             ('canonical', '00'), ('checked_checksums', 40), ('checked_checksums', 41.0),
                             ('recover_code', False), ('hex', original['hex'] + '00'), ('hex', original['hex'][:-2]),
                             ('hex', 'ff' * 65537)]:
            with self.subTest(field=field, value=str(value)[:40]):
                changed = copy.deepcopy(original)
                changed[field] = value
                with self.assertRaises(ValueError):
                    validate_recording(changed, 2, ENGINE)
        with self.assertRaisesRegex(ValueError, 'metadata'):
            validate_recording(original, 2, 'another-engine')

    def test_serialized_mutations(self):
        original = recording(2)
        raw = bytearray.fromhex(original['hex'])
        start = 24
        for _ in range(5):
            start += 1 + raw[start]
        # Header, post-midpoint original input/status/checksum/digest, final evidence.
        for offset, reason in [(4, 'configuration'), (6, 'configuration'), (23, 'configuration'),
                               (start + 25 * 37, 'input'), (start + 25 * 37 + 2, 'status'),
                               (start + 25 * 37 + 4, 'flag'), (start + 25 * 37 + 5, 'checksum'),
                               (start + 25 * 37 + 21, 'digest'), (len(raw) - 1, 'terminal')]:
            with self.subTest(offset=offset):
                changed = copy.deepcopy(original)
                altered = raw.copy()
                altered[offset] ^= 1
                changed['hex'] = altered.hex()
                with self.assertRaisesRegex(ValueError, reason):
                    validate_recording(changed, 2, ENGINE)


    def test_post_wrap_pressure_recordings_and_missing_evidence(self):
        result = {'passed': True, 'recordingPressure': True, 'mixed': True, 'faults': False, 'corrupt': False,
                  'errors': [], 'browser_instances': 2, 'records': [{'players': 2, 'peers': []}]}
        ids = [f'{index:08x}-0000-0000-0000-000000000000' for index in range(2)]
        packets = [[pressure_input(ids[index], ids[1 - index], index, start) for start in (129, 134)] for index in range(2)]
        final_packets = [pressure_input(ids[index], ids[1 - index], index, 256) for index in range(2)]
        for index in range(2):
            period = 5 + index
            retries = [dict(envelope=packet, start_frame=start, frame=start + 1, refused_turn=100 * period + n * period + 1,
                            retry_turn=101 * period + n * period, blocked_read=n + 1) for n, (packet, start) in enumerate(zip(packets[index], (129, 134)))]
            sends = [dict(wire=retry['envelope'], turn=retry['retry_turn'], first=True) for retry in retries]
            state = dict(uuid=ids[index], pressure_refusals=20, pressure_post_wrap_refusals=10,
                         pressure_retries=10, accepted_binary=30, refused_head_bytes=0, caller_pending=0,
                         maximum_pending=10, maximum_relay_pending=10, maximum_relay_received=10,
                         retried_inputs=retries, received_inputs=packets[1 - index] + [final_packets[1 - index]])
            channels = [dict(id=1), dict(id=2), dict(id=3, blockedLink=True, blockedReads=20, ordered=False, negotiated=True,
                                                   maxPacketLifeTime=1, maxRetransmits=None, sent=10, received=10)]
            row = dict(players=2, frames_submitted=257, canonical_comparisons=255, minimum_confirmed=255,
                       active_comparisons=254, rollback_loads=10, mixed=state, recording=recording(2, 257))
            row['recording_tail'] = {
                'held': dict(frame=257, received_frame=255, turn=1234, loads=9),
                'receipt': dict(envelope=final_packets[1 - index], frame=257, turn=1235, stage='recording_confirmation'),
                'after': dict(frame=257, confirmed_frame=256, received_frame=256, loads=10),
            }
            result['records'][0]['peers'].append(dict(result=dict(passed=True, records=[row], binary_receives=30),
                rtc=dict(binarySent=30, captureError=False, relayBlockedReads=20, relayPostWrapBlockedReads=10, channels=channels, recordingRelaySends=sends,
                         recordingFinalRelaySend=dict(wire=final_packets[index], turn=1235, released=True),
                         teardown=dict(channels=3, connections_created=1, connections=1, websockets_created=1, websockets=1))))
        self.assertIs(validate_pressure(result, ENGINE), result)
        for physical in (None, {'wire': packets[0][0], 'turn': 1235, 'released': True},
                         {'wire': final_packets[0], 'turn': 1235, 'released': False},
                         {'wire': final_packets[0], 'turn': 1234, 'released': True}):
            with self.subTest(physical=physical):
                changed = copy.deepcopy(result)
                changed['records'][0]['peers'][0]['rtc']['recordingFinalRelaySend'] = physical
                with self.assertRaisesRegex(ValueError, 'final addressed receipt missing matching physical send'):
                    validate_pressure(changed, ENGINE)
        for section, key, value, diagnostic in [
            ('held', 'received_frame', 256, 'was not held'),
            ('receipt', 'stage', 'gameplay', 'receipt missing after the hold'),
            ('receipt', 'turn', 1233, 'receipt missing after the hold'),
            ('receipt', 'envelope', packets[1][0], 'lacks original input 256'),
            ('after', 'frame', 258, 'did not correct input 256'),
            ('after', 'loads', 9, 'did not correct input 256'),
        ]:
            with self.subTest(section=section, key=key):
                changed = copy.deepcopy(result)
                changed['records'][0]['peers'][0]['result']['records'][0]['recording_tail'][section][key] = value
                with self.assertRaisesRegex(ValueError, diagnostic):
                    validate_pressure(changed, ENGINE)
        for section, key, value in [('mixed', 'pressure_post_wrap_refusals', 0), ('mixed', 'pressure_retries', 0),
                                    ('mixed', 'refused_head_bytes', 100), ('mixed', 'accepted_binary', True),
                                    ('rtc', 'relayPostWrapBlockedReads', 0), ('rtc', 'binarySent', 0), ('rtc', 'captureError', True),
                                    ('row', 'active_comparisons', 253), ('row', 'frames_submitted', 40),
                                    ('mixed', 'refused_head_bytes', False), ('mixed', 'refused_head_bytes', 0.0),
                                    ('mixed', 'caller_pending', False), ('mixed', 'caller_pending', 0.0),
                                    ('teardown', 'connections', True), ('teardown', 'connections', 1.0),
                                    ('teardown', 'channels', 3.0), ('channel', 'maxPacketLifeTime', True),
                                    ('channel', 'maxPacketLifeTime', 1.0), ('channel', 'id', 3.0), ('room', 'players', 2.0),
                                    ('teardown', 'websockets_created', 0), ('teardown', 'websockets_created', True),
                                    ('teardown', 'websockets_created', 1.0), ('teardown', 'websockets_created', None),
                                    ('teardown', 'websockets', 0), ('teardown', 'websockets', True),
                                    ('teardown', 'websockets', 1.0), ('teardown', 'websockets', None)]:
            with self.subTest(section=section, key=key):
                changed = copy.deepcopy(result)
                peer = changed['records'][0]['peers'][0]
                target = peer['rtc'] if section == 'rtc' else peer['result']['records'][0]
                if section == 'mixed':
                    target = target['mixed']
                elif section == 'teardown':
                    target = peer['rtc']['teardown']
                elif section == 'channel':
                    target = peer['rtc']['channels'][2]
                elif section == 'room':
                    target = changed['records'][0]
                target[key] = value
                with self.assertRaises(ValueError):
                    validate_pressure(changed, ENGINE)
        for mutation, diagnostic in [('missing_receipt', 'missing physical send or addressed receipt'),
                                     ('missing_send', 'inventory incomplete'), ('wrong_wire', 'missing physical send or addressed receipt'),
                                     ('prior_send', 'first physical send missing'),
                                     ('wrong_turn', 'retry turn'), ('reordered_retries', 'retry turn'), ('wrong_socket_read', 'socket read'),
                                     ('wrong_recipient', 'retry address'), ('wrong_session', 'retry address'), ('wrong_sample', 'original input bytes'),
                                     ('wrong_connection', 'header or identity')]:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(result)
                sender, receiver = changed['records'][0]['peers']
                sent = sender['rtc']['recordingRelaySends']
                retries = sender['result']['records'][0]['mixed']['retried_inputs']
                received = receiver['result']['records'][0]['mixed']['received_inputs']
                if mutation == 'missing_receipt':
                    received.pop(0)
                elif mutation == 'missing_send':
                    sender['rtc'].pop('recordingRelaySends')
                elif mutation == 'prior_send':
                    sent[0]['first'] = False
                elif mutation == 'wrong_wire':
                    sent[0]['wire'] = retries[1]['envelope']
                elif mutation == 'wrong_turn':
                    retries[0]['refused_turn'] = retries[0]['retry_turn']
                elif mutation == 'reordered_retries':
                    retries.reverse()
                elif mutation == 'wrong_socket_read':
                    retries[1]['blocked_read'] = retries[0]['blocked_read']
                else:
                    envelope = bytearray.fromhex(retries[0]['envelope'])
                    offset = {'wrong_recipient': 37, 'wrong_session': 5, 'wrong_sample': -1, 'wrong_connection': 89}[mutation]
                    envelope[offset] ^= 1
                    sent[0]['wire'] = received[0] = retries[0]['envelope'] = envelope.hex()
                with self.assertRaisesRegex(ValueError, diagnostic):
                    validate_pressure(changed, ENGINE)
        changed = copy.deepcopy(result)
        changed['records'][0]['peers'][0]['rtc']['teardown'].update(websockets_created=2, websockets=2)
        with self.assertRaisesRegex(ValueError, 'expected one WebSocket'):
            validate_pressure(changed, ENGINE)
        changed = copy.deepcopy(result)
        changed['records'][0]['peers'][0]['result']['records'][0]['recording'] = recording(2)
        with self.assertRaisesRegex(ValueError, 'recovery-only'):
            validate_pressure(changed, ENGINE)
        self.assertEqual(validate_recording(recording(2, 257), 2, ENGINE, frames=257), 257)


if __name__ == '__main__':
    unittest.main()
