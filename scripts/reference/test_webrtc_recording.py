"""Value: bind mixed-path recordings to original inputs and decoded canonical playback."""
import copy
import hashlib
import struct
import unittest

from browser.webrtc_recording import engine_identity, validate_recording


ENGINE = 'test-engine'


def recording(count):
    raw = bytearray(b'FRRP' + struct.pack('<HBIIIHBB', 6, count, 1, 40, 0, 0, 8, 0) + b'\0')
    for text in (ENGINE, '0.1.0', 'fortress-rollback d124c89080004d96971a629bb0427056ee1805e3', '0', 'fortress-webrtc-integer-v1'):
        encoded = text.encode('ascii')
        raw += bytes([len(encoded)]) + encoded
    values = [0] * count
    for frame in range(40):
        state = struct.pack('<' + 'I' * (count + 1), frame, *values)
        samples = bytes((frame * 17 + slot * 31 + 1) & 255 for slot in range(count))
        row = samples + bytes([1] * count)
        raw += row + b'\1' + hashlib.sha256(state).digest()[:16] + hashlib.sha256(row).digest()[:16]
        values = [(value * 33 + sample) & 0xffffffff for value, sample in zip(values, samples)]
    final = struct.pack('<' + 'I' * (count + 1), 40, *values)
    raw += hashlib.sha256(final).digest()[:16]
    return {'hex': raw.hex(), 'before_frame': 40, 'after_frame': 40, 'recover_code': 0, 'capture_code': 0,
            'decode_code': 0, 'playback_code': 16, 'playback_frame': 40, 'failure_frame': -1,
            'canonical': final.hex(), 'checked_checksums': 41}


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


if __name__ == '__main__':
    unittest.main()
