"""Godot wire header bytes, read from the shipped codec so probes track its layout version."""
from pathlib import Path
import re
import struct

_CODEC = Path(__file__).resolve().parents[2] / 'addons/fortress_rollback/protocol/protocol_codec.gd'
VERSION = int(re.search(r'^const VERSION: int = (\d+)$', _CODEC.read_text(encoding='utf-8'), re.M).group(1))
INPUT_KIND = 3
INPUT_HEADER = b'FRGP' + struct.pack('<HBB', VERSION, INPUT_KIND, 0)
