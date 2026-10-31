"""Independent asymmetric remote recording history and recovery-only export witness."""
import json
import copy
import tempfile
from pathlib import Path

from replay_launch import advance, compare, expected as playback_expected, state_bytes
from replay_remote import sample


def expected(rust, neutral=False, terminal=False):
    rounds = 257
    rows = [[sample(slot, frame, neutral) for slot in range(2)] for frame in range(rounds)]
    initial = (0, 0xffffffff, 0xffffffff, 0)
    canonical = [initial]
    for row in rows:
        canonical.append(advance(canonical[-1], row))
    peers, recovery = [], []
    for peer, period in enumerate((2, 3)):
        state, records, services, first_saved = initial, [], [], {}
        received, repaired = -1, -1

        def save():
            first_saved.setdefault(state[0], state_bytes(state).hex())
            records.append(dict(kind='save', frame=state[0], bytes=state_bytes(state).hex(), inputs=[]))

        def simulate(frame):
            nonlocal state
            applied = [dict(value=rows[frame][slot] if slot == peer or frame <= received else
                            (sample(slot, received, neutral) if received >= 0 else 0),
                            status='confirmed' if slot == peer or frame <= received else 'predicted') for slot in range(2)]
            state = advance(state, [value['value'] for value in applied])
            records.append(dict(kind='advance', frame=frame, bytes=state_bytes(state).hex(), inputs=applied))

        def repair(current, final=False):
            nonlocal state, repaired
            if received <= repaired or neutral:
                return
            state = canonical[repaired + 1]
            records.append(dict(kind='load', frame=repaired + 1, bytes=state_bytes(state).hex(), inputs=[]))
            for frame in range(repaired + 1, current):
                simulate(frame)
                if frame + 1 < current or final:
                    save()
            repaired = received

        for turn in range(rounds):
            first = len(records)
            repair(turn)
            if rust and turn == 0:
                save()
            save()
            simulate(turn)
            services.append(dict(round=turn, before=turn, after=turn + 1, requests=[row['kind'] for row in records[first:]]))
            if turn % period == period - 1:
                received = turn
        exported = received + 1
        if not rust:
            first = len(records)
            count = rounds - received - 1
            received = rounds - 1
            repair(rounds, True)
            recovery.append(dict(peer=peer, rows=count, before=rounds, after=rounds,
                                 requests=[row['kind'] for row in records[first:]]))
            exported = rounds
        checksums = [first_saved[frame] if rust else state_bytes(canonical[frame]).hex() for frame in range(exported)]
        playback = playback_expected(dict(name=f'remote-{peer}', players=2, seed=0xffffffff, validate=True,
                                          frames=rows[:exported], checksums=checksums), rust)
        if terminal:
            save()
            playback = playback_expected(dict(name=f'remote-{peer}', players=2, seed=0xffffffff, validate=True,
                                              frames=rows, checksums=checksums), False, version=6)
            playback['name'] = f'remote-{peer}'
        peers.append(dict(peer=peer, current_frame=rounds, bytes=state_bytes(state).hex(), records=records,
                          services=services, frames=copy.deepcopy(rows[:exported]), checksums=checksums, skipped=0, playback=playback))
        if terminal:
            peers[-1]['terminal_checksum'] = state_bytes(canonical[-1]).hex()
    deliveries = []
    if rust:
        # Each forward call emits one INPUT. Each received INPUT emits one ACK;
        # checksum reports are one-way and become eligible at the next 60-frame boundary.
        pending = [[0, 0], [0, 0]]  # Destination -> [INPUT, control].
        for turn in range(rounds):
            for peer in range(2):
                pending[1 - peer][0] += 1
                if turn >= 63 + peer and (turn - 63 - peer) % 60 == 0:
                    pending[1 - peer][1] += 1
            eligible = [turn % period == period - 1 for period in (2, 3)]
            if not any(eligible):
                continue
            count = 0
            for _ in range(4):
                # The actual socket pass drains sender zero before sender one.
                for peer in (1, 0):
                    if eligible[peer]:
                        inputs, controls = pending[peer]
                        pending[peer] = [0, 0]
                        count += inputs + controls
                        pending[1 - peer][1] += inputs
            deliveries.append(dict(round=turn, messages=count, eligible=eligible))
        count = sum(sum(group) for group in pending) + sum(group[0] for group in pending)
        recovery = [dict(messages=count, frames=[rounds, rounds], errors=[
            "Invalid Request: missing local input for one or more players"] * 2,
            frontiers=[dict(peer=peer, current_before=rounds, current_frame=rounds, confirmed_frame=rounds - 1, receipt_frame=rounds - 1,
                            last_inputs=rows[-1], callback_count=len(peers[peer]['records'])) for peer in range(2)])]
    else:
        deliveries = [dict(round=turn, peer=peer, rows=period) for turn in range(rounds)
                      for peer, period in enumerate((2, 3)) if turn % period == period - 1]
    return dict(format=1, peers=peers, deliveries=deliveries, recovery=recovery)


