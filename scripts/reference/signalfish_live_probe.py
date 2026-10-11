#!/usr/bin/env python3
"""Run native relay gameplay against an explicitly supplied local SignalFish server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tarfile
import tempfile
import time

from fetch import fetch, load_manifest
from signalfish_probe import inventory

ROOT = Path(__file__).resolve().parents[2]
MARKER = 'FORTRESS_LIVE_RELAY_RESULT '
TIMEOUT = 180
LATE_ERRORS = {name: name for name in ('protocol_error', 'server_error', 'room_join_failed', 'authentication_error', 'connection_failed',
                                    'reconnection_failed', 'disconnected', 'going_away', 'room_left', 'reconnected', 'room_joined',
                                    'player_joined', 'player_left', 'player_reconnected', 'spectator_joined', 'new_peer')}


def extract(archive, pin, destination):
    with tarfile.open(archive) as package:
        members = package.getmembers()
        if not members or any(member.name.split('/')[0] != pin['root'] for member in members):
            raise ValueError('unexpected pinned source archive root')
        package.extractall(destination, filter='data')
    return destination / pin['root']


def source_inventory(root):
    result = {}
    for source in sorted(root.rglob('*')):
        relative = source.relative_to(root)
        if relative.parts[0] in ('.git', 'target'):
            continue
        if source.is_symlink():
            raise ValueError('server source contains a symlink')
        if source.is_file():
            result[str(relative)] = hashlib.sha256(source.read_bytes()).hexdigest()
    return result


def wait_ready(server, port):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise ValueError('local server exited before readiness')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.05)
    raise ValueError('local server readiness timed out')


def validate_result(output):
    results = [json.loads(line[len(MARKER):]) for line in output.splitlines() if line.startswith(MARKER)]
    if len(results) != 1 or not isinstance(results[0], dict) or results[0].get('passed') is not True:
        raise ValueError('native relay result missing or invalid')
    result = results[0]
    records = result.get('records')
    if not isinstance(records, list) or len(records) != 3:
        raise ValueError('native relay player-count inventory incomplete')
    for record, count in zip(records, (2, 4, 8)):
        expected = {'players': count, 'frames_submitted': 40, 'canonical_comparisons': 38 * count}
        if not isinstance(record, dict) or any(type(record.get(key)) is not int or record[key] != value for key, value in expected.items()):
            raise ValueError('native relay gameplay evidence incomplete')
        if type(record.get('minimum_confirmed')) is not int or record['minimum_confirmed'] < 38:
            raise ValueError('native relay confirmation incomplete')
    if type(result.get('binary_receives')) is not int or result['binary_receives'] < 1:
        raise ValueError('native relay binary delivery unobserved')
    return result


def validate_late_error(returncode, output, kind):
    prefix = 'LIVE_RELAY_FAILED '
    results = [json.loads(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]
    if returncode != 1 or MARKER in output or 'ERROR:' in output or len(results) != 1 or not isinstance(results[0], dict):
        raise ValueError('late SDK error control did not reject the gameplay witness')
    result = results[0]
    if (type(result.get('players')) is not int or result['players'] != 8 or result.get('stage') != 'gameplay'
            or result.get('errors') != [LATE_ERRORS[kind]] or result.get('control') != kind or result.get('control_injected') is not True
            or type(result.get('binary_receives')) is not int or result['binary_receives'] < 1):
        raise ValueError('late SDK error control failed at the wrong boundary')
    return result


def run_native(command, log):
    try:
        process = subprocess.run(command, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as failure:
        log.write_bytes((failure.stdout or b'') + (failure.stderr or b''))
        raise ValueError('native relay witness timed out; see isolated native log') from failure
    raw = process.stdout + process.stderr
    log.write_bytes(raw)
    return process, raw.decode('utf-8')


def build_cargo(build):
    if not isinstance(build, dict):
        raise ValueError('server build receipt must be an object')
    clean = ['clean', '-p', 'signal-fish-server']
    compile_args = ['build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']
    commands = build.get('commands')
    valid_commands = (isinstance(commands, list) and len(commands) == 2
                      and all(isinstance(command, list) and command and all(isinstance(arg, str) for arg in command) for command in commands)
                      and Path(commands[0][0]).name == 'cargo' and commands[1][0] == commands[0][0]
                      and commands[0][1:] == clean and commands[1][1:] == compile_args)
    if not valid_commands:
        raise ValueError('server build commands do not match the pinned builder')
    return Path(commands[0][0])


def validate_build_receipt(build, revision, source, binary_digest, expected_inputs, log_digest):
    cargo = build_cargo(build)
    tools = build.get('tool_sha256')
    valid_tools = (isinstance(tools, dict) and set(tools) == {'cargo', 'rustc'}
                   and all(isinstance(value, str) and len(value) == 64 and set(value) <= set('0123456789abcdef') for value in tools.values()))
    exits = build.get('exit_codes')
    if (type(build.get('format')) is not int or build['format'] != 1 or build.get('passed') is not True
            or build.get('source_revision') != revision or build.get('source_inventory') != source
            or build.get('binary_sha256') != binary_digest or not valid_tools
            or not isinstance(exits, list) or len(exits) != 2 or any(type(code) is not int or code != 0 for code in exits)):
        raise ValueError('server build receipt does not bind the pinned source and executable')
    names = {'builder', 'fetch', 'pins', 'run', 'native_launcher', 'sdk_launcher', 'archive', 'cargo', 'rustc'}
    inputs = build.get('input_inventory')
    if (not isinstance(inputs, dict) or set(inputs) != names or inputs != expected_inputs
            or any(not isinstance(value, str) or len(value) != 64 or set(value) - set('0123456789abcdef') for value in inputs.values())
            or build.get('builder_sha256') != expected_inputs['builder'] or build.get('server_archive_sha256') != expected_inputs['archive']
            or build.get('log_sha256') != log_digest or tools != {name: expected_inputs[name] for name in ('cargo', 'rustc')}
            or not isinstance(build.get('binary'), str) or not build['binary']):
        raise ValueError('server build provenance differs from current known inputs or build log')
    return cargo


def build_log_digest(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as failure:
        raise ValueError('known build log must be a regular file') from failure
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ValueError('known build log must be a regular file')
    with os.fdopen(descriptor, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_inventory(paths):
    result = inventory({name: path for name, path in paths.items() if name != 'build_log'})
    result['build_log'] = build_log_digest(paths['build_log'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--server', required=True, type=Path)
    parser.add_argument('--server-source', required=True, type=Path)
    parser.add_argument('--build-receipt', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'signalfish-live.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    manifest = load_manifest()
    sdk_pin = manifest['sources']['sdk']
    server_pin = manifest['sources']['server']
    sdk_archive = fetch(sdk_pin['archive'], 'sdk.tar.gz', args.offline)
    server_archive = fetch(server_pin['archive'], 'server.tar.gz', args.offline)
    engine = Path(shutil.which(str(args.godot)) or args.godot).resolve()
    server_binary = args.server.resolve()
    sources = {'addon': ROOT / 'addons/fortress_rollback', 'engine': engine, 'server': server_binary,
               'sdk_archive': sdk_archive, 'server_archive': server_archive, 'launcher': Path(__file__).resolve(), 'build_receipt': args.build_receipt,
               'inventory_helper': ROOT / 'scripts/reference/signalfish_probe.py', 'fetch_helper': ROOT / 'scripts/reference/fetch.py',
               'pin_manifest': ROOT / 'docs/reference/pins.json', 'builder': ROOT / 'scripts/reference/signalfish_build_server.py',
               'run_helper': ROOT / 'scripts/reference/run.py', 'build_log': args.build_receipt.parent / 'build.log'}
    helpers = ('signalfish_live_probe.gd', 'signalfish_probe_relay.gd', 'signalfish_probe_relay_controls.gd')
    for helper in helpers:
        sources[helper] = ROOT / 'scripts/reference' / helper
    before = native_inventory(sources)
    source_before = source_inventory(args.server_source)
    build = json.loads(args.build_receipt.read_text())
    cargo = build_cargo(build)
    sources.update(cargo=cargo, rustc=cargo.with_name('rustc'))
    before = native_inventory(sources)
    expected_inputs = {'builder': before['builder'], 'fetch': before['fetch_helper'], 'pins': before['pin_manifest'], 'run': before['run_helper'],
                       'native_launcher': before['launcher'], 'sdk_launcher': before['inventory_helper'], 'archive': before['server_archive'],
                       'cargo': before['cargo'], 'rustc': before['rustc']}
    validate_build_receipt(build, server_pin['revision'], source_before, before['server'], expected_inputs, before['build_log'])
    with tempfile.TemporaryDirectory(prefix='fortress-signalfish-live-') as temporary:
        project = Path(temporary)
        sdk = extract(sdk_archive, sdk_pin, project / 'sdk-reference')
        server_source = extract(server_archive, server_pin, project / 'server-reference')
        if source_before != source_inventory(server_source):
            raise ValueError('supplied server source differs from pinned archive')
        shutil.copytree(sources['addon'], project / 'addons/fortress_rollback')
        shutil.copytree(sdk / 'addons/signal_fish', project / 'addons/signal_fish')
        for helper in helpers:
            shutil.copyfile(sources[helper], project / helper)
        (project / 'project.godot').write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        config = json.loads((server_source / 'config.example.json').read_text())
        with socket.socket() as selection:
            selection.bind(('127.0.0.1', 0))
            port = selection.getsockname()[1]
        config['port'] = port
        config['session'].update(default_topology='relay', enable_webrtc=False, enable_direct=False, enable_ice_pregather=False)
        app = config['security']['allowed_apps'][0]
        app.update(app_id='fortress-live-relay', app_name='Local rollback witness', max_players_per_room=8, rate_limit_per_minute=100000)
        for key in ('max_connections', 'max_messages', 'max_room_creations', 'max_relay_bytes', 'max_room_relay_bytes'):
            if key in config['rate_limit']:
                config['rate_limit'][key] = max(config['rate_limit'][key], 1000000)
        config_file = project / 'server-config.json'
        config_file.write_text(json.dumps(config))
        executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish',
                    'project': project / 'project.godot', 'config': config_file}
        for helper in helpers:
            executed[helper] = project / helper
        executed_before = inventory(executed)
        for name, digest in executed_before.items():
            if (name.startswith('addon/') or name in helpers) and before[name] != digest:
                raise ValueError('copied source inventory differs')
        server_command = [str(server_binary)]
        command = [str(engine), '--headless', '--path', str(project), '--script', 'res://signalfish_live_probe.gd', '--', f'ws://127.0.0.1:{port}/v3/ws']
        env = {'PATH': os.environ.get('PATH', ''), 'SIGNAL_FISH_CONFIG_JSON': json.dumps(config), 'RUST_LOG': 'error'}
        with (args.output / 'server.log').open('wb') as server_log:
            server = subprocess.Popen(server_command, env=env, stdout=server_log, stderr=subprocess.STDOUT)
            try:
                wait_ready(server, port)
                process, output = run_native(command, args.output / 'native.log')
                if process.returncode != 0 or 'ERROR:' in output:
                    raise ValueError('native relay witness failed; see isolated native.log')
                result = validate_result(output)
                controls = {}
                for kind in LATE_ERRORS:
                    control, output = run_native(command + [kind], args.output / f'late-{kind}.log')
                    controls[kind] = validate_late_error(control.returncode, output, kind)
                if server.poll() is not None:
                    raise ValueError('local server exited during native gameplay')
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
        if native_inventory(sources) != before or inventory(executed) != executed_before or source_inventory(args.server_source) != source_before:
            raise ValueError('source or tool inventory changed during execution')
    report = {'passed': True, 'sdk_revision': sdk_pin['revision'], 'server_source_revision': server_pin['revision'],
              'input_inventory': before, 'server_source_inventory': source_before, 'executed_inventory': executed_before,
              'command': command, 'server_command': server_command, 'exit': process.returncode, 'result': result,
              'late_error_controls': controls,
              'build_receipt_sha256': before['build_receipt'],
              'log_sha256': {name: hashlib.sha256((args.output / name).read_bytes()).hexdigest()
                             for name in ['native.log', 'server.log'] + [f'late-{kind}.log' for kind in LATE_ERRORS]},
              'limits': 'Real native loopback WebSocket gameplay using the supplied server binary; source tree matches pinned archive. '
                        'Build receipt binds executable bytes and pinned source; this invocation does not rebuild. '
                        'No browser, real WebRTC or live queue-pressure validation.'}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': str(receipt), 'records': result['records']}))


if __name__ == '__main__':
    main()
