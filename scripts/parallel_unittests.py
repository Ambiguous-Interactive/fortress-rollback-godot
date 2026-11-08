#!/usr/bin/env python3
"""Run unittest files in bounded parallel subprocesses with fail-closed aggregation.

Each discovered ``test_*.py`` file runs in its own fresh interpreter, so the
executed cases per file are unchanged and file-level state is isolated at
least as much as under single-process ``unittest discover``. A worker pool
keeps every interpreter busy, which shortens wall time without dropping or
reordering any case. The run fails unless every discovered file executed
exactly once and exited zero; timeouts and crashes are failures.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import time


def discover(start: Path, pattern: str) -> list[str]:
    files = sorted(path.name for path in start.glob(pattern) if path.is_file())
    if not files:
        raise ValueError(f'no test files match {pattern} under {start}')
    return files


def run_file(root: Path, start: Path, name: str, timeout: float) -> dict:
    command = [sys.executable, '-m', 'unittest', 'discover', '-s', str(start), '-p', name, '-v']
    began = time.monotonic()
    try:
        completed = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=timeout, check=False)
        return {'file': name, 'seconds': time.monotonic() - began, 'returncode': completed.returncode,
                'stdout': completed.stdout, 'stderr': completed.stderr, 'timeout': False}
    except subprocess.TimeoutExpired as expired:
        return {'file': name, 'seconds': time.monotonic() - began, 'returncode': 124,
                'stdout': (expired.stdout or b'').decode('utf-8', 'replace'), 'stderr': (expired.stderr or b'').decode('utf-8', 'replace'),
                'timeout': True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--start-dir', type=Path, default=Path(__file__).resolve().parent / 'reference')
    parser.add_argument('--pattern', default='test_*.py')
    parser.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument('--timeout', type=float, default=900.0, help='per-file subprocess bound in seconds')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    start = args.start_dir.resolve()
    if not start.is_dir():
        raise ValueError(f'test start directory is missing: {start}')
    files = discover(start, args.pattern)
    jobs = max(1, min(args.jobs, len(files)))
    print(f'Running {len(files)} test files from {start} with {jobs} parallel subprocesses.')
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        pending = {pool.submit(run_file, root, start, name, args.timeout): name for name in files}
        for future in concurrent.futures.as_completed(pending):
            try:
                result = future.result()
            except Exception as error:  # a worker crash is a failed file, never a partially counted run
                result = {'file': pending[future], 'seconds': 0.0, 'returncode': 1,
                          'stdout': '', 'stderr': f'{type(error).__name__}: {error}', 'timeout': False}
            results[result['file']] = result
            mark = 'pass' if result['returncode'] == 0 else 'FAIL'
            print(f"[{len(results)}/{len(files)}] {mark} {result['file']} {result['seconds']:.1f}s", flush=True)
    failed = [name for name in files if results[name]['returncode'] != 0]
    for name in failed:
        result = results[name]
        print(f'--- {name} exited {result["returncode"]}'
              + (' after exceeding the per-file timeout' if result['timeout'] else '') + ' ---')
        if result['stdout']:
            print(result['stdout'])
        if result['stderr']:
            print(result['stderr'], file=sys.stderr)
    summed = sum(result['seconds'] for result in results.values())
    print(f'Parallel unittest: {len(files)} files, {len(failed)} failed; {summed:.1f}s summed process time.')
    return int(bool(failed))


if __name__ == '__main__':
    raise SystemExit(main())
