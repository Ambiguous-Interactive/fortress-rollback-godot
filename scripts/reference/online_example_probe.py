"""Export the shipped online scene and validate original local input prefixes."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import time
import zipfile

from online_diagnostics import validate_download, validate_trace_history, game_checksum

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_capacity  # noqa: E402

from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from godot_smoke import run
from signalfish_probe import inventory
from wire import INPUT_HEADER

DESYNC_REASON = 18
# The witness owns the development host while it runs.
HOST_LEASE_NAME = "online-witness"
HOST_WAIT_SECONDS = 900.0
# examples/online/match.gd schedules local input this many frames ahead of the current frame.
INPUT_DELAY = 2


class StepTimings:
    """The elapsed time of every step of the online probe, next to the step it belongs to."""

    def __init__(self):
        self.steps = []

    def measure(self, name):
        """Measure one step. The elapsed time is recorded even when the step raises."""
        return _MeasuredStep(self, name)

    def record(self, name, elapsed_us, failed=False):
        self.steps.append({'step': name, 'elapsed_us': int(elapsed_us), 'failed': failed})

    def failed(self):
        return next((step for step in self.steps if step['failed']), None)

    def summary(self):
        """The measured durations, ready for the receipt."""
        return [dict(step) for step in self.steps]


class _MeasuredStep:
    """One measured step of the online probe."""

    def __init__(self, timings, name):
        self.timings = timings
        self.name = name
        self.started = 0.0

    def __enter__(self):
        self.started = time.monotonic()
        return self

    def __exit__(self, kind, value, traceback):
        elapsed_us = round((time.monotonic() - self.started) * 1000000)
        self.timings.record(self.name, elapsed_us, failed=kind is not None)
        if kind is not None and value is not None:
            report_step_failure(value, self.timings, self.name, elapsed_us)
        return False


def report_step_failure(error, timings, name, elapsed_us):
    """A rejected run names the step that failed and how long it took."""
    error.step_durations = timings.summary()
    error.failed_step = name
    error.args = (f'online example step {name} failed after {elapsed_us} us: {error}',)


def browser_step_durations(result):
    """The sub-step durations the browser reported, as step names and elapsed times."""
    timings = result.get('timings')
    if not isinstance(timings, dict):
        raise ValueError('online example browser step timings missing')
    durations = []
    for name, value in sorted(timings.items()):
        if not isinstance(name, str) or type(value) is not int or value < 0:
            raise ValueError('online example browser step timing invalid')
        durations.append((f'browser.{name.removesuffix("_us")}', value))
    return durations


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


def validate_replay_download(value, expected_engine, round_record):
    if (not isinstance(value, dict) or value.get('filename') != 'fortress-online.frrp' or value.get('disabled_peer') is not True
            or not isinstance(value.get('hex'), str) or not re.fullmatch(r'(?:[0-9a-f]{2}){23,16384}', value['hex'])):
        raise ValueError('online replay download missing or unbounded')
    boundaries = value.get('command_boundaries')
    expected = {'accepted': 33792, 'rejected': 33793, 'binary_limit': 16384}
    if (not isinstance(boundaries, dict) or boundaries != expected
            or any(type(boundaries.get(key)) is not int for key in expected)):
        raise ValueError('online replay command envelope boundaries missing or invalid')
    before, after = value.get('before'), value.get('after')
    if (not isinstance(before, dict) or not isinstance(after, dict) or before != after or before.get('state') != 'failed'
            or any(type(boundary.get(key)) is not int for boundary in (before, after) for key in ('frame', 'restores'))
            or not 100 <= before['frame'] <= 256 or before['restores'] < 1):
        raise ValueError('online replay download advanced a stopped match')
    raw = bytes.fromhex(value['hex'])
    version, players, width, frames, skipped, delay, prediction, sync = struct.unpack_from('<HBIIIHBB', raw, 4)
    if (raw[:4] != b'FRRP' or version != 6 or (players, width, skipped, delay, prediction, sync) != (2, 1, 0, 2, 8, 0)
            or not 100 <= frames <= min(before['frame'], 256) or raw[23:24] != b'\0'):
        raise ValueError('online replay configuration differs from the played match')
    capture = round_record.get('replay_capture')
    if (not isinstance(capture, dict) or capture.get('captured') is not True or type(capture.get('code')) is not int or capture['code'] != 0
            or type(capture.get('frame')) is not int or capture['frame'] != frames or frames != before['frame']
            or not isinstance(capture.get('before'), dict) or type(capture['before'].get('frame')) is not int
            or not 100 <= capture['before']['frame'] <= frames):
        raise ValueError('online replay lacks explicit finalized-boundary capture')
    cursor, texts = 24, []
    for _ in range(5):
        size = raw[cursor] if cursor < len(raw) else 129
        field = raw[cursor + 1:cursor + 1 + size]
        if size > 128 or len(field) != size or any(byte < 0x20 or byte > 0x7e for byte in field):
            raise ValueError('online replay metadata malformed')
        texts.append(field.decode('ascii'))
        cursor += 1 + size
    if (not isinstance(expected_engine, str) or not expected_engine or texts[0] != expected_engine or texts[1:] != ['0.1.0',
            'fortress-rollback d124c89080004d96971a629bb0427056ee1805e3', '1701', 'fortress-online-integer-v1']):
        raise ValueError('online replay lost its engine or game metadata')
    peers = value.get('peers')
    if (not isinstance(peers, list) or len(peers) != 2 or any(not isinstance(peer, dict) or type(peer.get('slot')) is not int for peer in peers)
            or sorted(peer['slot'] for peer in peers) != [0, 1]):
        raise ValueError('online replay original input identities missing')
    histories = [peer.get('inputs') for peer in sorted(peers, key=lambda peer: peer['slot'])]
    if any(not isinstance(history, list) or not frames <= len(history) <= 256
           or any(type(button) is not int or not 0 <= button <= 15 for button in history) for history in histories):
        raise ValueError('online replay original input histories incomplete')
    original = [peer['inputs'] for peer in sorted(round_record['peers'], key=lambda peer: peer['slot'])]
    stopped = round_record['terminal']['frame_after']
    retained = round_record['diagnostics'][1]['before']
    if histories != original or before['frame'] != stopped or before['frame'] != retained['frame'] or before['restores'] != retained['restores']:
        raise ValueError('online replay does not belong to the witnessed round')
    states = expected_states([history[:frames] + [0] for history in histories], frames + 1)
    checksums = 0
    for frame in range(frames):
        if cursor + 5 > len(raw) or raw[cursor:cursor + 2] != bytes(history[frame] for history in histories):
            raise ValueError('online replay differs from original submitted input')
        row = raw[cursor:cursor + 4]
        if row[2:] != bytes([1, 1]):
            raise ValueError('online replay player statuses differ from the played match')
        flag = raw[cursor + 4]
        cursor += 5
        if flag not in (0, 1):
            raise ValueError('online replay contains skipped or malformed frames')
        if flag == 1:
            if raw[cursor:cursor + 16].hex() != game_checksum(states[frame]):
                raise ValueError('online replay checksum differs from canonical history')
            checksums += 1
            cursor += 16
        if raw[cursor:cursor + 16] != hashlib.sha256(row).digest()[:16]:
            raise ValueError('online replay input digest differs from the original row')
        cursor += 16
    if version == 6:
        if raw[cursor:cursor + 16].hex() != game_checksum(states[frames]):
            raise ValueError('online replay terminal checksum differs from canonical final state')
        cursor += 16
        checksums += 1
    if cursor != len(raw) or checksums == 0:
        raise ValueError('online replay missing checksum evidence or has trailing bytes')
    playback = value.get('playback')
    if (not isinstance(playback, dict) or any(type(playback.get(key)) is not int for key in ('decode_code', 'code', 'frames', 'failure_frame'))
            or playback != {'decode_code': 0, 'code': 16, 'frames': frames, 'failure_frame': -1, 'canonical': states[frames]}):
        raise ValueError('downloaded replay did not play back to its independent canonical state')
    return frames


SCHEDULING_FIELDS = ('turns', 'ticks_per_second', 'max_gap_us', 'max_gap_turns', 'max_gap_transport_us',
                     'confirmation_max_gap_us', 'confirmation_max_gap_turns', 'confirmed_frames')


def validate_scheduling(summary, confirmed=None):
    """The host's service cadence and confirmation waits must be published for every room.

    The counters describe one room: the page restarts them with the next room.
    ``confirmed_frames`` counts the frames the page saw confirmed, so it cannot
    exceed the room's own confirmed frontier by more than the frontier's first frame.
    """
    if (not isinstance(summary, dict) or set(summary) != set(SCHEDULING_FIELDS)
            or any(type(summary.get(field)) is not int or summary[field] < 0 for field in SCHEDULING_FIELDS)
            or summary['turns'] < 1 or summary['ticks_per_second'] < 1):
        raise ValueError('online example scheduling summary missing or malformed')
    ticks = summary['ticks_per_second']
    for gap, turns in (('max_gap_us', 'max_gap_turns'), ('confirmation_max_gap_us', 'confirmation_max_gap_turns')):
        if summary[turns] != max(1, summary[gap] * ticks // 1000000):
            raise ValueError('online example scheduling gap disagrees with its nominal turn count')
    # The page cannot confirm more frames than the room itself observed.
    if confirmed is not None and summary['confirmed_frames'] > confirmed + 1:
        raise ValueError('online example scheduling summary claims more confirmations than the room observed')


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
    if (len(raw) < 76 or raw[:8] != INPUT_HEADER
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
                or bytes.fromhex(held[0])[:8] != INPUT_HEADER
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



def validate_corrupt_control(record, peers):
    """The corrupt control must reach a restore on every peer and the desync must be caught.

    The corruption is applied while a peer restores a snapshot, so a peer that never rolled back
    never corrupted anything. The witness therefore waits for the restore it needs and records the
    restore counts it waited for. The corrupted peer must terminate with the desync reason and the
    healthy peer must keep its confirmed history.
    """
    control = record.get('corrupt_control')
    if (not isinstance(control, dict) or set(control) != {'restores', 'corrupt_page', 'desync_page', 'desync_reason'}
            or type(control.get('corrupt_page')) is not int or type(control.get('desync_page')) is not int
            or type(control.get('desync_reason')) is not int or control['desync_reason'] != DESYNC_REASON):
        raise ValueError('online example corrupt control evidence missing')
    pages = {peer['page_index']: peer for peer in peers}
    if set(pages) != {0, 1} or control['corrupt_page'] not in pages or control['desync_page'] not in pages:
        raise ValueError('online example corrupt control evidence missing')
    ordered = sorted(peers, key=lambda peer: peer['page_index'])
    corrupt = pages[control['corrupt_page']]
    healthy = [peer for peer in ordered if peer['page_index'] != control['corrupt_page']]
    if (corrupt.get('corrupt') is not True or any(peer.get('corrupt') is not False for peer in healthy)
            or not isinstance(control['restores'], list) or control['restores'] != [peer['restores'] for peer in ordered]
            or any(type(value) is not int or value < 1 for value in control['restores'])):
        raise ValueError('online example corrupt control evidence missing')
    desynced = pages[control['desync_page']]
    if desynced.get('state') != 'failed' or desynced.get('terminal_reason') != DESYNC_REASON:
        raise ValueError('online example corrupt control observed no desync')
    if any(peer.get('terminal_reason') not in (0, DESYNC_REASON) for peer in healthy):
        raise ValueError('online example corrupt control lost the healthy peer')


def validate_prediction_gate(record, peers):
    """Both actual predicted callbacks precede release of every staged original input."""
    evidence = record.get('prediction')
    if (not isinstance(evidence, list) or len(evidence) != 2 or any(not isinstance(item, dict) for item in evidence)
            or any(type(item.get('page_index')) is not int for item in evidence)
            or sorted(item['page_index'] for item in evidence) != [0, 1]):
        raise ValueError('online example prediction barrier evidence missing')
    pages = {peer['page_index']: peer for peer in peers}
    retained = {identity['page_index']: identity for identity in record['identity']}
    for item in evidence:
        peer = pages[item['page_index']]
        before, after = item.get('before'), item.get('after')
        identity = {key: peer.get(key) or retained[item['page_index']].get(key) for key in ('room', 'room_id')}
        if (type(item.get('frame')) is not int or type(peer.get('frame')) is not int or not 2 <= item['frame'] < peer['frame']
                or type(peer.get('predicted_frame')) is not int or peer['predicted_frame'] != item['frame']
                or peer['inputs'][2] != (2 if item['page_index'] == 0 else 4)
                or not isinstance(before, dict) or not isinstance(after, dict)
                or any(type(boundary.get(key)) is not int for boundary in (before, after)
                       for key in ('pending', 'bytes', 'released', 'releases'))
                or type(peer.get('game_lifetime')) is not int or peer['game_lifetime'] <= 0
                or type(peer.get('predicted_lifetime')) is not int or peer['predicted_lifetime'] != peer['game_lifetime']
                or any(boundary.get(key) != identity[key] for boundary in (before, after) for key in ('room', 'room_id'))
                or any(boundary.get(key) != peer.get(key) for boundary in (before, after) for key in ('session_id', 'game_lifetime'))
                or any(type(boundary.get('game_lifetime')) is not int for boundary in (before, after))
                or before.get('active') is not True or before.get('failure') != ''
                or not 1 <= before['pending'] <= 256 or not 8 * before['pending'] <= before['bytes'] <= 262144
                or before['released'] != 0 or before['releases'] != 0
                or after.get('active') is not False or after.get('failure') != ''
                or after['pending'] != 0 or after['bytes'] != 0 or after['released'] != before['pending'] or after['releases'] != 1):
            raise ValueError('online example prediction barrier did not precede original delivery')


def validate_result(value, corrupt=False, expected_engine=None):
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
        for page_index, download in enumerate(downloads):
            validate_download(download, trace_enabled=not corrupt and round_index == 0 and page_index == 0)
            before, after = download['before'], download['after']
            if (before.get('state') != 'offline' or after.get('state') != 'offline'
                    or before['frame'] != after['frame'] or before['restores'] != after['restores']):
                raise ValueError('online example diagnostic export crossed offline boundary')
        peers = record.get('peers', [])
        if (not isinstance(peers, list) or len(peers) != 2 or any(not isinstance(peer, dict) for peer in peers)
                or any(type(peer.get('slot')) is not int or type(peer.get('page_index')) is not int for peer in peers)
                or sorted(peer['slot'] for peer in peers) != [0, 1] or sorted(peer.get('page_index') for peer in peers) != [0, 1]
                or not isinstance(record.get('room'), str) or not re.fullmatch('[A-Z0-9]{6}', record['room'])):
            raise ValueError('online example frozen player slots invalid')
        peers.sort(key=lambda peer: peer['slot'])
        rooms.append(record['room'])
        identity = record.get('identity')
        if (not isinstance(identity, list) or len(identity) != 2
                or any(not isinstance(value, dict) or type(value.get('page_index')) is not int for value in identity)):
            raise ValueError('online example room identity missing')
        identified = {value['page_index']: value for value in identity}
        if set(identified) != {0, 1}:
            raise ValueError('online example room identity missing')
        identity_rooms = [identified[index].get('room_id') for index in (0, 1)]
        if (any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value)
                for value in identity_rooms) or identity_rooms[0] != identity_rooms[1]):
            raise ValueError('online example actual room UUID evidence invalid')
        uuids = [peer.get('room_id') or identified[peer['page_index']].get('room_id') for peer in peers]
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
        validate_prediction_gate(record, peers)
        expected = expected_states(histories, min(map(len, histories)))
        for peer in peers:
            intended_desync = (corrupt and peer.get('state') == 'failed' and type(peer.get('terminal_reason')) is int
                               and peer['terminal_reason'] == DESYNC_REASON and isinstance(peer.get('failure'), str) and bool(peer['failure']))
            # Inputs are indexed by scheduled frame, so a complete capture covers every confirmed frame.
            # A desynced peer stops capturing at termination; the session still bounds its confirmation.
            confirmed_limit = (peer['frame'] + INPUT_DELAY if intended_desync and type(peer.get('frame')) is int
                               else len(peer['inputs']) - 1)
            # A closed room clears the lobby state but never the session, so a peer without a session failure stays valid.
            session_intact = peer.get('failure') == '' and peer.get('terminal_reason') == 0
            if (type(peer.get('restores')) is not int or peer['restores'] < 1 or (peer.get('failure') != '' and not intended_desync)
                    or type(peer.get('confirmed')) is not int or not (20 if corrupt else 90) <= peer['confirmed'] <= confirmed_limit
                    or type(peer.get('frame')) is not int or not 20 <= peer['frame'] <= len(peer['inputs'])
                    or (peer.get('state') != 'playing' and not intended_desync and not session_intact)
                    or (peer.get('room') or identified[peer['page_index']].get('room')) != record['room']):
                raise ValueError('online example rollback or confirmation missing')
            validate_scheduling(peer.get('scheduling'), peer.get('confirmed'))
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
                comparisons.append((page_index, frame, expected[frame], state))
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
        elif corrupt:
            validate_corrupt_control(record, peers)
    if (not corrupt and (len(set(rooms)) != 5 or len(set(room_ids)) != 5 or len(set(identities)) != 5)) or value.get('teardown') is not True:
        raise ValueError('online example reused room or retained connections')
    mismatched = {}
    for page_index, frame, expected, state in comparisons:
        if expected != state:
            mismatched.setdefault(page_index, []).append(frame)
    if corrupt:
        # Only the corrupted peer may leave the canonical history. The healthy peer keeps its own prefix.
        corrupt_page = rounds[0]['corrupt_control']['corrupt_page']
        healthy = [page for page in mismatched if page != corrupt_page]
        if healthy:
            raise ValueError('online example healthy peer lost its canonical history')
        if corrupt_page not in mismatched:
            raise ValueError('online example corruption did not reach the canonical state')
        raise ValueError(f'online example canonical prefix mismatch at frame {mismatched[corrupt_page][0]}')
    if mismatched:
        first = next(frame for page_index, frame, expected, state in comparisons if expected != state)
        raise ValueError(f'online example canonical prefix mismatch at frame {first}')
    if not corrupt:
        validate_replay_download(rounds[0].get('replay_download'), expected_engine, rounds[0])
        validate_viewer(value.get('viewer'), rounds[0]['replay_download'])
        histories = [peer['inputs'] for peer in rounds[0]['peers']]
        expected = expected_states(histories, min(map(len, histories)))
        validate_trace_history(rounds[0]['diagnostics'][0]['report'], expected, histories)
        validate_diagnostic_viewer(value.get('diagnostic_viewer'), rounds[0]['diagnostics'][0]['report']['trace'], histories)
    return value


def validate_viewer(value, download):
    if not isinstance(value, dict) or set(value) != {'initial', 'stepped', 'paused', 'restarted', 'rejected', 'completed', 'forward', 'backward'}:
        raise ValueError('online replay viewer controls missing')
    frames = download['playback']['frames']
    for label, row in value.items():
        if (not isinstance(row, dict) or set(row) != {'frame', 'frames', 'playing', 'message', 'state'}
                or type(row['frame']) is not int or type(row['frames']) is not int or row['frames'] != frames
                or row['playing'] is not False or not isinstance(row['message'], str)
                or not isinstance(row['state'], str) or not re.fullmatch(r'[0-9a-f]{272}', row['state'])):
            raise ValueError('online replay viewer control evidence malformed: ' + label)
    histories = [peer['inputs'] for peer in sorted(download['peers'], key=lambda peer: peer['slot'])]
    expected = expected_states(histories, 13)
    initial = value['initial']
    if (value['forward']['frame'] != 12 or value['forward']['state'] != expected[12]
            or value['backward']['frame'] != 6 or value['backward']['state'] != expected[6]
            or initial['frame'] != 0 or value['stepped']['frame'] != 1 or not 4 <= value['paused']['frame'] < frames
            or any(value[label]['frame'] != 0 or value[label]['state'] != initial['state'] for label in ('restarted', 'rejected'))
            or not value['rejected']['message'].startswith('Could not open replay')
            or value['completed']['frame'] != frames or value['completed']['state'] != download['playback']['canonical']
            or not value['completed']['message'].startswith('Replay complete.')):
        raise ValueError('online replay viewer did not reproduce downloaded gameplay and controls')


def validate_diagnostic_viewer(value, trace, histories):
    labels = {'initial', 'stepped', 'restarted', 'rejected', 'completed', 'diverged'}
    if not isinstance(value, dict) or value.keys() != labels:
        raise ValueError('diagnostic viewer control inventory missing')
    rows = trace['frames']
    final_frame = rows[-1]['frame'] + bool(rows[-1]['inputs'])
    if rows[0]['frame'] > min(map(len, histories)):
        raise ValueError('diagnostic viewer initial boundary exceeds original inputs')
    # The captured window can end with speculative inputs after the remote sender stopped.
    # Check its original prefix independently, then reproduce the inputs actually applied by this peer.
    applied = [history[:final_frame + 1] + [0] * max(0, final_frame + 1 - len(history)) for history in histories]
    for row in rows:
        for sample in row['inputs']:
            applied[sample['player']][row['frame']] = int(sample['bytes'], 16)
    states = expected_states(applied, final_frame + 1)
    for label, row in value.items():
        if (not isinstance(row, dict) or row.keys() != {'status', 'state', 'message'} or not isinstance(row['status'], dict)
                or not isinstance(row['message'], str) or not isinstance(row['state'], str) or not re.fullmatch(r'[0-9a-f]{272}', row['state'])):
            raise ValueError('diagnostic viewer observation malformed')
        status = row['status']
        integers = ('code', 'first_boundary', 'last_boundary', 'next_boundary', 'rows_consumed', 'row_count',
                    'game_frame', 'validated_states', 'advanced_frames')
        if (any(type(status.get(field)) is not int for field in integers) or status.get('loaded') is not True
                or status.get('playing') is not False or type(status.get('complete')) is not bool
                or status.get('application_version') != trace['application_version'] or status.get('seed') != trace['seed']
                or status.get('capture_failure') != trace['first_divergence'] or status['row_count'] != len(rows)
                or status['first_boundary'] != rows[0]['frame'] or status['last_boundary'] != rows[-1]['frame']):
            raise ValueError('diagnostic viewer lost captured metadata or boundaries')
    initial = {'loaded': True, 'playing': False, 'code': 0, 'first_boundary': rows[0]['frame'], 'last_boundary': rows[-1]['frame'],
               'next_boundary': rows[0]['frame'], 'rows_consumed': 0, 'row_count': len(rows), 'game_frame': 0,
               'seed': trace['seed'], 'application_version': trace['application_version'], 'capture_failure': trace['first_divergence'],
               'complete': False, 'validated_states': 0, 'advanced_frames': 0, 'failure': {}}
    stepped = dict(initial, rows_consumed=1, validated_states=1, advanced_frames=1,
                   next_boundary=rows[1]['frame'], game_frame=rows[0]['frame'] + 1)
    complete = dict(initial, complete=True, rows_consumed=len(rows), next_boundary=-1, game_frame=final_frame,
                    validated_states=sum(row['state_available'] for row in rows), advanced_frames=sum(bool(row['inputs']) for row in rows))
    changed_index = next(index for index, row in enumerate(rows) if index > 0 and row['state_available'])
    changed = rows[changed_index]
    failed = dict(initial, code=DESYNC_REASON, rows_consumed=changed_index, next_boundary=changed['frame'], game_frame=changed['frame'],
                  validated_states=sum(row['state_available'] for row in rows[:changed_index]),
                  advanced_frames=sum(bool(row['inputs']) for row in rows[:changed_index]),
                  failure={'frame': changed['frame'], 'kind': 'state', 'byte': 24, 'expected_bytes': 136, 'actual_bytes': 136})
    failure = value['diverged']['status'].get('failure')
    if not isinstance(failure, dict) or any(type(failure.get(field)) is not int for field in ('frame', 'byte', 'expected_bytes', 'actual_bytes')):
        raise ValueError('diagnostic viewer failure positions must be integers')
    expected_status = {'initial': initial, 'restarted': initial, 'rejected': initial, 'stepped': stepped, 'completed': complete, 'diverged': failed}
    expected_frame = {'initial': 0, 'restarted': 0, 'rejected': 0, 'stepped': rows[0]['frame'] + 1,
                      'completed': final_frame, 'diverged': changed['frame']}
    if (any(row['status'] != expected_status[label] or row['state'] != states[expected_frame[label]] for label, row in value.items())
            or not value['rejected']['message'].startswith('This viewer needs')):
        raise ValueError('diagnostic viewer controls differ from downloaded canonical history')


def validate_diagnostic_playback(output, trace):
    prefix = 'FORTRESS_DIAGNOSTIC_RESULT '
    records = [line[len(prefix):] for line in output.splitlines() if line.startswith(prefix)]
    if len(records) != 1:
        raise ValueError('online diagnostic reproduction result missing or duplicated')
    report = json.loads(records[0])
    expected = {'code': 16, 'complete': True, 'failure': {},
                'validated_states': sum(row['state_available'] for row in trace['frames']),
                'advanced_frames': sum(bool(row['inputs']) for row in trace['frames'])}
    if (not isinstance(report, dict) or any(type(report.get(key)) is not int for key in ('code', 'validated_states', 'advanced_frames'))
            or report.get('complete') is not True or report != expected or expected['validated_states'] < 2 or expected['advanced_frames'] < 1):
        raise ValueError('downloaded diagnostic did not reproduce all captured canonical boundaries')
    return report


def run_online(root, version, engine, sdk, sources, environment, output, certificate, private_key, port, server):
    # The browser witness needs a responsive host. It waits for a local probe to finish and then holds
    # the host, so a native suite that starts meanwhile runs its wave serially instead of starving it.
    if not host_capacity.acquire_when_free(HOST_LEASE_NAME, HOST_WAIT_SECONDS):
        raise ValueError('the development host stayed busy; the online witness needs a responsive host')
    project, export = root / version, root / ('export-' + version)
    export.mkdir()
    timings = StepTimings()
    install_command = [sys.executable, str(sources['online_installer']), '--project', str(project)]
    with timings.measure('install'):
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
    with timings.measure('engine_version'):
        actual = run([str(engine), '--version'], environment, output / f'{version}-version.log').strip()
    if not actual.startswith(version + '.stable.'):
        raise ValueError('unexpected online example engine version')
    with timings.measure('no_sdk_import'):
        run(command + ['--editor', '--quit'], environment, output / f'{version}-no-sdk-import.log')
    installed_frozen = freeze_after_import(installed, installed_inventory)
    no_sdk_command = command + ['--script', str(sources['online_install_check'])]
    with timings.measure('no_sdk_check'):
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
    with timings.measure('install_sdk'):
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
    with timings.measure('sdk_import'):
        run(command + ['--editor', '--quit'], environment, output / f'{version}-sdk-import.log')
    installed_frozen = freeze_after_import(installed, before_sdk_import)
    documented_command = command + ['--export-release', 'Web', str(documented_export / 'index.html')]
    with timings.measure('documented_export'):
        run(documented_command, environment, output / f'{version}-documented-export.log')
    if inventory(installed) != installed_frozen:
        raise ValueError('documented export changed installed runtime sources')
    documented_inventory = inventory({'export': documented_export})
    shutil.copyfile(sources['online_bridge'], project / 'bridge.gd')
    shutil.copyfile(sources['diagnostic_cli'], project / 'diagnose_trace.gd')
    project_text = (project / 'project.godot').read_text()
    (project / 'project.godot').write_text(project_text.replace('res://examples/online/online.tscn', 'res://main.tscn'))
    (project / 'main.tscn').write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://bridge.gd" id="1"]\n'
        '[node name="ExampleWitness" type="Node"]\nscript = ExtResource("1")\n')
    executed = {'addon': project / 'addons/fortress_rollback', 'sdk': project / 'addons/signal_fish', 'examples': project / 'examples',
                'bridge': project / 'bridge.gd', 'diagnostic_cli': project / 'diagnose_trace.gd', 'project': project / 'project.godot', 'scene': project / 'main.tscn',
                'preset': project / 'export_presets.cfg', 'license': project / 'LICENSE', 'certificate': certificate, 'private_key': private_key}
    frozen = inventory(executed)
    with timings.measure('import'):
        run(command + ['--editor', '--quit'], environment, output / f'{version}-import.log')
    frozen = freeze_after_import(executed, frozen)
    with timings.measure('export'):
        run(command + ['--export-release', 'Web', str(export / 'index.html')], environment, output / f'{version}-export.log')
    exported = inventory({'export': export})
    browser = [str(sources['node']), str(sources['online_browser']), str(export), f'ws://127.0.0.1:{port}/v3/ws']
    clean_command = browser + ['clean', str(output / f'{version}-online-events.log')]
    offset = len(server.events)
    with timings.measure('browser_flow'):
        result = validate_result(json.loads(run_browser(clean_command, environment, output / f'{version}-online.log', rooms=5)),
                                 expected_engine=no_sdk['engine_identity'])
        durations = browser_step_durations(result)
    for name, elapsed_us in durations:
        timings.record(name, elapsed_us)
    if (output / f'{version}-online-replay.frrp').read_bytes().hex() != result['rounds'][0]['replay_download']['hex']:
        raise ValueError('saved replay artifact differs from the downloaded bytes')
    diagnostic_path = (output / f'{version}-diagnostic.json').resolve()
    diagnostic_path.write_text(json.dumps(result['rounds'][0]['diagnostics'][0]['report']), encoding='utf-8')
    diagnostic_command = command + ['--script', 'res://diagnose_trace.gd', '--', str(diagnostic_path)]
    with timings.measure('diagnostic_reproduction'):
        diagnostic_output = run(diagnostic_command, environment, output / f'{version}-diagnostic-reproduction.log')
    diagnostic_result = validate_diagnostic_playback(diagnostic_output, result['rounds'][0]['diagnostics'][0]['report']['trace'])
    restart = result['rounds'][3]['server_restart']
    if server.events[offset:] != [restart['stopped'], restart['started']]:
        raise ValueError('browser process evidence disagrees with owned handles')
    server.verify_live()
    control_command = browser + ['corrupt', str(output / f'{version}-online-corrupt-events.log')]
    with timings.measure('corrupt_control'):
        control = json.loads(run_browser(control_command, environment, output / f'{version}-online-corrupt.log', rooms=1))
        try:
            validate_result(control, corrupt=True, expected_engine=no_sdk['engine_identity'])
        except ValueError as error:
            if not str(error).startswith('online example canonical prefix mismatch at frame '):
                raise
            result['restore_mutation'] = {'rejected': True, 'reason': str(error), 'teardown': control['teardown'], 'command': control_command,
                                          'corrupt_control': control['rounds'][0].get('corrupt_control')}
        else:
            raise ValueError('online example accepted altered restored game state')
    if (inventory(executed) != frozen or inventory({'export': export}) != exported
            or inventory({'export': documented_export}) != documented_inventory):
        raise ValueError('online example executed sources changed')
    print(f'online {version} steps: ' + ', '.join(f'{step["step"]}={step["elapsed_us"]}us' for step in timings.steps),
          file=sys.stderr, flush=True)
    host_capacity.release()
    return ({'engine': actual, 'command': clean_command, 'result': result, 'steps': timings.summary(),
             'diagnostic_reproduction': {'command': diagnostic_command, 'result': diagnostic_result},
             'clean_install': {'install_command': install_command, 'sdk_command': sdk_command, 'no_sdk_command': no_sdk_command,
                               'import_commands': [command + ['--editor', '--quit']],
                               'engine_user_directories': {key: environment[key] for key in ('XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME')},
                               'no_sdk': no_sdk, 'documented_export_command': documented_command, 'fresh_user_directories': True,
                               'installed_inventory': installed_inventory, 'documented_inventory': installed_frozen,
                               'documented_export_inventory': documented_inventory}},
            {'engine': actual, 'source_inventory': frozen, 'export_inventory': exported})
