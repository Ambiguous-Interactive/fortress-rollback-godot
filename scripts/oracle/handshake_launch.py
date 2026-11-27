#!/usr/bin/env python3
"""Run actual pinned upstream P2P handshake and production Godot byte endpoint twice."""
import json
import hashlib
from pathlib import Path
import subprocess
from copy import deepcopy
import sys

from handshake_contract import compare, project, negative_controls, raw_negative_controls
from launch import ROOT, execute, git_identity, require_unchanged
from handshake_formal import check as check_formal
from tlc_artifact import ARTIFACT, ensure_jar
from fetch import digest, parse_manifest, sources
from receipt_arguments import ReceiptParser
from run import CACHE, setup_rust, rust_environment
from engine_path import resolve_engine
from source_build import prepare_source_build, source_build_environment, upstream_inventory
from source_wire import REVIEWED_REVISION, decode_trace, wire_version


def scenarios(*, source_revision=REVIEWED_REVISION):
    def op(kind, time, token=None, **kwargs):
        value = {'kind': kind, 'now_us': time}
        if token is not None:
            value['token_index'] = token
        return dict(value, **kwargs)
    result = {
        'model_matching': [op('poll', 200001), op('reply', 200002, 0), op('reply', 200003, 0), op('reply', 200004, 2), op('reply', 200005, 1)],
        'duplicate': [op('reply', 1, 0), op('reply', 2, 0), op('reply', 3, 1), op('reply', 4, 0)],
        'reordered': [op('poll', 200000), op('poll', 200001), op('reply', 200002, 1), op('reply', 200003, 0), op('reply', 200004, 2)],
        'timeout_retry': [op('poll', 200000), op('poll', 200001), op('poll', 1000000), op('poll', 1000001), op('poll', 1000002),
                          op('reply', 1000003, 0), op('reply', 1000004, 1)],
        'request_then_reply': [op('request', 1, 0), op('reply', 2, 0), op('reply', 3, 2)],
        'unknown_echo': [op('reply', 1, 0, echo=42, changes={'fps': 61}), op('reply', 2, 0), op('reply', 3, 1)],
        'wrong_source': [op('reply', 1, 0, source='stranger'), op('reply', 2, 0), op('reply', 3, 1)],
        'wrong_connection': [op('reply', 1, 0), op('reply', 2, 1, connection=78), op('reply', 3, 1)],
        'reply_refreshes_retry': [op('request', 190000, 0), op('poll', 201000), op('poll', 390000), op('poll', 390001)],
    }
    changes = {'min_compat_version': wire_version(source_revision) + 1, 'num_players': 3, 'input_bytes_per_player': 8, 'fps': 61, 'max_prediction': 9,
               'desync_interval': 61, 'features': 1, 'config_digest': 0}
    for kind in ('request', 'reply'):
        for field, value in changes.items():
            result[f'{kind}_{field}'] = [op(kind, 1, 0, changes={field: value}), op('poll', 1000001), op('request', 1000002, 0), op('reply', 1000003, 0)]
    result['precedence'] = [op('reply', 1, 0, changes=changes)]
    return {name: {'format': 1, 'operations': operations} for name, operations in result.items()}


def parse_godot(stdout, stderr):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('Godot engine error')
    prefix = 'FORTRESS_HANDSHAKE_RESULT '
    rows = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(rows) != 1:
        raise ValueError('missing/duplicate Godot completion')
    return json.loads(rows[0])



