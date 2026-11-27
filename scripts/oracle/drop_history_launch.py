#!/usr/bin/env python3
"""Compare original-history recovery through inventory, donor-data and commit loss twice per engine."""
import copy
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))
from fetch import CACHE, ROOT, digest, load_manifest, sources
from receipt_arguments import OwnedReceiptParser
from run import setup_rust, rust_environment
from engine_path import resolve_engine
from launch import execute, git_identity, require_unchanged
from p2p_launch import source_files, upstream_inventory, executable_identity
from drop_history_contract import history_bytes, compare, negative_controls, loss_evidence_controls, commit_loss_evidence_controls, require, REVISION

from drop_history_contract import same, wrapped_evidence_controls
from drop_history_deadline import check_commit_deadline, deadline_controls
from drop_history_timeout import check_delivery_control, check_timeout, timeout_controls
import drop_failover_run
from drop_history_ack_controls import controls as ack_loss_evidence_controls
from drop_history_inventory_controls import controls as inventory_loss_evidence_controls
from source_build import prepare_source_build
from source_wire import RECOVERY_REVISION, decode_trace

PREFIX = 'FORTRESS_DROP_HISTORY_RESULT '


def inventory():
    files = [*source_files(), ROOT / 'project.godot', ROOT / 'scripts/oracle/rust/src/bin/drop_history.rs',
             *(ROOT / 'tests/unit').glob('*.gd'), *(ROOT / 'tests/runner').glob('*.gd'),
             drop_failover_run.SCHEDULE, drop_failover_run.PROBES, drop_failover_run.RUST_OBSERVER]
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(set(files))}


def parse_godot(stdout, stderr, prefix=PREFIX):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('drop history: Godot engine error')
    records = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(records) != 1:
        raise ValueError('drop history: missing/duplicate Godot completion')
    return decode_trace(records[0])



def observation_controls(engine, output, source, source_revision):
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
        compare(source, unaffected, source_revision=source_revision)
        try:
            compare(source, godot, source_revision=source_revision)
        except ValueError as error:
            require(str(error) == comparison_failure, 'observer control unrelated comparison failure')
        else:
            raise ValueError('drop history: observer control survived: ' + status)
        controls.append('observed_export_' + status)
    return controls




def prepare_publication_control(engine, output):
    # A prepare recorded at its publication seam but never routed must be caught
    # by the fixture's own completeness assertion, before any Python comparison.
    result = subprocess.run([str(engine), '--headless', '--path', str(ROOT), '--script',
        'res://tests/oracle/drop_history_trace.gd', '--', '--unrouted-prepare'],
        cwd=ROOT, env=rust_environment(), capture_output=True, text=True, encoding='utf-8', timeout=120)
    (output / 'observer-unrouted-prepare.log').write_text(result.stdout + result.stderr)
    require(result.returncode == 1, 'unrouted prepare control must fail the fixture')
    godot = parse_godot(result.stdout, result.stderr)
    failure = {'kind': 'equality', 'label': 'every accepted observed control reaches owned routing', 'expected': 'true', 'actual': 'false'}
    require(godot['failures'] == [failure], 'unrouted prepare control exact completeness diagnostic')
    return 'observed_unrouted_prepare'


def interior_history_control(engine, output, source, target_slots=1, *, source_revision):
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
        compare(source, godot, False, 4, target_slots, source_revision=source_revision)
    except ValueError as error:
        require(str(error) == 'drop history: Godot original rows, statuses or canonical states', 'interior control unrelated comparison failure')
    else:
        raise ValueError('drop history: interior history control survived')
    return 'observed_interior_history_permutation'



def donor_timeout_evidence(engine, binary, output, source_revision):
    results = []
    for repeat in (1, 2):
        stdout, stderr = execute([str(binary), '--drop-all-history'], output / f'source-donor-timeout-{repeat}.log')
        require(not stderr.strip(), 'source donor timeout stderr')
        source = decode_trace(stdout)
        stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                                  'res://tests/oracle/drop_history_trace.gd', '--', '--drop-all-history'],
                                  output / f'godot-donor-timeout-{repeat}.log')
        godot = parse_godot(stdout, stderr)
        check_timeout(source, godot, source_revision=source_revision)
        stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                                  'res://tests/oracle/drop_history_trace.gd', '--', '--deliver-all-history'],
                                  output / f'godot-donor-delivery-control-{repeat}.log')
        delivered = parse_godot(stdout, stderr)
        check_delivery_control(delivered, godot)
        results.append({'source': source, 'godot': godot, 'godot_delivery_control': delivered})
    require(same(*results), 'donor timeout fresh-process repeat mismatch')
    result = results[0]
    source, godot, delivered = (result[key] for key in ('source', 'godot', 'godot_delivery_control'))
    return (result, check_timeout(source, godot, source_revision=source_revision),
            timeout_controls(source, godot, delivered, source_revision=source_revision))



