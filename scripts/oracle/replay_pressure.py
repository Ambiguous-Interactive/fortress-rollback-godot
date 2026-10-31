"""Independent stalled/resumed asymmetric recording history across default queue reuse."""
import copy
import json

from replay_launch import advance, compare, expected as playback_expected, state_bytes
from replay_remote import sample


def expected(rust, neutral=False, terminal=False):
    rounds = 257
    rows = [[sample(slot, frame, neutral) for slot in range(2)] for frame in range(rounds)]
    initial = (0, 0xffffffff, 0xffffffff, 0)
    canonical = [initial]
    for row in rows:
        canonical.append(advance(canonical[-1], row))
    peers = [dict(state=initial, received=-1, repaired=-1, records=[], services=[], saved={}, checksums=[], confirmed=-1,
                  next_report=60, submitted=-1) for _ in range(2)]
    pending = [[0, 0], [0, 0]]
    deliveries = []

    def save(peer):
        state = peer['state']
        peer['saved'][state[0]] = state_bytes(state).hex()
        peer['records'].append(dict(kind='save', frame=state[0], bytes=state_bytes(state).hex(), inputs=[]))

    def simulate(peer, slot, frame):
        received = peer['received']
        applied = [dict(value=rows[frame][index] if index == slot or frame <= received else
                        (sample(index, received, neutral) if received >= 0 else 0),
                        status='confirmed' if index == slot or frame <= received else 'predicted') for index in range(2)]
        peer['state'] = advance(peer['state'], [value['value'] for value in applied])
        peer['records'].append(dict(kind='advance', frame=frame, bytes=state_bytes(peer['state']).hex(), inputs=applied))

    def repair(peer, slot, final=False):
        current, received, repaired = peer['state'][0], peer['received'], peer['repaired']
        if neutral or received <= repaired or repaired + 1 >= current:
            return
        peer['state'] = canonical[repaired + 1]
        peer['records'].append(dict(kind='load', frame=repaired + 1, bytes=state_bytes(peer['state']).hex(), inputs=[]))
        for frame in range(repaired + 1, current):
            simulate(peer, slot, frame)
            if frame + 1 < current or final:
                save(peer)
        peer['repaired'] = received

    for turn in range(400):
        if all(peer['state'][0] == rounds for peer in peers):
            break
        for slot, peer in enumerate(peers):
            before = peer['state'][0]
            if before == rounds:
                continue
            first = len(peer['records'])
            if rust:
                if peer['confirmed'] >= peer['next_report']:
                    pending[1 - slot][1] += 1
                    peer['next_report'] += 60
                confirmed = min(peer['submitted'], peer['received'])
                for frame in range(len(peer['checksums']), confirmed + 1):
                    peer['checksums'].append(peer['saved'][frame])
                peer['confirmed'] = confirmed
            repair(peer, slot)
            if rust and before == 0:
                save(peer)
            confirmed = min(before, peer['received']) if not rust else peer['confirmed']
            stalled = (before if confirmed == -1 else before - confirmed) >= 4
            if rust or not stalled:
                save(peer)
            if before > peer['submitted']:
                pending[1 - slot][0] += 1
                peer['submitted'] = before
            if not stalled:
                simulate(peer, slot, before)
            peer['services'].append(dict(round=turn, before=before, after=peer['state'][0],
                                         requests=[row['kind'] for row in peer['records'][first:]]))
        eligible = [turn % period == period - 1 for period in (2, 5)]
        if rust:
            if not any(eligible):
                continue
            count = 0
            for _ in range(4):
                for target in (1, 0):
                    if eligible[target]:
                        inputs, controls = pending[target]
                        pending[target] = [0, 0]
                        count += inputs + controls
                        pending[1 - target][1] += inputs
            deliveries.append(dict(round=turn, messages=count, eligible=eligible))
        else:
            for slot, period in enumerate((2, 5)):
                if eligible[slot]:
                    last = peers[1 - slot]['state'][0] - 1
                    deliveries.append(dict(round=turn, peer=slot, rows=last - peers[slot]['received']))
        for slot in range(2):
            if eligible[slot]:
                peers[slot]['received'] = peers[1 - slot]['submitted'] if rust else peers[1 - slot]['state'][0] - 1
    recovery = []
    if rust:
        count = sum(sum(group) for group in pending) + sum(group[0] for group in pending)
        recovery = [dict(messages=count, frames=[rounds, rounds], errors=[
            'Invalid Request: missing local input for one or more players'] * 2)]
    else:
        for slot, peer in enumerate(peers):
            first = len(peer['records'])
            count = rounds - peer['received'] - 1
            peer['received'] = rounds - 1
            repair(peer, slot, True)
            recovery.append(dict(peer=slot, rows=count, before=rounds, after=rounds,
                                 requests=[row['kind'] for row in peer['records'][first:]]))
    result = []
    for slot, peer in enumerate(peers):
        if terminal:
            save(peer)
        checksums = peer['checksums'] if rust else [state_bytes(state).hex() for state in canonical[:-1]]
        exported = rows[:len(checksums)]
        playback = playback_expected(dict(name=f'remote-{slot}', players=2, seed=0xffffffff, validate=True,
                                          frames=exported, checksums=checksums), rust, version=6 if terminal else 5)
        playback['name'] = f'remote-{slot}'
        result.append(dict(peer=slot, current_frame=rounds, bytes=state_bytes(peer['state']).hex(), records=peer['records'],
                           services=peer['services'], frames=copy.deepcopy(exported), checksums=checksums, skipped=0, playback=playback))
        if terminal:
            result[-1]['terminal_checksum'] = state_bytes(canonical[-1]).hex()
    return dict(format=1, peers=result, deliveries=deliveries, recovery=recovery)


