#!/usr/bin/env python3
"""Compare actual pinned Rust and production Godot queues in fresh processes."""
import copy
import json
from pathlib import Path
import platform
import hashlib
import shutil
import subprocess
import tempfile

from launch import ROOT, CACHE, execute, digest, load_manifest, sources, setup_rust
from fetch import retain_verified_tree
from receipt_arguments import ReceiptParser
from queue_contract import compare, validate_bundle
from queue_corpus import bundle



# Observation wrappers only: each delegates directly to an unchanged pinned queue path.
OBSERVATION_HOOK = """
impl<T: Config> InputQueue<T> {
    pub fn oracle_add_reclaim(&mut self, input: PlayerInput<T::Input>, floor: Frame) -> Frame {
        self.add_input_reclaiming_before(input, floor)
    }
    pub fn oracle_delay_reclaim(&mut self, delay: usize, floor: Frame) -> Result<(), FortressError> {
        self.set_frame_delay_reclaiming_before(delay, floor)
    }
    pub fn oracle_retained(&self, frame: Frame) -> Option<PlayerInput<T::Input>> {
        self.retained_confirmed_input(frame).ok()
    }
}
"""


def observation_source(tree):
    """Leave verified sources immutable; append access-only wrappers in a disposable copy."""
    workspace = CACHE / 'queue-observation'
    upstream = workspace / 'fortress'
    workspace.mkdir(parents=True, exist_ok=True)
    relative = Path('src/input_queue/mod.rs')
    original = (tree / relative).read_bytes()
    hooked = original + OBSERVATION_HOOK.encode()
    with tempfile.TemporaryDirectory(dir=workspace) as temporary:
        expected = Path(temporary) / 'fortress'
        shutil.copytree(tree, expected)
        (expected / relative).write_bytes(hooked)
        retain_verified_tree(expected, upstream)
    adapter = workspace / 'adapter'
    original_manifest = ROOT / 'scripts/oracle/rust/Cargo.toml'
    manifest = original_manifest.read_text()
    old = '../../../.cache/reference/fortress-rollback-' + 'f13cd5c0f2815926785a395947e18da0dbea0dd8'
    if manifest.count(old) != 1:
        raise ValueError('queue adapter dependency anchor changed')
    manifest = manifest.replace(old, str(upstream))
    manifest += '\n[[bin]]\nname = "queue"\npath = ' + json.dumps(str(ROOT / 'scripts/oracle/rust/src/bin/queue.rs')) + '\n'
    with tempfile.TemporaryDirectory(dir=workspace) as temporary:
        expected = Path(temporary) / 'adapter'
        expected.mkdir()
        (expected / 'Cargo.toml').write_text(manifest)
        shutil.copyfile(ROOT / 'scripts/oracle/rust/Cargo.lock', expected / 'Cargo.lock')
        retain_verified_tree(expected, adapter)
    return adapter / 'Cargo.toml', {
        'method': 'unchanged verified source plus three access-only delegation wrappers in isolated copy',
        'original_queue_sha256': hashlib.sha256(original).hexdigest(),
        'hook_sha256': hashlib.sha256(OBSERVATION_HOOK.encode()).hexdigest(),
        'observed_queue_sha256': hashlib.sha256(hooked).hexdigest(),
        'hook': OBSERVATION_HOOK,
        'original_queue_unmodified': (tree / relative).read_bytes() == original,
    }


