#!/usr/bin/env python3
"""Run production Fortress spectator adapters over actual SignalFish and authenticated loopback control."""
import json
import hashlib
import platform
import sys
import zipfile
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile

from fetch import CACHE, ROOT, digest, fetch, load_manifest
from engine_path import resolve_engine
from receipt_arguments import ReceiptParser
from signalfish_probe import inventory
from signalfish_live_probe import (build_cargo, extract, source_inventory, validate_build_receipt, wait_ready)
from spectator_control import Control
import host_capacity
import local_ownership
import spectator_browser
from browser.webrtc_import import freeze_after_import

FILES = ['signalfish_spectator_live.gd', 'spectator_live_game.gd']
MARKER = 'FORTRESS_LIVE_SPECTATOR_RESULT '
FAILURE = 'FORTRESS_LIVE_SPECTATOR_FAILED '
DEPARTURE = 'FORTRESS_LIVE_SPECTATOR_DEPARTURE '
LATE_SIGNALS = ['spectator_join_failed', 'spectator_left', 'spectator_disconnected']


def validate_result(returncode, output):
    rows = [json.loads(line[len(MARKER):]) for line in output.splitlines() if line.startswith(MARKER)]
    if returncode != 0 or 'ERROR:' in output or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ValueError('live spectator failed; inspect native.log')
    result = rows[0]
    for field, expected in [('passed', True), ('frames', 48), ('compared', 48), ('seated_players', 2), ('viewer_seated', False), ('provisioning_controls', 7)]:
        if type(result.get(field)) is not type(expected) or result[field] != expected:
            raise ValueError('incomplete live spectator evidence: ' + field)
    if any(type(result.get(field)) is not int or result[field] < 1 for field in ['host_rollbacks', 'binary_receives', 'viewer_binary_receives']):
        raise ValueError('unobserved rollback or actual binary receipt')
    if type(result.get('catchup_steps')) is not int or not 2 <= result['catchup_steps'] <= 4 or type(result.get('paused_frames')) is not int or result['paused_frames'] != 8:
        raise ValueError('paused catch-up evidence missing')
    return result


def validate_late_failure(returncode, output, signal_name):
    rows = [json.loads(line[len(FAILURE):]) for line in output.splitlines() if line.startswith(FAILURE)]
    if returncode != 1 or MARKER in output or 'ERROR:' in output or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ValueError('late spectator failure was not rejected cleanly')
    if rows[0].get('reason') != 'late SDK error or spectator altered host seats' or signal_name not in rows[0].get('errors', []):
        raise ValueError('late spectator control failed before its intended boundary')
    return {'signal': signal_name, 'rejected': True}


def validate_departure(returncode, output, departure):
    rows = [json.loads(line[len(DEPARTURE):]) for line in output.splitlines() if line.startswith(DEPARTURE)]
    if returncode != 0 or 'ERROR:' in output or MARKER in output or FAILURE in output or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ValueError('physical spectator departure was not verified')
    result = rows[0]
    for field, expected in [('passed', True), ('departure', departure), ('remote_departure', True), ('socket_closed', True),
                            ('host_continued', departure == 'viewer'), ('host_frame', 21 if departure == 'viewer' else 20)]:
        if type(result.get(field)) is not type(expected) or result[field] != expected:
            raise ValueError('incomplete physical departure evidence: ' + field)
    for field, minimum in [('buffered_rows', 2), ('viewer_frame', 1), ('compared', 1), ('viewer_binary_receives', 1)]:
        if type(result.get(field)) is not int or result[field] < minimum:
            raise ValueError('missing paused history at physical departure: ' + field)
    if result['viewer_frame'] != result['compared'] or result['viewer_frame'] >= 20 or result['viewer_frame'] + result['buffered_rows'] > 20:
        raise ValueError('inconsistent physical departure history')
    return result


