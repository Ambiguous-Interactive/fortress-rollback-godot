#!/usr/bin/env python3
"""Build the pinned local game relay server and record source/tool provenance."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fetch import CACHE, MANIFEST, fetch, load_manifest
from receipt_arguments import ReceiptParser
from signalfish_live_probe import extract, server_cargo_home, source_inventory
from signalfish_probe import inventory
from run import rust_environment


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shared_target(revision):
    """One revision-keyed cargo build tree, shared by every session.

    The cargo output of this server is about 970 MB. Building it into the
    per-run output directory meant every session left another copy behind
    (measured: twenty copies, 21 GB, all byte-identical). Keying the tree
    by the pinned source revision keeps exactly one copy and lets every
    later session reuse the dependency artifacts.

    The `cargo clean -p` step still runs before every build, so the binary
    is always compiled from the current source; the tree only holds the
    third-party artifacts that are expensive to rebuild.
    """
    return CACHE / 'server-target' / revision


def cargo_home():
    """One stable cargo home, seeded once from the reference registry.

    Cargo records the absolute path of every registry source in its build
    fingerprints. A per-run cargo home changes every one of those paths, so
    every dependency is recompiled from scratch. A stable home keeps the
    paths identical between runs and between CI jobs, and it holds the
    downloaded crates in one place the CI can cache.
    """
    home = server_cargo_home()
    home.mkdir(parents=True, exist_ok=True)
    seed = CACHE / 'cargo'
    for relative in ('registry/cache', 'registry/index'):
        cached = seed / relative
        if cached.exists() and not (home / relative).exists():
            shutil.copytree(cached, home / relative)
    return home


def locked(target):
    """Exclusive lock over a shared build tree.

    `cargo clean -p` removes artifacts from the whole target directory, so
    two sessions building at once would delete each other's work. The lock
    serializes them.
    """
    target.mkdir(parents=True, exist_ok=True)
    lock = target.with_name(target.name + '.lock')
    handle = lock.open('w')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def main():
    parser = ReceiptParser(description=__doc__, receipt='build-receipt.json')
    parser.add_argument('--cargo', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / 'build-receipt.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    pin = load_manifest()['sources']['server']
    archive = fetch(pin['archive'], 'server.tar.gz', args.offline)
    source = args.source.resolve()
    cargo = args.cargo.resolve()
    tools = {'cargo': digest(cargo), 'rustc': digest(cargo.parent / 'rustc')}
    inputs = {'builder': Path(__file__).resolve(), 'fetch': Path(__file__).with_name('fetch.py'), 'pins': MANIFEST,
              'run': Path(__file__).with_name('run.py'), 'native_launcher': Path(__file__).with_name('signalfish_live_probe.py'),
              'sdk_launcher': Path(__file__).with_name('signalfish_probe.py'),
              'receipt_arguments': Path(__file__).with_name('receipt_arguments.py'), 'archive': archive, 'cargo': cargo, 'rustc': cargo.parent / 'rustc'}
    input_before = inventory(inputs)
    before = source_inventory(source)
    commands = [[str(cargo), 'clean', '-p', 'signal-fish-server'],
                [str(cargo), 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']]
    log_path = output / 'build.log'
    target = shared_target(pin['revision'])
    home = cargo_home()
    with tempfile.TemporaryDirectory(prefix='fortress-server-build-') as temporary:
        workspace = Path(temporary)
        reference = extract(archive, pin, workspace / 'reference')
        if before != source_inventory(reference):
            raise ValueError('server source differs from pinned archive')
        environment = rust_environment()
        environment.update(CARGO_HOME=str(home), CARGO_TARGET_DIR=str(target),
                           RUSTC=str(cargo.parent / 'rustc'), PATH=str(cargo.parent) + os.pathsep + environment.get('PATH', ''))
        if args.offline:
            environment['CARGO_NET_OFFLINE'] = 'true'
        exits = []
        with locked(target):
            with log_path.open('wb') as log:
                for command in commands:
                    process = subprocess.run(command, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=600)
                    exits.append(process.returncode)
                    if process.returncode != 0:
                        raise ValueError('local server build failed; see build.log')
                    if command[1] == 'clean':
                        # The clean drops the server package's own artifacts. Drop the
                        # published binary too, so a restored build tree can never
                        # supply the server executable itself.
                        (target / 'debug/signal-fish-server').unlink(missing_ok=True)
            if before != source_inventory(source) or input_before != inventory(inputs):
                raise ValueError('server build source or compiler changed')
            # Publish the executable at the path the probes and the docs
            # name. It is a copy, never a link: a later rebuild in the shared
            # tree must not be able to mutate bytes an older receipt binds.
            published = output / 'target/debug/signal-fish-server'
            shutil.rmtree(output / 'target', ignore_errors=True)
            published.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target / 'debug/signal-fish-server', published)
    binary = output / 'target/debug/signal-fish-server'
    report = {'format': 1, 'passed': True, 'commands': commands, 'exit_codes': exits,
              'source_revision': pin['revision'], 'source_inventory': before, 'tool_sha256': tools,
              'binary': str(binary), 'binary_sha256': digest(binary), 'log_sha256': digest(log_path),
              'input_inventory': input_before, 'builder_sha256': digest(Path(__file__)), 'server_archive_sha256': digest(archive),
              'cargo_home': str(home)}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'receipt': str(receipt), 'server': str(binary)}))


if __name__ == '__main__':
    main()
