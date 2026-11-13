#!/usr/bin/env python3
"""Compare the pinned SyncLayer and the shipped session on the global-floor schedule.

The launcher drives the tests/unit/test_rollback.gd::global_floor schedule through both
session engines in fresh processes: three players, prediction window four, capacity nine,
a fast queue receiving ahead of the session, a three-frame lagger and a delay raise during
active prediction. The pinned crate is compiled from a verified isolated copy carrying one
access-only wrapper block; the shipped session runs unchanged. The comparison covers every
ordered request and canonical state, each recorded accept or refusal, and the floor,
occupancy, confirmed-floor and recoverable-floor observations. A mutant build that replaces
the global floor with the fast player's local high-water must accept the above-floor add
the clean floor refuses at the frame-twelve boundary, the comparison's first divergence.
"""
import copy
import json
from pathlib import Path
import platform
import hashlib
import shutil
import tempfile

from launch import ROOT, CACHE, execute, digest, load_manifest, sources, setup_rust, git_identity, require_unchanged
from engine_path import resolve_engine
from fetch import retain_verified_tree
from receipt_arguments import ReceiptParser
from sync_floor_contract import compare, first_acceptance_divergence
from sync_floor_corpus import bundle, validate_bundle

REVISION = 'd124c89080004d96971a629bb0427056ee1805e3'
SYNC_LAYER_SOURCE = Path('src/sync_layer/mod.rs')
QUEUE_SOURCE = Path('src/input_queue/mod.rs')
FAST_FLOOR_SEARCH = """    fn rollback_window_floor(&self) -> Frame {
        let prediction = i32::try_from(self.max_prediction).unwrap_or(i32::MAX);
        Frame::new(
            self.current_frame
                .as_i32()
                .saturating_sub(prediction)
                .max(0),
        )
    }
"""
FAST_FLOOR_REPLACE = """    fn rollback_window_floor(&self) -> Frame {
        let high_water = self
            .input_queues
            .get(1)
            .map_or(Frame::new(0), |queue: &InputQueue<T>| queue.oracle_fast_high_water());
        Frame::new(high_water.as_i32().max(0))
    }
"""

# Mutant-only access wrapper: exposes the fast queue's local high-water so the mutated
# floor can use it. Lives in the queue module because the field is module-private.
QUEUE_MUTANT_HOOK = """
// Mutant-only access wrapper appended by sync_floor_launch.py.
impl<T: Config> InputQueue<T> {
    pub fn oracle_fast_high_water(&self) -> Frame {
        self.last_added_frame
    }
}
"""

# The queue's recoverable-history lookup is private; one read-only wrapper exposes it
# to the sync-layer observation block without changing any queue path.
QUEUE_RETAINED_HOOK = """
// Access-only oracle wrapper appended by sync_floor_launch.py.
impl<T: Config> InputQueue<T> {
    pub fn oracle_retained_confirmed(&self, frame: Frame) -> Option<PlayerInput<T::Input>> {
        self.retained_confirmed_input(frame).ok()
    }
}
"""

# The confirmed-frame bookkeeping wrapper reproduces these pinned setter clamps;
# each anchor must occur exactly once in the pinned source, so a drift in the
# clamps the wrapper mirrors fails the run instead of diverging silently.
CONFIRM_ANCHORS = (
    """        // never delete stuff ahead of the current frame
        frame = std::cmp::min(frame, self.current_frame());""",
    """            .map(InputQueue::first_incorrect_frame)
            .fold(Frame::NULL, std::cmp::max);""",
    "        if !first_incorrect.is_null() && first_incorrect < frame {",
)