def malformed_controls(fixture, engine, output):
    mutants = {'empty': {}, 'empty_operations': dict(fixture, operations=[]), 'unknown_field': dict(fixture, unknown=1)}
    mutated = deepcopy(fixture); mutated['operations'][0]['now_us'] = True; mutants['bool_time'] = mutated
    mutated = deepcopy(fixture); mutated['local']['fps'] = '60'; mutants['string_fps'] = mutated
    for name, value in mutants.items():
        path = output / ('malformed-' + name + '.json'); path.write_text(json.dumps(value) + '\n')
        result = subprocess.run([str(engine.resolve()), '--headless', '--path', str(ROOT), '--script',
            'res://tests/oracle/handshake_trace.gd', '--', '--scenario', str(path.resolve())], capture_output=True,
            text=True, encoding='utf-8', timeout=120, env=rust_environment())
        (output / ('malformed-' + name + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode != 2 or 'FORTRESS_HANDSHAKE_RESULT ' in result.stdout or any(
                marker in result.stdout + result.stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('malformed Godot fixture did not fail at scenario validation: ' + name)
    return list(mutants)


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json', output_owner='formal-oracle')
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--tlc-jar', type=Path, default=CACHE / 'tla2tools.jar')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--formal', choices=('on', 'off'), default='on',
                        help='run the TLA+ model check on the model_matching scenario; off records'
                             ' formal_skipped for the tier that owns the model evidence elsewhere')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/handshake-oracle')
    args = parser.parse_args()
    with parser.claim_output(args.output):
        run(args)


def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'; receipt.unlink(missing_ok=True)
    identity = git_identity()
    engine = resolve_engine(args.godot)
    formal_on = args.formal == 'on'
    files = [* (ROOT / 'addons/fortress_rollback/protocol').glob('*.gd'), ROOT / 'tests/oracle/handshake_trace.gd',
             *Path(__file__).parent.glob('*.py'), ROOT / 'scripts/oracle/rust/src/bin/handshake.rs',
             ROOT / 'scripts/oracle/rust/Cargo.toml', ROOT / 'scripts/oracle/rust/Cargo.lock',
             ROOT / 'scripts/oracle/rust/src/source_revision.rs',
             ROOT / 'scripts/oracle/contract.py', ROOT / 'scripts/oracle/launch.py',
             *(ROOT / 'scripts/reference').glob('*.py')]
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}
    manifest_path = ROOT / 'docs/reference/pins.json'
    manifest_bytes = manifest_path.read_bytes()
    manifest = parse_manifest(manifest_bytes)
    files.append(manifest_path)
    source_hashes['docs/reference/pins.json'] = hashlib.sha256(manifest_bytes).hexdigest()
    if formal_on:
        artifact = manifest['artifacts'][ARTIFACT]
        jar_source, jar_digest = ROOT / artifact['repository_path'], artifact['digest']
        ensure_jar(args.tlc_jar, jar_source, jar_digest)
        files.append(jar_source)
        source_hashes[str(jar_source.relative_to(ROOT))] = jar_digest
    trees = sources(manifest, offline=args.offline)
    source_revision = manifest['sources']['fortress']['revision']
    cargo_manifest = prepare_source_build(ROOT / 'scripts/oracle/rust/Cargo.toml', trees['fortress'], source_revision, CACHE)
    environment = source_build_environment(cargo_manifest, trees['fortress'], source_revision)
    adapter_hashes = upstream_inventory(cargo_manifest.parent)
    upstream_hashes = upstream_inventory(trees['fortress'])
    cargo, _ = setup_rust(manifest, args.offline)
    cargo_version, _ = execute([str(cargo), '+' + manifest['rust']['version'], '--version'], args.output / 'cargo-version.log')
    rust_version, _ = execute([str(cargo.with_name('rustc')), '+' + manifest['rust']['version'], '--version'], args.output / 'rustc-version.log')
    engine_version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    if not engine_version.startswith(('4.3.stable', '4.7.2.stable')):
        raise ValueError('unsupported handshake engine profile')
    execute([str(cargo), '+' + manifest['rust']['version'], 'build', '--locked', '--offline', '--manifest-path',
             str(cargo_manifest), '--bin', 'handshake', '--features', 'handshake-oracle'], args.output / 'build.log', timeout=600, environment=environment)
    binary = CACHE / 'target/debug/handshake'
    evidence = []; formal = None
    for name, scenario in scenarios(source_revision=source_revision).items():
        submitted = args.output / f'{name}-scenario.json'; submitted.write_text(json.dumps(scenario, indent=2) + '\n')
        outputs = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary)], args.output / f'{name}-rust-{repeat}.log', submitted.read_text())
            if stderr.strip():
                raise ValueError('upstream unexpected stderr')
            outputs.append(decode_trace(stdout))
        if outputs[0] != outputs[1]:
            raise ValueError('upstream fresh process divergence')
        fixture, expected = project(outputs[0], scenario, source_revision=source_revision)
        raw_path = args.output / f'{name}-upstream.json'; raw_path.write_text(json.dumps(outputs[0], indent=2) + '\n')
        fixture_path = args.output / f'{name}-godot.json'; fixture_path.write_text(json.dumps(fixture, indent=2) + '\n')
        actuals = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                'res://tests/oracle/handshake_trace.gd', '--', '--scenario', str(fixture_path.resolve())], args.output / f'{name}-godot-{repeat}.log')
            actual = parse_godot(stdout, stderr); compare(actual, expected); actuals.append(actual)
        if actuals[0] != actuals[1]:
            raise ValueError('Godot fresh process divergence')
        actual_path = args.output / f'{name}-actual.json'; actual_path.write_text(json.dumps(actuals[0], indent=2) + '\n')
        if name == 'model_matching' and formal_on:
            formal = check_formal(actuals[0], args.output, args.tlc_jar.resolve(), upstream=trees['fortress'], jar_digest=jar_digest)
            mutant = deepcopy(actuals[0]); mutant['records'][0]['transitions'][0].update(remaining=0, state='running')
            try:
                check_formal(mutant, args.output, args.tlc_jar.resolve(), upstream=trees['fortress'], jar_digest=jar_digest)
            except ValueError as error:
                if 'formal begin' not in str(error):
                    raise ValueError('formal initial control failed at unrelated boundary') from error
                formal['invalid_begin_rejected'] = True
            else:
                raise ValueError('formal initial control survived')
        evidence.append({'name': name, 'operations': len(fixture['operations']), 'scenario_sha256': digest(submitted),
                        
                         'upstream_sha256': digest(raw_path), 'Godot_fixture_sha256': digest(fixture_path), 'actual_sha256': digest(actual_path),
                         'negative_controls': negative_controls(actuals[0], expected),
                         'raw_negative_controls': raw_negative_controls(outputs[0], scenario, source_revision=source_revision),
                         'Godot_repeat_equal': True, 'upstream_repeat_equal': True})
        print(f'{name}: actual upstream/Godot transitions, packets and events match twice', flush=True)
    malformed = malformed_controls(fixture, engine, args.output)
    if formal_on:
        ensure_jar(args.tlc_jar, jar_source, jar_digest)
    require_unchanged('local source inventory', source_hashes, {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)})
    require_unchanged('upstream source inventory', upstream_hashes, upstream_inventory(trees['fortress']))
    require_unchanged('Cargo adapter inventory', adapter_hashes, upstream_inventory(cargo_manifest.parent))
    require_unchanged('repository identity', identity, git_identity())
    receipt.write_text(json.dumps({'format': 1, 'complete': True, 'passed': True,
        'upstream_revision': manifest['sources']['fortress']['revision'],
        'upstream_archive_sha256': manifest['sources']['fortress']['archive']['digest'], 'upstream_source_sha256': upstream_hashes,
        'manifest_sha256': source_hashes['docs/reference/pins.json'], 'upstream_lock_sha256': upstream_hashes['Cargo.lock'],
        'commit': identity['commit'],
        'working_tree_dirty': identity['working_tree_dirty'],
        'engine': engine_version.strip(), 'cargo': cargo_version.strip(), 'rustc': rust_version.strip(),
        'features': ['handshake-oracle', 'fortress-rollback/trace-validation'], 'default_features': False,
        'formal': formal, 'formal_skipped': not formal_on, 'malformed_controls': malformed, 'binary_sha256': digest(binary),
        'engine_sha256': digest(engine), 'engine_path': str(engine), 'source_sha256': source_hashes, 'cases': evidence}, indent=2) + '\n')


if __name__ == '__main__':
    main()
