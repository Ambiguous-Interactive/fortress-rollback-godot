"""Source-bound remote recording with real late corrections and an unchanged-input control."""
import copy
import json
import tempfile
from pathlib import Path

from replay_launch import advance, compare, expected as playback_expected, state_bytes


def sample(slot, frame, neutral=False):
    return 0 if neutral else (0xffffffff + frame * 1234567 + slot * 0x1020304) & 0xffffffff


def expected(rust, neutral=False, long=False):
    rounds = 257 if long else 9
    rows = [[sample(slot, frame, neutral) for slot in range(2)] for frame in range(rounds)]
    initial = (0, 0xffffffff, 0xffffffff, 0)
    canonical = [initial]
    for row in rows:
        canonical.append(advance(canonical[-1], row))
    peers = []
    for peer in range(2):
        state, records, services, first_saved = initial, [], [], {}

        def save():
            first_saved.setdefault(state[0], state_bytes(state).hex())
            records.append(dict(kind='save', frame=state[0], bytes=state_bytes(state).hex(), inputs=[]))

        def simulate(frame, corrected):
            nonlocal state
            high = 2 * (frame // 2) - 1
            applied = [dict(value=rows[frame][slot] if corrected or slot == peer else
                            (sample(slot, high, neutral) if high >= 0 else 0),
                            status='confirmed' if corrected or slot == peer else 'predicted') for slot in range(2)]
            state = advance(state, [value['value'] for value in applied])
            records.append(dict(kind='advance', frame=frame, bytes=state_bytes(state).hex(), inputs=applied))

        for turn in range(rounds):
            first = len(records)
            if turn >= 2 and turn % 2 == 0 and not neutral:
                state = canonical[turn - 2]
                records.append(dict(kind='load', frame=turn - 2, bytes=state_bytes(state).hex(), inputs=[]))
                simulate(turn - 2, True)
                save()
                simulate(turn - 1, True)
            if rust and turn == 0:
                save()
            save()
            simulate(turn, False)
            services.append(dict(round=turn, before=turn, after=turn + 1, requests=[row['kind'] for row in records[first:]]))
        # Source records newly confirmed rows before executing the correction's returned SAVE requests.
        checksums = [first_saved[frame] if rust else state_bytes(canonical[frame]).hex() for frame in range(rounds - 1)]
        playback = playback_expected(dict(name=f'remote-{peer}', players=2, seed=0xffffffff, validate=True,
                                          frames=rows[:-1], checksums=checksums), rust)
        peers.append(dict(peer=peer, current_frame=rounds, bytes=state_bytes(state).hex(), records=records,
                          services=services, frames=rows[:-1], checksums=checksums, skipped=0, playback=playback))
    # Default source desync detection sends one report per endpoint every 60 confirmed frames.
    # A boundary 60*k becomes eligible on turn 60*k+2 and is delivered on the next odd turn.
    deliveries = [dict(round=turn, **({'messages': 8 + (2 if turn >= 63 and turn % 60 == 3 else 0)} if rust else {'rows': 4}))
                  for turn in range(1, rounds, 2)]
    return dict(format=1, peers=peers, deliveries=deliveries)


def validate(actual, rust, neutral=False, long=False):
    compare(actual, expected(rust, neutral, long), 'remote.' + ('rust' if rust else 'godot'))
    # Keep the exercised correction boundary independent of the generated complete expectation.
    for peer in actual['peers']:
        if long:
            compare(peer['current_frame'], 257, 'remote.required_long_boundary')
            compare(len(peer['frames']), 256, 'remote.required_long_recording')
            compare(len(peer['services']), 257, 'remote.required_long_services')
        loads = [record['frame'] for record in peer['records'] if record['kind'] == 'load']
        compare(loads, [] if neutral else list(range(0, 256 if long else 8, 2)), 'remote.required_loads')
        if rust:
            compare([event['frame'] for event in peer['playback']['events']], [] if neutral else list(range(1, 256 if long else 8, 2)), 'remote.source_checksum_events')
        else:
            compare(peer['playback']['failure_frame'], -1, 'remote.godot_playback_healthy')


def controls(observed):
    names = []
    for runtime in ('rust', 'godot'):
        for fault in ('omitted-load', 'original-input', 'original-state', 'recorded-input', 'checksum', 'playback-state'):
            changed = copy.deepcopy(observed[runtime])
            peer = changed['peers'][0]
            field = 'records'
            if fault == 'omitted-load':
                peer['records'] = [row for row in peer['records'] if not (row['kind'] == 'load' and row['frame'] == 2)]
            elif fault in ('original-input', 'original-state'):
                index = next(i for i, row in enumerate(peer['records']) if row['kind'] == 'advance' and row['frame'] == 3)
                field = f'records[{index}]'
                if fault == 'original-input':
                    peer['records'][index]['inputs'][1]['value'] ^= 1
                else:
                    peer['records'][index]['bytes'] = '00' * 16
            elif fault == 'recorded-input':
                peer['frames'][3][1] ^= 1
                field = 'frames[3][1]'
            elif fault == 'checksum':
                peer['checksums'][3] = '00' * 16
                field = 'checksums[3]'
            else:
                peer['playback']['records'][5]['bytes'] = '00' * 16
                field = 'playback.records[5].bytes'
            try:
                validate(changed, runtime == 'rust')
            except ValueError as error:
                if not str(error).startswith(f'remote.{runtime}.peers[0].{field}'):
                    raise ValueError(f'{fault}: wrong remote rejection: {error}') from error
            else:
                raise ValueError(f'{runtime}-{fault}: remote mutation accepted')
            names.append(f'{runtime}-{fault}')
    return names


def long_controls(observed):
    """The second ring's original history, corrections, export and playback are independently required."""
    names = []
    for runtime in ('rust', 'godot'):
        for fault in ('post-wrap-load', 'post-wrap-input', 'post-wrap-export', 'post-wrap-playback', 'post-wrap-delivery'):
            changed = copy.deepcopy(observed[runtime])
            peer = changed['peers'][0]
            if fault == 'post-wrap-load':
                peer['records'] = [row for row in peer['records'] if not (row['kind'] == 'load' and row['frame'] == 128)]
                field = 'records'
            elif fault == 'post-wrap-input':
                index = next(i for i, row in enumerate(peer['records']) if row['kind'] == 'advance' and row['frame'] == 129)
                peer['records'][index]['inputs'][1]['value'] ^= 1
                field = f'records[{index}].inputs[1].value'
            elif fault == 'post-wrap-export':
                peer['frames'][129][1] ^= 1
                field = 'frames[129][1]'
            elif fault == 'post-wrap-playback':
                index = next(i for i, row in enumerate(peer['playback']['records']) if row['kind'] == 'advance' and row['frame'] == 129)
                peer['playback']['records'][index]['bytes'] = '00' * 16
                field = f'playback.records[{index}].bytes'
            else:
                key = 'messages' if runtime == 'rust' else 'rows'
                changed['deliveries'][91][key] += 1
                field = f'deliveries[91].{key}'
            if fault != 'post-wrap-delivery':
                field = 'peers[0].' + field
            try:
                validate(changed, runtime == 'rust', long=True)
            except ValueError as error:
                if not str(error).startswith(f'remote.{runtime}.{field}'):
                    raise ValueError(f'{fault}: wrong long remote rejection: {error}') from error
            else:
                raise ValueError(f'{runtime}-{fault}: long remote mutation accepted')
            names.append(f'{runtime}-{fault}')
    return names



def delivery_control(engine, root, output, execute):
    """Duplicate actual idempotent receipts without changing gameplay; the measured inventory must reject them."""
    original = (root / 'tests/oracle/replay_remote_trace.gd').read_text()
    loop = 'for frame: int in range(round - 1, round + 1):'
    if original.count(loop) != 1:
        raise ValueError('remote delivery control loop missing or ambiguous')
    scratch_root = root / '.cache/scratch'
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='replay-remote-delivery-', dir=scratch_root) as directory:
        scratch = Path(directory) / 'control.gd'
        scratch.write_text(original.replace(loop, 'for frame: int in [round - 1, round, round]:'))
        command = [str(engine), '--headless', '--path', str(root), '--script', 'res://' + scratch.relative_to(root).as_posix(),
                   '--', '--remote-recording-neutral']
        stdout, stderr = execute(command, output / 'remote-duplicate-delivery-godot.log')
        lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
        if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('invalid duplicate-delivery control completion')
        actual = json.loads(lines[0])
        wanted = expected(False, True)
        for delivery in wanted['deliveries']:
            delivery['rows'] = 6
        compare(actual, wanted, 'remote.duplicate.observed')
        try:
            validate(actual, False, True)
        except ValueError as error:
            if not str(error).startswith('remote.godot.deliveries[0].rows:'):
                raise ValueError(f'wrong duplicate-delivery rejection: {error}') from error
        else:
            raise ValueError('duplicate delivery observer accepted')
    return ['godot-measured-duplicate-delivery']


