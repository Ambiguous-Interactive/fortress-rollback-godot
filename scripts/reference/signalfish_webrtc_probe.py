#!/usr/bin/env python3
"""Verify exported Godot rollback gameplay through real Chromium WebRTC meshes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tempfile
import zipfile

from browser.webrtc_import import freeze_after_import
from fetch import CACHE, ROOT, digest, fetch, load_manifest
from godot_smoke import run
from signalfish_live_probe import (build_cargo, extract, native_inventory, source_inventory, validate_build_receipt, wait_ready)
from signalfish_probe import inventory

def validate_engine(engine, expected):
    if digest(engine) != expected:
        raise ValueError("supplied engine differs from pinned editor archive")

def validate_browser(result, faults):
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('browser') != 'Chromium'
            or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2
            or result.get('faults') is not faults or result.get('corrupt') is not False or result.get('errors') != []):
        raise ValueError('browser WebRTC witness failed or incomplete')
    records = result.get('records')
    if not isinstance(records, list) or len(records) != 3:
        raise ValueError('WebRTC player-count inventory incomplete')
    for record, count in zip(records, (2, 4, 8)):
        if type(record.get('players')) is not int or record['players'] != count or len(record.get('peers', [])) != count:
            raise ValueError('WebRTC peer inventory incomplete')
        for peer in record['peers']:
            witness = peer.get('result', {})
            rows = witness.get('records')
            if witness.get('passed') is not True or type(witness.get('binary_receives')) is not int or witness['binary_receives'] != 0:
                raise ValueError('gameplay used relay or failed')
            if not isinstance(rows, list) or len(rows) != 1:
                raise ValueError('peer gameplay result missing')
            row = rows[0]
            for key, expected in [('players', count), ('frames_submitted', 40), ('canonical_comparisons', 38)]:
                if type(row.get(key)) is not int or row[key] != expected:
                    raise ValueError('original-input canonical prefixes were not compared')
            if type(row.get('minimum_confirmed')) is not int or row['minimum_confirmed'] < 38:
                raise ValueError('peer confirmation incomplete')
            for key, minimum in [('active_comparisons', 37), ('rollback_loads', 1)]:
                if type(row.get(key)) is not int or row[key] < minimum:
                    raise ValueError('active prefix comparisons or actual rollback loads missing')
            direct = row.get('direct', {})
            if any(type(direct.get(key)) is not int or direct[key] < 1 for key in ('sent', 'received')):
                raise ValueError('direct packet delivery unobserved')
            rtc = peer.get('rtc', {})
            teardown = rtc.get('teardown', {})
            if (type(teardown.get('channels')) is not int or teardown['channels'] != 3 * (count - 1)
                    or type(teardown.get('connections_created')) is not int or teardown['connections_created'] < count - 1
                    or type(teardown.get('connections')) is not int or teardown['connections'] != teardown['connections_created']):
                raise ValueError('actual browser data channels or ICE connections survived teardown')
            channels = rtc.get('channels')
            if not isinstance(channels, list) or len(channels) != 3 * (count - 1):
                raise ValueError('actual browser data-channel inventory incomplete')
            for channel in channels:
                if (not isinstance(channel, dict) or type(channel.get('id')) is not int or channel['id'] not in (1, 2, 3)
                        or any(type(channel.get(key)) is not int or channel[key] < 0 for key in ('sent', 'received'))):
                    raise ValueError('browser channel identity or packet counts invalid')
            if any(sum(channel['id'] == channel_id for channel in channels) != count - 1 for channel_id in (1, 2, 3)):
                raise ValueError('browser default channel IDs incomplete')
            used = [channel for channel in channels if channel.get('sent', 0) > 0 or channel.get('received', 0) > 0]
            if len(used) != count - 1:
                raise ValueError('a direct peer channel was not exercised')
            for channel in used:
                if (channel.get('id') != 3 or channel.get('ordered') is not False or channel.get('negotiated') is not True
                        or type(channel.get('maxPacketLifeTime')) is not int or channel['maxPacketLifeTime'] != 1
                        or 'maxRetransmits' not in channel or channel['maxRetransmits'] is not None or channel['sent'] < 1 or channel['received'] < 1):
                    raise ValueError('actual unreliable channel options differ from audited defaults')
            if any(type(rtc.get(key)) is not int or rtc[key] < 1 for key in ('sent', 'received')):
                raise ValueError('actual browser packet evidence missing')
            for key in ('dropped', 'reordered'):
                if type(rtc.get(key)) is not int or (rtc[key] < 1 if faults else rtc[key] != 0):
                    raise ValueError('data-channel fault controls unobserved')
    return result

def validate_restore_control(result, kind="corrupt"):
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('corrupt') is not (kind == 'corrupt')
            or result.get('defaultFactory') is not (kind == 'default')
            or result.get('faults') is not False or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2 or result.get('errors') != []):
        raise ValueError('snapshot corruption control did not complete')
    records = result.get('records')
    if not isinstance(records, list) or len(records) != 1 or records[0].get('players') != 2 or len(records[0].get('peers', [])) != 2:
        raise ValueError('snapshot control peer inventory incomplete')
    for peer in records[0]['peers']:
        witness = peer.get('result', {})
        failure = witness.get('failure', {})
        errors = failure.get('errors')
        expected = errors == ['direct_poll_3_peer_0'] if kind == 'default' else (
            isinstance(errors, list) and len(errors) == 1 and isinstance(errors[0], str)
            and errors[0].startswith('canonical_prefix_frame_') and errors[0][len('canonical_prefix_frame_'):].isdigit())
        if witness.get('passed') is not False or failure.get('stage') != ('handshake' if kind == 'default' else 'gameplay') or not expected:
            raise ValueError('snapshot corruption rejected outside canonical gameplay prefix comparison')
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--server-source', type=Path, required=True)
    parser.add_argument('--build-receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--godot', type=Path, help='supplied pinned editor; requires exactly one --version')
    parser.add_argument('--version', action='append', help='pinned engine version; defaults to minimum and current')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'signalfish-webrtc.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    pins = load_manifest()
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if platform.system() != 'Linux' or arch is None:
        raise ValueError('WebRTC tool bootstrap supports Linux arm64/x86_64')
    versions = args.version or [pins['godot']['minimum'], pins['godot']['current_stable']]
    if not versions or any(version not in [pins['godot']['minimum'], pins['godot']['current_stable']] for version in versions):
        raise ValueError('only pinned engine versions are accepted')
    if args.godot and len(versions) != 1:
        raise ValueError('--godot requires exactly one --version')
    owned_logs = ['server.log', 'tls-certificate.log', 'instrument-controls.log'] + [f'{version}-{suffix}.log' for version in versions
        for suffix in ('version', 'import', 'clock-test', 'export', 'clean', 'faults', 'corrupt', 'clean-events',
                       'faults-events', 'corrupt-events', 'default', 'default-events')]
    for name in owned_logs:
        (args.output / name).unlink(missing_ok=True)
    sdk_pin, server_pin = pins['sources']['sdk'], pins['sources']['server']
    sdk_archive = fetch(sdk_pin['archive'], 'sdk.tar.gz', args.offline)
    server_archive = fetch(server_pin['archive'], 'server.tar.gz', args.offline)
    build = json.loads(args.build_receipt.read_text())
    cargo = build_cargo(build)
    sources = {'addon': ROOT / 'addons/fortress_rollback', 'server': args.server.resolve(), 'sdk_archive': sdk_archive,
               'server_archive': server_archive, 'build_receipt': args.build_receipt, 'build_log': args.build_receipt.parent / 'build.log',
               'builder': ROOT / 'scripts/reference/signalfish_build_server.py', 'fetch': ROOT / 'scripts/reference/fetch.py',
               'godot_helper': ROOT / 'scripts/reference/godot_smoke.py', 'pins': ROOT / 'docs/reference/pins.json', 'run': ROOT / 'scripts/reference/run.py',
               'native_launcher': ROOT / 'scripts/reference/signalfish_live_probe.py', 'sdk_launcher': ROOT / 'scripts/reference/signalfish_probe.py',
               'cargo': cargo, 'rustc': cargo.with_name('rustc'), 'launcher': Path(__file__).resolve(),
               'clock_test': ROOT / 'scripts/reference/signalfish_webrtc_probe_clock_test.gd', 'clock_fixture': ROOT / 'tests/unit/test_input_endpoint.gd',
               'host': ROOT / 'scripts/reference/signalfish_webrtc_probe.gd', 'setup': ROOT / 'scripts/reference/browser/webrtc_setup.gd',
               'game': ROOT / 'scripts/reference/browser/webrtc_game.gd', 'import_helper': ROOT / 'scripts/reference/browser/webrtc_import.py',
               'browser_launcher': ROOT / 'scripts/reference/browser/webrtc.cjs',
               'instrument_test': ROOT / 'scripts/reference/browser/webrtc_instrument.test.cjs', 'node': Path(shutil.which('node')),
               'browser_lock': ROOT / 'scripts/reference/browser/package-lock.json', 'openssl': Path(shutil.which('openssl'))}
    for module in sorted((CACHE / 'browser/node_modules').rglob('*')):
        relative = module.relative_to(CACHE / 'browser/node_modules')
        if relative.parts[0] == '.bin':
            continue
        if module.is_symlink():
            raise ValueError('executed browser module is symlinked')
        if module.is_file():
            sources['browser_package/' + str(relative)] = module
    browser_name = f'chromium-1194-{arch}.zip'
    browser_archive = fetch(pins['artifacts'][browser_name], browser_name, args.offline)
    browser_root = CACHE / 'webrtc-browser' / arch
    browser_root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(browser_archive) as package:
        package.extractall(browser_root)
        for member in package.infolist():
            if not member.is_dir():
                (browser_root / member.filename).chmod((member.external_attr >> 16) & 0o777 or 0o644)
    sources['browser_installation'] = browser_root
    sources['browser_archive'] = browser_archive
    sources['browser_executable'] = browser_root / 'chrome-linux/chrome'
    sources['browser_registry'] = CACHE / 'browser/node_modules/playwright-core/browsers.json'
    if digest(sources['browser_registry']) != pins['browser']['browser_registry_sha256']:
        raise ValueError('browser registry differs from pin')
    engines = {}
    environment = os.environ.copy()
    environment.update(XDG_DATA_HOME=str(CACHE / 'godot-data'), FORTRESS_CHROMIUM_EXECUTABLE=str(sources['browser_executable']),
                       FORTRESS_PLAYWRIGHT_PACKAGE=str(CACHE / 'browser/node_modules/@playwright/test'))
    for version in versions:
        name = f'Godot_v{version}-stable_linux.{arch}.zip'
        archive = fetch(pins['artifacts'][name], name, args.offline)
        editor_dir = CACHE / 'webrtc-editors' / version
        editor_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as package:
            expected_engine = hashlib.sha256(package.read(name[:-4])).hexdigest()
            package.extractall(editor_dir)
        engine = args.godot.resolve() if args.godot else editor_dir / name[:-4]
        validate_engine(engine, expected_engine)
        if not args.godot:
            engine.chmod(0o755)
        engines[version] = engine
        template_name = f'Godot_v{version}-stable_export_templates.tpz'
        templates = fetch(pins['artifacts'][template_name], template_name, args.offline)
        template_dir = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates' / (version + '.stable')
        template_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(templates) as package:
            for member in package.namelist():
                if Path(member).name.startswith('web_'):
                    (template_dir / Path(member).name).write_bytes(package.read(member))
        sources.update({f'engine_{version}': engine, f'engine_archive_{version}': archive, f'templates_{version}': templates})
    before = native_inventory(sources)
    server_before = source_inventory(args.server_source)
    expected = {name: before[name] for name in ('builder', 'fetch', 'pins', 'run', 'native_launcher', 'sdk_launcher', 'cargo', 'rustc')}
    expected['archive'] = before['server_archive']
    validate_build_receipt(build, server_pin['revision'], server_before, before['server'], expected, before['build_log'])
    run([str(sources['node']), '--test', str(sources['instrument_test'])], environment, args.output / 'instrument-controls.log')
    records, executed_records = [], []
    with tempfile.TemporaryDirectory(prefix='fortress-real-webrtc-') as temporary:
        root = Path(temporary)
        certificate, tls_private_key = root / 'localhost.crt', root / 'localhost.key'
        run([str(sources['openssl']), 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(tls_private_key), '-out', str(certificate)],
            environment, args.output / 'tls-certificate.log')
        environment.update(FORTRESS_TLS_CERT=str(certificate), FORTRESS_TLS_KEY=str(tls_private_key))
        sdk = extract(sdk_archive, sdk_pin, root / 'sdk-reference')
        server_source = extract(server_archive, server_pin, root / 'server-reference')
        if source_inventory(server_source) != server_before:
            raise ValueError('server source differs from pinned archive')
        config = json.loads((server_source / 'config.example.json').read_text())
        with socket.socket() as selection:
            selection.bind(('127.0.0.1', 0))
            port = selection.getsockname()[1]
        config['port'] = port
        config['session'].update(default_topology='mesh', enable_webrtc=True, enable_direct=False, enable_ice_pregather=False, ice_servers=[])
        config['turn'].update(enabled=False, urls=[], stun_urls=[])
        config['security']['allowed_apps'][0].update(app_id='fortress-live-webrtc', app_name='Local WebRTC rollback witness',
                                                    max_players_per_room=8, rate_limit_per_minute=100000)
        for key in config['rate_limit']:
            if key.startswith('max_'):
                config['rate_limit'][key] = max(config['rate_limit'][key], 1000000)
        server_environment = {'PATH': os.environ.get('PATH', ''), 'SIGNAL_FISH_CONFIG_JSON': json.dumps(config), 'RUST_LOG': 'error'}
        with (args.output / 'server.log').open('wb') as log:
            server = subprocess.Popen([str(sources['server'])], env=server_environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                wait_ready(server, port)
                for version, engine in engines.items():
                    project = root / version
                    project.mkdir()
                    shutil.copytree(sources['addon'], project / 'addons/fortress_rollback')
                    shutil.copytree(sdk / 'addons/signal_fish', project / 'addons/signal_fish')
                    for key, filename in [('host', 'host.gd'), ('game', 'webrtc_game.gd'), ('setup', 'webrtc_setup.gd'),
                                          ('clock_test', 'clock_test.gd'), ('clock_fixture', 'clock_fixture.gd')]:
                        shutil.copyfile(sources[key], project / filename)
                    (project / 'project.godot').write_text(
                        'config_version=5\n[application]\nconfig/name="WebRTC witness"\nrun/main_scene="res://main.tscn"\n'
                        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
                    (project / 'main.tscn').write_text('[gd_scene load_steps=2 format=3]\n'
                        '[ext_resource type="Script" path="res://host.gd" id="1"]\n[node name="Witness" type="Node"]\nscript = ExtResource("1")\n')
                    (project / 'export_presets.cfg').write_text('[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\n'
                        'export_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\n[preset.0.options]\n'
                        'variant/extensions_support=false\nvariant/thread_support=false\n')
                    export = root / ('export-' + version)
                    export.mkdir()
                    executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish',
                                'host': project / 'host.gd', 'game': project / 'webrtc_game.gd', 'setup': project / 'webrtc_setup.gd', 'project': project / 'project.godot',
                                'clock_test': project / 'clock_test.gd', 'clock_fixture': project / 'clock_fixture.gd',
                                'scene': project / 'main.tscn', 'preset': project / 'export_presets.cfg', 'certificate': certificate, 'private_key': tls_private_key}
                    frozen = inventory(executed)
                    command = [str(engine), '--headless', '--path', str(project)]
                    actual = run([str(engine), '--version'], environment, args.output / f'{version}-version.log').strip()
                    if not actual.startswith(version + '.stable.'):
                        raise ValueError('unexpected engine version')
                    run(command + ['--editor', '--quit'], environment, args.output / f'{version}-import.log')
                    frozen = freeze_after_import(executed, frozen)
                    if 'WEBRTC_CLOCK_TEST passed' not in run(command + ['--script', 'res://clock_test.gd', '--quit-after', '2'],
                            environment, args.output / f'{version}-clock-test.log'): raise ValueError('transport clock regression incomplete')
                    run(command + ['--export-release', 'Web', str(export / 'index.html')], environment, args.output / f'{version}-export.log')
                    export_before = inventory({'export': export})
                    for label in ('clean', 'faults', 'corrupt', 'default'):
                        faults = label == 'faults'
                        browser_command = [str(sources['node']), str(sources['browser_launcher']), str(export),
                                           f'ws://127.0.0.1:{port}/v3/ws', label, str(args.output / f'{version}-{label}-events.log')]
                        output = run(browser_command, environment, args.output / f'{version}-{label}.log')
                        result = validate_restore_control(json.loads(output), label) if label in ('corrupt', 'default') else validate_browser(json.loads(output), faults)
                        records.append({'engine': actual, 'faults': faults, 'control': label if label in ('corrupt', 'default') else None,
                                        'command': browser_command, 'result': result})
                    if inventory(executed) != frozen or inventory({'export': export}) != export_before:
                        raise ValueError('executed Web sources changed')
                    executed_records.append({'engine': actual, 'source_inventory': frozen, 'export_inventory': export_before})
                if server.poll() is not None:
                    raise ValueError('signaling server exited during gameplay')
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
    if native_inventory(sources) != before or source_inventory(args.server_source) != server_before:
        raise ValueError('source or tool inventory changed during execution')
    report = {'passed': True, 'sdk_revision': sdk_pin['revision'], 'server_revision': server_pin['revision'],
              'input_inventory': before, 'server_source_inventory': server_before, 'executed': executed_records,
              'server_config': config, 'records': records,
              'log_sha256': {name: digest(args.output / name) for name in owned_logs if (args.output / name).exists()},
              'limits': 'Real release Web exports in two independent Chromium processes; local host ICE, 2/4/8 peers, '
                        '40 submitted frames per peer and 38 corrected original-input canonical prefixes per peer. '
                        'All browser data channels and peer connections close at teardown. Snapshot restore corruption fails '
                        'at the gameplay canonical prefix comparison. Browser data-channel send drops/delays are synthetic; no WAN/NAT/TURN, native WebRTC, '
                        'other browsers, automatic relay fallback or reconnect/replan claim.'}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': str(receipt), 'engines': versions, 'runs': len(records)}))

if __name__ == '__main__':
    main()
