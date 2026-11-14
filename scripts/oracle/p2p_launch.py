#!/usr/bin/env python3
"""Run actual upstream P2P mesh and shipped Godot byte sessions, twice each."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))
from fetch import ROOT, CACHE, digest, load_manifest, sources
from receipt_arguments import ReceiptParser
from run import setup_rust, rust_environment
from launch import execute, git_identity, require_unchanged
from engine_path import resolve_engine
from p2p_contract import validate, validate_scenario, compare, REVISION
from p2p_controls import process_controls
import p2p_lifecycle_corpus
import p2p_lifecycle
import p2p_lifecycle_controls
import p2p_recovery
import p2p_capacity
import p2p_shrink

PREFIX = 'FORTRESS_P2P_RESULT '


def parse_godot(stdout, stderr):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('Godot engine error')
    rows = [line[len(PREFIX):] for line in stdout.splitlines() if line.startswith(PREFIX)]
    if len(rows) != 1:
        raise ValueError('missing/duplicate Godot completion')
    return json.loads(rows[0])


def source(binary, scenario):
    result = subprocess.run([str(binary)], input=json.dumps(scenario), capture_output=True, encoding='utf-8', timeout=30, env=rust_environment())
    if result.returncode or result.stderr.strip():
        raise ValueError('corpus source process failed: ' + result.stderr[:200])
    value = json.loads(result.stdout); validate(value, scenario, True)
    return value


def corpus(binary, selected=None):
    """Schedules derive only from actual sent packet inventories, never request traces."""
    cases = {}
    for players in range(2, 9):
        for delay in (0, 2):
            name = f'mesh_{players}_delay_{delay}'
            if selected is None or selected == name:
                cases[name] = build_case(binary, players, delay, 'ordinary')
    for players in (2, 4, 8):
        for mode in ('loss', 'reorder', 'stall', 'retry'):
            name = f'mesh_{players}_{mode}'
            if selected is None or selected == name:
                cases[name] = build_case(binary, players, 0, mode)
    # The maximum comparable prediction window: the ordinary cases hold the deepest configured
    # rollback boundary, and the stall schedule that exceeds window four instead recovers through
    # a six-frame prediction run, so both the threshold refusal and the deep recovery path compare.
    for players in (2, 4, 8):
        name = f'mesh_{players}_window_8'
        if selected is None or selected == name:
            cases[name] = build_case(binary, players, 0, 'ordinary', window=8)
    name = 'mesh_2_window_8_stall'
    if selected is None or selected == name:
        cases[name] = build_case(binary, 2, 0, 'stall', window=8)
    # Explicit multi-local endpoint layouts: couch co-op machines owning several local slots.
    for name, (layout, mode) in LAYOUT_CASES.items():
        if selected is None or selected == name:
            cases[name] = build_layout_case(binary, layout, mode)
    for name, (players, delay, mode) in DELAY_CASES.items():
        if selected is None or selected == name:
            cases[name] = build_case(binary, players, delay, mode)
    if selected is None or selected == p2p_recovery.NAME:
        cases[p2p_recovery.NAME] = p2p_recovery.build(binary, source)
    if selected is None or selected == p2p_capacity.NAME:
        cases[p2p_capacity.NAME] = p2p_capacity.build(binary, source)
    cases.update(p2p_lifecycle_corpus.corpus(binary, source, selected))
    return cases


# Runtime set_input_delay after each listed (frame, peer) step: raises, repeats, refused decreases and too-large values.
DELAY_CASES = {'mesh_2_delay_change_loss': (2, 0, 'delay_loss'), 'mesh_4_delay_change_rapid': (4, 2, 'delay_rapid'),
               'mesh_3_delay_change_stall': (3, 0, 'delay_stall')}
DELAY_CHANGES = {
    'delay_loss': {(0, 1): [1], (1, 0): [2], (2, 1): [1, 3], (3, 0): [1, 500, 2, 3], (4, 1): [4, 0]},
    # Raises start after frame zero's flight is acknowledged: upstream drops a resend that starts at a nonzero initial delay (see docs).
    'delay_rapid': {**{(1, peer): [3] for peer in range(4)}, (2, 1): [4, 5, 6], (3, 2): [59, 58], (4, 3): [4, 4, 1000], (5, 0): [5]},
    'delay_stall': {(1, 1): [2], (2, 2): [1, 2]},
}

# Multi-local endpoint layouts: (machine sizes, mode). The couch mesh holds the shared-address
# row shape, the split holds three machines, and the fault modes hold loss recovery and a
# prediction-window stall released through reversed withheld flights under one layout.
LAYOUT_CASES = {'mesh_4_couch_2x2': ([2, 2], 'ordinary'), 'mesh_6_split_2x2x2': ([2, 2, 2], 'ordinary'),
                'mesh_4_couch_loss': ([2, 2], 'loss'), 'mesh_4_couch_stall': ([2, 2], 'stall')}


def build_layout_case(binary, layout, mode):
    """Schedules where machines own several local slots: step ops address one slot, and a
    machine's advance happens on the op that completes its row. The stall case withholds the
    couch machine's flights so the solo machine runs its prediction window out through the
    pinned engine's silent stall, then releases everything reversed for the deep rollback
    recovery; the loss case drops round-zero packets and recovers them through later batch
    flights."""
    players = sum(layout)
    scenario = {'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': 4,
                'layout': list(layout), 'operations': []}
    now = 0; delivered = set(); withheld = []; latest = None
    machines = []
    start = 0
    for size in layout:
        machines.append(list(range(start, start + size))); start += size
    owner = [machine for machine, slots in enumerate(machines) for _ in slots]
    def append(kind, refresh=True, **kwargs):
        nonlocal now, latest
        now += 1; scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))
        if refresh:
            latest = source(binary, scenario)
    def step(slot):
        frame = next((r['frame_after'] for r in reversed(latest['records']) if r['peer'] == owner[slot]), 0) if latest else 0
        append('step', peer=slot, bytes=((frame + 1) * (slot + 1) * 17).to_bytes(4, 'little').hex())
    def deliver_new(lose=False, keep=False):
        nonlocal latest
        while True:
            pending = [p for p in latest['packets'] if p['id'] not in delivered]
            if not pending:
                return
            for p in pending:
                delivered.add(p['id'])
                if lose and p['id'] % 3 == 1:
                    continue
                if keep and p['from'] == 0:
                    withheld.append(p['id'])
                    continue
                append('deliver', refresh=False, packet=p['id'])
            latest = source(binary, scenario)
    for frame in range(6):
        # Stall rounds four and five step only the starved machine, so both machines hold
        # four predicted frames before the release and converge again through the recovery.
        stepping = machines if frame < 4 or mode != 'stall' else machines[1:]
        for slots in stepping:
            for slot in slots:
                step(slot)
        deliver_new(lose=(mode == 'loss' and frame == 0), keep=mode == 'stall')
    if mode == 'stall':
        for p in reversed(withheld):
            append('deliver', refresh=False, packet=p)
            latest = source(binary, scenario)
        for frame in range(2):
            for slots in machines:
                for slot in slots:
                    step(slot)
            deliver_new()
    for machine in range(len(machines)):
        append('poll', peer=machines[machine][0])
    validate_scenario(scenario)
    return scenario


def build_case(binary, players, delay, mode, window=4):
    scenario = {'format': 1, 'players': players, 'input_delay': delay, 'max_prediction': window, 'operations': []}
    now = 0; delivered = set(); latest = None
    def append(kind, refresh=True, **kwargs):
        nonlocal now, latest
        now += 1; scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))
        if refresh:
            latest = source(binary, scenario)
    def step(peer):
        frame = next((r['frame_after'] for r in reversed(latest['records']) if r['peer'] == peer), 0) if latest else 0
        append('step', peer=peer, bytes=((frame + 1) * (peer + 1) * 17).to_bytes(4, 'little').hex())
    def change(peer, delay):
        nonlocal latest
        scenario['operations'].append({'kind': 'delay', 'peer': peer, 'delay': delay}); latest = source(binary, scenario)
    def flush(reverse=False, lose=False):
        nonlocal latest
        while True:
            pending = [p for p in latest['packets'] if p['id'] not in delivered]
            if not pending:
                return
            if reverse:
                pending.reverse()
            for p in pending:
                delivered.add(p['id'])
                if lose and (p['id'] % 3 == 1 if mode == 'delay_loss' else p['id'] < players * (players - 1) + 1):
                    continue
                append('deliver', refresh=False, packet=p['id'])
            latest = source(binary, scenario)
    if mode in {'stall', 'delay_stall'}:
        for _ in range(6):
            step(0)
            if mode == 'delay_stall' and latest['records'][-1]['frame_before'] == latest['records'][-1]['frame_after']:
                change(0, 2)
        for peer in range(1, players):
            step(peer)
        flush(reverse=True)
    if mode == 'retry':
        for peer in range(players):
            step(peer)
        # Drop the entire first input flight. Exact interval stays silent;
        # interval+1 retries. Then drop the first ACK flight and retry again.
        delivered.update(p['id'] for p in latest['packets'])
        now = 199999; append('poll', peer=0); append('poll', peer=0)
        for p in list(latest['packets']):
            if p['id'] not in delivered:
                delivered.add(p['id']); append('deliver', packet=p['id'])
        delivered.update(p['id'] for p in latest['packets'])
        now = 400000; append('poll', peer=0); append('poll', peer=0)
        flush()
    for frame in range(6):
        for peer in range(players):
            step(peer)
            for delay in DELAY_CHANGES.get(mode, {}).get((frame, peer), []):
                change(peer, delay)
        if mode in {'reorder', 'delay_rapid'} and frame == 1:
            initial = [p['id'] for p in latest['packets'] if p['semantic']['kind'] == 'input']
            flush(reverse=True)
            append('deliver', packet=initial[0])
        else:
            flush(lose=(mode == 'loss' and frame == 0) or (mode == 'delay_loss' and frame < 4))
    for peer in range(players):
        append('poll', peer=peer)
    validate_scenario(scenario)
    return scenario


def negative_controls(actual, expected, scenario):
    if 'lifecycle' in scenario:
        return p2p_lifecycle_controls.controls(actual, expected, scenario)
    request_op = next(i for i, r in enumerate(actual['records']) if any(q['kind'] == 'advance' for q in r['requests']))
    request_index = next(i for i, q in enumerate(actual['records'][request_op]['requests']) if q['kind'] == 'advance')
    save_record = next(i for i, r in enumerate(actual['records']) if r['requests'] and r['requests'][0]['kind'] == 'save')
    controls = {
        'incomplete': lambda x: x.update(complete=False),
        'partial': lambda x: x['records'].pop(),
        'bool_confirmed': lambda x: x['records'][request_op].update(confirmed_frame=True),
        'float_frame': lambda x: x['records'][request_op].update(frame_before=0.0),
        'event': lambda x: x['records'][request_op]['events'].append('Synchronized'),
        'confirmed': lambda x: x['records'][request_op].update(confirmed_frame=42),
        'callback': lambda x: x['records'][request_op]['requests'].pop(request_index),
        # A layout scenario's first record can be a refused incomplete-row step with no requests.
        'duplicate_initial_save': lambda x: x['records'][save_record]['requests'].insert(
            0, deepcopy(x['records'][save_record]['requests'][0])),
        'embedded_bool': lambda x: x['scenario'].update(format=True),
        'packet_ack': lambda x: x['packets'][0]['semantic'].update(ack_frame=42),
    }
    stalled = next((i for i, record in enumerate(actual['records']) if record['error'] == 'PREDICTION_STALL'), None)
    if stalled is not None:
        controls['missing_stall_error'] = lambda x: x['records'][stalled].update(error=None)
    layout_packet = next((i for i, p in enumerate(actual['packets'])
                          if p['semantic']['kind'] == 'input' and len(p['semantic']['players']) > 1), None)
    if layout_packet is not None:
        # Multi-local row shape: dropping an owned slot or flipping a non-leading chunk must fail.
        def layout_players(x):
            x['packets'][layout_packet]['semantic']['players'].pop()
        def layout_row(x):
            row = x['packets'][layout_packet]['semantic']['frames'][0]
            x['packets'][layout_packet]['semantic']['frames'][0] = row[:8] + ('ff' if row[8:10] != 'ff' else '00') + row[10:]
        controls['layout_players'] = layout_players
        controls['layout_row'] = layout_row
    for name, mutate in controls.items():
        mutant = deepcopy(actual); mutate(mutant)
        try:
            compare(mutant, expected, scenario)
        except ValueError:
            pass
        else:
            raise ValueError('negative control survived: ' + name)
    return list(controls)


def differential_failure(name, binary, engine, scenario, expected, failure, output):
    """Shrink a fresh differential disagreement to a minimal scenario, confirm it, and raise with the evidence.

    Every probe candidate reruns both sides, so an adopted removal always
    reproduces the disagreement; the confirmation then replays the minimized
    scenario under the full green-path gates (twice per side, raw compression
    validation included) and writes its artifacts next to the shrink logs.
    """
    counts = [len(record['outgoing']) for record in expected['records']]

    def probe(candidate):
        try:
            validate_scenario(candidate)
            stdout, stderr = execute([str(binary)], output / f'{name}-shrink-source.log', json.dumps(candidate))
            if stderr.strip():
                return None
            value = json.loads(stdout); validate(value, candidate, True)
        except (ValueError, subprocess.TimeoutExpired, OSError):
            return None
        submitted = output / f'{name}-shrink-scenario.json'; submitted.write_text(json.dumps(candidate, indent=2) + '\n')
        try:
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                'res://tests/oracle/p2p_trace.gd', '--', '--scenario', str(submitted.resolve())],
                output / f'{name}-shrink-godot.log')
            actual = parse_godot(stdout, stderr)
        except (ValueError, subprocess.TimeoutExpired, OSError):
            return None
        try:
            compare(actual, value, candidate)
        except ValueError as disagreement:
            return str(disagreement)
        return None

    minimized, message, stats = p2p_shrink.minimize(scenario, counts, str(failure), probe)
    submitted = output / f'{name}-minimized-scenario.json'; submitted.write_text(json.dumps(minimized, indent=2) + '\n')
    statistics = {'case': name, 'original_failure': str(failure), 'minimized_failure': message, 'statistics': stats}
    try:
        source_results = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary)], output / f'{name}-minimized-source-{repeat}.log', submitted.read_text())
            if stderr.strip():
                raise ValueError('minimized source stderr')
            value = json.loads(stdout); validate(value, minimized, True); source_results.append(value)
        if source_results[0] != source_results[1]:
            raise ValueError('minimized source repeat mismatch')
        verified, stderr = execute([str(binary), '--validate-trace'],
            output / f'{name}-minimized-raw-validate.log', json.dumps(source_results[0]))
        raw_validation = json.loads(verified)
        if (stderr.strip() or type(raw_validation) is not dict or set(raw_validation) != {'complete', 'packets'}
                or raw_validation['complete'] is not True or type(raw_validation['packets']) is not int
                or raw_validation['packets'] != len(source_results[0]['packets'])):
            raise ValueError('minimized raw compression validator completion')
        (output / f'{name}-minimized-source.json').write_text(json.dumps(source_results[0], indent=2) + '\n')
        godot_actuals = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                'res://tests/oracle/p2p_trace.gd', '--', '--scenario', str(submitted.resolve())],
                output / f'{name}-minimized-godot-{repeat}.log')
            actual = parse_godot(stdout, stderr)
            godot_actuals.append(actual)
            (output / f'{name}-minimized-actual-{repeat}.json').write_text(json.dumps(actual, indent=2) + '\n')
            try:
                compare(actual, source_results[0], minimized)
            except ValueError:
                continue
            raise ValueError('minimized scenario does not reproduce on repeat ' + str(repeat))
        if godot_actuals[0] != godot_actuals[1]:
            raise ValueError('minimized Godot repeat mismatch')
    except (ValueError, subprocess.TimeoutExpired, OSError) as error:
        statistics.update({'outcome': 'aborted', 'error': str(error)})
        (output / f'{name}-minimized-report.json').write_text(json.dumps(statistics, indent=2) + '\n')
        raise ValueError(f'{name}: differential confirmation aborted: {error}; original failure: {failure}') from error
    statistics.update({'outcome': 'reproduced', 'scenario_sha256': digest(submitted),
        'source_sha256': digest(output / f'{name}-minimized-source.json')})
    (output / f'{name}-minimized-report.json').write_text(json.dumps(statistics, indent=2) + '\n')
    raise ValueError(f'{name}: differential disagreement survives shrinking from {stats["original_operations"]} to '
        f'{stats["final_operations"]} operations; first divergence: {message}; original failure: {failure}; '
        f'evidence in {output}')



def source_files():
    return [*(ROOT / 'addons/fortress_rollback/core').glob('*.gd'), *(ROOT / 'addons/fortress_rollback/protocol').glob('*.gd'),
        *(ROOT / 'tests/oracle').glob('*.gd'), *Path(__file__).parent.glob('*.py'), ROOT / 'scripts/oracle/rust/src/bin/p2p.rs',
        ROOT / 'scripts/oracle/rust/Cargo.toml', ROOT / 'scripts/oracle/rust/Cargo.lock', ROOT / 'docs/reference/pins.json',
        *(ROOT / 'scripts/reference').glob('*.py')]

def upstream_inventory(tree):
    paths = [*tree.rglob('*.rs'), tree / 'Cargo.toml', tree / 'Cargo.lock']
    return {str(path.relative_to(tree)): digest(path) for path in sorted(paths)}


def executable_identity(path):
    resolved = path.resolve(strict=True)
    return {'path': str(resolved), 'sha256': digest(resolved), 'mode': resolved.stat().st_mode & 0o777}


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--case')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/p2p-oracle')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'; receipt.unlink(missing_ok=True)
    identity = git_identity()
    engine = resolve_engine(args.godot)
    files = source_files()
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}
    manifest = load_manifest(); trees = sources(manifest, offline=args.offline)
    upstream_hashes = upstream_inventory(trees['fortress'])
    engine_identity = executable_identity(engine)
    cargo, _ = setup_rust(manifest, args.offline)
    version = manifest['rust']['version']
    cargo_version, _ = execute([str(cargo), '+' + version, '--version'], args.output / 'cargo-version.log')
    rust_version, _ = execute([str(cargo.with_name('rustc')), '+' + version, '--version'], args.output / 'rustc-version.log')
    engine_version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    if not engine_version.startswith(('4.3.stable', '4.7.2.stable')):
        raise ValueError('unsupported engine profile')
    execute([str(cargo), '+' + version, 'build', '--locked', '--offline', '--manifest-path',
        str(ROOT / 'scripts/oracle/rust/Cargo.toml'), '--bin', 'p2p'], args.output / 'build.log', timeout=600)
    binary = CACHE / 'target/debug/p2p'
    binary_identity = executable_identity(binary)
    require_unchanged('upstream source inventory', upstream_hashes, upstream_inventory(trees['fortress']))
    require_unchanged('Godot executable', engine_identity, executable_identity(engine))
    cases = corpus(binary, args.case)
    if args.case:
        cases = {args.case: cases[args.case]}
    evidence = []
    for name, scenario in cases.items():
        submitted = args.output / (name + '-scenario.json'); submitted.write_text(json.dumps(scenario, indent=2) + '\n')
        source_results = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary)], args.output / f'{name}-rust-{repeat}.log', submitted.read_text())
            if stderr.strip():
                raise ValueError('source stderr')
            value = json.loads(stdout); validate(value, scenario, True); source_results.append(value)
        if source_results[0] != source_results[1]:
            raise ValueError('source process repeat mismatch')
        expected = source_results[0]
        verified, stderr = execute([str(binary), '--validate-trace'], args.output / f'{name}-raw-validate.log', json.dumps(expected))
        raw_validation = json.loads(verified)
        if (stderr.strip() or type(raw_validation) is not dict or set(raw_validation) != {'complete', 'packets'}
                or raw_validation['complete'] is not True or type(raw_validation['packets']) is not int
                or raw_validation['packets'] != len(expected['packets'])):
            raise ValueError('raw compression validator completion')
        raw = args.output / (name + '-source.json'); raw.write_text(json.dumps(expected, indent=2) + '\n')
        actuals = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                'res://tests/oracle/p2p_trace.gd', '--', '--scenario', str(submitted.resolve())], args.output / f'{name}-godot-{repeat}.log')
            try:
                actual = parse_godot(stdout, stderr)
            except ValueError as failure:
                # A rejected trace script is itself a Godot-side disagreement with the validated source run.
                differential_failure(name, binary, engine, scenario, expected, failure, args.output)
            try:
                compare(actual, expected, scenario)
            except ValueError as failure:
                differential_failure(name, binary, engine, scenario, expected, failure, args.output)
            actuals.append(actual)
        if actuals[0] != actuals[1]:
            raise ValueError('Godot repeat mismatch')
        path = args.output / (name + '-actual.json'); path.write_text(json.dumps(actuals[0], indent=2) + '\n')
        controls = negative_controls(actuals[0], expected, scenario)
        lifecycle_evidence = p2p_lifecycle.corpus_evidence(name, expected, controls) if 'lifecycle' in scenario else {}
        recovery_evidence = {}
        if name == p2p_recovery.NAME:
            recovery_evidence = {'source': p2p_recovery.evidence(expected, scenario), 'godot': p2p_recovery.evidence(actuals[0], scenario)}
            controls.extend(p2p_recovery.controls(actuals[0], scenario))
        capacity_evidence = {}
        if name == p2p_capacity.NAME:
            capacity_evidence = {'source': p2p_capacity.evidence(expected, scenario), 'godot': p2p_capacity.evidence(actuals[0], scenario)}
            controls.extend(p2p_capacity.controls(actuals[0], scenario))
        evidence.append({'name': name, 'operations': len(scenario['operations']), 'packets': len(expected['packets']),
            'scenario_sha256': digest(submitted), 'source_sha256': digest(raw), 'actual_sha256': digest(path),
            'negative_controls': controls, 'lifecycle_evidence': lifecycle_evidence, 'recovery_evidence': recovery_evidence,
            'capacity_evidence': capacity_evidence, 'fresh_process_repeat_equal': True})
        print(name + ': actual input/ACK packets, ordered callbacks and confirmation match twice', flush=True)
    process_evidence = process_controls(binary, engine, cases['mesh_2_delay_0'],
        json.loads((args.output / 'mesh_2_delay_0-source.json').read_text()),
        json.loads((args.output / 'mesh_2_delay_0-actual.json').read_text()), args.output) if 'mesh_2_delay_0' in cases else []
    process_evidence.extend(p2p_lifecycle_controls.process_controls(binary, engine, cases, args.output))
    require_unchanged('local source inventory', hashes, {str(p.relative_to(ROOT)): digest(p) for p in sorted(source_files())})
    require_unchanged('upstream source inventory', upstream_hashes, upstream_inventory(trees['fortress']))
    require_unchanged('Godot executable', engine_identity, executable_identity(engine))
    require_unchanged('Rust oracle executable', binary_identity, executable_identity(binary))
    require_unchanged('repository identity', identity, git_identity())
    receipt.write_text(json.dumps({'format': 1, 'complete': True, 'passed': True,
        'upstream_revision': REVISION, 'upstream_archive_sha256': manifest['sources']['fortress']['archive']['digest'],
        'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'), 'upstream_source_sha256': upstream_hashes,
        'upstream_lock_sha256': upstream_hashes['Cargo.lock'],
        'upstream_manifest_sha256': upstream_hashes['Cargo.toml'], 'source_sha256': hashes,
        'commit': identity['commit'],
        'working_tree_dirty': identity['working_tree_dirty'],
        'engine': engine_version.strip(), 'engine_sha256': engine_identity['sha256'], 'binary_sha256': binary_identity['sha256'],
        'engine_identity': engine_identity, 'engine_path': str(engine),
        'binary_identity': binary_identity, 'execution_identities_unchanged': True,
        'cargo': cargo_version.strip(), 'rustc': rust_version.strip(), 'default_features': False, 'features': [],
        'process_controls': process_evidence, 'cases': evidence}, indent=2) + '\n')


if __name__ == '__main__':
    main()