# Observation wrappers only: each delegates to an unchanged pinned path, reads
# private engine state read-only, or stages the confirmed-frame bookkeeping
# exactly as the pinned setter assigns it after clamps. None of them reclaim
# queue rows outside the completion floor trim the harness performs.
OBSERVATION_HOOK = """
// Access-only oracle wrappers appended by sync_floor_launch.py.
impl<T: Config> SyncLayer<T> {
    pub fn oracle_floor(&self) -> i32 {
        self.rollback_window_floor().as_i32()
    }
    pub fn oracle_add_local(&mut self, player: usize, frame: i32, input: T::Input) -> i32 {
        self.add_local_input(PlayerHandle::new(player), PlayerInput { frame: Frame::new(frame), input }).as_i32()
    }
    pub fn oracle_add_remote(&mut self, player: usize, frame: i32, input: T::Input) -> bool {
        self.add_remote_input(PlayerHandle::new(player), PlayerInput { frame: Frame::new(frame), input })
    }
    pub fn oracle_last_added(&self, player: usize) -> Result<i32, FortressError> {
        self.last_added_frame(PlayerHandle::new(player)).map(|frame| frame.as_i32())
    }
    pub fn oracle_consistency(&self) -> i32 {
        let first = self.check_simulation_consistency(Frame::NULL);
        if first.is_null() { -1 } else { first.as_i32() }
    }
    pub fn oracle_confirm(&mut self, confirmed: i32) {
        // The Session books the confirmed frame without the facade's pre-advance
        // discard pass; the completion floor trim is the engine's only reclaim.
        // The pinned setter's clamps are reproduced: never ahead of the current
        // frame and never past a pending first-incorrect frame.
        let mut frame = Frame::new(confirmed);
        let current = self.current_frame;
        if frame > current {
            frame = current;
        }
        let first_incorrect = self
            .input_queues
            .iter()
            .map(InputQueue::first_incorrect_frame)
            .fold(Frame::NULL, std::cmp::max);
        if !first_incorrect.is_null() && first_incorrect < frame {
            frame = first_incorrect;
        }
        self.last_confirmed_frame = frame;
    }
    pub fn oracle_synchronized(&mut self, connect: &[ConnectionStatus]) -> Option<Vec<(T::Input, u8)>> {
        self.synchronized_inputs(connect).map(|inputs| {
            inputs.iter().map(|(input, status)| (*input, match status {
                InputStatus::Confirmed => 0_u8,
                InputStatus::Predicted => 1,
                InputStatus::Disconnected => 2,
            })).collect()
        })
    }
    pub fn oracle_confirmed(&self, player: usize, frame: i32) -> Option<T::Input> {
        self.input_queues.get(player)?.confirmed_input(Frame::new(frame)).ok().map(|row| row.input)
    }
    pub fn oracle_retained(&self, player: usize, frame: i32) -> Option<T::Input> {
        self.input_queues.get(player)?.oracle_retained_confirmed(Frame::new(frame)).map(|row| row.input)
    }
    pub fn oracle_range(&self, player: usize) -> Option<(i32, i32)> {
        self.input_queues.get(player)?.retained_input_range().map(|span| (span.first.as_i32(), span.last.as_i32()))
    }
    pub fn oracle_discard_floor(&mut self, floor: i32) {
        for queue in self.input_queues.iter_mut() {
            queue.discard_confirmed_frames(Frame::new(floor));
        }
    }
}
"""


def publish_tree(source, destination, edits):
    """Publish a disposable verified copy of the pinned tree with access-only edits."""
    workspace = CACHE / 'sync-floor-observation'
    workspace.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=workspace) as temporary:
        expected = Path(temporary) / destination.name
        shutil.copytree(source, expected)
        for relative, content in edits.items():
            (expected / relative).write_bytes(content)
        retain_verified_tree(expected, destination)
    return destination


def observed_source(tree):
    """Clean wrappers on the untouched sources; returns the tree and provenance."""
    original = (tree / SYNC_LAYER_SOURCE).read_bytes()
    for index, anchor in enumerate(CONFIRM_ANCHORS):
        if original.count(anchor.encode()) != 1:
            raise ValueError(f'confirmed-frame clamp anchor {index} changed in the pinned source')
    receipt = {'method': 'unchanged verified source plus access-only wrappers in isolated copy: '
                          'delegation over crate-private paths, read-only observations, and the '
                          'confirmed-frame bookkeeping reproducing the pinned setter clamps',
               'original_source_unmodified': True}
    edits = {}
    for relative, hook, stem in [(SYNC_LAYER_SOURCE, OBSERVATION_HOOK, 'sync_layer'), (QUEUE_SOURCE, QUEUE_RETAINED_HOOK, 'queue')]:
        original = (tree / relative).read_bytes()
        hooked = original + hook.encode()
        edits[relative] = hooked
        receipt[f'{stem}_original_sha256'] = hashlib.sha256(original).hexdigest()
        receipt[f'{stem}_hook_sha256'] = hashlib.sha256(hook.encode()).hexdigest()
        receipt[f'{stem}_observed_sha256'] = hashlib.sha256(hooked).hexdigest()
        receipt['original_source_unmodified'] &= (tree / relative).read_bytes() == original
    receipt['confirm_anchor_sha256'] = [hashlib.sha256(anchor.encode()).hexdigest() for anchor in CONFIRM_ANCHORS]
    upstream = publish_tree(tree, CACHE / 'sync-floor-observation' / 'fortress', edits)
    return upstream / 'Cargo.toml', receipt