def deadline_evidence(engine, binary, output, source_revision):
    cases = {}
    for offset in (-1, 0, 1):
        case = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary), '--commit-deadline', str(offset)], output / f'source-commit-deadline-{offset}-{repeat}.log')
            require(not stderr.strip(), 'source COMMIT deadline stderr')
            observed = decode_trace(stdout)
            check_commit_deadline(observed, offset, source_revision=source_revision)
            case.append(observed)
        require(same(*case), 'source COMMIT deadline fresh-process repeat mismatch')
        cases[str(offset)] = case[0]
    suite = 'res://tests/unit/test_peer_drop_commit.gd'
    stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/runner/run_tests.gd',
                              '--', '--suite', suite, '--case', 'commit_deadline'], output / 'godot-commit-deadline.log')
    godot = parse_godot(stdout, stderr, 'FORTRESS_TEST_RESULT ')
    require(godot.get('passed') is True and godot.get('complete') is True and len(godot.get('records', [])) == 1, 'Godot COMMIT deadline case')
    record = godot['records'][0]
    require(record.get('suite') == suite and record.get('case') == 'commit_deadline' and record.get('seed') == '1701'
            and len(record.get('runs', [])) == 2 and same(*record['runs'])
            and record['runs'][0].get('assertions', 0) > 0 and record['runs'][0].get('failures') == [], 'Godot COMMIT deadline repeat')

    return {'source': cases, 'godot': record}, deadline_controls(cases, source_revision=source_revision)


def build(command, log, rustc, source_revision):
    environment = rust_environment()
    environment['RUSTC'] = str(rustc)
    environment['FORTRESS_DROP_ORACLE_REVISION'] = source_revision
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


def select_source(manifest, source_revision, offline):
    pin = manifest['sources']['fortress']
    if source_revision == pin['revision']:
        return sources(manifest, offline=offline)['fortress'], pin['archive']['digest']
    require(source_revision == RECOVERY_REVISION, 'unsupported candidate revision')
    candidate = copy.deepcopy(manifest)
    candidate_pin = candidate['sources']['fortress']
    candidate_pin.update(revision=source_revision, root='fortress-rollback-' + source_revision)
    archive = {'url': pin['archive']['url'].rsplit('/', 1)[0] + '/' + source_revision, 'algorithm': 'sha256',
               'digest': 'ae67b3b5be6f9061e53356cf1c1402c4d2c30991e0bd2aafd66c7d986df32856'}
    candidate_pin['archive'] = archive
    candidate['sources'] = {'fortress': candidate_pin}
    candidate['rust']['lockfile_sha256'] = '2643529601aab0a25302bf8455b40ee352cd00576cc85c75256af22470e1caef'
    tree = sources(candidate, offline=offline, cache=CACHE / ('drop-source-' + source_revision))['fortress']
    return tree, archive['digest']


def build_observer(tool_paths, output, source_tree, source_revision, offline, *, coordinator_failover=False):
    base = ROOT / 'scripts/oracle/rust/Cargo.toml'
    manifest = prepare_source_build(base, source_tree, source_revision, CACHE)
    adapter_hashes = upstream_inventory(manifest.parent)
    command = [str(tool_paths['cargo']), 'build', '--locked', '--bin', 'drop_history', '--manifest-path', str(manifest)]
    if coordinator_failover:
        command += ['--features', 'coordinator-failover']
    if offline:
        command.append('--offline')
    target = CACHE / 'target'
    if manifest != base:
        target = target / ('drop-history-' + source_revision)
        command += ['--target-dir', str(target)]
    build(command, output / 'build.log', tool_paths['rustc'], source_revision)
    return target / 'debug/drop_history', manifest.parent, adapter_hashes


def main():
    parser = OwnedReceiptParser(description=__doc__, receipt='receipt.json', variants={'--coordinator-failover': drop_failover_run.RECEIPT})
    parser.add_argument('--godot', required=True)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--coordinator-failover', action='store_true', help='qualify the v6 candidate on the shared five-peer silence schedule')
    parser.add_argument('--source-revision', choices=(REVISION, RECOVERY_REVISION), help='select an exact registered Fortress source revision')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/drop-history')
    args = parser.parse_args()
    with parser.claim_output(args.output):
        return run(args)


