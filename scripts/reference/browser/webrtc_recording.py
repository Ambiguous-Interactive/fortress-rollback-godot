"""Compare real mixed-path recordings with the independently declared original game."""
import hashlib
import re
import struct

from wire import original_sample, validate_original_input


MAX_BYTES = 65536


def engine_identity(output, version, cli_version):
    identities = [line.removeprefix('WEBRTC_ENGINE_IDENTITY ') for line in output.splitlines() if line.startswith('WEBRTC_ENGINE_IDENTITY ')]
    expected = '.'.join((version.split('.') + ['0'])[:3]) + '.stable '
    if (len(identities) != 1 or not re.fullmatch(re.escape(expected) + r'[0-9a-f]{40}', identities[0])
            or not identities[0].split()[-1].startswith(cli_version.rsplit('.', 1)[-1])):
        raise ValueError('mixed recording native engine identity missing or differs from the pinned engine')
    return identities[0]


def validate_recording(value, count, expected_engine=None, frames=40, neutral=False):
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
        samples = bytes(original_sample(frame, slot, neutral) for slot in range(count))
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


def _addressed_payload(envelope, sender, recipient, label):
    if type(envelope) is not str or not re.fullmatch(r'(?:[0-9a-f]{2}){133,1081}', envelope):
        raise ValueError(f'{label} envelope invalid')
    data = bytes.fromhex(envelope)
    if (data[:21] != b'FSR1\x01' + bytes([2]) * 16 or data[21:37].hex() != sender.replace('-', '')
            or data[37:53].hex() != recipient.replace('-', '') or struct.unpack_from('<I', data, 53)[0] != len(data) - 57):
        raise ValueError(f'{label} address invalid')
    return data[57:]


def _validate_recording_tail(source, row, sender, recipient, slot, source_index, neutral):
    tail = row.get('recording_tail')
    if type(tail) is not dict or any(type(tail.get(key)) is not dict for key in ('held', 'receipt', 'after')):
        raise ValueError('recording pressure final receipt inventory incomplete')
    held, receipt, after = (tail[key] for key in ('held', 'receipt', 'after'))
    if (any(type(value) is not int for value in (held.get('frame'), held.get('received_frame'), held.get('turn'), held.get('loads')))
            or held['frame'] != 257 or held['received_frame'] != 255 or held['turn'] < 1 or held['loads'] < int(not neutral)):
        raise ValueError('recording pressure final input was not held at boundary 257')
    if (type(receipt.get('frame')) is not int or receipt['frame'] != 257 or type(receipt.get('turn')) is not int
            or receipt['turn'] < held['turn'] or receipt.get('stage') not in ('final_confirmation', 'recording_confirmation')):
        raise ValueError('recording pressure final addressed receipt missing after the hold')
    envelope = receipt.get('envelope')
    payload = _addressed_payload(envelope, sender, recipient, 'recording pressure final addressed receipt')
    start = validate_original_input(payload, 2, sender, slot, source_index, 257, (129, 257), 'recording pressure final receipt', neutral)
    if start + struct.unpack_from('<H', payload, 52)[0] != 257 or envelope not in row['mixed']['received_inputs']:
        raise ValueError('recording pressure final addressed receipt lacks original input 256')
    physical = source['rtc'].get('recordingFinalRelaySend')
    source_hold = source['result']['records'][0].get('recording_tail', {})
    source_held_turn = source_hold.get('held', {}).get('turn') if type(source_hold) is dict and type(source_hold.get('held')) is dict else None
    if (type(physical) is not dict or physical.get('wire') != envelope or physical.get('released') is not True
            or type(physical.get('turn')) is not int or type(source_held_turn) is not int or physical['turn'] <= source_held_turn):
        raise ValueError('recording pressure final addressed receipt missing matching physical send')
    wanted = {'frame': 257, 'received_frame': 256, 'confirmed_frame': 256, 'loads': held['loads'] + int(not neutral)}
    if any(type(after.get(key)) is not int or after[key] != value for key, value in wanted.items()) or after['loads'] != row['rollback_loads']:
        raise ValueError('recording pressure final recovery did not correct input 256 at boundary 257')


