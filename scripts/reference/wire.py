"""Validate scheduled WebRTC input packets against original samples and the shipped codec version."""
import hashlib
from pathlib import Path
import re
import struct

_CODEC = Path(__file__).resolve().parents[2] / 'addons/fortress_rollback/protocol/protocol_codec.gd'
VERSION = int(re.search(r'^const VERSION: int = (\d+)$', _CODEC.read_text(encoding='utf-8'), re.M).group(1))
INPUT_KIND = 3
INPUT_HEADER = b'FRGP' + struct.pack('<HBB', VERSION, INPUT_KIND, 0)


def original_sample(frame, slot, neutral=False):
    return 0 if neutral else (frame * 17 + slot * 31 + 1) & 255


def validate_original_input(raw, count, sender, slot, source_index, match_frames, window, label, neutral=False):
    size_offset = 57 + 7 * count
    if (len(raw) < size_offset + 5 or raw[:8] != INPUT_HEADER
            or int.from_bytes(raw[40:44], 'little') != len(raw) - 44
            or raw[8:24] != bytes([count]) * 16 or raw[24:32] != hashlib.sha256(sender.encode('ascii')).digest()[:8]
            or raw[32:40] != (source_index + 1).to_bytes(8, 'little')):
        raise ValueError(f'{label} protocol header or identity invalid')
    start = int.from_bytes(raw[44:48], 'little', signed=True)
    ack = int.from_bytes(raw[48:52], 'little', signed=True)
    frames = int.from_bytes(raw[52:54], 'little')
    if (start < window[0] or frames < 1 or start + frames > window[1] or not -1 <= ack < match_frames or raw[54:57] != bytes([1, slot, count])
            or len(raw) != size_offset + 4 + frames or int.from_bytes(raw[size_offset:size_offset + 4], 'little') != frames):
        raise ValueError(f'{label} protocol input layout invalid')
    for index in range(count):
        status = raw[57 + 7 * index:64 + 7 * index]
        if status[0] != 0 or status[5:7] != b'\x00\x00' or not -1 <= int.from_bytes(status[1:5], 'little', signed=True) < match_frames:
            raise ValueError(f'{label} protocol status invalid')
    expected = bytes(original_sample(frame, slot, neutral) for frame in range(start, start + frames))
    if raw[size_offset + 4:] != expected:
        raise ValueError(f'{label} original input bytes changed')
    return start


def decode_relay_carrier(raw):
    """Read the pinned v3 Server GameData map and its nonzero delivery stamp."""
    cursor = 0

    def take(size):
        nonlocal cursor
        end = cursor + size
        if end > len(raw):
            raise ValueError('truncated relay carrier')
        value = raw[cursor:end]
        cursor = end
        return value

    def number(size=1):
        return int.from_bytes(take(size), 'big')

    def text():
        marker = number()
        if not 0xa0 <= marker <= 0xbf:
            raise ValueError('invalid relay carrier text')
        return take(marker - 0xa0)

    def binary():
        marker = number()
        if not 0xc4 <= marker <= 0xc6:
            raise ValueError('invalid relay carrier binary field')
        return take(number(1 << (marker - 0xc4)))

    def unsigned():
        marker = number()
        if marker <= 0x7f:
            return marker
        if not 0xcc <= marker <= 0xcf:
            raise ValueError('invalid relay carrier integer')
        return number(1 << (marker - 0xcc))

    marker = number()
    if marker == 1:
        marker = number()
    if marker != 0x85:
        raise ValueError('invalid relay carrier map')
    readers = {b'from_player': binary, b'encoding': text, b'payload': binary, b'epoch': unsigned, b'seq': unsigned}
    fields = {}
    for _ in range(len(readers)):
        key = text()
        if key not in readers or key in fields:
            raise ValueError('invalid relay carrier fields')
        fields[key] = readers[key]()
    sender, payload, epoch, seq = (fields[key] for key in (b'from_player', b'payload', b'epoch', b'seq'))
    if (cursor != len(raw) or len(sender) != 16 or fields[b'encoding'] != b'message_pack'
            or not 1 <= epoch <= 0xffffffff or not 1 <= seq <= 0xffffffffffffffff):
        raise ValueError('invalid relay carrier sender, encoding or delivery stamp')
    return sender.hex(), payload.hex(), epoch, seq
