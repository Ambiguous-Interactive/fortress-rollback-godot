"""Compare real duplicate/reordered source traffic with confirmed-row playback."""
from copy import deepcopy
import json

from launch import ROOT, digest, execute
from replay_launch import compare
from spectator_roster import row
from spectator_startup import expected_rust, check_rust


def expected_bundle(swapped=False, ordered=False):
    traces = []
    for players in range(2, 9):
        for capacity in (4, 5):
            for speed in (1, 2):
                current, frontier, state = -1, -1, 0
                tags, inputs = [-1] * capacity, [[0] * players for _ in range(capacity)]
                transcript, canonical, deliveries, cycles = [], [], [], []

                def snapshot():
                    available = max(0, frontier - current - 1)
                    return {'current': current, 'received': frontier, 'tags': tags[:], 'inputs': deepcopy(inputs),
                            'backlog': frontier - current, 'advice': min(available, speed), 'catchup': available > 1}

                def policy():
                    value = snapshot()
                    return {field: value[field] for field in ('current', 'backlog', 'advice', 'catchup')}

                observations, services = [snapshot()], [policy()]
                for frame in range(12):
                    if frame % 2 == 1:
                        order = [frame - 1, frame] if ordered else [frame, frame, frame - 1, frame - 1]
                        for delivered in order:
                            deliveries.append([delivered, 0])
                            tags[delivered % capacity] = delivered
                            inputs[delivered % capacity] = row(delivered, players, swapped)
                        frontier = frame
                    observations.append(snapshot())
                    services.append(policy())
                    if frame % 2 == 1:
                        while frontier - current > 1:
                            before = policy()
                            for _ in range(before['advice']):
                                current += 1
                                values = row(current, players, swapped)
                                for value in values:
                                    state = (state * 17 + value + 31 + current) % 1000000007
                                transcript.append([current, *values])
                                canonical.append(state)
                                observations.append(snapshot())
                            cycles.append({'before': before, 'steps': before['advice'], 'after': policy()})
                        services.append(policy())
                        observations.append(snapshot())
                traces.append({'capacity': capacity, 'preplay': True, 'speed': speed, 'delay': 1, 'players': players,
                               'observations': observations, 'service_observations': services, 'cycles': cycles,
                               'transcript': transcript, 'reordered': True, 'deliveries': deliveries, 'canonical': canonical})
    return traces


def controls(observed, expected):
    compare(observed, expected)
    evidence = []
    for label, field, index, value, diagnostic in [
        ('ordered-delivery', 'deliveries', 0, [0, 0], 'result.traces[0].deliveries[0][0]: value mismatch'),
        ('canonical-prefix', 'canonical', 3, 0, 'result.traces[0].canonical[3]: value mismatch'),
    ]:
        mutant = deepcopy(observed)
        mutant['traces'][0][field][index] = value
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unexpected reordered spectator diagnostic') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: reordered spectator mutation survived')
    return evidence


def check(engine, output):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(engine), '--headless', '--path', str(ROOT), '--script',
               'res://tests/oracle/spectator_trace.gd', '--', '--reordered']

    def observe(arguments, label, swapped=False, ordered=False):
        stdout, stderr = execute(arguments, output / f'{label}.log', timeout=60)
        if any(item in stdout + stderr for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('reordered spectator observer failed')
        lines = [line.removeprefix('FORTRESS_SPECTATOR_TRACE ') for line in stdout.splitlines()
                 if line.startswith('FORTRESS_SPECTATOR_TRACE ')]
        if len(lines) != 1:
            raise ValueError('reordered spectator observer missing trace')
        value = json.loads(lines[0])
        compare(value, expected_bundle(swapped, ordered), 'reordered')
        return value

    traces = [observe(command, f'godot-{repeat}') for repeat in range(2)]
    compare(traces[0], traces[1])
    (output / 'observed.json').write_text(json.dumps(traces[0], indent=2) + '\n')
    rust = check_rust(traces[0], output, reordered=True)
    actual = json.loads((output / 'rust-observed.json').read_text())
    executed = []
    for argument, label, swapped, ordered, diagnostic in [
        ('--mutate-delivery', 'ordered-delivery', False, True, 'result.traces[0].deliveries: count mismatch'),
        ('--mutate-player', 'player-order', True, False, 'result.traces[0].transcript[0][1]: value mismatch'),
    ]:
        mutant = observe([*command, argument], label, swapped, ordered)
        try:
            compare(actual, expected_rust(mutant))
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: executed control failed at an unintended boundary: {error}') from error
            executed.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: executed spectator mutation survived')
    return {'complete': True, 'workloads': len(traces[0]), 'players': list(range(2, 9)), 'repetitions': 2,
            'observations_sha256': digest(output / 'observed.json'), 'rust': rust, 'executed_controls': executed,
            'limitations': ['Pairs of distinct source emissions are reversed and duplicated; no loss, expiry or live routing.',
                            'Godot receives reversed duplicate complete rows; Rust retains its own compressed player protocol.']}
