#!/usr/bin/env python3
"""Run the optional adapter against the verified SDK in an isolated project."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile

from fetch import fetch, load_manifest

ROOT = Path(__file__).resolve().parents[2]
MARKER = 'FORTRESS_SIGNALFISH_SDK_OK'
TIMEOUT = 30


def inventory(paths):
    result = {}
    for name, path in paths.items():
        if path.is_symlink():
            raise ValueError('evidence source is symlinked')
        files = sorted(path.rglob('*')) if path.is_dir() else [path]
        for source in files:
            if source.is_symlink():
                raise ValueError('evidence source is symlinked')
            if source.is_dir():
                continue
            key = name + '/' + str(source.relative_to(path)) if path.is_dir() else name
            with source.open('rb') as stream:
                result[key] = hashlib.file_digest(stream, 'sha256').hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'signalfish-sdk.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    manifest = load_manifest()
    sdk_pin = manifest['sources']['sdk']
    archive = fetch(sdk_pin['archive'], 'sdk.tar.gz', args.offline)
    executable = Path(shutil.which(str(args.godot)) or args.godot).resolve()
    inputs = {'addon': ROOT / 'addons/fortress_rollback', 'probe': ROOT / 'scripts/reference/signalfish_probe.gd',
              'new_peer_probe': ROOT / 'scripts/reference/signalfish_probe_new_peer.gd',
              'sdk_archive': archive, 'engine': executable, 'launcher': Path(__file__).resolve()}
    before = inventory(inputs)
    with tempfile.TemporaryDirectory(prefix='fortress-signalfish-sdk-') as temporary:
        project = Path(temporary)
        with tarfile.open(archive) as package:
            members = package.getmembers()
            if not members or any(member.name.split('/')[0] != sdk_pin['root'] for member in members):
                raise ValueError('unexpected SDK source archive root')
            package.extractall(project / 'reference', filter='data')
        sdk = project / 'reference' / sdk_pin['root']
        shutil.copytree(ROOT / 'addons/fortress_rollback', project / 'addons/fortress_rollback')
        shutil.copytree(sdk / 'addons/signal_fish', project / 'addons/signal_fish')
        shutil.copyfile(ROOT / 'scripts/reference/signalfish_probe.gd', project / 'probe.gd')
        shutil.copyfile(ROOT / 'scripts/reference/signalfish_probe_new_peer.gd', project / 'signalfish_probe_new_peer.gd')
        (project / 'project.godot').write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish',
                    'new_peer_probe': project / 'signalfish_probe_new_peer.gd',
                    'probe': project / 'probe.gd', 'project': project / 'project.godot'}
        executed_before = inventory(executed)
        if {name: digest for name, digest in executed_before.items() if name.startswith('addon/') or name in ('probe', 'new_peer_probe')} != {
                name: digest for name, digest in before.items() if name.startswith('addon/') or name in ('probe', 'new_peer_probe')}:
            raise ValueError('copied source inventory differs')
        command = [str(executable), '--headless', '--path', str(project), '--script', 'res://probe.gd']
        try:
            process = subprocess.run(command, capture_output=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired as failure:
            output = (failure.stdout or b'') + (failure.stderr or b'')
            (args.output / 'signalfish-sdk.log').write_bytes(output)
            raise ValueError('SDK integration timed out; see signalfish-sdk.log') from failure
        raw_output = process.stdout + process.stderr
        (args.output / 'signalfish-sdk.log').write_bytes(raw_output)
        output = raw_output.decode('utf-8')
        if process.returncode != 0 or MARKER not in output or 'ERROR:' in output:
            raise ValueError('SDK integration failed; see signalfish-sdk.log')
        if inventory(inputs) != before or inventory(executed) != executed_before:
            raise ValueError('source or tool inventory changed during execution')
    report = {'passed': True, 'sdk_revision': manifest['sources']['sdk']['revision'],
              'sdk_archive_digest': manifest['sources']['sdk']['archive']['digest'],
              'engine_sha256': before['engine'], 'input_inventory': before, 'executed_inventory': executed_before,
              'exit': process.returncode, 'marker': MARKER,
              'limits': 'Real pinned SDK decoder, public state, mesh attachment and signals; 70 confirmed two-peer gameplay steps '
                        'through SDK binary send/receive using an injected wire transport; '
                        'no live server, WebRTC or browser transport validation.'}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': str(receipt)}))


if __name__ == '__main__':
    main()
