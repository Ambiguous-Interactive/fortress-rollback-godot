#!/usr/bin/env python3
"""Observe pinned Rust ReplaySession and production Godot playback against independent frame history."""
import copy
import hashlib
import json
from pathlib import Path
import platform
import re
import struct
import subprocess
import zipfile

from launch import ROOT, CACHE, execute, digest, load_manifest, sources, setup_rust
from engine_path import resolve_engine
from fetch import fetch
from receipt_arguments import ReceiptParser

REVISION = 'f13cd5c0f2815926785a395947e18da0dbea0dd8'


def state_bytes(state):
    return struct.pack('<IIII', *state)


def advance(state, row):
    frame, accumulator, rng, pending = state
    for slot, value in enumerate(row):
        accumulator = (accumulator * 33 + value + slot) & 0xffffffff
        rng = (rng * 1664525 + 1013904223) & 0xffffffff
        pending = ((pending + accumulator) & 0xffffffff) ^ rng
    return frame + 1, accumulator, rng, pending


def corpus():
    cases = []
    for players in (2, 8):
        for count in (0, 1, 7):
            for mode in ('plain', 'all', 'sparse', 'first-mismatch', 'last-mismatch'):
                if count == 0 and mode != 'plain':
                    continue
                seed = 0xffffffff
                state = (0, seed, seed, 0)
                rows, checksums = [], []
                for frame in range(count):
                    row = [(seed + frame * 1234567 + slot * 0x1020304) & 0xffffffff for slot in range(players)]
                    saved = bytearray(state_bytes(state))
                    if (mode == 'first-mismatch' and frame == 0) or (mode == 'last-mismatch' and frame == count - 1):
                        saved[15] ^= 0x80
                    checksums.append(None if mode == 'sparse' and frame % 2 else saved.hex())
                    rows.append(row)
                    state = advance(state, row)
                cases.append(dict(name=f'{players}p-{count}-{mode}', players=players, seed=seed,
                                  validate=mode != 'plain', frames=rows, checksums=checksums))
    return cases


def encoded(case):
    """Independent FRRP packing; Rust consumes the original rows, Godot the actual file bytes."""
    data = b'FRRP' + struct.pack('<HBIIIHBB', 5, case['players'], 4, len(case['frames']), 0, 0, 8, 0)
    data += b'\0' * 4
    for text in ('oracle', '0.1.0', 'fortress-rollback ' + REVISION, str(case['seed']), 'replay-parity-v1'):
        data += bytes([len(text)]) + text.encode('ascii')
    for row, checksum in zip(case['frames'], case['checksums']):
        packed = struct.pack('<' + 'I' * case['players'], *row)
        statuses = bytes([1] * case['players'])
        data += packed + statuses + bytes([checksum is not None])
        if checksum is not None:
            data += bytes.fromhex(checksum)
        # Every frame carries the digest of its own input row.
        data += hashlib.sha256(packed + statuses).digest()[:16]
    return data


def expected(case, rust, expert=False):
    state = (0, case['seed'], case['seed'], 0)
    records, events = [], []
    failure = -1
    for frame, (row, checksum) in enumerate(zip(case['frames'], case['checksums'])):
        saved = state_bytes(state).hex()
        if case['validate'] and (rust or checksum is not None):
            records.append(dict(kind='save', frame=frame, bytes=saved, inputs=[]))
        if case['validate'] and checksum is not None and saved != checksum:
            if not rust:
                failure = frame
                break
            events.append(dict(frame=frame, expected=checksum, actual=saved))
        state = advance(state, row)
        records.append(dict(kind='advance', frame=frame, bytes=state_bytes(state).hex(),
                            inputs=[dict(value=value, status='confirmed') for value in row]))
    result = dict(name=case['name'] + ('-expert' if expert else ''), initial_frame=-1 if rust else 0,
                  current_frame=len(case['frames']) - 1 if rust else state[0],
                  complete=True if rust else failure < 0, records=records, bytes=state_bytes(state).hex())
    if rust:
        result.update(exhausted=True, events=events)
    else:
        result.update(code=16 if failure < 0 else 18, failure_frame=failure)
    return result


def compare(actual, wanted, path='result'):
    """Exact schema and numeric types, before value comparison (bool is not int)."""
    if type(actual) is not type(wanted):
        raise ValueError(f'{path}: type mismatch')
    if isinstance(wanted, dict):
        if actual.keys() != wanted.keys():
            raise ValueError(f'{path}: field mismatch')
        for key in wanted:
            compare(actual[key], wanted[key], f'{path}.{key}')
    elif isinstance(wanted, list):
        if len(actual) != len(wanted):
            raise ValueError(f'{path}: count mismatch')
        for index, (value, target) in enumerate(zip(actual, wanted)):
            compare(value, target, f'{path}[{index}]')
    elif actual != wanted:
        raise ValueError(f'{path}: value mismatch: expected {wanted!r}, actual {actual!r}')