def validate(actual, rust, neutral=False):
    compare(actual, expected(rust, neutral), 'asymmetric.' + ('rust' if rust else 'godot'))
    compare(len(actual['peers']), 2, 'asymmetric.required_peers')
    for peer in actual['peers']:
        compare(peer['current_frame'], 257, 'asymmetric.required_boundary')
        compare(len(peer['services']), 257, 'asymmetric.required_services')
        compare(len(peer['frames']), (256 if peer['peer'] == 0 else 255) if rust else 257, 'asymmetric.required_export')
    if not neutral:
        for peer, period in zip(actual['peers'], (2, 3)):
            loads = [row['frame'] for row in peer['records'] if row['kind'] == 'load']
            compare(loads, list(range(0, 257 - 257 % period, period)) + ([] if rust else [256 if period == 2 else 255]),
                    'asymmetric.required_loads')


def controls(observed):
    names = []
    for runtime in ('rust', 'godot'):
        for fault in ('symmetric-label', 'omitted-load', 'late-receipt', 'post-wrap-export', 'decoded-playback'):
            changed = copy.deepcopy(observed[runtime])
            peer = changed['peers'][1]
            if fault == 'symmetric-label':
                changed['peers'][1] = copy.deepcopy(changed['peers'][0])
                changed['peers'][1]['peer'] = 1
                field = 'peers[1].'
            elif fault == 'omitted-load':
                peer['records'] = [row for row in peer['records'] if not (row['kind'] == 'load' and row['frame'] == 129)]
                field = 'peers[1].records:'
            elif fault == 'late-receipt':
                changed['recovery'][0]['messages' if runtime == 'rust' else 'rows'] -= 1
                field = 'recovery[0].' + ('messages' if runtime == 'rust' else 'rows') + ':'
            elif fault == 'post-wrap-export':
                peer['frames'][129][0] ^= 1
                field = 'peers[1].frames[129][0]:'
            else:
                index = next(i for i, row in enumerate(peer['playback']['records']) if row['kind'] == 'advance' and row['frame'] == 129)
                peer['playback']['records'][index]['bytes'] = '00' * 16
                field = f'peers[1].playback.records[{index}].bytes:'
            try:
                validate(changed, runtime == 'rust')
            except ValueError as error:
                if not str(error).startswith(f'asymmetric.{runtime}.{field}'):
                    raise ValueError(f'{fault}: wrong asymmetric rejection: {error}') from error
            else:
                raise ValueError(f'{runtime}-{fault}: asymmetric mutation accepted')
            names.append(f'{runtime}-{fault}')
    return names


def observe(binary, engine, root, output, execute):
    combined = {}
    manual_api = {}
    for neutral in (False, True):
        mode = '--remote-recording-asymmetric' + ('-neutral' if neutral else '')
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
                        raise ValueError('invalid asymmetric recording completion')
                    stdout = lines[0]
                elif stderr.strip():
                    raise ValueError('unexpected asymmetric source stderr')
                observed[runtime] = json.loads(stdout)
                validate(observed[runtime], runtime == 'rust', neutral)
            repeats.append(observed)
        compare(repeats[0], repeats[1], 'asymmetric.repeat')
        combined['neutral' if neutral else 'corrected'] = repeats[0]
        from replay_api_parity import observe as observe_api
        manual_api['neutral' if neutral else 'corrected'] = observe_api(
            engine, root, output, execute, expected(False, neutral), mode)
    refused = []
    for runtime in ('rust', 'godot'):
        mode = '--remote-recording-asymmetric-withhold'
        command = [str(binary), mode] if runtime == 'rust' else [str(engine), '--headless', '--path', str(root),
            '--script', 'res://tests/oracle/replay_remote_trace.gd', '--', mode]
        log = output / f'asymmetric-withheld-{runtime}.log'
        try:
            execute(command, log)
        except ValueError:
            text = log.read_text()
            if 'asymmetric prediction-window stall: peer=1 round=4 frames=[5,4]' not in text or 'FORTRESS_REPLAY_RESULT ' in text:
                raise ValueError(f'{runtime}: wrong asymmetric withheld-receipt control')
            refused.append(runtime + '-asymmetric-withheld-receipts')
        else:
            raise ValueError(f'{runtime}: asymmetric missing receipts did not stop gameplay')
    from replay_corruption import observe as observe_corruption
    serialized = observe_corruption(engine, root, output, execute, combined['corrected']['godot'])
    from replay_recovery import observe as observe_recovery
    recovery = observe_recovery(binary, output, execute, combined)
    return dict(source_final_receipts=recovery, repeat_equal=True, observations=combined, manual_api=manual_api, negative_controls=controls(combined['corrected']),
                standalone_rejections=refused, serialized_controls=serialized, terminal=observe_terminal(engine, root, output, execute))