def parse_godot(stdout, stderr):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('Godot queue engine error')
    prefix = 'FORTRESS_QUEUE_RESULT '
    values = [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError('missing or duplicate queue completion')
    return values[0]


def startup_divergence(binary, game_command, output):
    value = {'format': 1, 'upstream_revision': 'f13cd5c0f2815926785a395947e18da0dbea0dd8', 'cases': [
        {'name': 'atomic-startup', 'capacity': 2, 'input_width': 1, 'player': 0, 'operations': [
            {'kind': 'add', 'frame': 3, 'bytes': '09'}, {'kind': 'confirmed', 'frame': 0},
            {'kind': 'confirmed', 'frame': 1}, {'kind': 'confirmed', 'frame': 2},
            {'kind': 'add', 'frame': 0, 'bytes': '09'}]}]}
    fixture = output / 'startup-divergence.json'
    fixture.write_text(json.dumps(validate_bundle(value)))
    stdout, stderr = execute([str(binary)], output / 'startup-rust.log', fixture.read_text())
    if stderr.strip():
        raise ValueError('startup oracle emitted unexpected stderr')
    rust = json.loads(stdout)
    stdout, stderr = execute(game_command + ['--', '--bundle', str(fixture.resolve())], output / 'startup-godot.log')
    godot = parse_godot(stdout, stderr)
    # Validate both complete traces before checking the specifically reviewed difference.
    compare(rust, rust, ['atomic-startup'], [5])
    compare(godot, godot, ['atomic-startup'], [5])
    rust_records = rust['cases'][0]['records']
    godot_records = godot['cases'][0]['records']
    if [record['accepted'] for record in rust_records] != [False, True, True, False, False]:
        raise ValueError('upstream partial startup insertion witness changed')
    if [record['accepted'] for record in godot_records] != [False, False, False, False, True]:
        raise ValueError('Godot atomic startup insertion violated')
    if [record['bytes'] for record in rust_records] != ['', '00', '00', '', '']:
        raise ValueError('upstream startup prefix bytes changed')
    return {'scenario_sha256': digest(fixture), 'rust': rust, 'godot': godot,
            'reason': 'Godot rejects the entire over-capacity initial prefix; upstream retains inserted default frames.'}


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/queue')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    manifest = load_manifest()
    trees = sources(manifest, args.offline)
    observed_manifest, observation = observation_source(trees['fortress'])
    cargo, _ = setup_rust(manifest, args.offline)
    command = [str(cargo), '+' + manifest['rust']['version'], 'build', '--locked',
               '--manifest-path', str(observed_manifest), '--bin', 'queue']
    if args.offline:
        command.append('--offline')
    execute(command, args.output / 'build.log', timeout=600)
    binary = CACHE / 'target/debug/queue'
    engine = args.godot.resolve()
    scenario = validate_bundle(bundle())
    fixture = args.output / 'bundle.json'
    fixture.write_text(json.dumps(scenario, indent=2) + '\n')
    names = [case['name'] for case in scenario['cases']]
    counts = [len(case['operations']) for case in scenario['cases']]
    rust_runs, godot_runs = [], []
    game_command = [str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/oracle/queue_trace.gd']
    for repetition in (1, 2):
        stdout, stderr = execute([str(binary)], args.output / f'rust-{repetition}.log', fixture.read_text())
        if stderr.strip():
            raise ValueError('queue oracle emitted unexpected stderr')
        rust_runs.append(json.loads(stdout))
        stdout, stderr = execute(game_command + ['--', '--bundle', str(fixture.resolve())], args.output / f'godot-{repetition}.log')
        godot_runs.append(parse_godot(stdout, stderr))
        compare(rust_runs[-1], godot_runs[-1], names, counts)
    compare(rust_runs[0], rust_runs[1], names, counts)
    compare(godot_runs[0], godot_runs[1], names, counts)
    # Process controls require each implementation to reject the whole artifact.
    controls = []
    for name, mutate in [('empty', lambda x: x.update(cases=[])), ('stale', lambda x: x.update(upstream_revision='stale')),
                          ('unknown', lambda x: x['cases'][0]['operations'][0].update(unknown=1)),
                          ('float', lambda x: x['cases'][0].update(capacity=2.5)),
                          ('floor-bool', lambda x: next(op for op in x['cases'][-1]['operations'] if op['kind'] == 'add_reclaim').update(floor=True))]:
        bad = copy.deepcopy(scenario)
        mutate(bad)
        control = args.output / f'control-{name}.json'
        control.write_text(json.dumps(bad))
        for implementation, cmd, stdin in [('rust', [str(binary)], control.read_text()),
                                            ('godot', game_command + ['--', '--bundle', str(control.resolve())], None)]:
            try:
                execute(cmd, args.output / f'control-{name}-{implementation}.log', stdin)
            except ValueError as error:
                if 'process failed (2)' not in str(error):
                    raise
                log = (args.output / f'control-{name}-{implementation}.log').read_text()
                required = 'queue oracle:' if implementation == 'rust' else 'queue oracle: invalid queue bundle'
                if required not in log or any(marker in log for marker in ('SCRIPT ERROR:', 'Parse Error:', 'FORTRESS_QUEUE_RESULT ')):
                    raise ValueError(f'{implementation} rejected {name} for unrelated reason')
            else:
                raise ValueError(f'{implementation} accepted {name} mutant')
        controls.append(name)
    divergence = startup_divergence(binary, game_command, args.output)
    version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    (args.output / 'rust-trace.json').write_text(json.dumps(rust_runs[0], indent=2) + '\n')
    (args.output / 'godot-trace.json').write_text(json.dumps(godot_runs[0], indent=2) + '\n')
    result = {'format': 1, 'passed': True, 'upstream_revision': manifest['sources']['fortress']['revision'],
              'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)),
              'engine': version.strip(), 'engine_sha256': digest(engine), 'platform': platform.platform(),
              'cases': len(names), 'operations': sum(counts), 'repeat_equal': True, 'controls': controls, 'reviewed_divergence': divergence,
              'observation': observation, 'upstream_archive': manifest['sources']['fortress']['archive'],
              'ordinary_cases': 705, 'reclaim_cases': len(names) - 705, 'features': [], 'default_features': False, 'binary_sha256': digest(binary),
              'oracle_lock_sha256': digest(ROOT / 'scripts/oracle/rust/Cargo.lock'),
              'bundle_sha256': digest(fixture), 'rust_trace_sha256': digest(args.output / 'rust-trace.json'),
              'godot_trace_sha256': digest(args.output / 'godot-trace.json'),
              'source_sha256': {str(path.relative_to(ROOT)): digest(path) for path in sorted(
                  list((ROOT / 'addons/fortress_rollback/core').glob('*.gd')) + list((ROOT / 'scripts/oracle').glob('queue_*.py'))
                  + [ROOT / 'scripts/oracle/rust/src/bin/queue.rs', ROOT / 'tests/oracle/queue_trace.gd', ROOT / 'scripts/reference/receipt_arguments.py'])},
              'limitations': ['Raw queue only; no session confirmation, prediction window, transport or rollback history.',
                              'Zero neutral input in differential corpus; custom neutral verified independently.',
                              'Upstream partial initial-gap capacity failure intentionally diverges: Godot rejects atomically.']}
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Queue parity: {len(names)} cases, {sum(counts)} operations, both engines repeated; {len(controls)} malformed controls per implementation")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