def validate(actual, rust, neutral=False):
    compare(actual, expected(rust, neutral), 'pressure.' + ('rust' if rust else 'godot'))
    for slot, peer in enumerate(actual['peers']):
        services = peer['services']
        stalls = [service['round'] for service in services if service['before'] == service['after']]
        compare(len(services), 285 + slot, 'pressure.required_service_count')
        compare(len(stalls), 28 + slot, 'pressure.required_stall_count')
        compare(sum(service['after'] - service['before'] for service in services), 257, 'pressure.required_advances')
        if not neutral and not any(row['kind'] == 'load' and row['frame'] > 128 for row in peer['records']):
            raise ValueError('pressure: missing post-wrap correction')


def controls(observed):
    names = []
    for runtime in ('rust', 'godot'):
        for fault in ('omitted-stall', 'resampled-input', 'post-wrap-export', 'delivery-count'):
            changed = copy.deepcopy(observed[runtime])
            peer = changed['peers'][1]
            if fault == 'omitted-stall':
                peer['services'] = [service for service in peer['services'] if service['round'] != 4]
                field = 'peers[1].services:'
            elif fault == 'resampled-input':
                index = next(index for index, row in enumerate(peer['records']) if row['kind'] == 'advance' and row['frame'] == 4)
                peer['records'][index]['inputs'][1]['value'] ^= 1
                field = f'peers[1].records[{index}].inputs[1].value:'
            elif fault == 'post-wrap-export':
                peer['frames'][129][0] ^= 1
                field = 'peers[1].frames[129][0]:'
            else:
                changed['deliveries'][0]['messages' if runtime == 'rust' else 'rows'] += 1
                field = 'deliveries[0].' + ('messages' if runtime == 'rust' else 'rows') + ':'
            try:
                validate(changed, runtime == 'rust')
            except ValueError as error:
                if not str(error).startswith(f'pressure.{runtime}.{field}'):
                    raise ValueError(f'{fault}: wrong pressure rejection: {error}') from error
            else:
                raise ValueError(f'{runtime}-{fault}: pressure mutation accepted')
            names.append(f'{runtime}-{fault}')
    return names


def observe(binary, engine, root, output, execute):
    combined = {}
    manual_api = {}
    for neutral in (False, True):
        mode = '--remote-recording-pressure' + ('-neutral' if neutral else '')
        repeats = []
        for repeat in (1, 2):
            observed = {}
            for runtime in ('rust', 'godot'):
                command = [str(binary), mode] if runtime == 'rust' else [str(engine), '--headless', '--path', str(root),
                    '--script', 'res://tests/oracle/replay_remote_trace.gd', '--', mode]
                stdout, stderr = execute(command, output / f'{mode[2:]}-{runtime}-{repeat}.log')
                if runtime == 'godot':
                    lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines()
                             if line.startswith('FORTRESS_REPLAY_RESULT ')]
                    if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                        raise ValueError('invalid pressure recording completion')
                    stdout = lines[0]
                elif stderr.strip():
                    raise ValueError('unexpected pressure source stderr')
                observed[runtime] = json.loads(stdout)
                validate(observed[runtime], runtime == 'rust', neutral)
            repeats.append(observed)
        compare(repeats[0], repeats[1], 'pressure.repeat')
        combined['neutral' if neutral else 'corrected'] = repeats[0]
        from replay_api_parity import observe as observe_api
        manual_api['neutral' if neutral else 'corrected'] = observe_api(
            engine, root, output, execute, expected(False, neutral), mode)
    refused = []
    for runtime in ('rust', 'godot'):
        mode = '--remote-recording-pressure-withhold'
        command = [str(binary), mode] if runtime == 'rust' else [str(engine), '--headless', '--path', str(root),
            '--script', 'res://tests/oracle/replay_remote_trace.gd', '--', mode]
        log = output / f'pressure-withheld-{runtime}.log'
        try:
            execute(command, log)
        except ValueError:
            text = log.read_text()
            if 'pressure prediction-window stall: peer=1 turn=4 frames=[5,4]' not in text or 'FORTRESS_REPLAY_RESULT ' in text:
                raise ValueError(f'{runtime}: wrong pressure withheld-receipt control')
            refused.append(runtime + '-pressure-withheld-receipts')
        else:
            raise ValueError(f'{runtime}: pressure missing receipts did not stop gameplay')
    original = (root / 'tests/oracle/replay_remote_trace.gd').read_text()
    needle = '_sample(peer, round, neutral)'
    if original.count(needle) != 1:
        raise ValueError('pressure resampling control sample missing or ambiguous')
    scratch = output / 'pressure-resampled.gd'
    scratch.write_text(original.replace(needle, '_sample(peer, turn, neutral)'))
    log = output / 'pressure-resampled-godot.log'
    try:
        execute([str(engine), '--headless', '--path', str(root), '--script', str(scratch.resolve()),
                 '--', '--remote-recording-pressure'], log)
    except ValueError:
        text = log.read_text()
        if 'pressure retry failed: peer=1 turn=5 frame=4 code=10' not in text or 'FORTRESS_REPLAY_RESULT ' in text:
            raise ValueError('wrong pressure resampling rejection')
        refused.append('godot-pressure-resampled-input')
    else:
        raise ValueError('pressure resampling was accepted')
    from replay_asymmetric import observe_terminal
    return dict(repeat_equal=True, observations=combined, manual_api=manual_api, negative_controls=controls(combined['corrected']), standalone_rejections=refused,
                terminal=observe_terminal(engine, root, output, execute, pressure=True))
