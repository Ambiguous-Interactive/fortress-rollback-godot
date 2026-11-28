#!/usr/bin/env python3
"""Export the installed native online example and qualify live SignalFish rooms."""
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zipfile

from browser.local_stun import local_port, local_stun
from browser.owned_server import OwnedServer
from browser.native_relay_stage import instrument_relay_delivery
from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from fetch import MANIFEST, ROOT, digest, parse_manifest
from godot_smoke import prepare_editor, run
from online_install import create_project, install_sdk, server_config
from receipt_arguments import ReceiptParser
from run import begin_results
from signalfish_probe import file_identity, inventory

sys.path.insert(0, str(ROOT / 'scripts'))
import host_capacity  # noqa: E402
from package_addon import ADDON, snapshot as runtime_snapshot  # noqa: E402
sys.path.insert(0, str(ROOT / 'scripts/oracle'))
from source_wire import REVIEWED_REVISION, wire_version  # noqa: E402

OVERLAP_CELL = 'mesh-recovery-overlap:4'
CELLS = tuple(f'{route}:{count}' for route in ('mesh', 'relay') for count in (2, 4, 8)) + (
    'mesh-startup:4', 'mesh-close:4', 'mesh-recovery:4', OVERLAP_CELL)
RECOVERY_MODES = ('mesh-recovery', 'mesh-recovery-overlap')
BROWSER_PAIRS = ('chromium', 'firefox', 'webkit', 'chromium-firefox', 'chromium-webkit', 'firefox-webkit')
BROWSER = ROOT / 'scripts/reference/browser'
TRACE_SOURCE = Path(__file__).with_name('server_trace')
EXTENSION = 'addons/fortress_native/fortress.gdextension'
TEMPLATE = 'web_dlink_nothreads_release.zip'
REPORT = 'native-online.json'
MIN_COMPARED_FRAMES = 40
HISTORY_LIMIT = 128
RECOVERY_HISTORY_LIMIT = 512


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


def stage_export(root, output, editor, templates, sdk, addon, environment, trace_relay_wire=False):
    project, export = root / 'game', root / 'web'
    export.mkdir()
    create_project(project, include_runtime=False)
    install_sdk(project, sdk)
    install_addon(project, addon)
    if trace_relay_wire:
        instrument_relay_delivery(project)
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


def create_server_config(source, route, port, stun_server=None):
    config = server_config(source, port, max_players=8, route=route)
    if route == 'mesh' and stun_server is not None:
        config['session']['ice_servers'] = [{'urls': [stun_server]}]
    for key in config['rate_limit']:
        if key.startswith('max_'):
            config['rate_limit'][key] = max(config['rate_limit'][key], 1000000)
    return config


def validate_cell(evidence, mode, players, browser_pair):
    required_frames = MIN_COMPARED_FRAMES
    if mode != 'mesh-startup':
        boundary = evidence['restored' if mode in RECOVERY_MODES else 'afterClose' if mode == 'mesh-close' else 'stalled']
        limit = RECOVERY_HISTORY_LIMIT if mode in RECOVERY_MODES else HISTORY_LIMIT
        indices = set()
        for peer in boundary:
            index, frame = peer['index'], peer['frame']
            if type(index) is not int or type(frame) is not int or not 0 <= frame <= limit - 2:
                raise ValueError(f'invalid post-fault frame boundary: {mode}:{players}')
            indices.add(index)
            required_frames = max(required_frames, frame + 2)
        if len(boundary) != players or indices != set(range(players)):
            raise ValueError(f'incomplete post-fault frame boundary: {mode}:{players}')
    compared_frames = evidence.get('compared_frames')
    if (evidence.get('passed') is not True or evidence.get('route') != mode or evidence.get('players') != players
            or type(compared_frames) is not int or compared_frames != required_frames):
        raise ValueError(f'incomplete browser evidence: {mode}:{players}')
    peers = evidence.get('browser_peers', [])
    if not isinstance(peers, list) or len(peers) != players or any(
            not isinstance(peer, dict) or type(peer.get('index')) is not int or peer['index'] != index
            or peer.get('name') != browser_pair[index % len(browser_pair)]
            or not isinstance(peer.get('version'), str) or not peer['version'].strip()
            for index, peer in enumerate(peers)):
        raise ValueError(f'wrong browser composition: {mode}:{players}')


