#!/usr/bin/env python3
"""Run the online leg's native probes in bounded parallel subprocesses.

The serial chain of seven native probes is the Reference Baseline wall-time
critical path (issue #340). Each probe already binds an ephemeral port, starts
its own pinned server subprocess and writes to its own output directory, so two
of them overlap safely when the host-capacity lease is held once for the whole
wave: the children run with ``FORTRESS_HOST_LEASE_HELD=1`` and the wave owner
releases the host when the last probe joins. The six browser-viewer cells stay
serial in the workflow because browser pages need a responsive host.

The run fails unless every probe executed exactly once and exited zero. Every
failure names its own log, and one rejection never masks a sibling's failure.
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

REFERENCE = Path(__file__).resolve().parent
ROOT = REFERENCE.parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import host_capacity  # noqa: E402

# Table order is the reporting and first-failure naming order, longest probe
# first: the pool starts the slowest probe immediately so the elapsed time
# approaches its duration instead of the duration plus every shorter probe.
# Each entry names its script, its extra arguments and its output-directory
# template, which must match the pre-overlap artifact layout exactly.
PROBES = {
    'live-relay': ('signalfish_live_probe.py', (), 'signalfish-live-{version}'),
    'spectator-live': ('signalfish_spectator_live.py', (), 'spectator-live-{version}'),
    'spectator-departure-host': ('signalfish_spectator_live.py', ('--departure', 'host'),
                                 'spectator-live-{version}-departure-host'),
    'spectator-departure-viewer': ('signalfish_spectator_live.py', ('--departure', 'viewer'),
                                   'spectator-live-{version}-departure-viewer'),
    'spectator-late-join-failed': ('signalfish_spectator_live.py', ('--late-signal', 'spectator_join_failed'),
                                   'spectator-live-{version}-spectator_join_failed'),
    'spectator-late-left': ('signalfish_spectator_live.py', ('--late-signal', 'spectator_left'),
                            'spectator-live-{version}-spectator_left'),
    'spectator-late-disconnected': ('signalfish_spectator_live.py', ('--late-signal', 'spectator_disconnected'),
                                    'spectator-live-{version}-spectator_disconnected'),
}

TAIL_LINES = 200
HOST_LEASE_NAME = 'online-native-probes'
HOST_WAIT_SECONDS = 900.0

# Probe spawns in flight, registered before their process starts, so an
# interruption can fence and kill every active group even while a probe is
# between spawn and registration. _abort makes every later launch return at
# once, so a fenced pool drains without running any remaining probe.
_active_lock = threading.Lock()
_active_handles: list[dict] = []
_abort = threading.Event()


def kill_group(pid: int) -> None:
    """Kill one probe's whole process group, tolerating an already-dead group."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def abort_active_groups() -> None:
    """Fence every later launch and kill every active probe's process group."""
    _abort.set()
    with _active_lock:
        pids = [handle["pid"] for handle in _active_handles if handle["pid"] is not None]
    for pid in pids:
        kill_group(pid)


def probe_command(name, script, extra, template, args):
    """The exact pre-overlap command for one probe, in the workflow's argument order."""
    output = args.results / template.format(version=args.version)
    command = [sys.executable, str(REFERENCE / script), '--godot', args.godot]
    command.extend(extra)
    command.extend(('--server', str(args.server)))
    command.extend(('--server-source', str(args.server_source)))
    command.extend(('--build-receipt', str(args.build_receipt)))
    command.extend(('--output', str(output)))
    return command


def run_probe(name, command, log_path, environment):
    """Execute one probe in its own process group and stream output to its log."""
    began = time.monotonic()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    handle = {"pid": None}
    with _active_lock:
        if _abort.is_set():
            return {'name': name, 'seconds': 0.0, 'returncode': 1, 'error': 'aborted before launch'}
        _active_handles.append(handle)
    try:
        with log_path.open('w', encoding='utf-8') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=environment)
            with _active_lock:
                handle["pid"] = process.pid
            if _abort.is_set():
                # The fence ran while this probe was between spawn and registration,
                # so nobody else can kill its group.
                kill_group(process.pid)
            returncode = process.wait()
    finally:
        with _active_lock:
            _active_handles.remove(handle)
    return {'name': name, 'seconds': time.monotonic() - began, 'returncode': returncode}


