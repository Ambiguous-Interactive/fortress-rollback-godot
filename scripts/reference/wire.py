"""Validate scheduled WebRTC input packets against original samples and the shipped codec version."""
import hashlib
from pathlib import Path
import re
import struct

_CODEC = Path(__file__).resolve().parents[2] / 'addons/fortress_rollback/protocol/protocol_codec.gd'
VERSION = int(re.search(r'^const VERSION: int = (\d+)$', _CODEC.read_text(encoding='utf-8'), re.M).group(1))
INPUT_KIND = 3
INPUT_HEADER = b'FRGP' + struct.pack('<HBB', VERSION, INPUT_KIND, 0)


def validate_original_input(raw, count, sender, slot, source_index, match_frames, window, label):
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
    expected = bytes((frame * 17 + slot * 31 + 1) & 255 for frame in range(start, start + frames))
    if raw[size_offset + 4:] != expected:
        raise ValueError(f'{label} original input bytes changed')
    return start
