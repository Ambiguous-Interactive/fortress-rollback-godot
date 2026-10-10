#!/usr/bin/env python3
"""Execute pinned upstream traces twice and replay the game boundaries in Godot."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys

from contract import fields, integer, validate_scenario, validate_trace
from corpus import scenarios, validate_history
from controls import negative_controls

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/reference'))
from fetch import CACHE, digest, load_manifest, sources  # noqa: E402
from run import rust_environment, setup_rust  # noqa: E402


def execute(command, log, input_text=None, timeout=120):
    log.write_text('COMMAND_STARTED: ' + repr(command) + '\n')
    try:
        result = subprocess.run(command, cwd=ROOT, input=input_text, capture_output=True,
                                text=True, encoding='utf-8', timeout=timeout,
                                env=rust_environment())
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b''
        errors = error.stderr or b''
        log.write_text(str(output) + '\n' + str(errors) + '\nTIMEOUT\n')
        raise
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(f'process failed ({result.returncode}); see {log}')
    return result.stdout, result.stderr


def oracle_result(stdout, stderr, scenario):
    if stderr.strip():
        raise ValueError('oracle emitted unexpected stderr')
    return validate_trace(json.loads(stdout), scenario)


def game_result(stdout, stderr, trace):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('Godot engine error')
    prefix = 'FORTRESS_ORACLE_GAME_RESULT '
    records = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(records) != 1:
        raise ValueError('game missing or duplicate completion')
    value = json.loads(records[0])
    fields(value, 'format complete passed count request_count request_counts records engine_version errors', 'game result')
    integer(value['format'], 1, 1, 'game result format')
    if value.get('complete') is not True or value.get('passed') is not True:
        raise ValueError('game boundary replay failed')
    if value['errors'] != [] or not isinstance(value['engine_version'], str) or not value['engine_version']:
        raise ValueError('game errors or missing engine identity')
    integer(value['count'], len(trace['operations']), len(trace['operations']), 'game operation count')
    if not isinstance(value['records'], list) or len(value['records']) != value['count']:
        raise ValueError('game missing operation records')
    for index, (record, operation) in enumerate(zip(value['records'], trace['operations'])):
        fields(record, 'index kind passed frame', 'game operation')
        integer(record['index'], index, index, 'game operation index')
        integer(record['frame'], operation['frame_after'], operation['frame_after'], 'game operation frame')
        if record['kind'] != operation['kind'] or record['passed'] is not True:
            raise ValueError('game operation mismatch')
    count = sum(len(operation['requests']) for operation in trace['operations'])
    if type(value.get('request_count')) is not int or value['request_count'] != count:
        raise ValueError('game replay did not consume every request')
    fields(value['request_counts'], 'save load advance', 'game request counts')
    for kind, actual in value['request_counts'].items():
        expected = sum(request['kind'] == kind for operation in trace['operations'] for request in operation['requests'])
        integer(actual, expected, expected, 'game request kind count')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/oracle')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    manifest = load_manifest()
    trees = sources(manifest, args.offline)
    cargo, _ = setup_rust(manifest, args.offline)
    version, _ = execute([str(cargo), '+' + manifest['rust']['version'], '--version'], args.output / 'cargo-version.log')
    command = [str(cargo), '+' + manifest['rust']['version'], 'build', '--locked',
               '--manifest-path', str(ROOT / 'scripts/oracle/rust/Cargo.toml')]
    if args.offline:
        command.append('--offline')
    execute(command, args.output / 'build.log', timeout=600)
    binary = CACHE / 'target/debug/fortress-development-oracle'
    engine = args.godot.resolve()
    engine_version, _ = execute([str(engine), '--version'], args.output / 'engine-version.log')
    cases = []
    control_case = None
    for name, scenario in scenarios():
        validate_scenario(scenario)
        fixture = args.output / f'{name}-scenario.json'
        fixture.write_text(json.dumps(scenario, indent=2) + '\n')
        runs = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(binary)], args.output / f'{fixture.stem}-rust-{repeat}.log', fixture.read_text())
            runs.append(oracle_result(stdout, stderr, scenario))
        if runs[0] != runs[1]:
            raise ValueError(f'{fixture.name}: upstream fresh-process trace divergence')
        validate_history(runs[0], scenario)
        if scenario['players'] == 2 and scenario['check_distance'] == 2:
            control_case = scenario, runs[0]
        trace_path = args.output / f'{fixture.stem}-trace.json'
        trace_path.write_text(json.dumps(runs[0], indent=2) + '\n')
        game_runs = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script',
                'res://tests/oracle/replay_trace.gd', '--', '--trace', str(trace_path.resolve())],
                args.output / f'{fixture.stem}-godot-{repeat}.log')
            game_runs.append(game_result(stdout, stderr, runs[0]))
        if game_runs[0] != game_runs[1]:
            raise ValueError(f'{fixture.name}: game fresh-process replay divergence')
        cases.append({'scenario': fixture.name, 'scenario_sha256': digest(fixture),
                      'trace_sha256': digest(trace_path), 'operations': len(runs[0]['operations']),
                      'requests': sum(len(op['requests']) for op in runs[0]['operations']),
                      'game': game_runs[0], 'repeat_equal': True})
        print(f'{name}: runtime trace and game boundaries passed twice', flush=True)
    controls = negative_controls(binary, [str(engine), '--headless', '--path', str(ROOT), '--script',
        'res://tests/oracle/replay_trace.gd'], *control_case, args.output, rust_environment())
    report = {'format': 1, 'passed': True, 'commit': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)),
        'upstream_revision': manifest['sources']['fortress']['revision'],
        'upstream_lock_sha256': digest(trees['fortress'] / 'Cargo.lock'),
        'oracle_lock_sha256': digest(ROOT / 'scripts/oracle/rust/Cargo.lock'),
        'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'), 'cargo': version.strip(),
        'binary_sha256': digest(binary), 'engine': engine_version.strip(), 'engine_sha256': digest(engine),
        'platform': platform.platform(), 'features': [], 'default_features': False, 'cases': cases, 'negative_controls': controls,
        'source_sha256': {str(path.relative_to(ROOT)): digest(path) for path in sorted(
            list((ROOT / 'scripts/oracle').rglob('*.py')) + list((ROOT / 'scripts/oracle/rust/src').glob('*.rs'))
            + list((ROOT / 'tests/oracle').glob('*.gd')))},
        'limitations': ['Sync-test public API only; no P2P, transport or protocol parity.',
                        'Godot replays game requests; no Godot session implementation exists.',
                        'Confirmation unavailable through upstream public sync-test API.']}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
