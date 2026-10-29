#!/usr/bin/env python3
"""Compare original-history recovery through donor-data and commit loss twice per engine."""
import copy
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))
from fetch import CACHE, ROOT, digest, load_manifest, sources
from receipt_arguments import ReceiptParser
from run import setup_rust, rust_environment
from engine_path import resolve_engine
from launch import execute
from p2p_launch import source_files, upstream_inventory, executable_identity, require_unchanged
from drop_history_contract import history_bytes, compare, negative_controls, loss_evidence_controls, commit_loss_evidence_controls, require, REVISION

from drop_history_ack_controls import controls as ack_loss_evidence_controls

PREFIX = 'FORTRESS_DROP_HISTORY_RESULT '


def inventory():
    files = [*source_files(), ROOT / 'project.godot', ROOT / 'scripts/oracle/rust/src/bin/drop_history.rs',
             *(ROOT / 'tests/unit').glob('*.gd'), *(ROOT / 'tests/runner').glob('*.gd')]
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(set(files))}


def parse_godot(stdout, stderr):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('drop history: Godot engine error')
    records = [line[len(PREFIX):] for line in stdout.splitlines() if line.startswith(PREFIX)]
    if len(records) != 1:
        raise ValueError('drop history: missing/duplicate Godot completion')
    return json.loads(records[0])



def observation_controls(engine, output, source):
    controls = []
    for status, observed_status in [('none', 'none'), ('predicted', 'predicted'), ('unknown', None)]:
        result = subprocess.run([str(engine), '--headless', '--path', str(ROOT), '--script',
            'res://tests/oracle/drop_history_trace.gd', '--', '--observer-status', status],
            cwd=ROOT, env=rust_environment(), capture_output=True, text=True, encoding='utf-8', timeout=120)
        (output / f'observer-{status}.log').write_text(result.stdout + result.stderr)
        require(result.returncode == 1, 'observer control must refuse exported ' + status)
        godot = parse_godot(result.stdout, result.stderr)
        failure = {'kind': 'equality', 'label': 'observed finalized export status', 'expected': 'confirmed', 'actual': observed_status}
        comparison_failure = 'drop history: Godot assertion failures'
        if status == 'unknown':
            # FrameInputs refuses the malformed row with INVALID_CONFIGURATION before exposing bytes or status.
            failure = {'kind': 'equality', 'label': 'export actual finalized original input', 'expected': '0', 'actual': '6'}
            comparison_failure = 'drop history: Godot original rows, statuses or canonical states'
        require(godot['failures'] == [failure], 'observer control exact status diagnostic')
        unaffected = copy.deepcopy(godot)
        unaffected['failures'] = []
        if status == 'unknown':
            require(godot['survivors'][0]['rows'][0]['inputs'] == [], 'observer malformed row must not expose input bytes')
            unaffected['survivors'][0]['rows'][0]['inputs'] = source['survivors'][0]['rows'][0]['inputs']
        compare(source, unaffected)
        try:
            compare(source, godot)
        except ValueError as error:
            require(str(error) == comparison_failure, 'observer control unrelated comparison failure')
        else:
            raise ValueError('drop history: observer control survived: ' + status)
        controls.append('observed_export_' + status)
    return controls




def interior_history_control(engine, output, source, target_slots=1):
    result = subprocess.run([str(engine), '--headless', '--path', str(ROOT), '--script',
        'res://tests/oracle/drop_history_trace.gd', '--', '--multi-row-history', '--corrupt-interior-history',
        *(['--multiple-target-slots'] if target_slots == 2 else [])],
        cwd=ROOT, env=rust_environment(), capture_output=True, text=True, encoding='utf-8', timeout=120)
    (output / f'observer-interior-history-{target_slots}-targets.log').write_text(result.stdout + result.stderr)
    require(result.returncode == 0, 'interior control must reach completed playback')
    godot = parse_godot(result.stdout, result.stderr)
    require(godot['failures'] == [] and godot['cuts'] == [[11] * target_slots, [11] * target_slots], 'interior control must preserve agreed final cut')
    original = history_bytes(4, target_slots)
    changed = bytearray(original)
    stride = 4 * target_slots
    changed[stride], changed[2 * stride] = changed[2 * stride], changed[stride]
    receipts = godot['history_receipts']
    require(bool(receipts) and all(packet['bytes'] == changed.hex() for packet in receipts), 'interior control actual changed donor bytes')
    require(sum(changed) == sum(original) and changed[:4] == original[:4] and changed[-4:] == original[-4:],
            'interior control preserves endpoints and sum')
    expected_final = source['survivors'][0]['rows'][-1]['state']['bytes']
    require(all(survivor['rows'][-1]['state']['bytes'] == expected_final for survivor in godot['survivors']),
            'interior control must preserve original final canonical state')
    try:
        compare(source, godot, False, 4, target_slots)
    except ValueError as error:
        require(str(error) == 'drop history: Godot original rows, statuses or canonical states', 'interior control unrelated comparison failure')
    else:
        raise ValueError('drop history: interior history control survived')
    return 'observed_interior_history_permutation'