def godot_expected(cases):
    return dict(format=1, cases=[expected(case, False, expert) for case in cases for expert in (False, True)])


def controls(observed, wanted):
    inventory = {case['name']: index for index, case in enumerate(wanted['cases'])}
    plain = inventory['2p-1-plain']
    temporal = inventory['2p-7-plain']
    final_mismatch = inventory['2p-1-last-mismatch']
    sparse = inventory['2p-7-sparse']
    return reject_mutations(observed, wanted, (
        ('intermediate-state', ('cases', temporal, 'records', 0, 'bytes'), '00' * 16),
        ('confirmed-status', ('cases', plain, 'records', 0, 'inputs', 0, 'status'), 'predicted'),
        ('frame-offset', ('cases', plain, 'current_frame'), 1),
        ('bool-alias', ('format',), True),
        ('missing-final-desync', ('cases', final_mismatch, 'events'), []),
        ('invented-event', ('cases', plain, 'events'), [{'frame': 0, 'expected': '00' * 16, 'actual': '00' * 16}]),
        ('missing-sparse-save', ('cases', sparse, 'records'),
         [record for record in observed['cases'][sparse]['records'] if not (record['kind'] == 'save' and record['frame'] == 1)]),
    ))


def expert_controls(observed, wanted):
    """Reject expert-only faults while leaving every callback observation unchanged."""
    compare(observed, wanted)
    inventory = {case['name']: index for index, case in enumerate(wanted['cases'])}
    validated = inventory['2p-7-all-expert']
    mismatch = inventory['2p-1-first-mismatch-expert']
    records = observed['cases'][validated]['records']
    return reject_mutations(observed, wanted, (
        ('expert-missing-save', ('cases', validated, 'records'), records[1:]),
        ('expert-duplicate-advance', ('cases', validated, 'records'), records + [records[-1]]),
        ('expert-frame-offset', ('cases', validated, 'records', 0, 'frame'), 1),
        ('expert-intermediate-state', ('cases', validated, 'records', 1, 'bytes'), '00' * 16),
        ('expert-input-status', ('cases', validated, 'records', 1, 'inputs', 0, 'status'), 'predicted'),
        ('expert-advance-after-desync', ('cases', mismatch, 'records'),
         observed['cases'][mismatch]['records'] + [records[1]]),
    ))


def reject_mutations(observed, wanted, mutations):
    controls = []
    for name, path, replacement in mutations:
        changed = copy.deepcopy(observed)
        target = changed
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = replacement
        diagnostic = 'result' + ''.join(f'[{key}]' if isinstance(key, int) else '.' + key for key in path)
        try:
            compare(changed, wanted)
        except ValueError as error:
            if not str(error).startswith(diagnostic + ':'):
                raise ValueError(f'{name}: rejected at unintended boundary: {error}') from error
            controls.append(name)
        else:
            raise ValueError(f'{name}: mutation was accepted')
    return controls


def fingerprints():
    paths = [*Path(ROOT / 'scripts/oracle').glob('*.py'), ROOT / 'scripts/oracle/rust/src/bin/replay.rs',
             ROOT / 'scripts/oracle/rust/Cargo.toml', ROOT / 'scripts/oracle/rust/Cargo.lock',
             ROOT / 'docs/reference/pins.json']
    pending = [ROOT / 'tests/oracle/replay_session_trace.gd']
    scripts = set()
    while pending:
        path = pending.pop()
        if path in scripts:
            continue
        scripts.add(path)
        pending.extend(ROOT / match[6:] for match in re.findall(r'(?:preload|load)\("(res://[^"\n]+\.gd)"\)', path.read_text()))
    paths += list(scripts)
    paths += [ROOT / 'scripts/oracle/launch.py', ROOT / 'scripts/reference/fetch.py',
              ROOT / 'scripts/reference/run.py', ROOT / 'scripts/reference/receipt_arguments.py']
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(set(paths))}


