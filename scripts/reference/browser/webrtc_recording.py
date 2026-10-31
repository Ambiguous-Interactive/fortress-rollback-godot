"""Compare real mixed-path recordings with the independently declared original game."""
import hashlib
import re
import struct


MAX_BYTES = 65536


def engine_identity(output, version, cli_version):
    identities = [line.removeprefix('WEBRTC_ENGINE_IDENTITY ') for line in output.splitlines() if line.startswith('WEBRTC_ENGINE_IDENTITY ')]
    expected = '.'.join((version.split('.') + ['0'])[:3]) + '.stable '
    if (len(identities) != 1 or not re.fullmatch(re.escape(expected) + r'[0-9a-f]{40}', identities[0])
            or not identities[0].split()[-1].startswith(cli_version.rsplit('.', 1)[-1])):
        raise ValueError('mixed recording native engine identity missing or differs from the pinned engine')
    return identities[0]


def validate_recording(value, count, expected_engine=None):
    if (type(value) is not dict or type(value.get('hex')) is not str
            or not re.fullmatch(r'(?:[0-9a-f]{2}){24,' + str(MAX_BYTES) + '}', value['hex'])):
        raise ValueError('mixed recording missing or exceeds its byte bound')
    expected = {'before_frame': 40, 'after_frame': 40, 'recover_code': 0, 'capture_code': 0,
                'decode_code': 0, 'playback_code': 16, 'playback_frame': 40, 'failure_frame': -1, 'checked_checksums': 41}
    if any(type(value.get(key)) is not int or value[key] != wanted for key, wanted in expected.items()):
        raise ValueError('mixed recording lacks recovery-only capture or complete decoded playback')
    raw = bytes.fromhex(value['hex'])
    if (count not in (2, 4, 8) or raw[:4] != b'FRRP'
            or struct.unpack_from('<HBIIIHBB', raw, 4) != (6, count, 1, 40, 0, 0, 8, 0) or raw[23] != 0):
        raise ValueError('mixed recording configuration differs from the actual match')
    cursor, texts = 24, []
    for _ in range(5):
        size = raw[cursor] if cursor < len(raw) else 129
        field = raw[cursor + 1:cursor + 1 + size]
        if size > 128 or len(field) != size or any(byte < 0x20 or byte > 0x7e for byte in field):
            raise ValueError('mixed recording metadata malformed')
        texts.append(field.decode('ascii'))
        cursor += 1 + size
    if (not texts[0] or (expected_engine is not None and texts[0] != expected_engine)
            or texts[1:] != ['0.1.0', 'fortress-rollback d124c89080004d96971a629bb0427056ee1805e3', '0', 'fortress-webrtc-integer-v1']):
        raise ValueError('mixed recording metadata differs from the executed game or engine')
    values = [0] * count
    for frame in range(40):
        samples = bytes((frame * 17 + slot * 31 + 1) & 255 for slot in range(count))
        if raw[cursor:cursor + count] != samples:
            raise ValueError(f'mixed recording original input mismatch at frame {frame}')
        if raw[cursor + count:cursor + 2 * count] != bytes([1] * count):
            raise ValueError(f'mixed recording finalized status mismatch at frame {frame}')
        row = samples + bytes([1] * count)
        cursor += 2 * count
        if raw[cursor:cursor + 1] != b'\1':
            raise ValueError(f'mixed recording checksum flag mismatch at frame {frame}')
        cursor += 1
        state = struct.pack('<' + 'I' * (count + 1), frame, *values)
        if raw[cursor:cursor + 16] != hashlib.sha256(state).digest()[:16]:
            raise ValueError(f'mixed recording state checksum mismatch at frame {frame}')
        cursor += 16
        if raw[cursor:cursor + 16] != hashlib.sha256(row).digest()[:16]:
            raise ValueError(f'mixed recording input digest mismatch at frame {frame}')
        cursor += 16
        values = [(value * 33 + sample) & 0xffffffff for value, sample in zip(values, samples)]
    final = struct.pack('<' + 'I' * (count + 1), 40, *values)
    if raw[cursor:cursor + 16] != hashlib.sha256(final).digest()[:16]:
        raise ValueError('mixed recording terminal checksum mismatch')
    if cursor + 16 != len(raw):
        raise ValueError('mixed recording has trailing bytes')
    if value.get('canonical') != final.hex():
        raise ValueError('mixed recording decoded playback lost the original final canonical state')
    return 40
