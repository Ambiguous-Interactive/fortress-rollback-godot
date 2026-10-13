#!/usr/bin/env python3
"""Verify exported Godot rollback gameplay through real Chromium WebRTC meshes."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import subprocess
import tempfile
import zipfile

from browser.webrtc_import import freeze_after_import
from browser.webrtc_runner import run_browser
from browser.owned_server import OwnedServer
from fetch import CACHE, ROOT, digest, fetch, load_manifest
from godot_smoke import run
from signalfish_live_probe import (build_cargo, extract, native_inventory, source_inventory, validate_build_receipt, wait_ready)
from signalfish_probe import inventory
from run import capture
def validate_engine(engine, expected):
    if digest(engine) != expected:
        raise ValueError("supplied engine differs from pinned editor archive")
def validate_browser(result, faults, mixed=False, default_budgets=False, physical_close=False):
    if (not isinstance(result, dict) or result.get('passed') is not True or result.get('browser') != 'Chromium'
            or type(result.get('browser_instances')) is not int or result['browser_instances'] != 2
            or result.get('faults') is not faults or result.get('corrupt') is not False or result.get('errors') != []
            or result.get('physicalClose', False) is not physical_close or result.get('mixed', False) is not mixed or result.get('mixedDefault', False) is not default_budgets):
        raise ValueError('browser WebRTC witness failed or incomplete')
    records = result.get('records')
    if not isinstance(records, list) or len(records) != 3:
        raise ValueError('WebRTC player-count inventory incomplete')
    for record, count in zip(records, (2, 4, 8)):
        if type(record.get('players')) is not int or record['players'] != count or len(record.get('peers', [])) != count:
            raise ValueError('WebRTC peer inventory incomplete')
        for index, peer in enumerate(record['peers']):
            witness = peer.get('result', {})
            rows = witness.get('records')
            if (witness.get('passed') is not True or type(witness.get('binary_receives')) is not int
                    or witness['binary_receives'] < 0 or (not mixed and witness['binary_receives'] != 0)):
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
            if mixed:
                validate_mixed_peer(row, rtc, index, count, default_budgets, physical_close)
                if row['mixed']['accepted_binary'] > witness['binary_receives']:
                    raise ValueError('addressed receipts exceed physical binary receipts')
                if not physical_close and index == 0 and row['mixed']['accepted_binary'] != 0:
                    raise ValueError('sender cannot receive its own broadcast relay output')
        if mixed and sum(peer['result']['records'][0]['mixed']['accepted_binary'] for peer in record['peers']) < 2:
            raise ValueError('addressed relay packets and overlapping delivery missing')
        if mixed: validate_overlap(record['peers'])
        if physical_close: validate_physical_close(record['peers'])
    return result

def validate_mixed_peer(row, rtc, index, count, default_budgets, physical_close):
    state = row.get('mixed', {})
    closed = [channel for channel in rtc['channels'] if channel.get('physicalCloseFrame') is not None] if physical_close else []
    work_budget = 8 if default_budgets else 32
    for key, expected in [('route_budget', 8), ('send_budget', work_budget), ('receive_budget', work_budget), ('caller_pending', 0), ('relay_peers', len(closed))]:
        if type(state.get(key)) is not int or state[key] != expected:
            raise ValueError('mixed transport budget or final ownership invalid')
    for key in ('maximum_pending', 'maximum_relay_pending', 'maximum_relay_received'):
        if type(state.get(key)) is not int or not 0 <= state[key] <= 128:
            raise ValueError('mixed owned queues exceeded their limits')
    if type(state.get('accepted_binary')) is not int or state['accepted_binary'] < 0:
        raise ValueError('addressed binary receipt count invalid')
    if type(state.get('overlap_packets')) is not int or state['overlap_packets'] != (1 if index == 0 else 0):
        raise ValueError('actual overlapping packet control missing')
    channels = [channel for channel in rtc['channels'] if channel['id'] == 3]
    if (rtc.get('captureError') is not False or type(rtc.get('maximumRelayBuffered')) is not int
            or not 0 <= rtc['maximumRelayBuffered'] <= 262144):
        raise ValueError('physical relay buffer or packet capture invalid')
    validate_payloads(state.get('relay_payloads'))
    if len(state['relay_payloads']) > state['accepted_binary']:
        raise ValueError('relay payload inventory exceeds addressed receipts')
    for channel in channels:
        validate_payloads(channel.get('earlySent'))
        validate_payloads(channel.get('earlyReceived'))
        if type(channel.get('maximumBuffered')) is not int or not 0 <= channel['maximumBuffered'] <= 262144:
            raise ValueError('physical direct buffer exceeded its limit')
    blocked = [channel for channel in channels if channel.get('blockedLink') is True]
    if len(blocked) != (1 if index == 0 else 0):
        raise ValueError('mixed fault must affect exactly one outgoing link')
    if index == 0 and not physical_close:
        if state.get('switched') is not True or state.get('restored') is not True:
            raise ValueError('fallback or direct restoration unobserved')
        if type(rtc.get('binarySent')) is not int or rtc['binarySent'] < 2:
            raise ValueError('physical binary relay sends missing')
        if (type(blocked[0].get('blockedReads')) is not int or blocked[0]['blockedReads'] < 1
                or type(blocked[0].get('mixedSent')) is not int or blocked[0]['mixedSent'] != 0):
            raise ValueError('direct send pressure did not block the selected link')
        if count > 2 and any(type(channel.get('mixedSent')) is not int or channel['mixedSent'] < 1 for channel in channels if not channel['blockedLink']):
            raise ValueError('healthy links lost direct service during fallback')
    for channel in channels:
        if physical_close and channel in closed: continue
        if type(channel.get('restoredSent')) is not int or channel['restoredSent'] < 1:
            raise ValueError('physical direct sends after restoration missing')

def validate_physical_close(peers):
    overlap = peers[0]['result']['records'][0]['mixed']['overlap']
    recipient = next(index for index, peer in enumerate(peers) if peer['result']['records'][0]['mixed']['uuid'] == overlap['recipient'])
    for index, peer in enumerate(peers):
        state, rtc = peer['result']['records'][0]['mixed'], peer['rtc']
        affected = index in (0, recipient)
        closed = [channel for channel in rtc['channels'] if channel.get('physicalCloseFrame') is not None]
        if len(closed) != int(affected) or state.get('switched') is not affected or state.get('restored') is not False:
            raise ValueError('physical outage must retain exactly the closed pair on relay')
        for channel in rtc['channels']:
            initiated = channel.get('closeInitiatedFrame')
            if channel in closed:
                frame = channel['physicalCloseFrame']
                if channel['id'] != 3 or type(frame) is not int or not (4 if index == 0 else 3) <= frame <= 8:
                    raise ValueError('physical unreliable channel did not close during active prediction')
                expected = 4 if index == 0 else None
                if initiated != expected or (expected is not None and type(initiated) is not int):
                    raise ValueError('physical close did not originate once at source frame four')
                if type(channel.get('restoredSent')) is not int or channel['restoredSent'] != 0:
                    raise ValueError('closed channel unexpectedly carried late gameplay')
                inventory = channel['earlySent'] if index == 0 else channel['earlyReceived']
                if overlap['payload'] not in inventory:
                    raise ValueError('closed pair does not match the correlated original input')
            elif initiated is not None:
                raise ValueError('unexpected physical close initiator')
            elif channel['id'] == 3 and (type(channel.get('mixedSent')) is not int or channel['mixedSent'] < 1):
                raise ValueError('healthy links lost physical direct service during outage')
        if affected and (type(rtc.get('binarySent')) is not int or rtc['binarySent'] < 2
                         or state['accepted_binary'] < 2):
            raise ValueError('closed pair did not continue bidirectional physical relay traffic')

def validate_payloads(values):
    if (not isinstance(values, list) or len(values) > 128 or any(not isinstance(value, str)
            or not 2 <= len(value) <= 2048 or len(value) % 2 or not re.fullmatch('[0-9a-f]+', value) for value in values)):
        raise ValueError('bounded physical packet inventory invalid')

def validate_overlap(peers):
    identities = [peer['result']['records'][0]['mixed'].get('uuid') for peer in peers]
    if (any(not isinstance(identity, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', identity)
            for identity in identities) or len(set(identities)) != len(peers)):
        raise ValueError('mixed physical peer identities invalid')
    source = peers[0]
    overlap = source['result']['records'][0]['mixed'].get('overlap', {})
    if not isinstance(overlap, dict) or overlap.get('recipient') not in identities[1:]:
        raise ValueError('overlap recipient missing from the remote roster')
    payload = overlap.get('payload')
    validate_payloads([payload])
    validate_overlap_input(bytes.fromhex(payload), len(peers), identities[0], sorted(identities).index(identities[0]))
    recipient = peers[identities.index(overlap['recipient'])]
    if (not any(payload in channel['earlySent'] for channel in source['rtc']['channels'] if channel['id'] == 3)
            or not any(payload in channel['earlyReceived'] for channel in recipient['rtc']['channels'] if channel['id'] == 3)
            or payload not in recipient['result']['records'][0]['mixed']['relay_payloads']):
        raise ValueError('the same overlap packet was not delivered by direct and relay')
    if any(peer['result']['records'][0]['mixed'].get('overlap') != {} for peer in peers[1:]):
        raise ValueError('unexpected overlap producer')

def validate_overlap_input(raw, count, sender, slot):
    size_offset = 57 + 7 * count
    if (len(raw) < size_offset + 5 or raw[:8] != b'FRGP\x01\x00\x03\x00'
            or int.from_bytes(raw[40:44], 'little') != len(raw) - 44
            or raw[8:24] != bytes([count]) * 16 or raw[24:32] != hashlib.sha256(sender.encode('ascii')).digest()[:8]
            or raw[32:40] != b'\x01\x00\x00\x00\x00\x00\x00\x00'):
        raise ValueError('overlap protocol header or identity invalid')
    start = int.from_bytes(raw[44:48], 'little', signed=True)
    ack = int.from_bytes(raw[48:52], 'little', signed=True)
    frames = int.from_bytes(raw[52:54], 'little')
    if (start < 0 or frames < 1 or start + frames > 3 or not -1 <= ack <= 39 or raw[54:57] != bytes([1, slot, count])
            or len(raw) != size_offset + 4 + frames or int.from_bytes(raw[size_offset:size_offset + 4], 'little') != frames):
        raise ValueError('overlap protocol input layout invalid')
    for index in range(count):
        status = raw[57 + 7 * index:64 + 7 * index]
        if status[0] != 0 or status[5:7] != b'\x00\x00' or not -1 <= int.from_bytes(status[1:5], 'little', signed=True) <= 39:
            raise ValueError('overlap protocol status invalid')
    expected = bytes((frame * 17 + slot * 31 + 1) & 255 for frame in range(start, start + frames))
    if raw[size_offset + 4:] != expected:
        raise ValueError('overlap original input bytes changed')

def validate_disabled_control(returncode, output):
    failures = []
    for line in output.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and 'failure' in value: failures.append(value)
    if type(returncode) is not int or returncode == 0 or len(failures) != 1:
        raise ValueError('disabled fallback control did not fail once')
    failure = failures[0]
    diagnostic = failure.get('failure', '')
    if (not isinstance(diagnostic, str) or not (diagnostic.startswith('Error: page evaluation exceeded active progress deadline ')
            or re.match(r'Error: peer [01] gameplay stalled ', diagnostic))
            or failure.get('errors') != [] or failure.get('records') != []):
        raise ValueError('disabled fallback failed outside the gameplay watchdog')
    rooms = failure.get('failed_rooms')
    if not isinstance(rooms, list) or len(rooms) != 1 or rooms[0].get('players') != 2 or len(rooms[0].get('peers', [])) != 2:
        raise ValueError('disabled fallback room diagnostics missing')
    for index, peer in enumerate(rooms[0]['peers']):
        if peer.get('index') != index or not isinstance(peer.get('frame'), str) or not peer['frame'].isdigit() or not 4 <= int(peer['frame']) < 16:
            raise ValueError('disabled fallback did not stall in the pressure interval')
    prefix = re.match(r'Error: (?:page evaluation exceeded active progress deadline|peer [01] gameplay stalled) ', diagnostic).group()
    expired_peer = re.match(r'Error: peer ([01]) gameplay stalled ', diagnostic)
    validate_gameplay_diagnostic(diagnostic[len(prefix):], rooms[0]['peers'], int(expired_peer[1]) if expired_peer else None)
    channels = rooms[0]['peers'][0].get('rtc', {}).get('channels', [])
    if not any(channel.get('id') == 3 and type(channel.get('blocked_reads')) is int and channel['blocked_reads'] > 0
               and channel.get('buffered_amount') == 262144 for channel in channels):
        raise ValueError('disabled fallback channel pressure was not observed')
    return failure

def validate_gameplay_diagnostic(text, captured, expired_peer=None):
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError('watchdog diagnostic is not JSON') from error
    numeric = lambda item: type(item) in (int, float) and math.isfinite(item) and item >= 0
    if (not isinstance(value, dict) or any(not numeric(value.get(field)) for field in ('elapsed_ms', 'deadline_ms', 'round_started_ms'))
            or value['elapsed_ms'] < value['deadline_ms'] or value['round_started_ms'] > value['elapsed_ms']
            or any(not isinstance(value.get(field), list) or len(value[field]) != 2
                   for field in ('peers', 'last_samples', 'evaluations', 'attempts'))):
        raise ValueError('watchdog diagnostic timing or peer inventory invalid')
    elapsed = value['elapsed_ms']
    def valid_sample(sample):
        if (not isinstance(sample, dict) or type(sample.get('frame')) is not int or not -1 <= sample['frame'] <= 39
                or type(sample.get('done')) is not bool or not numeric(sample.get('elapsed_ms')) or sample['elapsed_ms'] > elapsed
                or 'progress' not in sample):
            return False
        progress = sample['progress']
        if progress is None: return True
        return (isinstance(progress, dict) and all(isinstance(progress.get(field), list) and len(progress[field]) == 1
                for field in ('received', 'acked')) and type(progress.get('confirmed')) is int
                and all(type(item) is int and -1 <= item <= 39 for item in [progress['confirmed'], *progress['received'], *progress['acked']]))
    pending = []
    unaccepted = []
    for index, peer in enumerate(value['peers']):
        sample, current, attempt = (value[field][index] for field in ('last_samples', 'evaluations', 'attempts'))
        if (not isinstance(peer, dict) or type(peer.get('frame')) is not int or peer['frame'] != int(captured[index]['frame'])
                or peer.get('done') is not False or peer.get('final_ms', False) is not None or peer.get('frontier', False) is not None
                or not numeric(peer.get('changed_ms')) or not valid_sample(sample) or sample['frame'] != peer['frame']
                or sample['done'] is not False or not peer['changed_ms'] <= sample['elapsed_ms'] < min(240000, peer['changed_ms'] + 20000)):
            raise ValueError('watchdog diagnostic is not the captured gameplay stall')
        if (not isinstance(attempt, dict) or not numeric(attempt.get('started_ms')) or attempt['started_ms'] > elapsed
                or 'completed_ms' not in attempt):
            raise ValueError('watchdog diagnostic attempt timing invalid')
        started, completed = attempt['started_ms'], attempt['completed_ms']
        if completed is None:
            if current is not None or sample['elapsed_ms'] > started:
                raise ValueError('watchdog diagnostic pending evaluation invalid')
            pending.append(started)
        else:
            if (not numeric(completed) or not started <= completed <= elapsed or not valid_sample(current)
                    or current['elapsed_ms'] != completed or sample['elapsed_ms'] > completed
                    or current['frame'] < sample['frame']):
                raise ValueError('watchdog diagnostic completed evaluation invalid')
            if current != sample:
                if (completed < min(240000, peer['changed_ms'] + 20000) or completed != elapsed
                        or sample['elapsed_ms'] > started):
                    raise ValueError('watchdog diagnostic unaccepted evaluation timing invalid')
                unaccepted.append(index)
    if ((pending and value['round_started_ms'] != min(pending))
            or (not pending and value['round_started_ms'] != elapsed)):
        raise ValueError('watchdog diagnostic round start invalid')
    if expired_peer is None:
        if unaccepted:
            raise ValueError('watchdog diagnostic timer followed a rejected sample')
    elif unaccepted != [expired_peer] or elapsed >= 240000:
        raise ValueError('watchdog diagnostic named peer did not alone expire before the absolute deadline')
    expected_deadline = min(240000, min(peer['changed_ms'] for peer in value['peers']) + 20000)
    if abs(value['deadline_ms'] - expected_deadline) > 0.001:
        raise ValueError('watchdog diagnostic did not reach the gameplay inactivity deadline')
    return value

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
    parser.add_argument('--online-example', action='store_true', help='export and drive the shipped two-player online example')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / ('online-example.json' if args.online_example else 'signalfish-webrtc.json')
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
                       'faults-events', 'corrupt-events', 'default', 'default-events', 'mixed', 'mixed-events',
                       'mixed-default', 'mixed-default-events', 'mixed-disabled', 'mixed-disabled-events', 'mixed-close', 'mixed-close-events')]
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
               'mixed': ROOT / 'scripts/reference/browser/webrtc_mixed.gd',
               'browser_launcher': ROOT / 'scripts/reference/browser/webrtc.cjs',
               'watchdog': ROOT / 'scripts/reference/browser/webrtc_watchdog.cjs', 'browser_runner': ROOT / 'scripts/reference/browser/webrtc_runner.py',
               'server_owner': ROOT / 'scripts/reference/browser/owned_server.py',
               'instrument_test': ROOT / 'scripts/reference/browser/webrtc_instrument.test.cjs',
               'watchdog_test': ROOT / 'scripts/reference/browser/webrtc_watchdog.test.cjs', 'node': Path(shutil.which('node')),
               'browser_lock': ROOT / 'scripts/reference/browser/package-lock.json', 'openssl': Path(shutil.which('openssl'))}
    if args.online_example:
        sources.update(online_example=ROOT / 'examples/online', offline_example=ROOT / 'examples/offline',
                       online_launcher=ROOT / 'scripts/reference/online_example_probe.py',
                       online_browser=ROOT / 'scripts/reference/browser/online.cjs',
                       online_bridge=ROOT / 'scripts/reference/browser/online_bridge.gd')
        online_labels = ('online', 'online-corrupt', 'online-events', 'online-corrupt-events')
        owned_logs.extend(f'{version}-{label}.log' for version in versions for label in online_labels)
        owned_logs.extend(f'{version}-online.png' for version in versions)
        for version in versions:
            (args.output / f'{version}-online.png').unlink(missing_ok=True)
            for label in online_labels:
                (args.output / f'{version}-{label}.log').unlink(missing_ok=True)
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
    run([str(sources['node']), '--test', str(sources['instrument_test']), str(sources['watchdog_test'])], environment, args.output / 'instrument-controls.log')
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
            with OwnedServer(sources['server'], server_environment, port, log) as server:
                if args.online_example:
                    environment['FORTRESS_SERVER_CONTROL'] = server.url
                for version, engine in engines.items():
                    if args.online_example:
                        from online_example_probe import run_online
                        record, executed_record = run_online(root, version, engine, sdk, sources, environment,
                                                             args.output, certificate, tls_private_key, port, server)
                        records.append(record)
                        executed_records.append(executed_record)
                        continue
                    project = root / version
                    project.mkdir()
                    shutil.copytree(sources['addon'], project / 'addons/fortress_rollback')
                    shutil.copytree(sdk / 'addons/signal_fish', project / 'addons/signal_fish')
                    for key, filename in [('host', 'host.gd'), ('game', 'webrtc_game.gd'), ('setup', 'webrtc_setup.gd'),
                                          ('mixed', 'webrtc_mixed.gd'), ('clock_test', 'clock_test.gd'), ('clock_fixture', 'clock_fixture.gd')]:
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
                                'mixed': project / 'webrtc_mixed.gd',
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
                    for label in ('clean', 'faults', 'corrupt', 'default', 'mixed', 'mixed-default', 'mixed-disabled', 'mixed-close'):
                        faults = label == 'faults'
                        browser_command = [str(sources['node']), str(sources['browser_launcher']), str(export),
                                           f'ws://127.0.0.1:{port}/v3/ws', label, str(args.output / f'{version}-{label}-events.log')]
                        if label == 'mixed-disabled':
                            code, output = capture(browser_command, environment, args.output / f'{version}-{label}.log', timeout=540)
                            result = validate_disabled_control(code, output)
                        else:
                            output = run_browser(browser_command, environment, args.output / f'{version}-{label}.log', rooms=1 if label in ('corrupt', 'default') else 3)
                            result = (validate_restore_control(json.loads(output), label) if label in ('corrupt', 'default')
                                      else validate_browser(json.loads(output), faults, mixed=label.startswith('mixed'),
                                                            default_budgets=label == 'mixed-default', physical_close=label == 'mixed-close'))
                        records.append({'engine': actual, 'faults': faults, 'control': label if label in ('corrupt', 'default', 'mixed-disabled') else None,
                                        'command': browser_command, 'result': result})
                    if inventory(executed) != frozen or inventory({'export': export}) != export_before:
                        raise ValueError('executed Web sources changed')
                    executed_records.append({'engine': actual, 'source_inventory': frozen, 'export_inventory': export_before})
                server.verify_live()
                server_events = list(server.events)
    if native_inventory(sources) != before or source_inventory(args.server_source) != server_before:
        raise ValueError('source or tool inventory changed during execution')
    report = {'passed': True, 'sdk_revision': sdk_pin['revision'], 'server_revision': server_pin['revision'],
              'input_inventory': before, 'server_source_inventory': server_before, 'executed': executed_records,
              'server_config': config, 'server_events': server_events, 'records': records,
              'log_sha256': {name: digest(args.output / name) for name in owned_logs if (args.output / name).exists()},
              'limits': 'Real release Web exports in two independent Chromium processes; local host ICE, 2/4/8 peers, '
                        '40 submitted frames per peer and 38 corrected original-input canonical prefixes per peer. '
                        'All successful browser data channels and peer connections close at teardown. Snapshot restore corruption fails '
                        'at the gameplay canonical prefix comparison. Mixed runs exercise actual relay bytes and direct restoration under '
                        'synthetic single-link send pressure, with default and selected work budgets and correlated overlapping input bytes. '
                        'A real unreliable channel closes at frame four; both ends retain relay through final confirmation while healthy links remain direct. '
                        'Disabled fallback fails the gameplay watchdog. Send drops/delays and pressure are synthetic; no WAN/NAT/TURN, '
                        'native WebRTC, other browsers, channel replacement, ICE recovery, relay congestion or reconnect/replan claim.'}
    if args.online_example:
        report['limits'] = ('Actual shipped online scene in two independent Chromium processes on each selected pinned engine; '
                            'physical keyboard movement, sender-owned original input histories, corrected canonical prefixes, '
                            'actual rollback, suspension/expiry and pre-Leave RTC/WebSocket closure. Both signaling socket pairs '
                            'are cut during gameplay. The owned server then exits with SIGKILL and restarts on the same endpoint; '
                            'a fifth room establishes a new identity and corrected gameplay after delayed old-room inputs. '
                            'Local ICE and injected input delivery delay/send pressure; no WAN/NAT/TURN, other browser, transparent reconnect '
                            'or ICE restoration claim.')
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'results': str(receipt), 'engines': versions, 'runs': len(records)}))

if __name__ == '__main__':
    main()
