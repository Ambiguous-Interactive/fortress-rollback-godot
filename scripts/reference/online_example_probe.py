"""Export the shipped online scene and validate original local input prefixes."""
import json
import re
import shutil
import struct

from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from godot_smoke import run
from signalfish_probe import inventory


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


def validate_result(value, corrupt=False):
    if (not isinstance(value, dict) or value.get('passed') is not True or type(value.get('browser_instances')) is not int
            or value['browser_instances'] != 2 or value.get('errors') != [] or value.get('corrupt') is not corrupt):
        raise ValueError('online example browser flow failed')
    rounds = value.get('rounds')
    if not isinstance(rounds, list) or len(rounds) != (1 if corrupt else 2):
        raise ValueError('online example did not restart in a fresh room')
    if not corrupt:
        terminal = rounds[0].get('terminal', {})
        if (terminal.get('state') != 'failed' or not isinstance(terminal.get('message'), str)
                or 'fresh room' not in terminal['message'] or type(terminal.get('frame_before')) is not int
                or type(terminal.get('frame_after')) is not int or not 100 <= terminal['frame_before'] <= 256
                or terminal['frame_after'] != terminal['frame_before']):
            raise ValueError('online example peer departure did not stop simulation with actionable recovery')
    rooms, identities, comparisons = [], [], []
    for round_index, record in enumerate(rounds):
        peers = record.get('peers', [])
        if (len(peers) != 2 or any(type(peer.get('slot')) is not int or type(peer.get('page_index')) is not int for peer in peers)
                or sorted(peer['slot'] for peer in peers) != [0, 1] or sorted(peer.get('page_index') for peer in peers) != [0, 1]
                or not isinstance(record.get('room'), str) or not re.fullmatch('[A-Z0-9]{6}', record['room'])):
            raise ValueError('online example frozen player slots invalid')
        peers.sort(key=lambda peer: peer['slot'])
        rooms.append(record['room'])
        session_ids = [peer.get('session_id') for peer in peers]
        if (any(not isinstance(identity, str) or not re.fullmatch('[a-f0-9]{32}', identity) for identity in session_ids)
                or session_ids[0] != session_ids[1]):
            raise ValueError('online example peers disagree on the frozen rollback identity')
        identities.append(session_ids[0])
        teardown = record.get('teardown')
        if not isinstance(teardown, list) or len(teardown) != 2:
            raise ValueError('online example physical teardown missing')
        for closed in teardown:
            if (not isinstance(closed, dict) or any(type(closed.get(field)) is not int for field in
                    ('channels', 'channels_closed', 'connections', 'connections_closed'))
                    or closed['channels'] != 3 * (round_index + 1) or closed['channels_closed'] != closed['channels']
                    or closed['connections'] < round_index + 1 or closed['connections_closed'] != closed['connections']):
                raise ValueError('online example retained physical channels or ICE connections')
        histories = [peer['inputs'] for peer in peers]
        for history in histories:
            if (not isinstance(history, list) or len(history) < (20 if corrupt else 100) or len(history) > 256
                    or any(type(buttons) is not int or not 0 <= buttons <= 15 for buttons in history)
                    or not any(history) or history[:2] != [0, 0]):
                raise ValueError('actual physical keyboard submission evidence incomplete')
        expected = expected_states(histories, min(map(len, histories)))
        for peer in peers:
            if (type(peer.get('restores')) is not int or peer['restores'] < 1 or peer.get('failure') != ''
                    or type(peer.get('confirmed')) is not int or not (20 if corrupt else 90) <= peer['confirmed'] <= len(peer['inputs']) - 1
                    or type(peer.get('frame')) is not int or not 20 <= peer['frame'] <= len(peer['inputs'])
                    or peer.get('state') != 'playing' or peer.get('room') != record['room']):
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
                raise ValueError('online example corrected prefix coverage incomplete')
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
    if (not corrupt and (rooms[0] == rooms[1] or identities[0] == identities[1])) or value.get('teardown') is not True:
        raise ValueError('online example reused room or retained connections')
    for frame, expected, state in comparisons:
        if expected != state:
            raise ValueError(f'online example canonical prefix mismatch at frame {frame}')
    return value


def run_online(root, version, engine, sdk, sources, environment, output, certificate, private_key, port):
    project, export = root / version, root / ('export-' + version)
    project.mkdir()
    export.mkdir()
    for source, destination in [(sources['addon'], 'addons/fortress_rollback'), (sdk / 'addons/signal_fish', 'addons/signal_fish'),
                                (sources['offline_example'], 'examples/offline'), (sources['online_example'], 'examples/online')]:
        shutil.copytree(source, project / destination)
    shutil.copyfile(sources['online_bridge'], project / 'bridge.gd')
    (project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Online example witness"\n'
        'run/main_scene="res://main.tscn"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    (project / 'main.tscn').write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://bridge.gd" id="1"]\n'
        '[node name="ExampleWitness" type="Node"]\nscript = ExtResource("1")\n')
    (project / 'export_presets.cfg').write_text('[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\nexport_filter="all_resources"\n'
        'include_filter=""\nexclude_filter=""\n[preset.0.options]\nvariant/extensions_support=false\nvariant/thread_support=false\n')
    executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish', 'examples': project / 'examples',
                'bridge': project / 'bridge.gd', 'project': project / 'project.godot', 'scene': project / 'main.tscn',
                'preset': project / 'export_presets.cfg', 'certificate': certificate, 'private_key': private_key}
    frozen = inventory(executed)
    command = [str(engine), '--headless', '--path', str(project)]
    actual = run([str(engine), '--version'], environment, output / f'{version}-version.log').strip()
    if not actual.startswith(version + '.stable.'):
        raise ValueError('unexpected online example engine version')
    run(command + ['--editor', '--quit'], environment, output / f'{version}-import.log')
    frozen = freeze_after_import(executed, frozen)
    run(command + ['--export-release', 'Web', str(export / 'index.html')], environment, output / f'{version}-export.log')
    exported = inventory({'export': export})
    browser = [str(sources['node']), str(sources['online_browser']), str(export), f'ws://127.0.0.1:{port}/v3/ws']
    clean_command = browser + ['clean', str(output / f'{version}-online-events.log')]
    result = validate_result(json.loads(run_browser(clean_command, environment, output / f'{version}-online.log', rooms=1)))
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
    if inventory(executed) != frozen or inventory({'export': export}) != exported:
        raise ValueError('online example executed sources changed')
    return ({'engine': actual, 'command': clean_command, 'result': result},
            {'engine': actual, 'source_inventory': frozen, 'export_inventory': exported})