def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / (drop_failover_run.RECEIPT if args.coordinator_failover else 'receipt.json')
    receipt.unlink(missing_ok=True)
    identity = git_identity()
    local_sources = inventory()
    manifest = load_manifest()
    pin = manifest['sources']['fortress']
    source_revision = args.source_revision or (RECOVERY_REVISION if args.coordinator_failover else pin['revision'])
    if args.coordinator_failover:
        require(source_revision == RECOVERY_REVISION, 'coordinator failover requires the exact v6 candidate')
    source_tree, archive_digest = select_source(manifest, source_revision, args.offline)
    pinned_sources = upstream_inventory(source_tree)
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
    verify_tools(tool_paths, tool_identities)
    binary, adapter, adapter_hashes = build_observer(
        tool_paths, args.output, source_tree, source_revision, args.offline,
        coordinator_failover=args.coordinator_failover)
    verify_tools(tool_paths, tool_identities)
    binary_identity = executable_identity(binary)

    def verify_identity():
        require_unchanged('local source inventory', local_sources, inventory())
        require_unchanged('upstream source inventory', pinned_sources, upstream_inventory(source_tree))
        require_unchanged('Cargo adapter inventory', adapter_hashes, upstream_inventory(adapter))
        require_unchanged('Godot executable', engine_identity, executable_identity(engine))
        require_unchanged('drop oracle executable', binary_identity, executable_identity(binary))
        require_unchanged('repository identity', identity, git_identity())
        verify_tools(tool_paths, tool_identities)

    def provenance():
        return {'format': 1, 'complete': True, 'passed': True, 'upstream_revision': source_revision,
            'upstream_archive_sha256': archive_digest,
            'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'), 'upstream_source_sha256': pinned_sources,
            'source_sha256': local_sources, 'commit': identity['commit'],
            'working_tree_dirty': identity['working_tree_dirty'],
            'engine': engine_version.strip(), 'engine_identity': engine_identity, 'binary_identity': binary_identity,
            'cargo': cargo_version.strip(), 'rustc': rust_version.strip(), 'tool_identities': tool_identities, 'default_features': False, 'features': [],
            'execution_identities_unchanged': True}

    if args.coordinator_failover:
        observation = drop_failover_run.observe(engine, binary, args.output, parse_godot, tool_paths, source_tree, args.offline)
        verify_identity()
        receipt.write_text(json.dumps({**provenance(), 'observer_features': ['coordinator-failover'], **observation}, indent=2) + '\n')
        print('coordinator failover: source endpoint 1 certified cut 5; three Godot survivors timed out; all preserved rows 0–4, twice', flush=True)
        print('coordinator failover: exact grace boundary and addressed stale PREPARE and INVENTORY replay passed, twice', flush=True)
        return

    observed = []
    evidence = {}
    controls = []
    for repeat in (1, 2):
        scenarios = {}
        for name, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss, inventory_loss, prepare_loss, warmup in [
                ('clean', False, 1, 1, False, False, False, False, False, 0), ('lost-history', True, 1, 1, False, False, False, False, False, 0),
                ('multi-clean', False, 4, 1, False, False, False, False, False, 0), ('multi-lost-history', True, 4, 1, False, False, False, False, False, 0),
                ('grouped-clean', False, 4, 2, False, False, False, False, False, 0), ('grouped-lost-history', True, 4, 2, False, False, False, False, False, 0),
                ('unequal-clean', False, 4, 2, True, False, False, False, False, 0), ('unequal-lost-history', True, 4, 2, True, False, False, False, False, 0),
                ('unequal-lost-commit', False, 4, 2, True, True, False, False, False, 0), ('unequal-lost-history-and-commit', True, 4, 2, True, True, False, False, False, 0),
                ('unequal-lost-ack', False, 4, 2, True, False, True, False, False, 0),
                ('unequal-lost-history-commit-and-ack', True, 4, 2, True, True, True, False, False, 0),
                ('unequal-lost-inventory', False, 4, 2, True, False, False, True, False, 0),
                ('unequal-lost-inventory-history-commit-and-ack', True, 4, 2, True, True, True, True, False, 0),
                ('unequal-lost-prepare', False, 4, 2, True, False, False, False, True, 0),
                ('wrapped-clean', False, 4, 2, True, False, False, False, False, 251),
                ('wrapped-lost-inventory-history-commit-and-ack', True, 4, 2, True, True, True, True, False, 251)]:
            fault_args = ['--drop-first-history'] if loss else []
            if warmup:
                fault_args.append('--wrapped-history')
            if inventory_loss:
                fault_args.append('--drop-first-inventory')
            if prepare_loss:
                fault_args.append('--drop-first-prepare')
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
            source = decode_trace(stdout)
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                                      'res://tests/oracle/drop_history_trace.gd', '--', *fault_args],
                                      args.output / f'godot-{name}-{repeat}.log')
            godot = parse_godot(stdout, stderr)
            evidence[name] = compare(source, godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss, inventory_loss, warmup, prepare_loss,
                                     source_revision=source_revision)
            controls.extend(name + ':' + control for control in negative_controls(
                source, godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss, inventory_loss, warmup, prepare_loss,
                source_revision=source_revision))
            scenarios[name] = {'source': source, 'godot': godot}
        controls.extend(wrapped_evidence_controls(scenarios['unequal-clean'], scenarios['wrapped-clean'], source_revision=source_revision))
        controls.extend(loss_evidence_controls(scenarios['clean'], scenarios['lost-history'], source_revision=source_revision))
        controls.extend('multi:' + control for control in loss_evidence_controls(
            scenarios['multi-clean'], scenarios['multi-lost-history'], 4, source_revision=source_revision))
        controls.extend('grouped:' + control for control in loss_evidence_controls(
            scenarios['grouped-clean'], scenarios['grouped-lost-history'], 4, 2, source_revision=source_revision))
        controls.extend('unequal:' + control for control in loss_evidence_controls(
            scenarios['unequal-clean'], scenarios['unequal-lost-history'], 4, 2, True, source_revision=source_revision))
        controls.extend(commit_loss_evidence_controls(scenarios['unequal-clean'], scenarios['unequal-lost-commit'], source_revision=source_revision))
        controls.extend(ack_loss_evidence_controls(scenarios['unequal-clean'], scenarios['unequal-lost-ack'], source_revision=source_revision))
        controls.extend(inventory_loss_evidence_controls(scenarios['unequal-clean'], scenarios['unequal-lost-inventory'], source_revision=source_revision))
        observed.append(scenarios)
    if observed[0] != observed[1]:
        raise ValueError('drop history: fresh-process repeat mismatch')
    controls = sorted(set(controls))
    controls.extend(observation_controls(engine, args.output, observed[0]['clean']['source'], source_revision))
    controls.append(prepare_publication_control(engine, args.output))
    controls.append(interior_history_control(engine, args.output, observed[0]['multi-clean']['source'], source_revision=source_revision))
    controls.append('grouped:' + interior_history_control(engine, args.output, observed[0]['grouped-clean']['source'], 2, source_revision=source_revision))
    deadline, rejected_deadlines = deadline_evidence(engine, binary, args.output, source_revision)
    controls.extend(rejected_deadlines)
    timeout, timeout_summary, rejected_timeouts = donor_timeout_evidence(engine, binary, args.output, source_revision)
    controls.extend(rejected_timeouts)
    verify_identity()
    records = args.output / 'comparison.json'
    records.write_text(json.dumps({**observed[0], 'commit-deadline': deadline, 'donor-timeout': timeout}, indent=2) + '\n')
    receipt.write_text(json.dumps({**provenance(), 'fresh_process_repeat_equal': True, 'comparison_sha256': digest(records),
        'evidence': evidence, 'commit_deadline': {offset: outcome['advance'] for offset, outcome in deadline['source'].items()},
        'donor_timeout_retries_discarded': timeout_summary, 'negative_controls': controls,
        'scope': ('Paired one/four-row single-target and four-row two-target clean/lost-first-history three-endpoint original-history/cut scenarios: source explicit removal; '
                  'Godot elapsed timeout; equal and unequal exposed frontiers; first-prepare loss alone; first-inventory/COMMIT/ACK loss alone or combined with donor data; '
                  'prepare publications are paired with their routing; '
                  '251-frame warmup wraps the original queues before equal-policy donor recovery; distinct non-interoperable wires. '
                  'Every barrier payload names its carried roster digest; the coordinator survivor-link proposal is compared byte-exact '
                  'against the pinned participants.')}, indent=2) + '\n')
    print('drop history: two survivors preserve twenty original canonical prefixes and statuses through '
          'one/four-row single/two-target donor recovery and lost inventory/commits/acknowledgements, twice', flush=True)
    print('drop history: source and Godot commit before the deadline and refuse at equality and after', flush=True)
    print(f'drop history: all donor retries lost ({timeout_summary}); both survivors preserve exposed history and refuse advancement', flush=True)


if __name__ == '__main__':
    main()
