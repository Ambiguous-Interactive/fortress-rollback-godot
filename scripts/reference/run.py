#!/usr/bin/env python3
"""Run a representative pinned upstream baseline twice; retain raw logs and results."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

from fetch import CACHE, ROOT, digest, fetch, load_manifest, sources
from receipt_arguments import ReceiptParser

# Existing upstream tests exercise real sync, queue and seeded P2P implementations.
CASES = [
    ('queue', ['--lib', 'input_queue::']),
    ('sync', ['--test', 'sessions', 'synctest::']),
    ('network', ['--test', 'simulation', 'simulation::fleet::pr_smoke_']),
    ('repeat_trace', ['--test', 'simulation', 'simulation::fleet::same_schedule_produces_identical_trace', '--', '--exact']),
    ('oracle_negative_control', ['--test', 'simulation', 'simulation::fleet::oracle_and_inband_detector_catch_seeded_state_divergence', '--', '--exact']),
]


def rust_environment():
    environment = os.environ.copy()
    environment.update(CARGO_HOME=str(CACHE / 'cargo'), RUSTUP_HOME=str(CACHE / 'rustup'),
                       CARGO_TARGET_DIR=str(CACHE / 'target'), CARGO_INCREMENTAL='0',
                       PROPTEST_RNG_SEED='1', PROPTEST_RNG_ALGORITHM='xs')
    # User flags could silently enable unreviewed cfg/features or change the oracle.
    for key in ('RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER'):
        environment.pop(key, None)
    return environment


def begin_results(directory, report_name, log_names):
    """Invalidate prior success before any operation that may fail."""
    directory.mkdir(parents=True, exist_ok=True)
    (directory / report_name).unlink(missing_ok=True)
    for name in log_names:
        (directory / name).unlink(missing_ok=True)


def captured_text(value):
    # TimeoutExpired streams can be bytes even when subprocess used text=True.
    return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value or ''


def capture(cmd, environment, log, timeout, cwd=None):
    log.write_text('COMMAND_STARTED: ' + repr(cmd) + '\n')
    try:
        completed = subprocess.run(cmd, cwd=cwd, env=environment, capture_output=True,
                                   text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        log.write_text(captured_text(error.output) + captured_text(error.stderr)
                       + f'\nTIMEOUT: command exceeded {error.timeout} seconds\n')
        raise
    except OSError as error:
        log.write_text(f'TOOL_FAILURE: {error}\n')
        raise
    output = completed.stdout + completed.stderr
    log.write_text(output)
    return completed.returncode, output


def command(command, cwd, environment, log):
    returncode, output = capture(command, environment, log, timeout=1800, cwd=cwd)
    if returncode:
        raise RuntimeError(f'command failed ({returncode}): {command}; see {log}')
    return output


def semantic(output):
    tests = sorted(re.findall(r'^test (\S+)(?: - should panic)? \.\.\. (ok|FAILED|ignored)$', output, re.MULTILINE))
    starts = re.findall(r'^running (\d+) tests?$', output, re.MULTILINE)
    ends = re.findall(r'^test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured;', output, re.MULTILINE)
    if not tests or starts != [str(len(tests))] or ends != starts or len({name for name, _ in tests}) != len(tests) or any(status != 'ok' for _, status in tests):
        raise ValueError('empty, failed or ignored baseline selection')
    return tests


def setup_rust(data, offline):
    arch = {'aarch64': 'aarch64', 'x86_64': 'x86_64'}.get(platform.machine())
    if arch is None or platform.system() != 'Linux':
        raise ValueError('bootstrap supports Linux aarch64/x86_64 only')
    # Pin the distribution metadata in addition to rustup integrity checking components.
    fetch(data['artifacts']['rust-channel-1.99.1'], 'rust-channel-1.99.1', offline)
    installer = fetch(data['artifacts']['rustup-init-' + arch], 'rustup-init-' + arch, offline)
    installer.chmod(0o755)
    environment = rust_environment()
    version = data['rust']['version']
    cargo = CACHE / 'cargo/bin/cargo'
    if not cargo.exists():
        if offline:
            raise FileNotFoundError('offline Rust toolchain unavailable')
        subprocess.run([str(installer), '-y', '--no-modify-path', '--profile', data['rust']['profile'],
                        '--default-toolchain', version], env=environment, check=True)
    return cargo, environment


def main():
    parser = ReceiptParser(description=__doc__, receipt='rust-baseline.json')
    parser.add_argument('--offline', action='store_true', help='require cached sources, compiler and crates')
    parser.add_argument('--setup-rust', action='store_true')
    parser.add_argument('--output', type=Path, default=CACHE / 'results')
    args = parser.parse_args()
    logs = ['cargo-version.log'] + [f'{name}-{repeat}.log' for name, _ in CASES for repeat in (1, 2)]
    begin_results(args.output, 'rust-baseline.json', logs)
    data = load_manifest()
    trees = sources(data, args.offline)
    cargo, environment = setup_rust(data, args.offline) if args.setup_rust else (CACHE / 'cargo/bin/cargo', rust_environment())
    args.output.mkdir(parents=True, exist_ok=True)
    version = command([str(cargo), '+' + data['rust']['version'], '--version'], ROOT,
                      environment, args.output / 'cargo-version.log').strip()
    records = []
    for name, flags in CASES:
        cmd = [str(cargo), '+' + data['rust']['version'], 'test', '--locked', '--no-default-features']
        if data['rust']['features']:
            cmd += ['--features', ','.join(data['rust']['features'])]
        if args.offline:
            cmd.append('--offline')
        cmd += flags
        if '--' not in cmd:
            cmd.append('--')
        cmd += ['--test-threads=1']
        outputs = []
        for repeat in (1, 2):
            output = command(cmd, trees['fortress'], environment, args.output / f'{name}-{repeat}.log')
            outputs.append(semantic(output))
        if outputs[0] != outputs[1]:
            raise ValueError(f'{name}: repeat semantic output differs')
        records.append({'case': name, 'command': cmd, 'tests': outputs[0], 'repeat_equal': True,
                        'raw_log_sha256': [digest(args.output / f'{name}-{repeat}.log') for repeat in (1, 2)],
                        'semantic_sha256': hashlib.sha256(json.dumps(outputs[0]).encode()).hexdigest()})
        print(f'{name}: {len(outputs[0])} tests passed twice', flush=True)
    report = {'status': 'passed', 'schema_version': 1, 'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'),
              'platform': platform.platform(), 'cargo_version': version, 'features': data['rust']['features'],
              'proptest_seed': 1, 'proptest_rng_algorithm': 'xs',
              'sources': {name: value['revision'] for name, value in data['sources'].items()},
              'cases': records, 'limitations': ['Test outcome equality is not full state trace equality.',
              'Upstream same_schedule test asserts trace equality internally.',
              'No full suite, advanced-feature, formal-model or browser parity claim.']}
    (args.output / 'rust-baseline.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