def _validate_pressure_routes(peers, identities, neutral):
    for index, (sender, recipient) in enumerate((identities, identities[::-1])):
        source, destination = peers[index], peers[1 - index]
        sent, retried = source['rtc'].get('recordingRelaySends'), source['result']['records'][0]['mixed'].get('retried_inputs')
        destination_row = destination['result']['records'][0]
        receipt = destination_row['mixed']
        received = receipt.get('received_inputs')
        if (type(sent) is not list or len(sent) != 2 or type(retried) is not list or len(retried) != 2
                or type(received) is not list or len(received) > min(512, receipt['accepted_binary'])
                or any(type(item) is not str or not re.fullmatch(r'(?:[0-9a-f]{2}){133,1081}', item) for item in received)
                or len(set(received)) != len(received)):
            raise ValueError('recording pressure attributed retry inventory incomplete')
        period = 5 + index
        slot = sorted(identities).index(sender)
        last_retry, last_read, starts = 0, 0, set()
        for retry, physical in zip(retried, sent):
            if type(retry) is not dict or type(physical) is not dict:
                raise ValueError('recording pressure attributed retry entry invalid')
            refused_turn, retry_turn, frame, start, read = (retry.get(key) for key in ('refused_turn', 'retry_turn', 'frame', 'start_frame', 'blocked_read'))
            if (any(type(value) is not int for value in (refused_turn, retry_turn, frame, start, read, physical.get('turn')))
                    or not 130 <= frame <= 253 or last_retry >= refused_turn or refused_turn % period == 0
                    or retry_turn != refused_turn + period - refused_turn % period or physical['turn'] != retry_turn):
                raise ValueError('recording pressure attributed retry turn invalid')
            if not last_read < read <= source['rtc']['relayPostWrapBlockedReads']:
                raise ValueError('recording pressure attributed retry socket read invalid')
            envelope = retry.get('envelope')
            payload = _addressed_payload(envelope, sender, recipient, 'recording pressure attributed retry')
            if validate_original_input(payload, 2, sender, slot, index, 257, (129, frame), 'recording pressure', neutral) != start or start in starts:
                raise ValueError('recording pressure attributed retry original range invalid')
            if physical.get('first') is not True:
                raise ValueError('recording pressure attributed retry first physical send missing')
            if physical.get('wire') != envelope or envelope not in received:
                raise ValueError('recording pressure attributed retry missing physical send or addressed receipt')
            starts.add(start)
            last_retry, last_read = retry_turn, read
        _validate_recording_tail(source, destination_row, sender, recipient, slot, index, neutral)


def validate_pressure_teardown(rtc):
    teardown = rtc.get('teardown')
    if type(teardown) is not dict or type(teardown.get('websockets_created')) is not int or teardown['websockets_created'] != 1:
        raise ValueError('recording pressure expected one WebSocket per endpoint')
    if (type(teardown.get('channels')) is not int or teardown['channels'] != 3 or type(teardown.get('connections_created')) is not int
            or teardown['connections_created'] < 1 or type(teardown.get('connections')) is not int
            or teardown['connections'] != teardown['connections_created']
            or type(teardown.get('websockets')) is not int or teardown['websockets'] != 1):
        raise ValueError('recording pressure browser resources survived teardown')


def validate_pressure(result, expected_engine=None, neutral=False):
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
        for key, minimum in [('minimum_confirmed', 255), ('active_comparisons', 254), ('rollback_loads', int(not neutral))]:
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
        if (rtc.get('captureError') is not False or type(witness.get('binary_receives')) is not int or witness['binary_receives'] < state['accepted_binary']
                or type(rtc.get('binarySent')) is not int or rtc['binarySent'] < 2):
            raise ValueError('recording pressure physical binary transport missing')
        for key in ('relayBlockedReads', 'relayPostWrapBlockedReads'):
            if type(rtc.get(key)) is not int or rtc[key] < 2:
                raise ValueError('recording pressure physical socket refusal control missing')
        validate_pressure_teardown(rtc)
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
        if neutral and row['rollback_loads'] != 0:
            raise ValueError('neutral recording performed a rollback')
        validate_recording(row.get('recording'), 2, expected_engine, frames=257, neutral=neutral)
    if len(set(identities)) != 2:
        raise ValueError('recording pressure endpoints share an identity')
    _validate_pressure_routes(peers, identities, neutral)
    return result
