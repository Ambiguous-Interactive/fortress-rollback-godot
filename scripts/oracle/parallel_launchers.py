#!/usr/bin/env python3
"""Run the oracle launchers in bounded parallel subprocesses with fail-closed aggregation.

Each launcher runs in its own fresh interpreter against its own output directory, so
the receipts, seeds, upstream sessions and Godot probes per launcher are exactly what
the serial workflow steps produced. Launchers share the pinned cargo target tree, whose
own build lock keeps concurrent compiles correct; the execution phases are what overlap.
The run fails unless every launcher executed exactly once and exited zero. Every
launcher is joined so each receipt and log is complete; the first failure in table
order is named, and only the cargo lock serializes work that used to serialize the
whole step.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

ORACLE_DIR = Path(__file__).resolve().parent
ROOT = ORACLE_DIR.parent.parent

sys.path.insert(0, str(ROOT / 'scripts' / 'reference'))
from fetch import load_manifest  # noqa: E402
from run import setup_rust  # noqa: E402

# Table order is the reporting and first-failure rejection order, longest launcher
# first: the pool starts the slowest launcher immediately so the elapsed time
# approaches its duration instead of its duration plus every shorter launcher.
LAUNCHERS = {
    'p2p': 'p2p_launch.py',
    'drop-history': 'drop_history_launch.py',
    'replay': 'replay_launch.py',
    'oracle': 'launch.py',
    'handshake': 'handshake_launch.py',
    'queue': 'queue_launch.py',
}

TAIL_LINES = 200

# Launcher process groups that are currently running. Interruption terminates them
# before waiting, so a cancelled run cannot block on engines that keep executing.
_active_lock = threading.Lock()
_active_groups: set[int] = set()


def kill_group(pid: int) -> None:
    """Kill one launcher's whole process group, tolerating an already-dead group."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def launcher_command(name, script, godot, output):
    return [sys.executable, str(script), '--godot', godot, '--output', str(output)]


def run_launcher(name, command, log_path, timeout):
    """Execute one launcher in its own process group and stream output to its log."""
    began = time.monotonic()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    timed_out = False
    with log_path.open('w', encoding='utf-8') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        with _active_lock:
            _active_groups.add(process.pid)
        try:
            returncode = process.wait(timeout=timeout or None)
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_group(process.pid)
            process.wait()
            returncode = 124
        finally:
            with _active_lock:
                _active_groups.discard(process.pid)
    return {'name': name, 'seconds': time.monotonic() - began, 'returncode': returncode, 'timeout': timed_out}


def print_tail(log_path):
    lines = log_path.read_text(encoding='utf-8', errors='replace').splitlines()
    if len(lines) > TAIL_LINES:
        print(f'--- last {TAIL_LINES} of {len(lines)} log lines ---')
    for line in lines[-TAIL_LINES:]:
        print(line)
    print(f'--- complete log: {log_path} ---')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--results', type=Path, default=ROOT / '.cache/reference/results')
    parser.add_argument('--suffix', default='', help='output-directory suffix, normally the engine version')
    parser.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 2))
    parser.add_argument('--timeout', type=float, default=0.0,
                        help='per-launcher bound in seconds; 0 keeps the workflow job timeout as the only bound')
    args = parser.parse_args()
    jobs = max(1, min(args.jobs, len(LAUNCHERS)))
    if args.timeout < 0:
        parser.error('launcher timeout must not be negative')
    # Provision the pinned Rust toolchain once before any launcher starts: the CI
    # cache keeps crates and downloads but not the toolchain, and six concurrent
    # rustup installations into the shared CARGO_HOME/RUSTUP_HOME raced on the same
    # partial downloads. Each launcher's own setup_rust call then finds cargo
    # present and becomes a no-op.
    setup_rust(load_manifest(), False)
    outputs = {name: (args.results / f'{name}-{args.suffix}' if args.suffix else args.results / name)
               for name in LAUNCHERS}
    logs = {name: (args.results / f'launcher-{args.suffix}-{name}.log' if args.suffix
                   else args.results / f'launcher-{name}.log')
            for name in LAUNCHERS}
    commands = {name: launcher_command(name, ORACLE_DIR / script, args.godot, outputs[name])
                for name, script in LAUNCHERS.items()}
    print(f'Running {len(LAUNCHERS)} oracle launchers with {jobs} parallel subprocesses.', flush=True)
    results = {}
    began = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        pending = {pool.submit(run_launcher, name, commands[name], logs[name], args.timeout): name
                   for name in LAUNCHERS}
        try:
            for future in concurrent.futures.as_completed(pending):
                name = pending[future]
                try:
                    result = future.result()
                except Exception as error:  # a worker crash is a failed launcher, never a partially counted run
                    result = {'name': name, 'seconds': 0.0, 'returncode': 1, 'timeout': False,
                              'error': f'{type(error).__name__}: {error}'}
                results[name] = result
                mark = 'pass' if result['returncode'] == 0 else 'FAIL'
                print(f'[{len(results)}/{len(LAUNCHERS)}] {mark} {name} {result["seconds"]:.1f}s', flush=True)
        except BaseException:
            # Fence queued launches and terminate active launcher groups before
            # waiting: an interruption must not block on engines that keep running
            # while the default per-launcher timeout is disabled.
            for future in pending:
                future.cancel()
            with _active_lock:
                groups = list(_active_groups)
            for pid in groups:
                kill_group(pid)
            raise
    failed = [name for name in LAUNCHERS if results[name]['returncode'] != 0]
    for name in failed:
        result = results[name]
        print(f'--- {name} exited {result["returncode"]}'
              + (' after exceeding the per-launcher timeout' if result.get('timeout') else '') + ' ---')
        if result.get('error'):
            print(result['error'])
        if logs[name].exists():
            print_tail(logs[name])
        else:
            print(f'--- {name} produced no log ---')
    elapsed = time.monotonic() - began
    summed = sum(result['seconds'] for result in results.values())
    print(f'Parallel oracle launchers: {len(LAUNCHERS)} launchers, {len(failed)} failed; '
          f'elapsed {elapsed:.1f}s, summed process time {summed:.1f}s.')
    return int(bool(failed))


if __name__ == '__main__':
    sys.exit(main())
