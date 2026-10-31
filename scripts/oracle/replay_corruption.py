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
    fields = {'before', 'after', 'statuses'} if fault == 'status' else {'before', 'after'}
    if type(encoded) is not dict or encoded.keys() != fields:
        raise ValueError('serialized.control: missing byte evidence')
    try:
        before, after = (bytes.fromhex(encoded[key]) for key in ('before', 'after'))
    except (ValueError, TypeError) as error:
        raise ValueError('serialized.control: invalid byte evidence') from error
    if fault not in ('input', 'checksum', 'status', 'terminal'):
        raise ValueError('serialized.control: unknown fault')
    header = b'FRRP' + struct.pack('<HBIIIHBB', 6 if fault == 'terminal' else 5, 2, 4, 257, 0, 0, 4, 0) + b'\0' * 4
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
    if fault == 'terminal':
        original += bytes.fromhex(peer['terminal_checksum'])
    compare(before, bytes(original), 'serialized.control.original_file')
    target = len(before) - 16 if fault == 'terminal' else len(header) + FRAME * 43 + {'input': 0, 'checksum': 11, 'status': 8}[fault]
    changed = bytearray(before)
    changed[target] ^= 2 if fault == 'status' else 1
    compare(after, bytes(changed), 'serialized.control.exact_mutation')
    if fault == 'status':
        statuses = [[1, 1] for _ in range(257)]
        statuses[FRAME][0] = 3
        compare(encoded['statuses'], statuses, 'serialized.control.decoded_statuses')
    wanted = copy.deepcopy(healthy)
    peer = wanted['peers'][1]
    playback = peer['playback']
    if fault == 'input':
        peer['frames'][FRAME][0] ^= 1
    elif fault == 'checksum':
        checksum = bytearray.fromhex(peer['checksums'][FRAME])
        checksum[0] ^= 1
        peer['checksums'][FRAME] = checksum.hex()
    if fault == 'terminal':
        checksum = bytearray.fromhex(peer['terminal_checksum'])
        checksum[0] ^= 1
        peer['terminal_checksum'] = checksum.hex()
        playback.update(complete=False, code=18, failure_frame=257)
        compare(actual, wanted, 'serialized.observed')
        return
    playback['records'] = [record for record in playback['records']
                           if record['frame'] < FRAME or (fault == 'checksum' and record['frame'] == FRAME and record['kind'] == 'save')]
    boundary = next(record['bytes'] for record in healthy['peers'][1]['playback']['records']
                    if record['kind'] == 'save' and record['frame'] == FRAME)
    playback.update(current_frame=FRAME, complete=False, code=18, failure_frame=FRAME, bytes=boundary)
    compare(actual, wanted, 'serialized.observed')


def observe(engine, root, output, execute, healthy, terminal=False):
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
        for fault in (('terminal',) if terminal else ('input', 'checksum', 'status')):
            injection = '''\t\tvar encoded: PackedByteArray = recording.to_bytes()
\t\tif peer == 1:
\t\t\tvar before: PackedByteArray = encoded.duplicate()
\t\t\tvar cursor: int = 23 + 4
\t\t\tfor field: int in 5:
\t\t\t\tcursor += 1 + encoded[cursor]
\t\t\tcursor += 129 * 43 + %d
\t\t\tencoded[cursor] ^= %d
\t\t\tserialized_control = {"before": before.hex_encode(), "after": encoded.hex_encode()}
\t\tif decoded.decode(encoded) != Replay.DecodeCode.OK or decoded.to_bytes() != encoded:''' % (
                {'input': 0, 'checksum': 11, 'status': 8, 'terminal': 0}[fault], 2 if fault == 'status' else 1)
            if terminal:
                injection = injection.replace('cursor += 129 * 43 + 0', 'cursor = encoded.size() - 16')
            altered = original.replace('var deliveries: Array[Dictionary] = []',
                                       'var deliveries: Array[Dictionary] = []\n\tvar serialized_control: Dictionary = {}')
            altered = altered.replace(needle, injection).replace(result_needle, '\tresult.serialized_control = serialized_control\n' + result_needle)
            if fault == 'status':
                status_guard = '\t\t\t\tif input.status != Queue.Status.CONFIRMED:'
                if original.count(status_guard) != 1:
                    raise ValueError('serialized control status boundary missing or ambiguous')
                altered = altered.replace('\t\tvar rows: Array[Array] = []',
                                          '\t\tvar decoded_statuses: Array[Array] = []\n\t\tvar rows: Array[Array] = []')
                altered = altered.replace('\t\t\tvar row: Array[int] = []',
                                          '\t\t\tvar row_statuses: Array[int] = []\n\t\t\tvar row: Array[int] = []')
                altered = altered.replace(status_guard,
                                          '\t\t\t\trow_statuses.append(input.status)\n' + status_guard.removesuffix(':') +
                                          ' and not (peer == 1 and frame == 129 and slot == 0 and input.status == Queue.Status.DISCONNECTED):')
                altered = altered.replace('\t\t\trows.append(row)', '\t\t\tdecoded_statuses.append(row_statuses)\n\t\t\trows.append(row)')
                altered = altered.replace('\t\tvar playback: Dictionary = _play(decoded, 0xffffffff, true, false)',
                                          '\t\tif peer == 1:\n\t\t\tserialized_control.statuses = decoded_statuses\n' +
                                          '\t\tvar playback: Dictionary = _play(decoded, 0xffffffff, true, false)')
            script = Path(directory) / (fault + '.gd')
            script.write_text(altered)
            command = [str(engine), '--headless', '--path', str(root), '--script', 'res://' + script.relative_to(root).as_posix(),
                       '--', '--remote-recording-asymmetric-terminal' if terminal else '--remote-recording-asymmetric']
            stdout, stderr = execute(command, output / f'asymmetric-serialized-{fault}-godot.log')
            lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
            if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                raise ValueError('invalid serialized corruption control completion')
            actual = json.loads(lines[0])
            validate(actual, healthy, fault, engine_metadata)
            try:
                compare({key: value for key, value in actual.items() if key != 'serialized_control'}, healthy, 'asymmetric.godot')
            except ValueError as error:
                field = {'input': 'frames[129][0]', 'checksum': 'checksums[129]', 'status': 'playback.bytes', 'terminal': 'playback.code'}[fault]
                if not str(error).startswith(f'asymmetric.godot.peers[1].{field}:'):
                    raise ValueError(f'wrong serialized {fault} rejection: {error}') from error
            else:
                raise ValueError(f'serialized {fault} corruption accepted')
            names.append('godot-serialized-' + ('final-boundary' if terminal else 'post-wrap-' + fault))
    return names