def play_cells(cells, attempted_cells, export, environment, server_source, server_binary, output, browser_pair, stun_server, control, trace_server):
    results = []
    routes = {route: [cell for cell in cells if cell.split(':')[0].split('-')[0] == route] for route in ('mesh', 'relay')}
    groups = [('relay', [cell]) for cell in routes['relay']] if trace_server else [(route, selected) for route, selected in routes.items() if selected]
    for route, selected in groups:
        port = local_port()
        config = create_server_config(server_source, route, port, stun_server)
        server_environment = {'PATH': environment['PATH'], 'SIGNAL_FISH_CONFIG_JSON': json.dumps(config), 'RUST_LOG': 'error'}
        label = selected[0].replace(':', '-') if trace_server else route
        browser_environment = environment.copy()
        if trace_server:
            trace_paths = {'FORTRESS_RELAY_TRACE_SCOPE': str(output / f'{label}-server-scope.json'),
                           'FORTRESS_RELAY_TRACE_OUTPUT': str(output / f'{label}-server-trace.json')}
            server_environment.update(trace_paths)
            browser_environment.update(trace_paths)
        else:
            for variable in ('FORTRESS_RELAY_TRACE_SCOPE', 'FORTRESS_RELAY_TRACE_OUTPUT'):
                browser_environment.pop(variable, None)
        with (output / f'{label}-server.log').open('wb') as log:
            with OwnedServer(server_binary, server_environment, port, log) as server:
                for cell in selected:
                    mode, players = cell.split(':')
                    command = ['node', str(BROWSER / 'native_online.cjs'), str(export), f'ws://127.0.0.1:{port}/v3/ws', mode, players,
                               '-'.join(browser_pair)]
                    if control:
                        command.append(control)
                    attempted_cells.append(cell)
                    evidence = json.loads(run_browser(command, browser_environment, output / f'{mode}-{players}.log', rooms=1))
                    validate_cell(evidence, mode, int(players), browser_pair)
                    results.append(evidence)
                    print(f'{cell} passed', flush=True)
                server.verify_live()
    return results


def validate_trace_build(receipt, revision, frozen):
    contents = receipt.read_bytes()
    build = json.loads(contents.decode('utf-8'))
    if (hashlib.sha256(contents).hexdigest() != frozen['relay_trace_build'] or not isinstance(build, dict)
            or build.get('format') != 1 or build.get('passed') is not True or build.get('source_revision') != revision
            or build.get('binary_sha256') != frozen['server']):
        raise ValueError('relay trace server build receipt does not match the pinned binary')
    inputs = build.get('input_inventory')
    if not isinstance(inputs, dict) or inputs.get('pins') != frozen['pins']:
        raise ValueError('relay trace server build receipt does not match the current pin manifest')
    if not isinstance(inputs, dict) or any(inputs.get(name) != frozen['relay_trace_' + name] for name in ('patch', 'module')):
        raise ValueError('relay trace server build receipt does not match the current trace sources')


