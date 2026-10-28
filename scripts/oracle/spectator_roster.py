"""Compare changing 2–8-player spectator histories with actual pinned sessions."""
from copy import deepcopy
import json

from launch import ROOT, digest, execute
from replay_launch import compare
from spectator_startup import _delay_history, expected_rust, check_rust


def row(frame, players, swapped=False):
    values = [(frame * 17 + player * 31 + frame * player) % 256 for player in range(players)]
    if swapped:
        values[-2], values[-1] = values[-1], values[-2]
    return values


def expected_bundle(swapped=False):
    """Independent original inputs and complete receive/request schedule, not oracle output."""
    traces = []
    for players in range(2, 9):
        for preplay in (True, False):
            for capacity in (4, 5):
                for speed in (1, 2):
                    delay = 1 if preplay else capacity - 1
                    observations, services, cycles = _delay_history(
                        capacity, speed, delay, False, players, lambda frame: row(frame, players, swapped))
                    traces.append({'capacity': capacity, 'preplay': preplay, 'speed': speed, 'delay': delay,
                                   'players': players, 'observations': observations, 'service_observations': services,
                                   'cycles': cycles, 'transcript': [[frame, *row(frame, players, swapped)]
                                                                  for frame in range(12 - delay)]})
    return traces


def validate_bundle(traces, swapped=False):
    # The comparator checks exact container and scalar types, lengths, keys and every observation.
    compare(traces, expected_bundle(swapped), 'roster')
    return traces


def controls(observed, expected):
    compare(observed, expected)
    evidence = []
    for label, mutate, diagnostic in [
        ('missing-eight-player', lambda value: value['traces'].pop(), 'result.traces: count mismatch'),
        ('last-player-input', lambda value: value['traces'][48]['transcript'][0].__setitem__(8, 0),
         'result.traces[48].transcript[0][8]: value mismatch'),
        ('last-player-type', lambda value: value['traces'][48]['transcript'][0].__setitem__(8, 217.0),
         'result.traces[48].transcript[0][8]: type mismatch'),
    ]:
        mutant = deepcopy(observed)
        mutate(mutant)
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unexpected roster diagnostic: {error}') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: spectator roster mutation survived')
    return evidence


def check(engine, output):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(engine), '--headless', '--path', str(ROOT), '--script',
               'res://tests/oracle/spectator_trace.gd', '--', '--roster']

    def observe(arguments, label, swapped=False):
        stdout, stderr = execute(arguments, output / f'{label}.log', timeout=60)
        if any(item in stdout + stderr for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('spectator roster observer failed')
        lines = [line.removeprefix('FORTRESS_SPECTATOR_TRACE ') for line in stdout.splitlines()
                 if line.startswith('FORTRESS_SPECTATOR_TRACE ')]
        if len(lines) != 1:
            raise ValueError('spectator roster observer missing trace')
        return validate_bundle(json.loads(lines[0]), swapped)

    traces = [observe(command, f'godot-{repetition}') for repetition in range(2)]
    compare(traces[0], traces[1])
    (output / 'observed.json').write_text(json.dumps(traces[0], indent=2) + '\n')
    rust = check_rust(traces[0], output, delayed=True, roster=True)
    actual = json.loads((output / 'rust-observed.json').read_text())
    negative = rust['negative_controls']
    mutant = observe([*command, '--mutate-player'], 'godot-player-order', swapped=True)
    diagnostic = 'result.traces[0].transcript[0][1]: value mismatch'
    try:
        compare(actual, expected_rust(mutant))
    except ValueError as error:
        if not str(error).startswith(diagnostic):
            raise ValueError('executed player-order control failed for an unintended reason') from error
    else:
        raise ValueError('executed player-order mutation survived')
    return {'complete': True, 'workloads': len(traces[0]), 'players': list(range(2, 9)), 'repetitions': 2,
            'observations_sha256': digest(output / 'observed.json'), 'rust': rust, 'negative_controls': negative,
            'executed_player_order': {'rejected': True, 'diagnostic': diagnostic},
            'limitations': ['In-order fully confirmed rows only; no host loss, disconnected-status or live routing parity.']}
