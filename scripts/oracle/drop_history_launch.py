#!/usr/bin/env python3
"""Compare one actual upstream/Godot missing-history donor scenario twice per engine."""
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
from drop_history_contract import compare, negative_controls, require, REVISION

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
    for status, observed_status in [('none', 'none'), ('predicted', 'predicted'), ('unknown', 'unknown:42')]:
        result = subprocess.run([str(engine), '--headless', '--path', str(ROOT), '--script',
            'res://tests/oracle/drop_history_trace.gd', '--', '--observer-status', status],
            cwd=ROOT, env=rust_environment(), capture_output=True, text=True, encoding='utf-8', timeout=120)
        (output / f'observer-{status}.log').write_text(result.stdout + result.stderr)
        require(result.returncode == 1, 'observer control must refuse exported ' + status)
        godot = parse_godot(result.stdout, result.stderr)
        require(godot['failures'] == [{'kind': 'equality', 'label': 'observed finalized export status',
                                     'expected': 'confirmed', 'actual': observed_status}], 'observer control exact status diagnostic')
        try:
            compare(source, godot)
        except ValueError as error:
            require(str(error) == 'drop history: Godot assertion failures', 'observer control unrelated comparison failure')
        else:
            raise ValueError('drop history: observer control survived: ' + status)
        controls.append('observed_export_' + status)
    return controls




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
    for repeat in (1, 2):
        stdout, stderr = execute([str(binary)], args.output / f'source-{repeat}.log')
        if stderr.strip():
            raise ValueError('drop history: unexpected source stderr')
        source = json.loads(stdout)
        stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                                  'res://tests/oracle/drop_history_trace.gd'], args.output / f'godot-{repeat}.log')
        godot = parse_godot(stdout, stderr)
        evidence = compare(source, godot)
        controls = negative_controls(source, godot)
        observed.append({'source': source, 'godot': godot})
    if observed[0] != observed[1]:
        raise ValueError('drop history: fresh-process repeat mismatch')
    controls.extend(observation_controls(engine, args.output, observed[0]['source']))
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
        'scope': 'One three-peer original-history/cut scenario: source explicit removal; Godot elapsed timeout; distinct non-interoperable wires.'}, indent=2) + '\n')
    print('drop history: two survivors preserve twenty original canonical prefixes and statuses through donor recovery, twice', flush=True)


if __name__ == '__main__':
    main()