def observe_terminal(engine, root, output, execute, pressure=False):
    """Recovered complete histories require an actual final SAVE and decoded terminal validation."""
    combined = {}
    manual_api = {}
    for neutral in (False, True):
        mode = '--remote-recording-' + ('pressure' if pressure else 'asymmetric') + '-terminal' + ('-neutral' if neutral else '')
        observations = []
        for repeat in (1, 2):
            stdout, stderr = execute([str(engine), '--headless', '--path', str(root), '--script',
                                      'res://tests/oracle/replay_remote_trace.gd', '--', mode],
                                     output / f'{mode[2:]}-godot-{repeat}.log')
            lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines()
                     if line.startswith('FORTRESS_REPLAY_RESULT ')]
            if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                raise ValueError('invalid asymmetric terminal completion')
            actual = json.loads(lines[0])
            validate_terminal(actual, neutral, pressure)
            observations.append(actual)
        compare(observations[0], observations[1], 'asymmetric.terminal.repeat')
        combined['neutral' if neutral else 'corrected'] = observations[0]
        from replay_api_parity import observe as observe_api
        from replay_pressure import expected as pressure_expected
        wanted = (pressure_expected if pressure else expected)(False, neutral, terminal=True)
        manual_api['neutral' if neutral else 'corrected'] = observe_api(
            engine, root, output, execute, wanted, mode, terminal=True)
    from replay_corruption import observe as observe_corruption
    serialized = observe_corruption(engine, root, output, execute, combined['corrected'], terminal=True, pressure=pressure)
    bypassed = terminal_capture_controls(engine, root, output, execute, pressure)
    return dict(repeat_equal=True, observations=combined, manual_api=manual_api, serialized_controls=serialized, capture_controls=bypassed)


def validate_terminal(actual, neutral=False, pressure=False):
    from replay_pressure import expected as pressure_expected
    wanted = (pressure_expected if pressure else expected)(False, neutral, terminal=True)
    for peer in (0, 1):
        compare(actual['peers'][peer]['terminal_checksum'], wanted['peers'][peer]['terminal_checksum'],
                f'asymmetric.terminal.peers[{peer}].terminal_checksum')
    compare(actual, wanted, 'asymmetric.terminal')


def terminal_capture_controls(engine, root, output, execute, pressure=False):
    from replay_pressure import expected as pressure_expected
    expectation = pressure_expected if pressure else expected
    mode = '--remote-recording-' + ('pressure' if pressure else 'asymmetric') + '-terminal'
    original = (root / 'tests/oracle/replay_remote_trace.gd').read_text()
    needle = 'if terminal and drivers[peer].capture_replay_boundary().code != Types.Code.OK:'
    if original.count(needle) != 1:
        raise ValueError('terminal capture boundary missing or ambiguous')
    names = []
    scratch_root = root / '.cache/scratch'
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='replay-terminal-capture-', dir=scratch_root) as directory:
        for peer in (0, 1):
            script = Path(directory) / f'peer-{peer}.gd'
            script.write_text(original.replace(needle, needle.replace('terminal and', f'terminal and peer != {peer} and')))
            stdout, stderr = execute([str(engine), '--headless', '--path', str(root), '--script',
                                      'res://' + script.relative_to(root).as_posix(), '--', mode],
                                     output / f'{mode[2:]}-skipped-{peer}-godot.log')
            lines = [line.removeprefix('FORTRESS_REPLAY_RESULT ') for line in stdout.splitlines()
                     if line.startswith('FORTRESS_REPLAY_RESULT ')]
            if len(lines) != 1 or any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                raise ValueError('invalid skipped terminal capture completion')
            actual = json.loads(lines[0])
            wanted = expectation(False, terminal=True)
            wanted['peers'][peer] = expectation(False)['peers'][peer]
            wanted['peers'][peer]['terminal_checksum'] = ''
            compare(actual, wanted, 'asymmetric.capture_bypass')
            try:
                validate_terminal(actual, pressure=pressure)
            except ValueError as error:
                if not str(error).startswith(f'asymmetric.terminal.peers[{peer}].terminal_checksum:'):
                    raise ValueError(f'wrong skipped terminal capture rejection: {error}') from error
            else:
                raise ValueError('skipped terminal capture accepted')
            names.append(f'godot-skipped-terminal-capture-{peer}')
    return names