def publish_room_receipt(receipt, logs, evidence, files, export, started_identities, outcome):
    existing_logs = {name: receipt.parent / name for name in logs if (receipt.parent / name).is_file()}
    report = {**evidence, **outcome, 'logs': inventory(existing_logs)}
    pending = receipt.with_suffix('.json.next')
    try:
        pending.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        identities = {}
        for sources, expected in ((files, evidence['inputs']), ({'export': export}, evidence['export'])):
            actual = inventory(sources, identities=identities)
            if actual != expected:
                changed = next(name for name in sorted(actual.keys() | expected.keys()) if actual.get(name) != expected.get(name))
                raise ValueError(f'native browser witness inputs changed during execution: {changed}')
        changed = next((path for path, identity in identities.items()
                        if started_identities.get(path) != identity or file_identity(path.lstat()) != identity), None)
        if changed is None:
            changed = min(started_identities.keys() - identities.keys(), default=None)
        if changed is not None:
            raise ValueError(f'native browser witness inputs changed during execution: {changed}')
        pending.replace(receipt)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = ReceiptParser(description=__doc__, receipt=REPORT)
    parser.add_argument('--version', help='pinned Godot version, defaults to current stable')
    parser.add_argument('--source-revision', help='exact Fortress revision, defaults to the reviewed pin')
    parser.add_argument('--cell', action='append', choices=CELLS)
    parser.add_argument('--omit-second-replacement', action='store_true', help='negative control for the overlapping recovery cell')
    parser.add_argument('--trace-relay-wire', action='store_true', help='capture bounded browser, SDK and native inbox packet receipts in relay cells')
    parser.add_argument('--relay-trace-server', type=Path, help='build receipt for the optional instrumented local relay server')
    parser.add_argument('--release-delay', choices=('delivery', 'continuation'), help='delay one boundary in a Firefox relay:8 room')
    retention = parser.add_mutually_exclusive_group()
    retention.add_argument('--trace-chromium-socket', action='store_const', dest='receive_trace', const='--trace-chromium-socket',
                           help='diagnose relay receipt using bounded Chromium socket capture')
    retention.add_argument('--trace-chromium-frames', action='store_const', dest='receive_trace', const='--trace-chromium-frames',
                           help='add Chromium renderer receive evidence to a Chromium or mixed relay room')
    retention.add_argument('--trace-firefox-frames', action='store_const', dest='receive_trace', const='--trace-firefox-frames',
                           help='diagnose relay receipt using bounded Firefox frame capture')
    retention.add_argument('--trace-mixed-receive', action='store_const', dest='receive_trace', const='--trace-mixed-receive',
                           help='capture Chromium and Firefox receive evidence in the same relay room')
    retention.add_argument('--relay-retention-control', action='store_const', dest='relay_control', const='--relay-retention-control',
                           help='mute one link while a traced eight-player room continues traffic')
    retention.add_argument('--relay-same-link-control', action='store_const', dest='relay_control', const='--relay-same-link-control',
                           help='drop addressed delivery while the same link continues sending')
    parser.add_argument('--browser-pair', choices=BROWSER_PAIRS, default='chromium', help='single engine or alternating engines in each room')
    parser.add_argument('--cache', type=Path, default=ROOT / '.cache/reference')
    parser.add_argument('--addon', type=Path, required=True, help='complete Web addon archive for this revision')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output, cache, addon = args.output.resolve(), args.cache.resolve(), args.addon.resolve()
    logs = [cell.replace(':', '-') + '.log' for cell in CELLS]
    logs += ['mesh-server.log', 'relay-server.log', 'import.log', 'export.log', 'version.log', 'tls.log', 'stun.log']
    trace_files = ('.log', '-scope.json', '-scope.json.new', '-trace.json', '-trace.json.request', '-trace.json.request.next')
    logs += [f'relay-{players}-server{suffix}' for players in (2, 4, 8) for suffix in trace_files]
    receipt = output / REPORT
    begin_results(output, REPORT, [*logs, receipt.with_suffix('.json.next').name])
    manifest_bytes = MANIFEST.read_bytes()
    manifest = parse_manifest(manifest_bytes)
    source_revision = manifest['sources']['fortress']['revision'] if args.source_revision is None else args.source_revision
    wire = wire_version(source_revision)
    profile_generation = 1 if source_revision == REVIEWED_REVISION else wire
    native_profile = f'fortress-native-{source_revision[:8]}-v{profile_generation}-u32'
    versions = (manifest['godot']['minimum'], manifest['godot']['current_stable'])
    if args.version is None:
        args.version = versions[-1]
    elif args.version not in versions:
        parser.error(f'--version must be one of {", ".join(versions)}')
    environment = os.environ.copy()
    environment['FORTRESS_NATIVE_SOURCE_REVISION'] = source_revision
    browser_pair = tuple(args.browser_pair.split('-'))
    tools = {name: f'FORTRESS_{name.upper()}_EXECUTABLE' for name in browser_pair}
    if 'firefox' in browser_pair:
        tools['xdotool'] = 'FORTRESS_XDOTOOL_EXECUTABLE'
    for variable in ('FORTRESS_PLAYWRIGHT_PACKAGE', *tools.values()):
        if not environment.get(variable):
            parser.error(f'{variable} must name the installed browser tool')
    cells = tuple(dict.fromkeys(args.cell)) if args.cell else CELLS
    if args.omit_second_replacement and cells != (OVERLAP_CELL,):
        parser.error(f'--omit-second-replacement requires --cell {OVERLAP_CELL}')
    trace_wire = args.trace_relay_wire or args.relay_trace_server is not None
    if trace_wire and any(not cell.startswith('relay:') for cell in cells):
        parser.error('relay tracing requires explicit relay cells')
    if args.receive_trace == '--trace-chromium-socket' and (not args.relay_trace_server or browser_pair != ('chromium',)):
        parser.error('--trace-chromium-socket requires --relay-trace-server and --browser-pair chromium')
    if args.receive_trace == '--trace-chromium-frames' and (not args.relay_trace_server or args.browser_pair not in ('chromium', 'chromium-firefox')):
        parser.error('--trace-chromium-frames requires --relay-trace-server and a Chromium or chromium-firefox browser profile')
    if args.receive_trace == '--trace-firefox-frames' and (not args.relay_trace_server or 'firefox' not in browser_pair):
        parser.error('--trace-firefox-frames requires --relay-trace-server and a Firefox browser profile')
    if args.receive_trace == '--trace-mixed-receive' and (not args.relay_trace_server or args.browser_pair != 'chromium-firefox'):
        parser.error('--trace-mixed-receive requires --relay-trace-server and --browser-pair chromium-firefox')
    if args.relay_control and (not args.relay_trace_server or cells != ('relay:8',)):
        parser.error(f'{args.relay_control} requires --relay-trace-server and --cell relay:8')
    if args.release_delay and (args.browser_pair != 'firefox' or cells != ('relay:8',) or trace_wire):
        parser.error('--release-delay requires an untraced Firefox relay:8 cell')
    control = args.relay_control or args.receive_trace
    if control is None:
        control = '--trace-relay-wire' if trace_wire else '--omit-second-replacement' if args.omit_second_replacement else None
    if args.release_delay:
        control = f'--delay-release-{args.release_delay}'
    stun_tool = None
    if browser_pair != ('chromium',) and any(cell.startswith('mesh') for cell in cells):
        stun = environment.get('FORTRESS_STUN_EXECUTABLE') or shutil.which('turnserver')
        if not stun:
            parser.error('install Coturn or set FORTRESS_STUN_EXECUTABLE to its turnserver binary')
        stun_tool = Path(stun)
    stem = f'Godot_v{args.version}-stable'
    editor = prepare_editor(manifest, args.version, offline=True, cache=cache)
    templates = cache / f'downloads/{stem}_export_templates.tpz'
    sdk_pin, server_pin = (manifest['sources'][kind] for kind in ('sdk', 'server'))
    sdk, server_source = (cache / pin['root'] for pin in (sdk_pin, server_pin))
    server_binary = cache / f"server-target/{server_pin['revision']}/debug/signal-fish-server"
    trace_build = args.relay_trace_server.resolve() if args.relay_trace_server else None
    if trace_build is not None:
        server_binary = trace_build.with_name('signal-fish-server')
    files = {'pins': MANIFEST, 'editor': editor, 'templates': templates, 'addon': addon, 'server': server_binary,
             'server_config': server_source / 'config.example.json', **{name: Path(environment[var]) for name, var in tools.items()},
             'runner': Path(__file__), 'editor_setup': BROWSER.parent / 'godot_smoke.py', 'artifact_helper': BROWSER.parent / 'fetch.py',
             'source_wire': ROOT / 'scripts/oracle/source_wire.py', 'wire_contract': ROOT / 'scripts/oracle/contract.py',
             'inventory_helper': BROWSER.parent / 'signalfish_probe.py',
             'client': BROWSER / 'native_online.cjs', 'host': BROWSER / 'online_host.cjs', 'display': BROWSER / 'webrtc_display.cjs',
             'watchdog': BROWSER / 'webrtc_watchdog.cjs', 'recovery': BROWSER / 'native_recovery.cjs', 'local_stun': BROWSER / 'local_stun.py',
             'relay_proxy': BROWSER / 'native_relay_proxy.cjs', 'chromium_socket': BROWSER / 'native_chromium_socket.cjs',
             'chromium_frames': BROWSER / 'native_chromium_frames.cjs', 'firefox_frames': BROWSER / 'native_firefox_frames.cjs',
             'bridge': BROWSER / 'native_online_bridge.gd', 'sdk': sdk / 'addons/signal_fish', 'relay_wire_trace': BROWSER / 'native_relay_trace.cjs',
             'relay_stage': BROWSER / 'native_relay_stage.py', 'relay_control': BROWSER / 'native_relay_control.cjs',
             'relay_hold': BROWSER / 'native_relay_hold.cjs', 'departure_clock': BROWSER / 'native_departure_clock.cjs',
             'runtime': ROOT / 'addons/fortress_rollback', 'example': ROOT / 'examples'}
    if 'firefox' in browser_pair and args.receive_trace in ('--trace-firefox-frames', '--trace-mixed-receive', '--trace-chromium-frames'):
        resolve_core = "console.log(require('node:module').createRequire(require.resolve(process.argv[1])).resolve('playwright-core/lib/coreBundle'))"
        files['playwright_core'] = Path(subprocess.check_output(
            ['node', '-e', resolve_core, environment['FORTRESS_PLAYWRIGHT_PACKAGE']], env=environment, text=True, timeout=10).strip())
    if stun_tool is not None:
        files['stun'] = stun_tool
        files['stun_readiness'] = BROWSER.parent / 'signalfish_live_probe.py'
    if trace_build is not None:
        files.update(relay_trace_build=trace_build, relay_trace_patch=TRACE_SOURCE / 'hooks.patch',
                     relay_trace_module=TRACE_SOURCE / 'relay_packet_trace.rs')
    started_identities = {}
    frozen = inventory(files, identities=started_identities)
    if frozen['pins'] != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError('pin manifest changed during native browser witness setup')
    if trace_build is not None:
        validate_trace_build(trace_build, server_pin['revision'], frozen)
    template_pin = manifest['artifacts'][templates.name]
    if digest(templates, template_pin['algorithm']) != template_pin['digest']:
        raise ValueError('export template archive differs from the pinned digest')
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
        export, staged = stage_export(root, output, editor, templates, sdk, addon, environment, trace_wire)
        affinity = getattr(os, 'sched_getaffinity', None)
        attempted_cells = []
        evidence = {'engine': actual, 'cells': cells, 'browser_pair': args.browser_pair, 'control': control,
                    'source_revision': source_revision, 'wire_version': wire, 'native_profile': native_profile,
                    'attempted_cells': attempted_cells, 'cpu_affinity': sorted(affinity(0)) if affinity else None, 'inputs': frozen, 'staged': staged,
                    'export': inventory({'export': export}, identities=started_identities)}
        try:
            if not host_capacity.acquire_when_free('native-online-witness', 600):
                raise ValueError('development host stayed busy')
            room_error = None
            try:
                stun = local_stun(stun_tool, root, output / 'stun.log') if stun_tool is not None else nullcontext(None)
                with stun as stun_server:
                    evidence['stun_server'] = stun_server
                    results = play_cells(cells, attempted_cells, export, environment, server_source, server_binary,
                                         output, browser_pair, stun_server, control, trace_build is not None)
            except BaseException as failure:
                room_error = failure
                raise
            finally:
                try:
                    host_capacity.release()
                except OSError as release_error:
                    if room_error is None:
                        raise
                    room_error.add_note(f'Could not release the native browser host: {release_error}')
            if args.omit_second_replacement:
                raise ValueError('overlapping recovery passed with the second replacement omitted')
            if args.release_delay and any(room.get('releaseDelay') != args.release_delay for room in results):
                raise ValueError('missing release delay control evidence')
        except Exception as error:
            try:
                publish_room_receipt(receipt, logs, evidence, files, export, started_identities, {'passed': False})
            except (OSError, ValueError) as receipt_error:
                error.add_note(f'Could not publish native browser failure receipt: {receipt_error}')
            raise
        publish_room_receipt(receipt, logs, evidence, files, export, started_identities, {'passed': True, 'results': results})


if __name__ == '__main__':
    main()
