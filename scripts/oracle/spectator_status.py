"""Compare real reserved-slot spectator inputs/statuses with production Godot playback."""
from copy import deepcopy
import json

from launch import ROOT, digest, execute
from replay_launch import compare
from spectator_roster import row
from spectator_startup import _delay_history, expected_rust, check_rust


def original_row(frame, players):
    values = row(frame, players)
    # The pinned builder freezes a reserved slot at the u8 input's default value.
    values[-1] = 0
    return values


def expected_bundle(mutate_status=False):
    traces = []
    for players in range(2, 9):
        for preplay in (True, False):
            for capacity in (4, 5):
                for speed in (1, 2):
                    delay = 1 if preplay else capacity - 1
                    observations, services, cycles = _delay_history(
                        capacity, speed, delay, False, players, lambda frame: original_row(frame, players))
                    # The real source host's prediction-enabled startup first exposes two rows together.
                    observations[1] = deepcopy(observations[0])
                    services[1] = deepcopy(services[0])
                    state, transcript = 0, []
                    for frame in range(12 - delay):
                        record = [frame]
                        for player, value in enumerate(original_row(frame, players)):
                            status = 3 if player == players - 1 and not mutate_status else 1
                            state = (state * 17 + value + status * 31 + frame) % 1000000007
                            record.extend((value, status))
                        transcript.append([*record, state])
                    traces.append({'capacity': capacity, 'preplay': preplay, 'speed': speed, 'delay': delay,
                                   'players': players, 'observations': observations, 'service_observations': services,
                                   'cycles': cycles, 'transcript': transcript})
    return traces


def controls(observed, expected):
    compare(observed, expected)
    evidence = []
    for label, mutate, diagnostic in [
        ('lost-disconnected-status', lambda value: value['traces'][0]['transcript'][0].__setitem__(4, 1),
         'result.traces[0].transcript[0][4]: value mismatch'),
        ('wrong-frozen-input', lambda value: value['traces'][0]['transcript'][0].__setitem__(3, 31),
         'result.traces[0].transcript[0][3]: value mismatch'),
        ('wrong-canonical-boundary', lambda value: value['traces'][0]['transcript'][1].__setitem__(-1, 0),
         'result.traces[0].transcript[1][5]: value mismatch'),
    ]:
        mutant = deepcopy(observed)
        mutate(mutant)
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unintended status diagnostic: {error}') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: spectator status mutation survived')
    return evidence


def check(engine, output):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(engine), '--headless', '--path', str(ROOT), '--script',
               'res://tests/oracle/spectator_trace.gd', '--', '--statuses']

    def observe(arguments, label, mutate_status=False):
        stdout, stderr = execute(arguments, output / f'{label}.log', timeout=60)
        if any(item in stdout + stderr for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('spectator status observer failed')
        lines = [line.removeprefix('FORTRESS_SPECTATOR_TRACE ') for line in stdout.splitlines()
                 if line.startswith('FORTRESS_SPECTATOR_TRACE ')]
        if len(lines) != 1:
            raise ValueError('spectator status observer missing trace')
        traces = json.loads(lines[0])
        compare(traces, expected_bundle(mutate_status), 'status')
        return traces

    traces = [observe(command, f'godot-{repetition}') for repetition in range(2)]
    compare(traces[0], traces[1])
    (output / 'observed.json').write_text(json.dumps(traces[0], indent=2) + '\n')
    rust = check_rust(traces[0], output, delayed=True, roster=True, statuses=True)
    actual = json.loads((output / 'rust-observed.json').read_text())
    mutant = observe([*command, '--mutate-status'], 'godot-lost-status', mutate_status=True)
    diagnostic = 'result.traces[0].transcript[0][4]: value mismatch'
    try:
        compare(actual, expected_rust(mutant))
    except ValueError as error:
        if not str(error).startswith(diagnostic):
            raise ValueError('executed status control failed for an unintended reason') from error
    else:
        raise ValueError('executed disconnected-as-confirmed mutation survived')
    canonical_diagnostic = 'canonical[0][0]: value mismatch'
    try:
        compare([[record[-1] for record in trace['transcript']] for trace in actual['traces']],
                [[record[-1] for record in trace['transcript']] for trace in mutant], 'canonical')
    except ValueError as error:
        if not str(error).startswith(canonical_diagnostic):
            raise ValueError('executed status control failed at an unintended canonical boundary') from error
    else:
        raise ValueError('lost disconnected status preserved canonical boundaries')
    return {'complete': True, 'workloads': len(traces[0]), 'players': list(range(2, 9)), 'repetitions': 2,
            'observations_sha256': digest(output / 'observed.json'), 'rust': rust,
            'executed_lost_status': {'rejected': True, 'diagnostic': diagnostic, 'canonical_diagnostic': canonical_diagnostic},
            'limitations': ['One reserved slot frozen at default input zero from frame zero; no mid-match drop or reactivation.',
                            'In-order fake delivery; no disconnected-status formal projection or live routing parity.']}