def mutant_source(tree):
    """The fast-local-high-water floor mutant plus its queue access wrappers."""
    original = (tree / SYNC_LAYER_SOURCE).read_bytes()
    count = original.count(FAST_FLOOR_SEARCH.encode())
    if count != 1:
        raise ValueError('floor mutant anchor changed in the pinned source')
    hooked = original.replace(FAST_FLOOR_SEARCH.encode(), FAST_FLOOR_REPLACE.encode(), 1) + OBSERVATION_HOOK.encode()
    queue_original = (tree / QUEUE_SOURCE).read_bytes()
    queue_hooked = queue_original + QUEUE_MUTANT_HOOK.encode() + QUEUE_RETAINED_HOOK.encode()
    upstream = publish_tree(tree, CACHE / 'sync-floor-observation' / 'fortress-mutant', {
        SYNC_LAYER_SOURCE: hooked, QUEUE_SOURCE: queue_hooked})
    receipt = {
        'method': 'rollback_window_floor replaced with the fast player\'s local high-water in isolated copy',
        'mutant_search_sha256': hashlib.sha256(FAST_FLOOR_SEARCH.encode()).hexdigest(),
        'mutant_replaced_sha256': hashlib.sha256(FAST_FLOOR_REPLACE.encode()).hexdigest(),
        'mutant_sync_hook_sha256': hashlib.sha256(OBSERVATION_HOOK.encode()).hexdigest(),
        'mutant_queue_hook_sha256': hashlib.sha256((QUEUE_MUTANT_HOOK + QUEUE_RETAINED_HOOK).encode()).hexdigest(),
        'original_source_unmodified': (tree / SYNC_LAYER_SOURCE).read_bytes() == original,
    }
    return upstream / 'Cargo.toml', receipt


def build_manifest(observed_cargo_toml, binary_name):
    """Rewrite the dependency anchor to the given observed tree and add the binary."""
    original = (ROOT / 'scripts/oracle/rust/Cargo.toml').read_text()
    old = '../../../.cache/reference/fortress-rollback-' + 'd124c89080004d96971a629bb0427056ee1805e3'
    if original.count(old) != 1:
        raise ValueError('floor adapter dependency anchor changed')
    manifest = original.replace(old, str(observed_cargo_toml.parent))
    manifest += '\n[[bin]]\nname = ' + json.dumps(binary_name) + '\npath = ' + \
        json.dumps(str(ROOT / 'scripts/oracle/rust/src/bin/sync_floor.rs')) + '\n'
    return manifest


def write_adapter(name, manifest):
    adapter = CACHE / 'sync-floor-observation' / name
    adapter.mkdir(parents=True, exist_ok=True)
    (adapter / 'Cargo.toml').write_text(manifest)
    shutil.copyfile(ROOT / 'scripts/oracle/rust/Cargo.lock', adapter / 'Cargo.lock')
    return adapter / 'Cargo.toml'


def engine_artifact(scenario_data):
    """Engine inputs carry no oracle expectations; accept flags are validation knowledge."""
    stripped = copy.deepcopy(scenario_data)
    for operation in stripped['operations']:
        operation.pop('accepted', None)
        operation.pop('ok', None)
    return stripped


