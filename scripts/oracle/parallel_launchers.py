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
from fetch import load_manifest, sources  # noqa: E402
from run import rust_environment, setup_rust  # noqa: E402

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

# Launcher spawns in flight, registered before their process starts, so an
# interruption can fence and kill every active group even while a launcher is
# between spawn and registration. _abort makes every later launch return at
# once, so a fenced pool drains without running any remaining launcher. The
# lock is reentrant because the SIGTERM handler runs in the main thread and may
# fence while that thread already holds the lock.
_active_lock = threading.RLock()
_active_handles: list[dict] = []
_abort = threading.Event()


def kill_group(pid: int) -> None:
    """Kill one launcher's whole process group, tolerating an already-dead group."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def abort_active_groups() -> None:
    """Fence every later launch and kill every active launcher's process group."""
    _abort.set()
    with _active_lock:
        pids = [handle["pid"] for handle in _active_handles if handle["pid"] is not None]
    for pid in pids:
        kill_group(pid)


def _on_terminate(signum, _frame):
    """Fence and kill on SIGTERM, then exit: engines must not outlive the wave."""
    abort_active_groups()
    raise SystemExit(128 + signum)


def run_wave(args, jobs):
    """Run every launcher in the bounded pool and return the per-launcher results."""
    outputs = {name: (args.results / f'{name}-{args.suffix}' if args.suffix else args.results / name)
               for name in LAUNCHERS}
    logs = {name: (args.results / f'launcher-{args.suffix}-{name}.log' if args.suffix
                   else args.results / f'launcher-{name}.log')
            for name in LAUNCHERS}
    commands = {name: launcher_command(name, ORACLE_DIR / script, args.godot, outputs[name])
                for name, script in LAUNCHERS.items()}
    print(f'Running {len(LAUNCHERS)} oracle launchers with {jobs} parallel subprocesses.', flush=True)
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        pending = {}
        try:
            pending = {pool.submit(run_launcher, name, commands[name], logs[name], args.timeout): name
                       for name in LAUNCHERS}
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
            # Fence queued launches and terminate every active launcher group:
            # an interruption must not block on engines that keep running while
            # the default per-launcher timeout is disabled.
            for future in pending:
                future.cancel()
            abort_active_groups()
            raise
    return results, logs


def prefetch_oracle_crates(cargo, environment, manifest, version, log_path):
    """Download the complete locked crate set into the shared registry before the pool.

    The launchers build with ``--offline``, so the shared registry cache must already
    hold every crate of the pinned lockfile. A partially populated cache (jobs racing
    one cache key, last writer winning) made an offline build fail on a crate a
    concurrent launcher had not downloaded yet; one non-offline fetch of the same
    lockfile removes that ordering assumption, and every build still proves offline
    completeness.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run([str(cargo), '+' + version, 'fetch', '--locked',
                                '--manifest-path', str(manifest)],
                               env=environment, capture_output=True, text=True, timeout=1800)
    log_path.write_text(completed.stdout + completed.stderr, encoding='utf-8')
    if completed.returncode != 0:
        raise ValueError('oracle crate pre-fetch failed: ' + (completed.stderr or completed.stdout)[-2000:])


def launcher_command(name, script, godot, output):
    return [sys.executable, str(script), '--godot', godot, '--output', str(output)]


def run_launcher(name, command, log_path, timeout):
    """Execute one launcher in its own process group and stream output to its log."""
    began = time.monotonic()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    timed_out = False
    handle = {"pid": None}
    with _active_lock:
        if _abort.is_set():
            return {'name': name, 'seconds': 0.0, 'returncode': 1, 'timeout': False,
                    'error': 'aborted before launch'}
        _active_handles.append(handle)
    try:
        with log_path.open('w', encoding='utf-8') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            with _active_lock:
                handle["pid"] = process.pid
            if _abort.is_set():
                # The fence ran while this launcher was between spawn and
                # registration, so nobody else can kill its group.
                kill_group(process.pid)
            try:
                returncode = process.wait(timeout=timeout or None)
            except subprocess.TimeoutExpired:
                timed_out = True
                kill_group(process.pid)
                process.wait()
                returncode = 124
    finally:
        with _active_lock:
            _active_handles.remove(handle)
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
    # Every main() run is a fresh wave: a leftover abort from a caught
    # interruption must not refuse the next run in the same process.
    _abort.clear()
    if args.timeout < 0:
        parser.error('launcher timeout must not be negative')
    # Provision the pinned Rust toolchain once before any launcher starts: the CI
    # cache keeps crates and downloads but not the toolchain, and six concurrent
    # rustup installations into the shared CARGO_HOME/RUSTUP_HOME raced on the same
    # partial downloads. Each launcher's own setup_rust call then finds cargo
    # present and becomes a no-op.
    manifest_data = load_manifest()
    cargo, environment = setup_rust(manifest_data, False)
    # Publish the pinned upstream source trees once before the pool: a launcher whose
    # retain_verified_tree sees a stale or partial tree replaces it in place, so two
    # concurrent preparations could delete a tree another launcher is reading. Each
    # launcher's own sources() call then finds a verified-identical tree and keeps it.
    sources(manifest_data, False)
    prefetch_oracle_crates(cargo, environment, ROOT / 'scripts' / 'oracle' / 'rust' / 'Cargo.toml',
                           manifest_data['rust']['version'],
                           args.results / ('oracle-fetch-' + args.suffix + '.log' if args.suffix else 'oracle-fetch.log'))
    # The SIGTERM fence lives only while the wave runs; the previous handler
    # returns when the wave ends, however it ends.
    previous_term = signal.signal(signal.SIGTERM, _on_terminate)
    try:
        results, logs = run_wave(args, jobs)
    finally:
        signal.signal(signal.SIGTERM, previous_term)
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
    summed = sum(result['seconds'] for result in results.values())
    print(f'Parallel oracle launchers: {len(LAUNCHERS)} launchers, {len(failed)} failed; '
          f'summed process time {summed:.1f}s.')
    return int(bool(failed))


if __name__ == '__main__':
    sys.exit(main())
