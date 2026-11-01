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


def validate_recording(value, count, expected_engine=None, frames=40):
    if (type(value) is not dict or type(value.get('hex')) is not str
            or not re.fullmatch(r'(?:[0-9a-f]{2}){24,' + str(MAX_BYTES) + '}', value['hex'])):
        raise ValueError('mixed recording missing or exceeds its byte bound')
    expected = {'before_frame': frames, 'after_frame': frames, 'recover_code': 0, 'capture_code': 0,
                'decode_code': 0, 'playback_code': 16, 'playback_frame': frames, 'failure_frame': -1, 'checked_checksums': frames + 1}
    if any(type(value.get(key)) is not int or value[key] != wanted for key, wanted in expected.items()):
        raise ValueError('mixed recording lacks recovery-only capture or complete decoded playback')
    raw = bytes.fromhex(value['hex'])
    if (count not in (2, 4, 8) or raw[:4] != b'FRRP'
            or struct.unpack_from('<HBIIIHBB', raw, 4) != (6, count, 1, frames, 0, 0, 8, 0) or raw[23] != 0):
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
    for frame in range(frames):
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
    final = struct.pack('<' + 'I' * (count + 1), frames, *values)
    if raw[cursor:cursor + 16] != hashlib.sha256(final).digest()[:16]:
        raise ValueError('mixed recording terminal checksum mismatch')
    if cursor + 16 != len(raw):
        raise ValueError('mixed recording has trailing bytes')
    if value.get('canonical') != final.hex():
        raise ValueError('mixed recording decoded playback lost the original final canonical state')
    return frames


def validate_pressure(result, expected_engine=None):
    """Require actual socket receipt, repeated post-wrap refusal and original decoded history."""
    if (type(result) is not dict or result.get('passed') is not True or result.get('recordingPressure') is not True
            or result.get('mixed') is not True or result.get('faults') is not False or result.get('corrupt') is not False
            or result.get('errors') != [] or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2):
        raise ValueError('recording pressure browser execution incomplete')
    records = result.get('records')
    if type(records) is not list or len(records) != 1 or type(records[0].get('players')) is not int or records[0]['players'] != 2:
        raise ValueError('recording pressure room inventory incomplete')
    peers = records[0].get('peers')
    if type(peers) is not list or len(peers) != 2:
        raise ValueError('recording pressure peer inventory incomplete')
    identities = []
    for peer in peers:
        witness, rtc = peer.get('result', {}), peer.get('rtc', {})
        rows = witness.get('records')
        if witness.get('passed') is not True or type(rows) is not list or len(rows) != 1:
            raise ValueError('recording pressure gameplay missing')
        row = rows[0]
        for key, wanted in [('players', 2), ('frames_submitted', 257), ('canonical_comparisons', 255)]:
            if type(row.get(key)) is not int or row[key] != wanted:
                raise ValueError('recording pressure original canonical inventory incomplete')
        for key, minimum in [('minimum_confirmed', 255), ('active_comparisons', 254), ('rollback_loads', 1)]:
            if type(row.get(key)) is not int or row[key] < minimum:
                raise ValueError('recording pressure original active history unverified')
        state = row.get('mixed', {})
        uuid = state.get('uuid')
        if type(uuid) is not str or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', uuid):
            raise ValueError('recording pressure sender identity invalid')
        identities.append(uuid)
        for key in ('pressure_refusals', 'pressure_post_wrap_refusals', 'pressure_retries', 'accepted_binary'):
            if type(state.get(key)) is not int or state[key] < 2:
                raise ValueError('recording pressure repeated exact-byte retries or addressed receipts missing')
        if any(type(state.get(key)) is not int or state[key] != 0 for key in ('refused_head_bytes', 'caller_pending')):
            raise ValueError('recording pressure refused head survived final recovery')
        for key in ('maximum_pending', 'maximum_relay_pending', 'maximum_relay_received'):
            if type(state.get(key)) is not int or not 0 <= state[key] <= 128:
                raise ValueError('recording pressure owned queue exceeded its bound')
        if (type(witness.get('binary_receives')) is not int or witness['binary_receives'] < state['accepted_binary']
                or type(rtc.get('binarySent')) is not int or rtc['binarySent'] < 2):
            raise ValueError('recording pressure physical binary transport missing')
        for key in ('relayBlockedReads', 'relayPostWrapBlockedReads'):
            if type(rtc.get(key)) is not int or rtc[key] < 2:
                raise ValueError('recording pressure physical socket refusal control missing')
        teardown = rtc.get('teardown', {})
        if (type(teardown.get('channels')) is not int or teardown['channels'] != 3 or type(teardown.get('connections_created')) is not int
                or teardown['connections_created'] < 1 or type(teardown.get('connections')) is not int
                or teardown['connections'] != teardown['connections_created']
                or type(teardown.get('websockets_created')) is not int or teardown['websockets_created'] < 1
                or type(teardown.get('websockets')) is not int or teardown['websockets'] != teardown['websockets_created']):
            raise ValueError('recording pressure browser resources survived teardown')
        channels = rtc.get('channels')
        if (type(channels) is not list or len(channels) != 3 or any(type(channel.get('id')) is not int for channel in channels)
                or sorted(channel['id'] for channel in channels) != [1, 2, 3]):
            raise ValueError('recording pressure direct channel inventory incomplete')
        channel = next(channel for channel in channels if channel['id'] == 3)
        if (channel.get('blockedLink') is not True or type(channel.get('blockedReads')) is not int or channel['blockedReads'] < 2
                or channel.get('ordered') is not False or channel.get('negotiated') is not True
                or type(channel.get('maxPacketLifeTime')) is not int or channel['maxPacketLifeTime'] != 1
                or channel.get('maxRetransmits') is not None or type(channel.get('sent')) is not int or channel['sent'] < 1
                or type(channel.get('received')) is not int or channel['received'] < 1):
            raise ValueError('recording pressure direct send refusal or original delivery missing')
        validate_recording(row.get('recording'), 2, expected_engine, frames=257)
    if len(set(identities)) != 2:
        raise ValueError('recording pressure endpoints share an identity')
    return result