def observe(binary, engine, root, output, execute):
    combined = {}
    for neutral, long in ((False, False), (True, False), (False, True), (True, True)):
        mode = ('--remote-recording-neutral' if neutral else '--remote-recording') + ('-long' if long else '')
        rounds = []
        for repeat in (1, 2):
            result = {}
            for runtime in ('rust', 'godot'):
                command = [str(binary), mode] if runtime == 'rust' else [str(engine), '--headless', '--path', str(root),
                    '--script', 'res://tests/oracle/replay_remote_trace.gd', '--', mode]
                stdout, stderr = execute(command, output / f'{mode[2:]}-{runtime}-{repeat}.log')
                if runtime == 'godot':
                    lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines() if line.startswith('FORTRESS_REPLAY_RESULT ')]
                    if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                        raise ValueError('invalid remote recording completion')
                    stdout = lines[0]
                elif stderr.strip():
                    raise ValueError('unexpected remote source stderr')
                result[runtime] = json.loads(stdout)
                validate(result[runtime], runtime == 'rust', neutral, long)
            rounds.append(result)
        compare(rounds[0], rounds[1], 'remote.repeat')
        combined[('neutral' if neutral else 'corrected') + ('_long' if long else '')] = rounds[0]
    refused = []
    for runtime in ('rust', 'godot'):
        command = [str(binary), '--remote-recording-withhold'] if runtime == 'rust' else [str(engine), '--headless', '--path', str(root),
            '--script', 'res://tests/oracle/replay_remote_trace.gd', '--', '--remote-recording-withhold']
        log = output / f'remote-withheld-{runtime}.log'
        try:
            execute(command, log)
        except ValueError:
            text = log.read_text()
            diagnostic = ('remote prediction-window stall: round=4 before=4 after=4 stall_count=1' if runtime == 'rust' else
                          'remote prediction-window stall: round=4 code=PREDICTION_STALL(3) frame=4')
            if diagnostic not in text or 'FORTRESS_REPLAY_RESULT ' in text:
                raise ValueError(f'{runtime}: wrong withheld-receipt control')
            refused.append(runtime + '-withheld-receipts')
        else:
            raise ValueError(f'{runtime}: missing remote receipts did not stop gameplay')
    return dict(repeat_equal=True, observations=combined,
                negative_controls=controls(combined['corrected']) + long_controls(combined['corrected_long']), standalone_rejections=refused,
                delivery_controls=delivery_control(engine, root, output, execute))
