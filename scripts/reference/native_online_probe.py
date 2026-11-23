#!/usr/bin/env python3
"""Export the installed native online example and qualify live SignalFish rooms."""
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import socket
import sys
import tempfile
import zipfile

from browser.owned_server import OwnedServer
from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from fetch import ROOT, digest, load_manifest
from godot_smoke import prepare_editor, run
from online_install import create_project, install_sdk, server_config
from receipt_arguments import ReceiptParser
from run import begin_results
from signalfish_probe import inventory

sys.path.insert(0, str(ROOT / 'scripts'))
import host_capacity  # noqa: E402
from package_addon import ADDON, snapshot as runtime_snapshot  # noqa: E402

CELLS = tuple(f'{route}:{count}' for route in ('mesh', 'relay') for count in (2, 4, 8)) + ('mesh-startup:4', 'mesh-close:4')
BROWSER = ROOT / 'scripts/reference/browser'
EXTENSION = 'addons/fortress_native/fortress.gdextension'
TEMPLATE = 'web_dlink_nothreads_release.zip'
REPORT = 'native-online.json'
MIN_COMPARED_FRAMES = 40
HISTORY_LIMIT = 128


def install_addon(project, archive):
    addon_folder = PurePosixPath(EXTENSION).parent
    runtime_folder = PurePosixPath(ADDON.as_posix())
    if any((project / directory).exists() for directory in (addon_folder, runtime_folder)):
        raise ValueError('native addon directories must be absent before installation')
    runtime = runtime_snapshot(ROOT)
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        names = [PurePosixPath(entry.filename) for entry in entries]
        if len(set(names)) != len(names) or any(
                name.as_posix() != entry.orig_filename.removesuffix('/') or '..' in name.parts or '\\' in entry.filename
                or not (name.is_relative_to(addon_folder) or name.is_relative_to(runtime_folder))
                for name, entry in zip(names, entries)):
            raise ValueError('native archive must contain only distinct addon files')
        files = {name for name, entry in zip(names, entries) if not entry.is_dir()}
        installed_runtime = {entry.filename for name, entry in zip(names, entries) if name.is_relative_to(runtime_folder)}
        if installed_runtime != runtime.keys():
            raise ValueError(f'native archive runtime differs: missing {sorted(runtime.keys() - installed_runtime)}, '
                             f'extra {sorted(installed_runtime - runtime.keys())}')
        for name, data in runtime.items():
            if package.read(name) != data:
                raise ValueError(f'native archive runtime differs at {name}')
        if PurePosixPath(EXTENSION) not in files or not any(name.suffix == '.wasm' and name.is_relative_to(addon_folder) for name in files):
            raise ValueError('native archive needs a manifest and a Web side module')
        package.extractall(project)
    (project / '.godot').mkdir()
    (project / '.godot/extension_list.cfg').write_text(f'res://{EXTENSION}\n', encoding='utf-8')


def stage_export(root, output, editor, templates, sdk, addon, environment):
    project, export = root / 'game', root / 'web'
    export.mkdir()
    create_project(project, include_runtime=False)
    install_sdk(project, sdk)
    install_addon(project, addon)
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
    config = server_config(source, port, max_players=8, route=route)
    for key in config['rate_limit']:
        if key.startswith('max_'):
            config['rate_limit'][key] = max(config['rate_limit'][key], 1000000)
    return config


def validate_cell(evidence, mode, players):
    required_frames = MIN_COMPARED_FRAMES
    if mode != 'mesh-startup':
        boundary = evidence['afterClose' if mode == 'mesh-close' else 'stalled']
        indices = set()
        for peer in boundary:
            index, frame = peer['index'], peer['frame']
            if type(index) is not int or type(frame) is not int or not 0 <= frame <= HISTORY_LIMIT - 2:
                raise ValueError(f'invalid post-fault frame boundary: {mode}:{players}')
            indices.add(index)
            required_frames = max(required_frames, frame + 2)
        if len(boundary) != players or indices != set(range(players)):
            raise ValueError(f'incomplete post-fault frame boundary: {mode}:{players}')
    compared_frames = evidence.get('compared_frames')
    if (evidence.get('passed') is not True or evidence.get('route') != mode or evidence.get('players') != players
            or type(compared_frames) is not int or compared_frames != required_frames):
        raise ValueError(f'incomplete browser evidence: {mode}:{players}')


def play_cells(cells, export, environment, server_source, server_binary, output):
    results = []
    for route in ('mesh', 'relay'):
        selected = [cell for cell in cells if cell.split(':')[0].split('-')[0] == route]
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
                    mode, players = cell.split(':')
                    command = ['node', str(BROWSER / 'native_online.cjs'), str(export), f'ws://127.0.0.1:{port}/v3/ws', mode, players]
                    evidence = json.loads(run_browser(command, environment, output / f'{mode}-{players}.log', rooms=1))
                    validate_cell(evidence, mode, int(players))
                    results.append(evidence)
                    print(f'{cell} passed', flush=True)
                server.verify_live()
    return results


def main():
    parser = ReceiptParser(description=__doc__, receipt=REPORT)
    parser.add_argument('--version', help='pinned Godot version, defaults to current stable')
    parser.add_argument('--cell', action='append', choices=CELLS)
    parser.add_argument('--cache', type=Path, default=ROOT / '.cache/reference')
    parser.add_argument('--addon', type=Path, required=True, help='complete Web addon archive for this revision')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output, cache, addon = args.output.resolve(), args.cache.resolve(), args.addon.resolve()
    logs = [cell.replace(':', '-') + '.log' for cell in CELLS]
    logs += ['mesh-server.log', 'relay-server.log', 'import.log', 'export.log', 'version.log', 'tls.log']
    begin_results(output, REPORT, logs)
    receipt = output / REPORT
    manifest = load_manifest()
    versions = (manifest['godot']['minimum'], manifest['godot']['current_stable'])
    if args.version is None:
        args.version = versions[-1]
    elif args.version not in versions:
        parser.error(f'--version must be one of {", ".join(versions)}')
    environment = os.environ.copy()
    for variable in ('FORTRESS_PLAYWRIGHT_PACKAGE', 'FORTRESS_CHROMIUM_EXECUTABLE'):
        if not environment.get(variable):
            parser.error(f'{variable} must name the installed browser tool')
    stem = f'Godot_v{args.version}-stable'
    editor = prepare_editor(manifest, args.version, offline=True, cache=cache)
    templates = cache / f'downloads/{stem}_export_templates.tpz'
    sdk_pin, server_pin = (manifest['sources'][kind] for kind in ('sdk', 'server'))
    sdk, server_source = (cache / pin['root'] for pin in (sdk_pin, server_pin))
    server_binary = cache / f"server-target/{server_pin['revision']}/debug/signal-fish-server"
    files = {'editor': editor, 'templates': templates, 'addon': addon, 'server': server_binary,
             'server_config': server_source / 'config.example.json', 'chromium': Path(environment['FORTRESS_CHROMIUM_EXECUTABLE']),
             'runner': Path(__file__), 'editor_setup': BROWSER.parent / 'godot_smoke.py', 'artifact_helper': BROWSER.parent / 'fetch.py',
             'client': BROWSER / 'native_online.cjs', 'host': BROWSER / 'online_host.cjs',
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
