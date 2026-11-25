#!/usr/bin/env python3
"""Build the pinned SignalFish server with local gameplay receipt hooks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fetch import CACHE, MANIFEST, digest, fetch, parse_manifest
from receipt_arguments import ReceiptParser
from run import rust_environment
from signalfish_build_server import locked
from signalfish_live_probe import extract, source_inventory
from signalfish_probe import inventory

TRACE_SOURCE = Path(__file__).with_name('server_trace')


def build(cargo, cache, output, offline):
    with locked(output, lock_name='.trace-server-build.lock'):
        return _build_locked(cargo, cache, output, offline)


def _build_locked(cargo, cache, output, offline):
    binary = output / 'signal-fish-server'
    receipt = output / 'build-receipt.json'
    log_path = output / 'build.log'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n', encoding='utf-8')
    binary.unlink(missing_ok=True)
    log_path.unlink(missing_ok=True)

    manifest_bytes = MANIFEST.read_bytes()
    pins_digest = hashlib.sha256(manifest_bytes).hexdigest()
    pin = parse_manifest(manifest_bytes)['sources']['server']
    archive = fetch(pin['archive'], 'server.tar.gz', offline, cache)
    patch_tool = Path(shutil.which('patch') or 'patch').resolve(strict=True)
    patch = TRACE_SOURCE / 'hooks.patch'
    module = TRACE_SOURCE / 'relay_packet_trace.rs'
    patch_bytes, module_bytes = patch.read_bytes(), module.read_bytes()
    inputs = {'archive': archive, 'pins': MANIFEST, 'patch': patch, 'module': module, 'builder': Path(__file__),
              'patch_tool': patch_tool, 'cargo': cargo, 'rustc': cargo.with_name('rustc')}
    inputs.update((name, Path(__file__).with_name(name + '.py'))
                  for name in ('fetch', 'receipt_arguments', 'run', 'signalfish_build_server', 'signalfish_live_probe', 'signalfish_probe'))
    input_hashes = inventory(inputs)
    if input_hashes['pins'] != pins_digest or any(input_hashes[name] != hashlib.sha256(contents).hexdigest()
                                                 for name, contents in (('patch', patch_bytes), ('module', module_bytes))):
        raise ValueError('trace server build inputs changed')
    target = cache / 'server-target' / (pin['revision'] + '-relay-trace')
    home = cache / 'server-cargo'
    home.mkdir(parents=True, exist_ok=True)
    workspace_cache = cache / 'scratch'
    workspace_cache.mkdir(parents=True, exist_ok=True)
    environment = rust_environment()
    environment.update(CARGO_HOME=str(home), CARGO_TARGET_DIR=str(target), RUSTC=str(cargo.with_name('rustc')),
                       PATH=str(cargo.parent) + os.pathsep + environment.get('PATH', ''))
    if offline:
        environment['CARGO_NET_OFFLINE'] = 'true'

    commands = [[str(patch_tool), '--batch', '--forward', '--fuzz=0', '-p1'],
                [str(cargo), 'clean', '-p', 'signal-fish-server'],
                [str(cargo), 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']]
    with tempfile.NamedTemporaryFile(prefix='.relay-server-', dir=output) as staged:
        with tempfile.TemporaryDirectory(prefix='relay-trace-build-', dir=workspace_cache) as temporary, log_path.open('wb') as log:
            source = extract(archive, pin, Path(temporary))
            pristine = source_inventory(source)
            subprocess.run(commands[0], input=patch_bytes, check=True, cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            (source / 'src/relay_packet_trace.rs').write_bytes(module_bytes)
            patched = source_inventory(source)
            with locked(target):
                built = target / 'debug/signal-fish-server'
                subprocess.run(commands[1], check=True, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=60)
                built.unlink(missing_ok=True)
                subprocess.run(commands[2], check=True, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=600)
                if source_inventory(source) != patched:
                    raise ValueError('trace server build inputs changed')
                shutil.copy2(built, staged.name)
        report = {'format': 1, 'passed': True, 'source_revision': pin['revision'], 'binary': str(binary), 'binary_sha256': digest(Path(staged.name)),
                  'input_inventory': input_hashes, 'source_inventory': pristine, 'patched_source_inventory': patched,
                  'commands': commands, 'log_sha256': digest(log_path)}
        if inventory(inputs) != input_hashes:
            raise ValueError('trace server build inputs changed')
        os.link(staged.name, binary)
        receipt.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return report


def main():
    parser = ReceiptParser(description=__doc__, receipt='build-receipt.json')
    parser.add_argument('--cargo', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=CACHE)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    report = build(args.cargo.resolve(), args.cache.resolve(), args.output.resolve(), args.offline)
    print(json.dumps({'passed': True, 'receipt': str(args.output / 'build-receipt.json'), 'server': report['binary']}))


if __name__ == '__main__':
    main()
