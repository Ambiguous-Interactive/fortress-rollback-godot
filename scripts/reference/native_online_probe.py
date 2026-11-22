#!/usr/bin/env python3
"""Export the installed native online example and qualify live SignalFish rooms."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import sys
import tempfile
import zipfile

from browser.owned_server import OwnedServer
from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from fetch import ROOT, digest, load_manifest
from godot_smoke import run
from online_install import create_project, install_sdk, server_config
from signalfish_probe import inventory

sys.path.insert(0, str(ROOT / 'scripts'))
import host_capacity  # noqa: E402

CELLS = tuple(f'{route}:{count}' for route in ('mesh', 'relay') for count in (2, 4, 8))
BROWSER = ROOT / 'scripts/reference/browser'
EXTENSION = 'addons/fortress_native/fortress.gdextension'
TEMPLATE = 'web_dlink_nothreads_release.zip'


def install_extension(project, archive):
    addon_folder = Path(EXTENSION).parent
    with zipfile.ZipFile(archive) as package:
        members = [Path(item.filename) for item in package.infolist() if not item.is_dir()]
        if len(set(members)) != len(members) or any(not member.is_relative_to(addon_folder) or '..' in member.parts for member in members):
            raise ValueError('native archive must contain only distinct addon files')
        if Path(EXTENSION) not in members or not any(member.suffix == '.wasm' for member in members):
            raise ValueError('native archive needs a manifest and a Web side module')
        package.extractall(project)
    (project / '.godot').mkdir()
    (project / '.godot/extension_list.cfg').write_text(f'res://{EXTENSION}\n', encoding='utf-8')


def stage_export(root, output, editor, templates, sdk, addon, environment):
    project, export = root / 'game', root / 'web'
    export.mkdir()
    create_project(project)
    install_sdk(project, sdk)
    install_extension(project, addon)
    shutil.copyfile(BROWSER / 'native_online_bridge.gd', project / 'bridge.gd')
    config = project / 'project.godot'
    config.write_text(config.read_text().replace('res://examples/online/online.tscn', 'res://bridge.tscn'), encoding='utf-8')
    (project / 'bridge.tscn').write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://bridge.gd" id="1"]\n'
        '[node name="NativeOnlineWitness" type="Node"]\nscript = ExtResource("1")\n', encoding='utf-8')
    custom_template = root / TEMPLATE
    with zipfile.ZipFile(templates) as package:
        custom_template.write_bytes(package.read('templates/' + TEMPLATE))
    preset = project / 'export_presets.cfg'
    preset.write_text(preset.read_text().replace('variant/extensions_support=false', 'variant/extensions_support=true')
                      + f'custom_template/release="{custom_template.as_posix()}"\n', encoding='utf-8')
    tracked = {item.name: item for item in project.iterdir() if item.name != '.godot'}
    before = inventory(tracked)
    command = [str(editor), '--headless', '--path', str(project)]
    run(command + ['--editor', '--quit'], environment, output / 'import.log')
    frozen = freeze_after_import(tracked, before, uid_suffixes=('.gd.uid', '.gdextension.uid'))
    run(command + ['--export-release', 'Web', str(export / 'index.html')], environment, output / 'export.log')
    if inventory(tracked) != frozen:
        raise ValueError('Web export changed the staged project')
    return export, frozen


def create_server_config(source, route, port):
    config = server_config(source, port)
    config['security']['allowed_apps'][0]['max_players_per_room'] = 8
    if route == 'relay':
        config['session'].update(default_topology='relay', enable_webrtc=False)
    for key in config['rate_limit']:
        if key.startswith('max_'):
            config['rate_limit'][key] = max(config['rate_limit'][key], 1000000)
    return config


def play_cells(cells, export, environment, server_source, server_binary, output):
    results = []
    for route in ('mesh', 'relay'):
        selected = [cell for cell in cells if cell.startswith(route + ':')]
        if not selected:
            continue
        with socket.socket() as selection:
            selection.bind(('127.0.0.1', 0))
            port = selection.getsockname()[1]
        config = create_server_config(server_source, route, port)
        server_environment = {'PATH': environment['PATH'], 'SIGNAL_FISH_CONFIG_JSON': json.dumps(config), 'RUST_LOG': 'error'}
        with (output / f'{route}-server.log').open('wb') as log:
            with OwnedServer(server_binary, server_environment, port, log) as server:
                for cell in selected:
                    players = cell.split(':')[1]
                    command = ['node', str(BROWSER / 'native_online.cjs'), str(export), f'ws://127.0.0.1:{port}/v3/ws', route, players]
                    evidence = json.loads(run_browser(command, environment, output / f'{route}-{players}.log', rooms=1))
                    if (evidence.get('passed') is not True or evidence.get('route') != route
                            or evidence.get('players') != int(players) or evidence.get('compared_frames') != 40):
                        raise ValueError(f'incomplete browser evidence: {cell}')
                    results.append(evidence)
                    print(f'{cell} passed', flush=True)
                server.verify_live()
    return results


def main():
    manifest = load_manifest()
    versions = (manifest['godot']['minimum'], manifest['godot']['current_stable'])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', choices=versions, default=versions[-1])
    parser.add_argument('--cell', action='append', choices=CELLS)
    parser.add_argument('--cache', type=Path, default=ROOT / '.cache/reference')
    parser.add_argument('--addon', type=Path, required=True, help='locally built Web addon archive for this revision')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output, cache, addon = args.output.resolve(), args.cache.resolve(), args.addon.resolve()
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / 'native-online.json'
    receipt.unlink(missing_ok=True)
    environment = os.environ.copy()
    for variable in ('FORTRESS_PLAYWRIGHT_PACKAGE', 'FORTRESS_CHROMIUM_EXECUTABLE'):
        if not environment.get(variable):
            parser.error(f'{variable} must name the installed browser tool')
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}[platform.machine()]
    stem = f'Godot_v{args.version}-stable'
    editor = cache / f'editors/{args.version}/{stem}_linux.{arch}'
    templates = cache / f'downloads/{stem}_export_templates.tpz'
    sdk_pin, server_pin = (manifest['sources'][kind] for kind in ('sdk', 'server'))
    sdk, server_source = (cache / pin['root'] for pin in (sdk_pin, server_pin))
    server_binary = cache / f"server-target/{server_pin['revision']}/debug/signal-fish-server"
    files = {'editor': editor, 'templates': templates, 'addon': addon, 'server': server_binary,
             'server_config': server_source / 'config.example.json', 'chromium': Path(environment['FORTRESS_CHROMIUM_EXECUTABLE']),
             'runner': Path(__file__), 'client': BROWSER / 'native_online.cjs', 'host': BROWSER / 'online_host.cjs',
             'bridge': BROWSER / 'native_online_bridge.gd', 'sdk': sdk / 'addons/signal_fish',
             'runtime': ROOT / 'addons/fortress_rollback', 'example': ROOT / 'examples'}
    frozen = inventory(files)
    template_pin = manifest['artifacts'][templates.name]
    if digest(templates, template_pin['algorithm']) != template_pin['digest']:
        raise ValueError('export template archive differs from the pinned digest')
    cells = tuple(dict.fromkeys(args.cell or CELLS))
    with tempfile.TemporaryDirectory(prefix='native-online-', dir=output) as directory:
        root = Path(directory)
        for kind in ('CONFIG', 'CACHE', 'DATA'):
            environment['XDG_' + kind + '_HOME'] = str(root / kind.lower())
        certificate, key = root / 'localhost.crt', root / 'localhost.key'
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
             '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(key), '-out', str(certificate)], environment, output / 'tls.log')
        environment.update(FORTRESS_TLS_CERT=str(certificate), FORTRESS_TLS_KEY=str(key))
        actual = run([str(editor), '--version'], environment, output / 'version.log').strip()
        if not actual.startswith(args.version + '.stable.'):
            raise ValueError(f'unexpected Godot version: {actual}')
        export, staged = stage_export(root, output, editor, templates, sdk, addon, environment)
        exported = inventory({'export': export})
        if not host_capacity.acquire_when_free('native-online-witness', 600):
            raise ValueError('development host stayed busy')
        try:
            results = play_cells(cells, export, environment, server_source, server_binary, output)
        finally:
            host_capacity.release()
        if inventory(files) != frozen or inventory({'export': export}) != exported:
            raise ValueError('native browser witness inputs changed during execution')
    receipt.write_text(json.dumps({'passed': True, 'engine': actual, 'cells': cells, 'inputs': frozen,
                                   'staged': staged, 'export': exported, 'results': results}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
