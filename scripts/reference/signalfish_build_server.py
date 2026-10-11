#!/usr/bin/env python3
"""Build the pinned local game relay server and record source/tool provenance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fetch import CACHE, MANIFEST, fetch, load_manifest
from signalfish_live_probe import extract, source_inventory
from signalfish_probe import inventory
from run import rust_environment


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
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
              'sdk_launcher': Path(__file__).with_name('signalfish_probe.py'), 'archive': archive, 'cargo': cargo, 'rustc': cargo.parent / 'rustc'}
    input_before = inventory(inputs)
    before = source_inventory(source)
    commands = [[str(cargo), 'clean', '-p', 'signal-fish-server'],
                [str(cargo), 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']]
    log_path = output / 'build.log'
    with tempfile.TemporaryDirectory(prefix='fortress-server-build-') as temporary:
        workspace = Path(temporary)
        reference = extract(archive, pin, workspace / 'reference')
        if before != source_inventory(reference):
            raise ValueError('server source differs from pinned archive')
        home = workspace / 'cargo'
        home.mkdir()
        seed = output / 'cargo-cache' if (output / 'cargo-cache').exists() else CACHE / 'cargo'
        for relative in ('registry/cache', 'registry/index'):
            cached = seed / relative
            if cached.exists():
                shutil.copytree(cached, home / relative)
        environment = rust_environment()
        environment.update(CARGO_HOME=str(home), CARGO_TARGET_DIR=str(output / 'target'),
                           RUSTC=str(cargo.parent / 'rustc'), PATH=str(cargo.parent) + os.pathsep + environment.get('PATH', ''))
        if args.offline:
            environment['CARGO_NET_OFFLINE'] = 'true'
        exits = []
        with log_path.open('wb') as log:
            for command in commands:
                process = subprocess.run(command, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=600)
                exits.append(process.returncode)
                if process.returncode != 0:
                    raise ValueError('local server build failed; see build.log')
        if before != source_inventory(source) or input_before != inventory(inputs):
            raise ValueError('server build source or compiler changed')
        for relative in ('registry/cache', 'registry/index'):
            if (home / relative).exists():
                shutil.copytree(home / relative, output / 'cargo-cache' / relative, dirs_exist_ok=True)
    binary = output / 'target/debug/signal-fish-server'
    report = {'format': 1, 'passed': True, 'commands': commands, 'exit_codes': exits,
              'source_revision': pin['revision'], 'source_inventory': before, 'tool_sha256': tools,
              'binary': str(binary), 'binary_sha256': digest(binary), 'log_sha256': digest(log_path),
              'input_inventory': input_before, 'builder_sha256': digest(Path(__file__)), 'server_archive_sha256': digest(archive)}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'receipt': str(receipt), 'server': str(binary)}))


if __name__ == '__main__':
    main()