def print_tail(log_path):
    lines = log_path.read_text(encoding='utf-8', errors='replace').splitlines()
    if len(lines) > TAIL_LINES:
        print(f'--- last {TAIL_LINES} of {len(lines)} log lines ---')
    for line in lines[-TAIL_LINES:]:
        print(line)
    print(f'--- complete log: {log_path} ---')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, help='path to the pinned editor binary')
    parser.add_argument('--server', required=True, type=Path, help='pinned SignalFish server binary')
    parser.add_argument('--server-source', required=True, type=Path, help='verified server source tree')
    parser.add_argument('--build-receipt', required=True, type=Path, help='server build receipt')
    parser.add_argument('--version', required=True, help='engine version named in every output directory')
    parser.add_argument('--results', type=Path, default=ROOT / '.cache/reference/results')
    parser.add_argument('--jobs', type=int, default=2, help='overlapping probes; 2 matches the measured host budget')
    args = parser.parse_args()
    jobs = max(1, min(args.jobs, len(PROBES)))
    if not host_capacity.acquire_when_free(HOST_LEASE_NAME, HOST_WAIT_SECONDS):
        raise ValueError('the development host stayed busy; the native probe wave needs a responsive host')
    # The wave owns the host for its whole duration; the probe children inherit
    # that ownership instead of taking and releasing it one process at a time.
    environment = os.environ.copy()
    environment[host_capacity.WAVE_HELD_ENV] = HOST_LEASE_NAME
    outputs = {name: args.results / PROBES[name][2].format(version=args.version) for name in PROBES}
    logs = {name: args.results / f'native-probe-{args.version}-{name}.log' for name in PROBES}
    commands = {name: probe_command(name, *PROBES[name], args) for name in PROBES}
    print(f'Running {len(PROBES)} native probes with {jobs} parallel subprocesses.', flush=True)
    results = {}
    began = time.monotonic()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            pending = {}
            try:
                pending = {pool.submit(run_probe, name, commands[name], logs[name], environment): name
                           for name in PROBES}
                for future in concurrent.futures.as_completed(pending):
                    name = pending[future]
                    try:
                        result = future.result()
                    except Exception as error:  # a worker crash is a failed probe, never a partially counted run
                        result = {'name': name, 'seconds': 0.0, 'returncode': 1,
                                  'error': f'{type(error).__name__}: {error}'}
                    results[name] = result
                    mark = 'pass' if result['returncode'] == 0 else 'FAIL'
                    print(f'[{len(results)}/{len(PROBES)}] {mark} {name} {result["seconds"]:.1f}s', flush=True)
            except BaseException:
                # Fence queued launches and terminate every active probe group:
                # an interruption must not block on engines that keep running.
                for future in pending:
                    future.cancel()
                abort_active_groups()
                raise
    finally:
        host_capacity.release()
    failed = [name for name in PROBES if results[name]['returncode'] != 0]
    for name in failed:
        result = results[name]
        print(f'--- {name} exited {result["returncode"]} ---')
        if result.get('error'):
            print(result['error'])
        if logs[name].exists():
            print_tail(logs[name])
        else:
            print(f'--- {name} produced no log ---')
    elapsed = time.monotonic() - began
    summed = sum(result['seconds'] for result in results.values())
    print(f'Native probe wave: {len(PROBES)} probes, {len(failed)} failed; '
          f'elapsed {elapsed:.1f}s, summed process time {summed:.1f}s.')
    return int(bool(failed))


if __name__ == '__main__':
    sys.exit(main())