def parse_godot(stdout, stderr):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('sync floor: Godot engine error')
    prefix = 'FORTRESS_SYNC_FLOOR_RESULT '
    values = [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError('missing or duplicate floor completion')
    return values[0]


def run_mutant_control(binary, clean_rust, scenario_data, output):
    """The fast-high-water floor mutant must flip floor-protected acceptance results."""
    mutant_log = output / 'mutant-rust.log'
    try:
        stdout, stderr = execute([str(binary)], mutant_log, json.dumps(engine_artifact(scenario_data)))
    except ValueError as error:
        if 'process failed (2)' not in str(error):
            raise
        raise ValueError('floor mutant rejected the artifact instead of mis-reclaiming: ' + error) from error
    if stderr.strip():
        raise ValueError('floor mutant emitted unexpected stderr')
    mutant = json.loads(stdout)
    divergence = first_acceptance_divergence(clean_rust, mutant)
    if divergence is None:
        raise ValueError('floor mutant trace matched the clean trace')
    clean_record = clean_rust['operations'][divergence]
    mutant_record = mutant['operations'][divergence]
    source_operation = scenario_data['operations'][divergence]
    if source_operation['kind'] != 'receive' or source_operation['player'] != 1 \
            or source_operation['frame'] < 12 or source_operation['frame'] > 18:
        raise ValueError(f'floor mutant first diverged at unexpected operation {divergence}')
    if clean_record['accepted'] is not False or mutant_record['accepted'] is not True:
        raise ValueError(f'floor mutant diverged without flipping the refusal at operation {divergence}')
    return {'first_divergence_operation': divergence, 'controls': ['fast_local_high_water_floor']}


def artifact_control(scenario_data, mutate, name, binary, game_command, output):
    """Both implementations must refuse the whole mutated artifact."""
    bad = copy.deepcopy(scenario_data)
    mutate(bad)
    artifact = output / f'control-{name}.json'
    artifact.write_text(json.dumps(bad))
    for implementation, command, stdin in [
            ('rust', [str(binary)], json.dumps(bad)),
            ('godot', game_command + ['--', '--artifact', str(artifact.resolve())], None)]:
        try:
            execute(command, output / f'control-{name}-{implementation}.log', stdin)
        except ValueError as error:
            if 'process failed (2)' not in str(error):
                raise
            log = (output / f'control-{name}-{implementation}.log').read_text()
            required = 'oracle: ' if implementation == 'rust' else 'sync floor oracle: '
            if required not in log or 'FORTRESS_SYNC_FLOOR_RESULT ' in log:
                raise ValueError(f'{implementation} rejected {name} for an unrelated reason')
        else:
            raise ValueError(f'{implementation} accepted the {name} mutant')


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/sync-floor')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    identity = git_identity()
    source_paths = sorted(
        list((ROOT / 'scripts/oracle').rglob('*.py'))
        + list((ROOT / 'scripts/oracle/rust/src').rglob('*.rs'))
        + list((ROOT / 'tests/oracle').glob('*.gd'))
        + list((ROOT / 'addons/fortress_rollback/core').glob('*.gd'))
        + [ROOT / 'scripts/reference/fetch.py', ROOT / 'scripts/reference/run.py',
           ROOT / 'scripts/reference/owned_process.py', ROOT / 'scripts/reference/engine_path.py',
           ROOT / 'scripts/reference/receipt_arguments.py'])
    source_hashes = {str(path.relative_to(ROOT)): digest(path) for path in source_paths}
    engine = resolve_engine(args.godot)
    manifest = load_manifest()
    trees = sources(manifest, args.offline)
    observed_manifest, observation = observed_source(trees['fortress'])
    mutant_manifest, mutant_receipt = mutant_source(trees['fortress'])
    cargo, _ = setup_rust(manifest, args.offline)
    clean_adapter = write_adapter('adapter-clean', build_manifest(observed_manifest, 'sync_floor'))
    mutant_adapter = write_adapter('adapter-mutant', build_manifest(mutant_manifest, 'sync_floor_mutant'))
    clean_binary_identity = None
    for name, adapter, binary in [('sync_floor', clean_adapter, 'sync_floor'),
                                  ('sync_floor_mutant', mutant_adapter, 'sync_floor_mutant')]:
        command = [str(cargo), '+' + manifest['rust']['version'], 'build', '--locked',
                   '--manifest-path', str(adapter), '--bin', binary]
        if args.offline:
            command.append('--offline')
        execute(command, args.output / f'build-{name}.log', timeout=600)
        if name == 'sync_floor':
            clean_binary_identity = digest(CACHE / 'target/debug/sync_floor')
    clean_binary = CACHE / 'target/debug/sync_floor'
    mutant_binary = CACHE / 'target/debug/sync_floor_mutant'
    scenario_bundle = validate_bundle(bundle())
    scenario_data = scenario_bundle['scenario']
    baseline = [bytes.fromhex(state) for state in scenario_bundle['baseline']]
    artifact = args.output / 'scenario.json'
    artifact.write_text(json.dumps(engine_artifact(scenario_data)))
    artifact_text = artifact.read_text()
    game_command = [str(engine), '--headless', '--path', str(ROOT),
                    '--script', 'res://tests/oracle/sync_floor_trace.gd']
    rust_runs, godot_runs = [], []
    for repetition in (1, 2):
        stdout, stderr = execute([str(clean_binary)], args.output / f'rust-{repetition}.log', artifact_text)
        if stderr.strip():
            raise ValueError('floor oracle emitted unexpected stderr')
        rust_runs.append(json.loads(stdout))
        stdout, stderr = execute(game_command + ['--', '--artifact', str(artifact.resolve())],
                                 args.output / f'godot-{repetition}.log')
        godot_runs.append(parse_godot(stdout, stderr))
        compare(rust_runs[-1], godot_runs[-1], scenario_data, baseline)
    if rust_runs[0] != rust_runs[1] or godot_runs[0] != godot_runs[1]:
        raise ValueError('sync floor: fresh-process repeat mismatch')
    controls = ['fast_local_high_water_floor']
    run_mutant_control(mutant_binary, rust_runs[0], scenario_data, args.output)
    for name, mutate in [
            ('stale', lambda x: x.update(upstream_revision='stale')),
            ('unknown', lambda x: x['operations'][0].update(unknown=1)),
            ('float', lambda x: x.update(players=3.5)),
            ('width', lambda x: x['operations'][0].update(bytes='fff')),
            ('kind', lambda x: x['operations'][0].update(kind='quit'))]:
        artifact_control(engine_artifact(scenario_data), mutate, name, clean_binary, game_command, args.output)
        controls.append(name)
    version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    (args.output / 'rust-trace.json').write_text(json.dumps(rust_runs[0], indent=2) + '\n')
    (args.output / 'godot-trace.json').write_text(json.dumps(godot_runs[0], indent=2) + '\n')
    require_unchanged('local source inventory', source_hashes,
                      {str(path.relative_to(ROOT)): digest(path) for path in source_paths})
    require_unchanged('floor oracle binary', clean_binary_identity, digest(clean_binary))
    require_unchanged('repository identity', identity, git_identity())
    result = {'format': 1, 'passed': True, 'upstream_revision': REVISION,
              'commit': identity['commit'],
              'working_tree_dirty': identity['working_tree_dirty'],
              'engine': version.strip(), 'engine_sha256': digest(engine), 'engine_path': str(engine),
              'platform': platform.platform(),
              'operations': len(scenario_data['operations']), 'repeat_equal': True,
              'controls': controls, 'observation': observation, 'mutant': mutant_receipt,
              'binary_sha256': digest(clean_binary), 'mutant_binary_sha256': digest(mutant_binary),
              'oracle_lock_sha256': digest(ROOT / 'scripts/oracle/rust/Cargo.lock'),
              'scenario_sha256': digest(artifact),
              'rust_trace_sha256': digest(args.output / 'rust-trace.json'),
              'godot_trace_sha256': digest(args.output / 'godot-trace.json'),
              'source_sha256': source_hashes,
              'limitations': ['The harness mirrors the pinned P2P facade advance sequence with protocol polling omitted.',
                              'The two identical upstream frame-0 saves collapse to one same-frame save.',
                              'The completion trim mirrors the Session floor discard; the facade discards pre-advance at confirmed-1.',
                              'The Session receipt boundary owns sequential and retained-repeat dedup for remote rows.',
                              'Remote receipts carry scheduled frames; the contract pins zero remote delay.']}
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Sync floor: {len(scenario_data['operations'])} operations, both engines repeated, "
          f"{len(controls)} controls including the fast-high-water floor mutant")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