def build(command, log, rustc):
    environment = rust_environment()
    environment['RUSTC'] = str(rustc)
    environment.pop('CARGO_BUILD_RUSTC', None)
    log.write_text('COMMAND_STARTED: ' + repr(command) + '\n')
    result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                            text=True, encoding='utf-8', timeout=600)
    log.write_text(result.stdout + result.stderr)
    require(result.returncode == 0, 'pinned build failed; see ' + str(log))


def pinned_toolchain(cargo, version, output):
    rustup = cargo.with_name('rustup')
    identities = {'rustup': executable_identity(rustup)}
    paths = {'rustup': rustup}
    for tool in ('cargo', 'rustc'):
        require_unchanged('rustup executable', identities['rustup'], executable_identity(rustup))
        stdout, stderr = execute([str(rustup), 'which', '--toolchain', version, tool], output / f'{tool}-path.log')
        require(not stderr.strip() and len(stdout.splitlines()) == 1, 'pinned tool resolution: ' + tool)
        path = Path(stdout.strip())
        require(path.is_absolute(), 'absolute pinned tool path: ' + tool)
        paths[tool] = path
        identities[tool] = executable_identity(path)
    return paths, identities


def verify_tools(paths, identities):
    for tool, path in paths.items():
        require_unchanged(tool + ' executable', identities[tool], executable_identity(path))


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', required=True)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/drop-history')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    local_sources = inventory()
    manifest = load_manifest()
    trees = sources(manifest, offline=args.offline)
    pinned_sources = upstream_inventory(trees['fortress'])
    engine = resolve_engine(args.godot)
    engine_identity = executable_identity(engine)
    cargo, _ = setup_rust(manifest, args.offline)
    version = manifest['rust']['version']
    tool_paths, tool_identities = pinned_toolchain(cargo, version, args.output)
    verify_tools(tool_paths, tool_identities)
    cargo_version, _ = execute([str(tool_paths['cargo']), '--version'], args.output / 'cargo-version.log')
    rust_version, _ = execute([str(tool_paths['rustc']), '--version'], args.output / 'rustc-version.log')
    engine_version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    if not engine_version.startswith(('4.3.stable', '4.7.2.stable')):
        raise ValueError('drop history: unsupported engine profile')
    command = [str(tool_paths['cargo']), 'build', '--locked', '--manifest-path',
               str(ROOT / 'scripts/oracle/rust/Cargo.toml'), '--bin', 'drop_history']
    if args.offline:
        command.append('--offline')
    verify_tools(tool_paths, tool_identities)
    build(command, args.output / 'build.log', tool_paths['rustc'])
    verify_tools(tool_paths, tool_identities)
    binary = CACHE / 'target/debug/drop_history'
    binary_identity = executable_identity(binary)
    observed = []
    evidence = {}
    controls = []
    for repeat in (1, 2):
        scenarios = {}
        for name, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss in [
                ('clean', False, 1, 1, False, False, False), ('lost-history', True, 1, 1, False, False, False),
                ('multi-clean', False, 4, 1, False, False, False), ('multi-lost-history', True, 4, 1, False, False, False),
                ('grouped-clean', False, 4, 2, False, False, False), ('grouped-lost-history', True, 4, 2, False, False, False),
                ('unequal-clean', False, 4, 2, True, False, False), ('unequal-lost-history', True, 4, 2, True, False, False),
                ('unequal-lost-commit', False, 4, 2, True, True, False), ('unequal-lost-history-and-commit', True, 4, 2, True, True, False),
                ('unequal-lost-ack', False, 4, 2, True, False, True),
                ('unequal-lost-history-commit-and-ack', True, 4, 2, True, True, True)]:
            fault_args = ['--drop-first-history'] if loss else []
            if ack_loss:
                fault_args.append('--drop-first-ack')
            if commit_loss:
                fault_args.append('--drop-first-commit')
            if missing_rows == 4:
                fault_args.append('--multi-row-history')
            if target_slots == 2:
                fault_args.append('--multiple-target-slots')
            if unequal:
                fault_args.append('--unequal-exposure')
            stdout, stderr = execute([str(binary), *fault_args], args.output / f'source-{name}-{repeat}.log')
            if stderr.strip():
                raise ValueError('drop history: unexpected source stderr')
            source = json.loads(stdout)
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                                      'res://tests/oracle/drop_history_trace.gd', '--', *fault_args],
                                      args.output / f'godot-{name}-{repeat}.log')
            godot = parse_godot(stdout, stderr)
            evidence[name] = compare(source, godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss)
            controls.extend(name + ':' + control for control in negative_controls(source, godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss))
            scenarios[name] = {'source': source, 'godot': godot}
        controls.extend(loss_evidence_controls(scenarios['clean'], scenarios['lost-history']))
        controls.extend('multi:' + control for control in loss_evidence_controls(scenarios['multi-clean'], scenarios['multi-lost-history'], 4))
        controls.extend('grouped:' + control for control in loss_evidence_controls(
            scenarios['grouped-clean'], scenarios['grouped-lost-history'], 4, 2))
        controls.extend('unequal:' + control for control in loss_evidence_controls(
            scenarios['unequal-clean'], scenarios['unequal-lost-history'], 4, 2, True))
        controls.extend(commit_loss_evidence_controls(scenarios['unequal-clean'], scenarios['unequal-lost-commit']))
        controls.extend(ack_loss_evidence_controls(scenarios['unequal-clean'], scenarios['unequal-lost-ack']))
        observed.append(scenarios)
    if observed[0] != observed[1]:
        raise ValueError('drop history: fresh-process repeat mismatch')
    controls = sorted(set(controls))
    controls.extend(observation_controls(engine, args.output, observed[0]['clean']['source']))
    controls.append(interior_history_control(engine, args.output, observed[0]['multi-clean']['source']))
    controls.append('grouped:' + interior_history_control(engine, args.output, observed[0]['grouped-clean']['source'], 2))
    require_unchanged('local source inventory', local_sources, inventory())
    require_unchanged('upstream source inventory', pinned_sources, upstream_inventory(trees['fortress']))
    require_unchanged('Godot executable', engine_identity, executable_identity(engine))
    require_unchanged('drop oracle executable', binary_identity, executable_identity(binary))
    verify_tools(tool_paths, tool_identities)
    records = args.output / 'comparison.json'
    records.write_text(json.dumps(observed[0], indent=2) + '\n')
    receipt.write_text(json.dumps({'format': 1, 'complete': True, 'passed': True, 'upstream_revision': REVISION,
        'upstream_archive_sha256': manifest['sources']['fortress']['archive']['digest'],
        'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'), 'upstream_source_sha256': pinned_sources,
        'source_sha256': local_sources, 'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, encoding='utf-8').strip(),
        'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, encoding='utf-8')),
        'engine': engine_version.strip(), 'engine_identity': engine_identity, 'binary_identity': binary_identity,
        'cargo': cargo_version.strip(), 'rustc': rust_version.strip(), 'tool_identities': tool_identities, 'default_features': False, 'features': [],
        'execution_identities_unchanged': True, 'fresh_process_repeat_equal': True, 'comparison_sha256': digest(records),
        'evidence': evidence, 'negative_controls': controls,
        'scope': ('Paired one/four-row single-target and four-row two-target clean/lost-first-history three-endpoint original-history/cut scenarios: source explicit removal; '
                  'Godot elapsed timeout; equal and unequal exposed frontiers; first-COMMIT/ACK loss alone and combined with donor-data loss; '
                  'distinct non-interoperable wires.')}, indent=2) + '\n')
    print('drop history: two survivors preserve twenty original canonical prefixes and statuses through '
          'one/four-row single/two-target donor recovery and lost irreversible commits/acknowledgements, twice', flush=True)


if __name__ == '__main__':
    main()
