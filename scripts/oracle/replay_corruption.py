"""Execute serialized post-wrap corruption through actual remote-recording decode and playback."""
import copy
import hashlib
import json
import struct
import tempfile
from pathlib import Path

from replay_launch import REVISION, compare


FRAME = 129


def validate(actual, healthy, fault, engine_metadata):
    """A single encoded-byte change must stop playback at its owning boundary."""
    actual = copy.deepcopy(actual)
    encoded = actual.pop('serialized_control', None)
    if type(encoded) is not dict or encoded.keys() != {'before', 'after'}:
        raise ValueError('serialized.control: missing byte evidence')
    try:
        before, after = (bytes.fromhex(encoded[key]) for key in ('before', 'after'))
    except (ValueError, TypeError) as error:
        raise ValueError('serialized.control: invalid byte evidence') from error
    if fault not in ('input', 'checksum'):
        raise ValueError('serialized.control: unknown fault')
    header = b'FRRP' + struct.pack('<HBIIIHBB', 5, 2, 4, 257, 0, 0, 4, 0) + b'\0' * 4
    metadata = (engine_metadata, '0.1.0', 'fortress-rollback ' + REVISION, '', '')
    for text in metadata:
        value = text.encode('ascii')
        header += bytes([len(value)]) + value
    original = bytearray(header)
    peer = healthy['peers'][1]
    for frame in range(257):
        row = struct.pack('<II', *peer['frames'][frame])
        checksum = bytes.fromhex(peer['checksums'][frame])
        original += row + b'\1\1\1' + checksum + hashlib.sha256(row + b'\1\1').digest()[:16]
    compare(before, bytes(original), 'serialized.control.original_file')
    target = len(header) + FRAME * 43 + (11 if fault == 'checksum' else 0)
    changed = bytearray(before)
    changed[target] ^= 1
    compare(after, bytes(changed), 'serialized.control.exact_mutation')
    wanted = copy.deepcopy(healthy)
    peer = wanted['peers'][1]
    playback = peer['playback']
    if fault == 'input':
        peer['frames'][FRAME][0] ^= 1
    elif fault == 'checksum':
        checksum = bytearray.fromhex(peer['checksums'][FRAME])
        checksum[0] ^= 1
        peer['checksums'][FRAME] = checksum.hex()
    else:
        raise ValueError('serialized.control: unknown fault')
    playback['records'] = [record for record in playback['records']
                           if record['frame'] < FRAME or (fault == 'checksum' and record['frame'] == FRAME and record['kind'] == 'save')]
    boundary = next(record['bytes'] for record in healthy['peers'][1]['playback']['records']
                    if record['kind'] == 'save' and record['frame'] == FRAME)
    playback.update(current_frame=FRAME, complete=False, code=18, failure_frame=FRAME, bytes=boundary)
    compare(actual, wanted, 'serialized.observed')


def observe(engine, root, output, execute, healthy):
    """The unchanged asymmetric workload is the green control; copied observers alter actual encoded bytes."""
    original = (root / 'tests/oracle/replay_remote_trace.gd').read_text()
    needle = '\t\tif decoded.decode(recording.to_bytes()) != Replay.DecodeCode.OK or decoded.to_bytes() != recording.to_bytes():'
    result_needle = '\tprint("FORTRESS_REPLAY_RESULT " + JSON.stringify(result))'
    if original.count(needle) != 1 or original.count(result_needle) != 1:
        raise ValueError('serialized control decode boundary missing or ambiguous')
    names = []
    scratch_root = root / '.cache/scratch'
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='replay-serialized-control-', dir=scratch_root) as directory:
        metadata_script = Path(directory) / 'metadata.gd'
        metadata_script.write_text('extends SceneTree\nfunc _initialize() -> void:\n'
                                   '\tprint("FORTRESS_REPLAY_ENGINE " + JSON.stringify(Engine.get_version_info()))\n\tquit(0)\n')
        command = [str(engine), '--headless', '--path', str(root), '--script', 'res://' + metadata_script.relative_to(root).as_posix()]
        stdout, stderr = execute(command, output / 'asymmetric-serialized-engine-godot.log')
        lines = [line.removeprefix('FORTRESS_REPLAY_ENGINE ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_ENGINE ')]
        if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('invalid serialized control engine observation')
        info = json.loads(lines[0])
        engine_metadata = '%d.%d.%d.%s %s' % (info['major'], info['minor'], info['patch'], info['status'], info['hash'])
        for fault in ('input', 'checksum'):
            injection = '''\t\tvar encoded: PackedByteArray = recording.to_bytes()
\t\tif peer == 1:
\t\t\tvar before: PackedByteArray = encoded.duplicate()
\t\t\tvar cursor: int = 23 + 4
\t\t\tfor field: int in 5:
\t\t\t\tcursor += 1 + encoded[cursor]
\t\t\tcursor += 129 * 43 + %d
\t\t\tencoded[cursor] ^= 1
\t\t\tserialized_control = {"before": before.hex_encode(), "after": encoded.hex_encode()}
\t\tif decoded.decode(encoded) != Replay.DecodeCode.OK or decoded.to_bytes() != encoded:''' % (11 if fault == 'checksum' else 0)
            altered = original.replace('var deliveries: Array[Dictionary] = []',
                                       'var deliveries: Array[Dictionary] = []\n\tvar serialized_control: Dictionary = {}')
            altered = altered.replace(needle, injection).replace(result_needle, '\tresult.serialized_control = serialized_control\n' + result_needle)
            script = Path(directory) / (fault + '.gd')
            script.write_text(altered)
            command = [str(engine), '--headless', '--path', str(root), '--script', 'res://' + script.relative_to(root).as_posix(),
                       '--', '--remote-recording-asymmetric']
            stdout, stderr = execute(command, output / f'asymmetric-serialized-{fault}-godot.log')
            lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
            if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                raise ValueError('invalid serialized corruption control completion')
            actual = json.loads(lines[0])
            validate(actual, healthy, fault, engine_metadata)
            try:
                compare({key: value for key, value in actual.items() if key != 'serialized_control'}, healthy, 'asymmetric.godot')
            except ValueError as error:
                field = 'frames[129][0]' if fault == 'input' else 'checksums[129]'
                if not str(error).startswith(f'asymmetric.godot.peers[1].{field}:'):
                    raise ValueError(f'wrong serialized {fault} rejection: {error}') from error
            else:
                raise ValueError(f'serialized {fault} corruption accepted')
            names.append('godot-serialized-post-wrap-' + fault)
    return names