def rejection_controls(binary, engine, cases, output):
    """Exercise standalone process bounds, rather than trusting launcher-only validation."""
    command = [str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/oracle/replay_session_trace.gd']
    controls = [
        ('rust-byte-limit', [str(binary)], 'x' * 2097153, 'bundle exceeds byte limit'),
        ('rust-empty-bundle', [str(binary)], '[]', 'invalid case count'),
        ('rust-case-limit', [str(binary)], json.dumps([cases[0]] * 65), 'invalid case count'),
    ]
    invalid_file = output / 'oversized.json'
    invalid_file.write_text('x' * 2097153)
    controls.append(('godot-byte-limit', command + ['--', '--bundle', str(invalid_file.resolve())], None, 'invalid bundle file'))
    for name, invocation, input_text, diagnostic in controls:
        log = output / f'{name}.log'
        try:
            execute(invocation, log, input_text)
        except ValueError:
            text = log.read_text()
            if diagnostic not in text or 'FORTRESS_REPLAY_RESULT ' in text:
                raise ValueError(f'{name}: missing intended standalone rejection')
        else:
            raise ValueError(f'{name}: standalone accepted invalid input')
    return [name for name, *_ in controls]


def verified_engine(engine, manifest, offline):
    actual = digest(engine)
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}[platform.machine()]
    for version in (manifest['godot']['minimum'], manifest['godot']['current_stable']):
        name = f'Godot_v{version}-stable_linux.{arch}.zip'
        archive = fetch(manifest['artifacts'][name], name, offline)
        with zipfile.ZipFile(archive) as package:
            files = [entry for entry in package.infolist() if not entry.is_dir()]
            if len(files) != 1:
                raise ValueError('unexpected engine archive contents')
            if hashlib.sha256(package.read(files[0])).hexdigest() == actual:
                return version, actual
    raise ValueError('engine differs from both verified pinned archives')


def main():
    parser = ReceiptParser(description=__doc__, receipt='replay.json')
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/replay')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'replay.json'
    receipt.unlink(missing_ok=True)
    engine = resolve_engine(args.godot)
    manifest = load_manifest()
    if manifest['sources']['fortress']['revision'] != REVISION:
        raise ValueError('replay adapter revision differs from pinned source')
    trees = sources(manifest, args.offline)
    version, engine_hash = verified_engine(engine, manifest, args.offline)
    frozen = fingerprints()
    cargo, _ = setup_rust(manifest, args.offline)
    command = [str(cargo), '+' + manifest['rust']['version'], 'build', '--locked', '--bin', 'replay',
               '--manifest-path', str(ROOT / 'scripts/oracle/rust/Cargo.toml')]
    if args.offline:
        command.append('--offline')
    execute(command, args.output / 'build.log', timeout=600)
    binary = CACHE / 'target/debug/replay'
    binary_hash = digest(binary)
    cases = corpus()
    scenario = json.dumps(cases, indent=2) + '\n'
    (args.output / 'cases.json').write_text(scenario)
    bundle = [dict(name=case['name'], seed=case['seed'], validate=case['validate'], replay=encoded(case).hex()) for case in cases]
    fixture = args.output / 'files.json'
    fixture.write_text(json.dumps(bundle, indent=2) + '\n')
    observations = []
    for repeat in (1, 2):
        stdout, stderr = execute([str(binary)], args.output / f'rust-{repeat}.log', scenario)
        if stderr.strip():
            raise ValueError('Rust replay emitted unexpected stderr')
        rust = json.loads(stdout)
        wanted = dict(format=1, cases=[expected(case, True) for case in cases])
        compare(rust, wanted)
        stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
            'res://tests/oracle/replay_session_trace.gd', '--', '--bundle', str(fixture.resolve())], args.output / f'godot-{repeat}.log')
        if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('Godot replay engine error')
        prefix = 'FORTRESS_REPLAY_RESULT '
        lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
        if len(lines) != 1:
            raise ValueError('missing or duplicate Godot replay completion')
        godot = json.loads(lines[0])
        compare(godot, godot_expected(cases))
        observations.append(dict(rust=rust, godot=godot))
    compare(observations[0], observations[1])
    negative = controls(observations[0]['rust'], wanted)
    negative += expert_controls(observations[0]['godot'], godot_expected(cases))
    rejected = rejection_controls(binary, engine, cases, args.output)
    if fingerprints() != frozen or digest(engine) != engine_hash or digest(binary) != binary_hash:
        raise ValueError('source or tool changed during replay observation')
    receipt.write_text(json.dumps(dict(format=1, passed=True, repeat_equal=True, engine=version,
        engine_sha256=engine_hash, engine_path=str(engine), binary_sha256=binary_hash, upstream_revision=manifest['sources']['fortress']['revision'],
        upstream_lock_sha256=digest(trees['fortress'] / 'Cargo.lock'), source_sha256=frozen,
        cases_sha256=digest(args.output / 'cases.json'), files_sha256=digest(fixture),
        negative_controls=negative, standalone_rejections=rejected, observations=observations[0],
        limitations=['ReplaySession playback only; recording applicability is audited separately.',
                     'Native sequential replay; browser replay coverage is in ownership and online probes.',
                     'Godot callback and expert playback check only present checksums and stop before mismatching advances.',
                     'No snapshot seek acceleration or network-fault replay.']), indent=2) + '\n')
    print(f'Replay: {len(cases)} pinned upstream cases and both Godot interfaces passed twice; {len(negative)} negative controls rejected.')


if __name__ == '__main__':
    main()