def verify_engine(engine, data, offline):
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if platform.system() != 'Linux' or arch is None:
        raise ValueError('native spectator witness supports Linux arm64/x86_64')
    actual = digest(engine)
    for version in [data['godot']['minimum'], data['godot']['current_stable']]:
        name = f'Godot_v{version}-stable_linux.{arch}'
        archive = fetch(data['artifacts'][name + '.zip'], name + '.zip', offline)
        with zipfile.ZipFile(archive) as package, package.open(name) as member:
            expected = hashlib.file_digest(member, 'sha256').hexdigest()
        if actual == expected:
            return archive, version
    raise ValueError('supplied Godot bytes do not match either pinned editor')


def main():
    parser = ReceiptParser(description=__doc__, receipt='spectator-live.json')
    parser.add_argument('--godot', required=True)
    parser.add_argument('--server', required=True, type=Path)
    parser.add_argument('--server-source', required=True, type=Path)
    parser.add_argument('--build-receipt', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    scenario = parser.add_mutually_exclusive_group()
    scenario.add_argument('--late-signal', choices=LATE_SIGNALS)
    scenario.add_argument('--departure', choices=['host', 'viewer'])
    scenario.add_argument('--browser-viewer', action='store_true')
    parser.add_argument('--browser-fault', choices=['initial-state'])
    args = parser.parse_args()
    if args.browser_fault and not args.browser_viewer:
        parser.error('--browser-fault requires --browser-viewer')
    args.output.mkdir(parents=True, exist_ok=True)
    with local_ownership.claim('spectator-live', directory=args.output):
        try:
            run(args)
        finally:
            host_capacity.release()


def run(args):
    receipt = args.output / 'spectator-live.json'
    receipt.write_text(json.dumps({'passed': False, 'failure': 'in_progress'}) + '\n')
    if not host_capacity.acquire_when_free('live-spectator-witness', 900):
        raise ValueError('development host stayed busy before spectator witness')
    data = load_manifest()
    sdk = data['sources']['sdk']
    server_pin = data['sources']['server']
    sdk_archive = fetch(sdk['archive'], 'sdk.tar.gz', args.offline)
    server_archive = fetch(server_pin['archive'], 'server.tar.gz', args.offline)
    engine = resolve_engine(args.godot)
    engine_archive, engine_version = verify_engine(engine, data, args.offline)
    server_binary = args.server.resolve()
    build = json.loads(args.build_receipt.read_text())
    cargo = build_cargo(build)
    builder_files = {'builder': ROOT / 'scripts/reference/signalfish_build_server.py', 'fetch': ROOT / 'scripts/reference/fetch.py',
                     'pins': ROOT / 'docs/reference/pins.json', 'run': ROOT / 'scripts/reference/run.py',
                     'native_launcher': ROOT / 'scripts/reference/signalfish_live_probe.py', 'sdk_launcher': ROOT / 'scripts/reference/signalfish_probe.py',
                     'receipt_arguments': ROOT / 'scripts/reference/receipt_arguments.py', 'archive': server_archive,
                     'cargo': cargo, 'rustc': cargo.with_name('rustc')}
    server_before = source_inventory(args.server_source)
    validate_build_receipt(build, server_pin['revision'], server_before, digest(server_binary),
                           {name: digest(path) for name, path in builder_files.items()}, digest(args.build_receipt.parent / 'build.log'))
    sources = {'addon': ROOT / 'addons/fortress_rollback', 'engine': engine, 'server': server_binary, 'sdk_archive': sdk_archive,
               'server_archive': server_archive, 'launcher': Path(__file__).resolve(), 'control': ROOT / 'scripts/reference/spectator_control.py',
               'pins': ROOT / 'docs/reference/pins.json', 'engine_archive': engine_archive,
               'python': Path(sys.executable).resolve(), 'build_receipt': args.build_receipt, 'build_log': args.build_receipt.parent / 'build.log',
               'host_capacity': ROOT / 'scripts/host_capacity.py'}
    sources.update({'build_' + name: path for name, path in builder_files.items()})
    if args.browser_viewer:
        sources.update({name: ROOT / 'scripts/reference' / name for name in spectator_browser.FILES})
        sources['browser_launcher'] = ROOT / 'scripts/reference/spectator_browser.py'
        sources['browser_controller'] = ROOT / 'scripts/reference/browser/spectator.cjs'
        sources['import_freezer'] = ROOT / 'scripts/reference/browser/webrtc_import.py'
        sources['godot_smoke'] = ROOT / 'scripts/reference/godot_smoke.py'
    for helper in ['engine_path.py', 'local_ownership.py', 'receipt_arguments.py', 'signalfish_live_probe.py', 'signalfish_probe.py', 'run.py']:
        sources['helper/' + helper] = ROOT / 'scripts/reference' / helper
    sources.update({name: ROOT / 'scripts/reference' / name for name in FILES})
    before = inventory(sources)
    scratch = CACHE / 'scratch'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='spectator-live-', dir=scratch) as temporary:
        project = Path(temporary)
        sdk_source = extract(sdk_archive, sdk, project / 'sdk')
        server_source = extract(server_archive, server_pin, project / 'server')
        if source_inventory(server_source) != server_before:
            raise ValueError('server source differs from verified archive')
        shutil.copytree(ROOT / 'addons/fortress_rollback', project / 'addons/fortress_rollback')
        shutil.copytree(sdk_source / 'addons/signal_fish', project / 'addons/signal_fish')
        for name in FILES + (spectator_browser.FILES if args.browser_viewer else []):
            shutil.copyfile(sources[name], project / name)
        (project / 'project.godot').write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        config = json.loads((server_source / 'config.example.json').read_text())
        with socket.socket() as selection:
            selection.bind(('127.0.0.1', 0))
            port = selection.getsockname()[1]
        config['port'] = port
        config['session'].update(default_topology='relay', enable_webrtc=False, enable_direct=False, enable_ice_pregather=False)
        config['security']['allowed_apps'][0].update(app_id='fortress-live-relay', app_name='Local spectator witness', max_players_per_room=8,
                                                   rate_limit_per_minute=100000)
        server_config = project / 'server-config.json'
        server_config.write_text(json.dumps(config))
        authored_paths = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish',
                          **{name: project / name for name in FILES + (spectator_browser.FILES if args.browser_viewer else [])}}
        staged_authored = inventory(authored_paths)
        for name, value in staged_authored.items():
            if name.startswith('addon/') or name in FILES + spectator_browser.FILES:
                if before.get(name) != value:
                    raise ValueError('copied witness source differs before import')
        if inventory({'sdk': sdk_source / 'addons/signal_fish'}) != {
                name: value for name, value in staged_authored.items() if name.startswith('sdk/')}:
            raise ValueError('copied SDK source differs before import')
        export_server = None
        browser_environment = None
        if args.browser_viewer:
            arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}[platform.machine()]
            exported, browser_environment, browser_sources = spectator_browser.prepare(
                project, engine, engine_version, data, arch, args.offline, args.output, authored_paths, staged_authored)
            sources.update(browser_sources)
            expanded = inventory(sources)
            if any(expanded.get(name) != value for name, value in before.items()):
                raise ValueError('spectator witness inputs changed during browser preparation')
            before = expanded
            export_server = spectator_browser.ExportServer(exported)
            export_server.start()
        control = Control(allowed_origin=export_server.url if export_server else None)
        try:
            url = control.start()
            runtime = {'endpoint': f'ws://127.0.0.1:{port}/v3/ws', 'control': url, 'host_token': control.host_token,
                       'viewer_token': control.viewer_token, 'identity': secrets.token_hex(32), 'key': secrets.token_hex(32), 'browser_fault': args.browser_fault}
            runtime_path = project / 'runtime.json'
            runtime_path.write_text(json.dumps(runtime))
            runtime_path.chmod(0o600)
            executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish',
                        **{name: project / name for name in FILES + (spectator_browser.FILES if args.browser_viewer else [])},
                        'project': project / 'project.godot', 'runtime': runtime_path, 'server_config': server_config}
            if args.browser_viewer:
                executed.update({'web_export': exported, 'scene': project / 'main.tscn', 'export_preset': project / 'export_presets.cfg'})
            frozen = inventory(executed)
            if args.browser_viewer:
                freeze_after_import(authored_paths, staged_authored)
            elif inventory(authored_paths) != staged_authored:
                raise ValueError('staged native sources changed')
            environment = {'PATH': os.environ.get('PATH', ''), 'SIGNAL_FISH_CONFIG_JSON': json.dumps(config), 'RUST_LOG': 'error'}
            with (args.output / 'server.log').open('wb') as server_log:
                server = subprocess.Popen([str(server_binary)], env=environment, stdout=server_log, stderr=subprocess.STDOUT)
                try:
                    wait_ready(server, port)
                    if args.browser_viewer:
                        result = spectator_browser.execute(engine, project, runtime_path, export_server.url, browser_environment, args.output, control, args.browser_fault)
                        if not args.browser_fault and (control.received < 1 or control.done is None):
                            raise ValueError('browser authenticated acceptance or completion missing')
                    else:
                        command = [str(engine), '--headless', '--path', str(project), '--script', 'res://signalfish_spectator_live.gd', '--', str(runtime_path)]
                        if args.late_signal:
                            command.append(args.late_signal)
                        elif args.departure:
                            command.append(args.departure)
                        try:
                            process = subprocess.run(command, capture_output=True, timeout=75)
                        except subprocess.TimeoutExpired as failure:
                            (args.output / 'native.log').write_bytes((failure.stdout or b'') + (failure.stderr or b''))
                            raise ValueError('live spectator process deadline') from failure
                        if server.poll() is not None:
                            raise ValueError('owned server exited during spectator witness')
                        output = process.stdout + process.stderr
                        (args.output / 'native.log').write_bytes(output)
                        text = output.decode('utf-8')
                        if args.departure:
                            result = validate_departure(process.returncode, text, args.departure)
                        else:
                            result = validate_late_failure(process.returncode, text, args.late_signal) if args.late_signal else validate_result(process.returncode, text)
                        if control.received < 1 or control.rejected < 2:
                            raise ValueError('authenticated control or rejection controls missing')
                    if server.poll() is not None:
                        raise ValueError('owned server exited during spectator witness')
                    if before != inventory(sources) or frozen != inventory(executed) or source_inventory(args.server_source) != server_before:
                        raise ValueError('live witness sources or runtime changed')
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
        finally:
            control.close()
            if export_server:
                export_server.close()
        if args.browser_fault:
            spectator_browser.validate_no_acceptance(control)
        if before != inventory(sources) or frozen != inventory(executed) or source_inventory(args.server_source) != server_before:
            raise ValueError('live witness inputs changed before publication')
        receipt.write_text(json.dumps({'passed': True, 'schema_version': 1, 'result': result, 'sources': before,
                                      'executed': frozen, 'server_source': server_before, 'sdk_revision': sdk['revision'], 'server_revision': server_pin['revision'],
                                      'engine_version': engine_version, 'python_version': sys.version, 'negative_control': args.late_signal, 'departure': args.departure,
                                      'browser_viewer': args.browser_viewer, 'browser_fault': args.browser_fault,
                                      'control_accepts': control.received, 'control_rejections': control.rejected,
                                      'limitations': ['Loopback test admission uses per-run bearer capabilities, not a production identity provider.',
                                                      'Seated remote inputs use an injected deterministic schedule; spectator bytes use real sockets.',
                                                      ('Exported Chromium viewer with native host/seated fixture; exported host and remaining matrix remain unqualified.'
                                                       if args.browser_viewer else
                                                       'Native single-process host/viewer; exported browsers and remaining lifecycle matrix remain unqualified.')
                                                      ]}, indent=2) + '\n')
        print(json.dumps({'passed': True, 'receipt': str(receipt), 'result': result}))


if __name__ == '__main__':
    main()
