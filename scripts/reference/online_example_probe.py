"""Export the shipped online scene and validate original local input prefixes."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import zipfile

from online_diagnostics import validate_download

from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from godot_smoke import run
from signalfish_probe import inventory

DESYNC_REASON = 18
# examples/online/match.gd schedules local input this many frames ahead of the current frame.
INPUT_DELAY = 2


def expected_states(histories, count):
    """Independent integer game, fed sender-owned input queues, never remote callbacks."""
    frame, rng = 0, 1701
    x, y = [120, 360], [160, 160]
    pending, pending_color, event_id, event_frame, color = [-1, -1], [0, 0], [0, 0], [-1, -1], [0, 1]
    states = {}
    for _ in range(count):
        fields = [1, frame, rng]
        for player in range(2):
            fields.extend((x[player], y[player], pending[player], pending_color[player], event_id[player], event_frame[player], color[player]))
        states[frame] = struct.pack('<17q', *fields).hex()
        for player in range(2):
            buttons = histories[player][frame]
            x[player] = min(460, max(20, x[player] + 2 * (bool(buttons & 2) - bool(buttons & 1))))
            y[player] = min(280, max(20, y[player] + 2 * (bool(buttons & 8) - bool(buttons & 4))))
            if pending[player] == frame:
                color[player], event_id[player], event_frame[player], pending[player] = pending_color[player], frame * 2 + player + 1, frame, -1
            rng = (rng * 1103515245 + 12345) & 0x7fffffff
            if frame % 20 == 0:
                pending_color[player], pending[player] = (rng >> 16) % 4, frame + 3
        frame += 1
    return states


def validate_suspension(record, expired):
    evidence = record.get('suspension', {})
    label, duration = ('expired', 2500) if expired else ('short', 750)
    if (not isinstance(evidence, dict) or evidence.get('label') != label or evidence.get('method') != 'cdp-debugger-pause'
            or type(evidence.get('requested_ms')) is not int
            or evidence['requested_ms'] != duration or type(evidence.get('frozen_elapsed_us')) is not int
            or not duration * 1000 <= evidence['frozen_elapsed_us'] < 30000000):
        raise ValueError('online example actual page suspension missing')
    peers = evidence.get('peers')
    if not isinstance(peers, list) or len(peers) != 2:
        raise ValueError('online example resumed peers missing')
    frontiers = {peer['page_index']: peer for peer in record['peers']}
    for index, peer in enumerate(peers):
        fields = ('host_before_us', 'host_after_us', 'gap_us', 'protocol_before_us', 'protocol_after_us',
                  'epoch_us', 'frame_before', 'frame_after')
        if (not isinstance(peer, dict) or any(type(peer.get(field)) is not int or peer[field] < 0 for field in fields)
                or peer.get('label') != label or peer.get('session_id') != frontiers[index]['session_id']
                or peer['host_after_us'] - peer['host_before_us'] != peer['gap_us'] or peer['gap_us'] < duration * 1000
                or peer['protocol_before_us'] + peer['epoch_us'] != peer['host_before_us']
                or peer['protocol_after_us'] + peer['epoch_us'] != peer['host_after_us']
                or peer['frame_before'] < 40 or not peer['frame_before'] <= peer['frame_after'] <= peer['frame_before'] + 1):
            raise ValueError('online example truthful bounded resume evidence invalid')
        if expired:
            if (peer.get('state') != 'failed' or not isinstance(peer.get('message'), str) or 'fresh room' not in peer['message']
                    or peer['frame_before'] != peer['frame_after'] or peer['frame_before'] < frontiers[index]['frame']):
                raise ValueError('online example expired suspension advanced or revived gameplay')
        elif (peer.get('state') != 'playing' or peer['gap_us'] > 2000000
                or frontiers[index]['frame'] < peer['frame_after'] + 30):
            raise ValueError('online example short suspension did not recover gameplay')
    if expired:
        frozen = record.get('frozen_frames')
        if (not isinstance(frozen, list) or len(frozen) != 2 or any(not isinstance(frame, dict)
                or type(frame.get('before')) is not int or type(frame.get('after')) is not int or frame.get('state') != 'failed'
                or frame['before'] != peers[index]['frame_after'] or frame['after'] != frame['before'] for index, frame in enumerate(frozen))):
            raise ValueError('online example expired suspension lost its frozen frontier')


def validate_resources(evidence, round_index):
    if not isinstance(evidence, list) or len(evidence) != 2:
        raise ValueError('online example physical teardown missing')
    for closed in evidence:
        fields = ('channels', 'channels_closed', 'connections', 'connections_closed', 'ice_closed', 'websockets', 'websockets_closed')
        if (not isinstance(closed, dict) or any(type(closed.get(field)) is not int or closed[field] < 0 for field in fields)
                or closed['channels'] != 3 * (round_index + 1) or closed['channels_closed'] != closed['channels']
                or closed['connections'] < round_index + 1 or closed['connections_closed'] != closed['connections']
                or closed['ice_closed'] != closed['connections'] or closed['websockets'] != round_index + 1
                or closed['websockets_closed'] != closed['websockets']):
            raise ValueError('online example retained physical channels, ICE connections or websockets')


def validate_socket_loss(record):
    loss = record.get('socket_loss')
    if (not isinstance(loss, dict) or loss.get('kind') != 'signaling-websocket-socket-loss'
            or loss.get('method') != 'tls-proxy-destroy-both-pairs'
            or any(type(loss.get(key)) is not int or loss[key] != expected for key, expected in
                   (('proxy_pairs_before', 2), ('destroyed_pairs', 2), ('proxy_pairs_after', 0)))
            or loss.get('open_websockets_before') != [1, 1]
            or any(type(count) is not int for count in loss.get('open_websockets_before', []))
            or loss.get('upgrades_refused') is not True or loss.get('reopened') is not True
            or loss.get('before_user_leave') is not True or type(loss.get('refused_upgrade_attempts')) is not int
            or not 1 <= loss['refused_upgrade_attempts'] <= 100
            or any(type(loss.get(key)) is not int or not minimum <= loss[key] < 30000000
                   for key, minimum in (('held_elapsed_us', 750000), ('reopened_elapsed_us', 250000)))):
        raise ValueError('online example actual signaling socket loss missing')
    terminal = loss.get('terminal')
    if not isinstance(terminal, list) or len(terminal) != 2:
        raise ValueError('online example socket loss terminal peers missing')
    peers = {peer['page_index']: peer for peer in record['peers']}
    for index, observation in enumerate(terminal):
        if (not isinstance(observation, dict) or observation.get('state') != 'failed'
                or not isinstance(observation.get('message'), str) or 'fresh room' not in observation['message']
                or any(type(observation.get(key)) is not int for key in ('frame_before', 'frame_after'))
                or not peers[index]['frame'] <= observation['frame_before'] <= 256
                or observation['frame_after'] != observation['frame_before']
                or observation.get('session_before') != peers[index]['session_id']
                or observation.get('session_after') != peers[index]['session_id']):
            raise ValueError('online example socket loss advanced or revived gameplay')
    validate_resources(loss.get('resources'), 2)


def validate_held_input(payload, before, peer):
    raw = bytes.fromhex(payload)
    if (len(raw) < 76 or raw[:8] != b'FRGP\x01\x00\x03\x00'
            or raw[8:24].hex() != before['session_id'] or raw[24:32] != hashlib.sha256(peer['uuid'].encode('ascii')).digest()[:8]
            or raw[32:40] == bytes(8) or int.from_bytes(raw[40:44], 'little') != len(raw) - 44
            or raw[54:57] != bytes([1, peer['slot'], 2])):
        raise ValueError('online example delayed original input header invalid')
    start, ack, count = struct.unpack('<iiH', raw[44:54])
    histories = before.get('inputs')
    if (not isinstance(histories, list) or not 100 <= len(histories) <= 256
            or any(type(value) is not int or not 0 <= value <= 15 for value in histories)
            or not 0 <= start < len(histories) or not 1 <= count <= len(histories) - start or not -1 <= ack <= 255
            or len(raw) != 75 + count or int.from_bytes(raw[71:75], 'little') != count
            or raw[75:] != bytes(histories[start:start + count])):
        raise ValueError('online example delayed packet differs from original submitted inputs')
    for offset in (57, 64):
        status, received, flags = struct.unpack('<BiH', raw[offset:offset + 7])
        if status != 0 or not -1 <= received <= 255 or flags != 0:
            raise ValueError('online example delayed input status invalid')


def validate_server_restart(record):
    restart = record.get('server_restart')
    if not isinstance(restart, dict) or restart.get('before_user_leave') is not True:
        raise ValueError('online example owned server restart missing')
    stopped, started = restart.get('stopped', {}), restart.get('started', {})
    if (not isinstance(stopped, dict) or not isinstance(started, dict) or stopped.get('kind') != 'stop' or stopped.get('method') != 'sigkill'
            or started.get('kind') != 'start' or type(stopped.get('pid')) is not int or stopped['pid'] <= 0
            or type(stopped.get('exit_code')) is not int or stopped['exit_code'] != -9 or stopped.get('terminal') is not True
            or type(started.get('pid')) is not int or started['pid'] <= 0 or started['pid'] == stopped['pid']
            or type(started.get('previous_pid')) is not int or started['previous_pid'] != stopped['pid']
            or started.get('live') is not True or started.get('ready') is not True
            or type(started.get('port')) is not int or not 1 <= started['port'] <= 65535
            or any(not isinstance(started.get(key), str) or not re.fullmatch('[a-f0-9]{64}', started[key])
                   for key in ('binary_sha256', 'config_sha256'))):
        raise ValueError('online example owned process termination or ready restart invalid')
    for key, minimum in [('held_elapsed_us', 750000), ('restarted_elapsed_us', 250000)]:
        if type(restart.get(key)) is not int or not minimum <= restart[key] < 30000000:
            raise ValueError('online example server restart observation gap invalid')
    boundary, terminal = restart.get('boundary'), restart.get('terminal')
    if any(not isinstance(values, list) or len(values) != 2 for values in (boundary, terminal)):
        raise ValueError('online example restart peer observations missing')
    peers = {peer['page_index']: peer for peer in record['peers']}
    for index, (before, after) in enumerate(zip(boundary, terminal)):
        if not isinstance(before, dict) or not isinstance(after, dict):
            raise ValueError('online example restart peer observations invalid')
        fault = before.get('fault', {})
        held = fault.get('held', [])
        if (type(before.get('pending')) is not int or not 0 <= before['pending'] <= 128
                or type(before.get('relay_pending')) is not int or not 1 <= before['relay_pending'] <= 128
                or type(before.get('frame')) is not int or not peers[index]['frame'] <= before['frame'] <= 256
                or before.get('session_id') != peers[index]['session_id'] or fault.get('armed') is not True or fault.get('pressure') is not True
                or type(fault.get('pending')) is not int or fault['pending'] != 1
                or type(fault.get('reads')) is not int or fault['reads'] < 1 or not isinstance(held, list) or len(held) != 1
                or not isinstance(held[0], str) or not re.fullmatch('[a-f0-9]{2,2048}', held[0]) or len(held[0]) % 2
                or bytes.fromhex(held[0])[:8] != b'FRGP\x01\x00\x03\x00'
                or bytes.fromhex(held[0])[8:24].hex() != before['session_id']):
            raise ValueError('online example restart did not retain pressure and original old-room input')
        validate_held_input(held[0], before, peers[index])
        if (after.get('state') != 'failed' or not isinstance(after.get('message'), str) or 'fresh room' not in after['message']
                or after.get('first_message') != after['message']
                or any(type(after.get(key)) is not int for key in ('frame_before', 'frame_after'))
                or not before['frame'] <= after['frame_before'] <= 256 or after['frame_after'] != after['frame_before']
                or after.get('session_before') != before['session_id'] or after.get('session_after') != before['session_id']
                or any(type(after.get(key)) is not int or after[key] != expected for key, expected in
                       [('pending', 0), ('relay_pending', 0), ('delayed_pending', 0), ('delayed_dropped', 1)])):
            raise ValueError('online example server restart advanced, revived or retained failed gameplay')
    validate_resources(restart.get('resources'), 3)


def validate_stale_callbacks(peer):
    evidence = peer.get('stale_callbacks')
    if (not isinstance(evidence, dict) or type(evidence.get('calls')) is not int or evidence['calls'] != 4
            or evidence.get('kinds') != ['protocol_info', 'room_joined', 'lobby_state_changed', 'protocol_error']
            or not isinstance(evidence.get('before'), dict) or not isinstance(evidence.get('after'), dict)):
        raise ValueError('online example old SDK callback delivery missing')
    before = evidence['before']
    if (before.get('state') != 'playing' or before.get('failure') != '' or before.get('has_readied') is not True
            or before.get('all_ready') is not True or before.get('session_id') != peer['session_id'] or before.get('room_id') != peer['room_id']
            or type(before.get('frame')) is not int or not 45 <= before['frame'] <= peer['frame']
            or not isinstance(before.get('message'), str) or not before['message']
            or not isinstance(before.get('info_id'), str) or not re.fullmatch('-?[1-9][0-9]{0,18}', before['info_id'])
            or not -(1 << 63) <= int(before['info_id']) < (1 << 63)
            or not isinstance(before.get('canonical'), str) or not re.fullmatch('[a-f0-9]{272}', before['canonical'])
            or struct.unpack('<17q', bytes.fromhex(before['canonical']))[1] != before['frame']
            or evidence['after'] != before or any(type(evidence['after'].get(key)) is not type(value) for key, value in before.items())):
        raise ValueError('online example old SDK callbacks mutated the fresh match')



def validate_result(value, corrupt=False):
    if (not isinstance(value, dict) or value.get('passed') is not True or type(value.get('browser_instances')) is not int
            or value['browser_instances'] != 2 or value.get('errors') != [] or value.get('corrupt') is not corrupt):
        raise ValueError('online example browser flow failed')
    rounds = value.get('rounds')
    if not isinstance(rounds, list) or len(rounds) != (1 if corrupt else 5):
        raise ValueError('online example did not restart in a fresh room')
    if any(not isinstance(record, dict) for record in rounds):
        raise ValueError('online example round evidence malformed')
    if not corrupt:
        terminal = rounds[0].get('terminal', {})
        if (not isinstance(terminal, dict) or terminal.get('state') != 'failed' or not isinstance(terminal.get('message'), str)
                or 'fresh room' not in terminal['message'] or type(terminal.get('frame_before')) is not int
                or type(terminal.get('frame_after')) is not int or not 100 <= terminal['frame_before'] <= 256
                or terminal['frame_after'] != terminal['frame_before']):
            raise ValueError('online example peer departure did not stop simulation with actionable recovery')
    rooms, room_ids, identities, comparisons = [], [], [], []
    for round_index, record in enumerate(rounds):
        downloads = record.get('diagnostics')
        if not isinstance(downloads, list) or len(downloads) != 2:
            raise ValueError('online example missing real diagnostic downloads')
        for download in downloads:
            validate_download(download)
        peers = record.get('peers', [])
        if (not isinstance(peers, list) or len(peers) != 2 or any(not isinstance(peer, dict) for peer in peers)
                or any(type(peer.get('slot')) is not int or type(peer.get('page_index')) is not int for peer in peers)
                or sorted(peer['slot'] for peer in peers) != [0, 1] or sorted(peer.get('page_index') for peer in peers) != [0, 1]
                or not isinstance(record.get('room'), str) or not re.fullmatch('[A-Z0-9]{6}', record['room'])):
            raise ValueError('online example frozen player slots invalid')
        peers.sort(key=lambda peer: peer['slot'])
        rooms.append(record['room'])
        uuids = [peer.get('room_id') for peer in peers]
        if (any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value) for value in uuids)
                or uuids[0] != uuids[1]):
            raise ValueError('online example actual room UUID evidence invalid')
        room_ids.append(uuids[0])
        session_ids = [peer.get('session_id') for peer in peers]
        if (any(not isinstance(identity, str) or not re.fullmatch('[a-f0-9]{32}', identity) for identity in session_ids)
                or session_ids[0] != session_ids[1]):
            raise ValueError('online example peers disagree on the frozen rollback identity')
        identities.append(session_ids[0])
        uuids = [peer.get('uuid') for peer in peers]
        if (any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value) for value in uuids)
                or uuids != sorted(uuids) or len(set(uuids)) != 2):
            raise ValueError('online example actual player UUID slots invalid')
        validate_resources(record.get('teardown'), round_index)
        histories = [peer.get('inputs') for peer in peers]
        for history in histories:
            if (not isinstance(history, list) or len(history) < (20 if corrupt else 100) or len(history) > 256
                    or any(type(buttons) is not int or not 0 <= buttons <= 15 for buttons in history)
                    or not any(history) or history[:2] != [0, 0]):
                raise ValueError('actual physical keyboard submission evidence incomplete')
        expected = expected_states(histories, min(map(len, histories)))
        for peer in peers:
            intended_desync = (corrupt and peer.get('state') == 'failed' and type(peer.get('terminal_reason')) is int
                               and peer['terminal_reason'] == DESYNC_REASON and isinstance(peer.get('failure'), str) and bool(peer['failure']))
            # Inputs are indexed by scheduled frame, so a complete capture covers every confirmed frame.
            # A desynced peer stops capturing at termination; the session still bounds its confirmation.
            confirmed_limit = (peer['frame'] + INPUT_DELAY if intended_desync and type(peer.get('frame')) is int
                               else len(peer['inputs']) - 1)
            if (type(peer.get('restores')) is not int or peer['restores'] < 1 or (peer.get('failure') != '' and not intended_desync)
                    or type(peer.get('confirmed')) is not int or not (20 if corrupt else 90) <= peer['confirmed'] <= confirmed_limit
                    or type(peer.get('frame')) is not int or not 20 <= peer['frame'] <= len(peer['inputs'])
                    or (peer.get('state') != 'playing' and not intended_desync) or peer.get('room') != record['room']):
                raise ValueError('online example rollback or confirmation missing')
            page_index = peer['page_index']
            first, second = (2, 8) if page_index == 0 else (4, 1)
            if first not in peer['inputs'] or second not in peer['inputs']:
                raise ValueError('online example actual movement direction changes missing')
            channels = peer.get('rtc', {}).get('channels', [])
            if (len(channels) != 3 or any(type(channel.get('id')) is not int or any(type(channel.get(key)) is not int
                    or channel[key] < 0 for key in ('sent', 'received')) for channel in channels)
                    or sorted(channel.get('id') for channel in channels) != [1, 2, 3]
                    or type(peer.get('delayed')) is not int or peer['delayed'] < 1):
                raise ValueError('online example physical channel or delay inventory incomplete')
            used = [channel for channel in channels if channel.get('sent', 0) or channel.get('received', 0)]
            if len(used) != 1:
                raise ValueError('online example used an unexpected data channel')
            channel = used[0]
            if (channel['id'] != 3 or channel.get('ordered') is not False or channel.get('negotiated') is not True
                    or type(channel.get('maxPacketLifeTime')) is not int or channel['maxPacketLifeTime'] != 1
                    or 'maxRetransmits' not in channel or channel['maxRetransmits'] is not None
                    or any(type(channel.get(key)) is not int or channel[key] < 1 for key in ('sent', 'received'))):
                raise ValueError('online example physical unreliable channel contract missing')
            snapshots = peer.get('snapshots', {})
            if not isinstance(snapshots, dict) or not (8 if corrupt else 60) <= len(snapshots) <= 256:
                count = len(snapshots) if isinstance(snapshots, dict) else 'invalid'
                raise ValueError(f'online example corrected prefix coverage incomplete: page {page_index}, '
                                 f'frame {peer["frame"]}, confirmed {peer["confirmed"]}, snapshots {count}')
            for key, state in snapshots.items():
                if (not isinstance(key, str) or not re.fullmatch('0|[1-9][0-9]{0,2}', key)
                        or not isinstance(state, str) or not re.fullmatch('[a-f0-9]{272}', state)):
                    raise ValueError('online example malformed snapshot inventory')
                frame = int(key)
                if frame >= peer['confirmed'] or frame >= peer['frame'] or frame >= min(map(len, histories)):
                    raise ValueError('online example snapshot exceeds completed confirmed history')
                comparisons.append((frame, expected[frame], state))
        common = set(peers[0]['snapshots']) & set(peers[1]['snapshots'])
        if len(common) < (6 if corrupt else 50):
            raise ValueError('online example common confirmed history incomplete')
        record['canonical_comparisons'] = sum(len(peer['snapshots']) for peer in peers)
        if round_index == 0 and not corrupt:
            survivor = next(peer for peer in peers if peer['page_index'] == 1)
            if record['terminal']['frame_before'] < survivor['frame']:
                raise ValueError('online example terminal report lost the completed simulation frontier')
        if not corrupt and round_index < 2:
            validate_suspension(record, expired=round_index == 1)
            if round_index == 1:
                validate_resources(record.get('failure_resources'), round_index)
        elif not corrupt and round_index == 2:
            validate_socket_loss(record)
        elif not corrupt and round_index == 3:
            validate_server_restart(record)
        elif not corrupt and round_index == 4:
            held = [value['fault']['held'][0] for value in rounds[3]['server_restart']['boundary']]
            for peer in peers:
                validate_stale_callbacks(peer)
            if (record.get('stale_sent') != held or record.get('stale_received') != [1, 1]
                    or any(type(count) is not int for count in record.get('stale_received', []))
                    or any(type(peer.get('direct_rejected')) is not int or peer['direct_rejected'] != 1 for peer in peers)):
                raise ValueError('online example omitted old-room input delivery in the fresh match')
    if (not corrupt and (len(set(rooms)) != 5 or len(set(room_ids)) != 5 or len(set(identities)) != 5)) or value.get('teardown') is not True:
        raise ValueError('online example reused room or retained connections')
    for frame, expected, state in comparisons:
        if expected != state:
            raise ValueError(f'online example canonical prefix mismatch at frame {frame}')
    return value


def run_online(root, version, engine, sdk, sources, environment, output, certificate, private_key, port, server):
    project, export = root / version, root / ('export-' + version)
    export.mkdir()
    install_command = [sys.executable, str(sources['online_installer']), '--project', str(project)]
    run(install_command, environment, output / f'{version}-install.log')
    installed = {'addon': project / 'addons/fortress_rollback', 'examples': project / 'examples', 'license': project / 'LICENSE',
                 'project': project / 'project.godot', 'preset': project / 'export_presets.cfg'}
    installed_inventory = inventory(installed)
    if (project / '.godot').exists() or (project / 'addons/signal_fish').exists():
        raise ValueError('clean installation contains development cache or optional SDK')
    environment = environment.copy()
    for kind in ('CONFIG', 'CACHE', 'DATA'):
        location = root / f'{version}-user-{kind.lower()}'
        location.mkdir()
        environment['XDG_' + kind + '_HOME'] = str(location)
    command = [str(engine), '--headless', '--path', str(project)]
    actual = run([str(engine), '--version'], environment, output / f'{version}-version.log').strip()
    if not actual.startswith(version + '.stable.'):
        raise ValueError('unexpected online example engine version')
    run(command + ['--editor', '--quit'], environment, output / f'{version}-no-sdk-import.log')
    installed_frozen = freeze_after_import(installed, installed_inventory)
    no_sdk_command = command + ['--script', str(sources['online_install_check'])]
    no_sdk = run(no_sdk_command, environment, output / f'{version}-no-sdk.log')
    markers = [line.removeprefix('FORTRESS_CLEAN_INSTALL:') for line in no_sdk.splitlines() if line.startswith('FORTRESS_CLEAN_INSTALL:')]
    if len(markers) != 1:
        raise ValueError('clean install did not complete missing-SDK and offline checks')
    no_sdk = json.loads(markers[0])
    if (no_sdk.get('offline_frame') != 24 or type(no_sdk.get('offline_frame')) is not int
            or no_sdk.get('offline_state') != expected_states([[0] * 25, [0] * 25], 25)[24]
            or not isinstance(no_sdk.get('missing_sdk_message'), str)
            or 'SignalFish SDK is missing' not in no_sdk['missing_sdk_message']):
        raise ValueError('clean install local game differs from the independent canonical replay')
    if inventory(installed) != installed_frozen:
        raise ValueError('clean install runtime sources changed during missing-SDK checks')
    sdk_command = install_command + ['--sdk', str(sdk)]
    run(sdk_command, environment, output / f'{version}-install-sdk.log')
    # Templates are verified tools, copied into a fresh user directory rather than a cached editor profile.
    template_target = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates' / (version + '.stable')
    template_target.mkdir(parents=True)
    with zipfile.ZipFile(sources['templates_' + version]) as package:
        for member in package.namelist():
            if Path(member).name.startswith('web_'):
                (template_target / Path(member).name).write_bytes(package.read(member))
    documented_export = root / ('documented-export-' + version)
    documented_export.mkdir()
    installed['sdk'] = project / 'addons/signal_fish'
    before_sdk_import = inventory(installed)
    run(command + ['--editor', '--quit'], environment, output / f'{version}-sdk-import.log')
    installed_frozen = freeze_after_import(installed, before_sdk_import)
    documented_command = command + ['--export-release', 'Web', str(documented_export / 'index.html')]
    run(documented_command, environment, output / f'{version}-documented-export.log')
    if inventory(installed) != installed_frozen:
        raise ValueError('documented export changed installed runtime sources')
    documented_inventory = inventory({'export': documented_export})
    shutil.copyfile(sources['online_bridge'], project / 'bridge.gd')
    project_text = (project / 'project.godot').read_text()
    (project / 'project.godot').write_text(project_text.replace('res://examples/online/online.tscn', 'res://main.tscn'))
    (project / 'main.tscn').write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://bridge.gd" id="1"]\n'
        '[node name="ExampleWitness" type="Node"]\nscript = ExtResource("1")\n')
    executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish', 'examples': project / 'examples',
                'bridge': project / 'bridge.gd', 'project': project / 'project.godot', 'scene': project / 'main.tscn',
                'preset': project / 'export_presets.cfg', 'license': project / 'LICENSE', 'certificate': certificate, 'private_key': private_key}
    frozen = inventory(executed)
    run(command + ['--editor', '--quit'], environment, output / f'{version}-import.log')
    frozen = freeze_after_import(executed, frozen)
    run(command + ['--export-release', 'Web', str(export / 'index.html')], environment, output / f'{version}-export.log')
    exported = inventory({'export': export})
    browser = [str(sources['node']), str(sources['online_browser']), str(export), f'ws://127.0.0.1:{port}/v3/ws']
    clean_command = browser + ['clean', str(output / f'{version}-online-events.log')]
    offset = len(server.events)
    result = validate_result(json.loads(run_browser(clean_command, environment, output / f'{version}-online.log', rooms=5)))
    restart = result['rounds'][3]['server_restart']
    if server.events[offset:] != [restart['stopped'], restart['started']]:
        raise ValueError('browser process evidence disagrees with owned handles')
    server.verify_live()
    control_command = browser + ['corrupt', str(output / f'{version}-online-corrupt-events.log')]
    control = json.loads(run_browser(control_command, environment, output / f'{version}-online-corrupt.log', rooms=1))
    try:
        validate_result(control, corrupt=True)
    except ValueError as error:
        if not str(error).startswith('online example canonical prefix mismatch at frame '):
            raise
        result['restore_mutation'] = {'rejected': True, 'reason': str(error), 'teardown': control['teardown'], 'command': control_command}
    else:
        raise ValueError('online example accepted altered restored game state')
    if (inventory(executed) != frozen or inventory({'export': export}) != exported
            or inventory({'export': documented_export}) != documented_inventory):
        raise ValueError('online example executed sources changed')
    return ({'engine': actual, 'command': clean_command, 'result': result,
             'clean_install': {'install_command': install_command, 'sdk_command': sdk_command, 'no_sdk_command': no_sdk_command,
                               'import_commands': [command + ['--editor', '--quit']],
                               'engine_user_directories': {key: environment[key] for key in ('XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME')},
                               'no_sdk': no_sdk, 'documented_export_command': documented_command, 'fresh_user_directories': True,
                               'installed_inventory': installed_inventory, 'documented_inventory': installed_frozen,
                               'documented_export_inventory': documented_inventory}},
            {'engine': actual, 'source_inventory': frozen, 'export_inventory': exported})
