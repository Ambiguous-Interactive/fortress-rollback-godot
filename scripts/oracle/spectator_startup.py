"""Executed pinned spectator startup and an explicit two-predicate model repair.

The reviewed upstream files remain immutable. The derived model removes only the
NULL-current-frame exception from backlog calculation. Its catch-up constant is
one for per-request Godot observations; actual multi-frame service cycles are
compared separately with Rust's real advance_frame requests.
"""
from copy import deepcopy
import json

from launch import ROOT, CACHE, digest, execute, load_manifest, setup_rust
from replay_launch import compare

ANCHORS = (
    'IF lastRecvFrame = NULL_FRAME \\/ currentFrame = NULL_FRAME',
    "IF lastRecvFrame' = NULL_FRAME \\/ currentFrame = NULL_FRAME",
)


def repair_model(source):
    for anchor in ANCHORS:
        if source.count(anchor) != 1:
            raise ValueError('pinned spectator startup predicate differs from reviewed anchor')
        source = source.replace(anchor, anchor.replace(' \\/ currentFrame = NULL_FRAME', ''))
    return source


def expected_rust(traces):
    return {'format': 1, 'traces': [
        {'capacity': trace['capacity'], 'preplay': trace['preplay'], 'speed': trace['speed'],
         'observations': trace['service_observations'], 'cycles': trace['cycles'], 'transcript': trace['transcript'],
         **({'delay': trace['delay']} if 'delay' in trace else {}),
         **({'players': trace['players']} if 'players' in trace else {})}
        for trace in traces]}


def negative_controls(observed, expected):
    """Require exact comparison failures at real startup and first catch-up cycle."""
    compare(observed, expected)
    hidden = deepcopy(observed)
    hidden['traces'][0]['observations'][1]['backlog'] = 0
    wrong_speed = deepcopy(observed)
    wrong_speed['traces'][1]['cycles'][0]['steps'] = 1
    controls = [
        ('hidden-startup', hidden, 'result.traces[0].observations[1].backlog: value mismatch'),
        ('first-catchup', wrong_speed, 'result.traces[1].cycles[0].steps: value mismatch'),
    ]
    evidence = []
    for label, mutant, diagnostic in controls:
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unexpected spectator diagnostic') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: spectator observer mutation survived')
    return evidence


def check_rust(traces, output, delayed=False, roster=False, statuses=False):
    manifest = load_manifest()
    cargo, _ = setup_rust(manifest, False)
    execute([str(cargo), '+' + manifest['rust']['version'], 'build', '--locked', *(['--features', 'spectator-status'] if statuses else []), '--bin', 'spectator',
             '--manifest-path', str(ROOT / 'scripts/oracle/rust/Cargo.toml')], output / 'rust-build.log', timeout=600)
    binary = CACHE / 'target/debug/spectator'
    fingerprint = digest(binary)
    expected = expected_rust(traces)
    observations = []
    arguments = ['--statuses'] if statuses else (['--roster'] if roster else (['--delayed'] if delayed else []))
    for repetition in range(2):
        stdout, stderr = execute([str(binary), *arguments], output / f'rust-{repetition}.log', timeout=60)
        if stderr.strip():
            raise ValueError('pinned spectator runtime emitted unexpected stderr')
        actual = json.loads(stdout)
        compare(actual, expected)
        observations.append(actual)
    compare(observations[0], observations[1])
    if digest(binary) != fingerprint:
        raise ValueError('pinned spectator oracle changed during observation')
    (output / 'rust-observed.json').write_text(json.dumps(observations[0], indent=2) + '\n')
    if statuses:
        from spectator_status import controls
        negative = controls(observations[0], expected)
    elif roster:
        from spectator_roster import controls
        negative = controls(observations[0], expected)
    else:
        negative = delay_controls(observations[0], expected) if delayed else negative_controls(observations[0], expected)
    return {'complete': True, 'binary_sha256': fingerprint, 'workloads': len(traces), 'repetitions': 2,
            'observations_sha256': digest(output / 'rust-observed.json'),
            'negative_controls': negative}


def delay_controls(observed, expected):
    """Attack actual delayed service and callback records while preserving final totals."""
    compare(observed, expected)
    controls = []
    for label, target, value, diagnostic in [
        ('delay-bypass', ('observations', 1, 'advice'), 1, 'result.traces[0].observations[1].advice: value mismatch'),
        ('raw-backlog-catchup', ('observations', 5, 'catchup'), True, 'result.traces[0].observations[5].catchup: value mismatch'),
    ]:
        mutant = deepcopy(observed)
        sequence, index, field = target
        if mutant['traces'][0][sequence][index][field] == value:
            raise ValueError(f'{label}: spectator mutation is inert')
        mutant['traces'][0][sequence][index][field] = value
        controls.append((label, mutant, diagnostic))
    mutant = deepcopy(observed)
    mutant['traces'][0]['transcript'][0][1], mutant['traces'][0]['transcript'][1][1] = (
        mutant['traces'][0]['transcript'][1][1], mutant['traces'][0]['transcript'][0][1])
    controls.append(('temporal-input', mutant, 'result.traces[0].transcript[0][1]: value mismatch'))
    evidence = []
    for label, mutant, diagnostic in controls:
        try:
            compare(mutant, expected)
        except ValueError as error:
            if not str(error).startswith(diagnostic):
                raise ValueError(f'{label}: unexpected delayed spectator diagnostic') from error
            evidence.append({'name': label, 'rejected': True, 'diagnostic': diagnostic})
        else:
            raise ValueError(f'{label}: delayed spectator mutation survived')
    return evidence


def validate_delay_bundle(traces, mutate_input=False):
    """Validate the independent delayed workload, including actual service boundaries."""
    inventory = [(preplay, capacity, speed, 1 if preplay else capacity - 1)
                 for preplay in (True, False) for capacity in (4, 5) for speed in (1, 2)]
    if not isinstance(traces, list) or len(traces) != len(inventory):
        raise ValueError('delayed spectator inventory differs')
    for trace, identity in zip(traces, inventory):
        fields = {'capacity', 'preplay', 'speed', 'delay', 'observations', 'transcript', 'service_observations', 'cycles'}
        if not isinstance(trace, dict) or set(trace) != fields:
            raise ValueError('invalid delayed spectator trace')
        capacity, speed, delay = trace['capacity'], trace['speed'], trace['delay']
        if (type(trace['preplay']) is not bool or any(type(value) is not int for value in (capacity, speed, delay))
                or (trace['preplay'], capacity, speed, delay) != identity):
            raise ValueError('delayed spectator inventory differs')
        original = [[frame, frame % 2, 0] for frame in range(12 - delay)]
        expected = deepcopy(original)
        if mutate_input:
            expected[0][1], expected[1][1] = expected[1][1], expected[0][1]
        compare(trace['transcript'], expected)
        if sum(row[1] for row in expected) != sum(row[1] for row in original):
            raise ValueError('delayed temporal input changed final total')
        services = trace['service_observations']
        observations = trace['observations']
        cycles = trace['cycles']
        if (not isinstance(services, list) or not 14 <= len(services) <= 32 or not isinstance(observations, list)
                or not 14 <= len(observations) <= 64 or not isinstance(cycles, list) or not 1 <= len(cycles) <= 12):
            raise ValueError('invalid delayed spectator observation counts')
        if any(not isinstance(cycle, dict) or set(cycle) != {'before', 'steps', 'after'} for cycle in cycles):
            raise ValueError('invalid delayed spectator cycle')
        for item in services + [cycle[edge] for cycle in cycles for edge in ('before', 'after')]:
            _delay_policy(item, capacity, speed, delay)
        compare(services[0], {'current': -1, 'backlog': 0, 'advice': 0, 'catchup': False})
        compare(services[-1], {'current': 11 - delay, 'backlog': delay, 'advice': 0, 'catchup': False})
        for item in observations:
            if not isinstance(item, dict) or set(item) != {'current', 'received', 'tags', 'inputs', 'backlog', 'advice', 'catchup'}:
                raise ValueError('invalid delayed spectator ring observation')
            _delay_policy({field: item[field] for field in ('current', 'backlog', 'advice', 'catchup')}, capacity, speed, delay)
            if (type(item['received']) is not int or not -1 <= item['received'] <= 11
                    or item['backlog'] != item['received'] - item['current']
                    or not isinstance(item['tags'], list) or len(item['tags']) != capacity
                    or any(type(tag) is not int or not -1 <= tag <= 11 for tag in item['tags'])
                    or not isinstance(item['inputs'], list) or len(item['inputs']) != capacity):
                raise ValueError('invalid delayed spectator retained ring')
            for row in item['inputs']:
                if not isinstance(row, list) or len(row) != 2 or any(type(value) is not int or value not in (0, 1) for value in row):
                    raise ValueError('invalid delayed spectator retained input')
        for cycle in cycles:
            if not isinstance(cycle, dict) or set(cycle) != {'before', 'steps', 'after'}:
                raise ValueError('invalid delayed spectator cycle')
            if (type(cycle['steps']) is not int or cycle['steps'] != cycle['before']['advice']
                    or cycle['after']['current'] != cycle['before']['current'] + cycle['steps']
                    or cycle['after']['backlog'] != cycle['before']['backlog'] - cycle['steps']):
                raise ValueError('delayed spectator service boundary differs')
        if speed == 2 and delay == 1 and not any(cycle['steps'] == 2 for cycle in cycles):
            raise ValueError('delayed spectator did not exercise catchup')
        expected_observations, expected_services, expected_cycles = _delay_history(capacity, speed, delay, mutate_input)
        compare(observations, expected_observations, 'delayed spectator observations')
        compare(services, expected_services, 'delayed spectator services')
        compare(cycles, expected_cycles, 'delayed spectator cycles')
    return traces


def _delay_history(capacity, speed, delay, mutate_input, players=2, row_for_frame=None):
    """Independent delivery schedule: retain every receive, advance microstep and refused advance."""
    current = -1
    tags = [-1] * capacity
    rows = [[0] * players for _ in range(capacity)]

    def snapshot(received):
        backlog = received - current
        available = max(0, backlog - delay)
        return {'current': current, 'received': received, 'tags': tags[:], 'inputs': deepcopy(rows),
                'backlog': backlog, 'advice': min(available, speed), 'catchup': available > 1}

    def policy(received):
        item = snapshot(received)
        return {field: item[field] for field in ('current', 'backlog', 'advice', 'catchup')}

    observations, services, cycles = [snapshot(-1)], [policy(-1)], []
    for received in range(12):
        tags[received % capacity] = received
        value = 1 - received % 2 if mutate_input and received < 2 else received % 2
        rows[received % capacity] = row_for_frame(received) if row_for_frame is not None else [value, 0]
        observations.append(snapshot(received))
        services.append(policy(received))
        if received - current == capacity or received == 11:
            while received - current > delay:
                before = policy(received)
                for _ in range(before['advice']):
                    current += 1
                    observations.append(snapshot(received))
                cycles.append({'before': before, 'steps': before['advice'], 'after': policy(received)})
            services.append(policy(received))
            observations.append(snapshot(received))
    return observations, services, cycles


def _delay_policy(item, capacity, speed, delay):
    if not isinstance(item, dict) or set(item) != {'current', 'backlog', 'advice', 'catchup'}:
        raise ValueError('invalid delayed spectator policy')
    if (any(type(item[field]) is not int for field in ('current', 'backlog', 'advice'))
            or not -1 <= item['current'] <= 11 or not 0 <= item['backlog'] <= capacity or type(item['catchup']) is not bool):
        raise ValueError('invalid delayed spectator policy type or bound')
    available = max(0, item['backlog'] - delay)
    if item['advice'] != min(available, speed if available > 1 else 1) or item['catchup'] != (available > 1):
        raise ValueError('delayed spectator policy differs from viewable backlog')


def check_delay(engine, output):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/oracle/spectator_trace.gd', '--', '--delayed']
    observations = []
    for repetition in range(2):
        stdout, stderr = execute(command, output / f'godot-{repetition}.log', timeout=60)
        if any(item in stdout + stderr for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
            raise ValueError('delayed spectator observer failed')
        lines = [line.removeprefix('FORTRESS_SPECTATOR_TRACE ') for line in stdout.splitlines() if line.startswith('FORTRESS_SPECTATOR_TRACE ')]
        if len(lines) != 1:
            raise ValueError('delayed spectator observer missing trace')
        observations.append(validate_delay_bundle(json.loads(lines[0])))
    compare(observations[0], observations[1])
    (output / 'observed.json').write_text(json.dumps(observations[0], indent=2) + '\n')
    rust = check_rust(observations[0], output, delayed=True)
    stdout, stderr = execute([*command, '--mutate-input'], output / 'godot-temporal-input.log', timeout=60)
    if any(item in stdout + stderr for item in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('delayed temporal-input observer failed')
    lines = [line.removeprefix('FORTRESS_SPECTATOR_TRACE ') for line in stdout.splitlines() if line.startswith('FORTRESS_SPECTATOR_TRACE ')]
    if len(lines) != 1:
        raise ValueError('delayed temporal-input observer missing trace')
    mutant = validate_delay_bundle(json.loads(lines[0]), mutate_input=True)
    actual_rust = json.loads((output / 'rust-observed.json').read_text())
    diagnostic = 'result.traces[0].transcript[0][1]: value mismatch'
    try:
        compare(actual_rust, expected_rust(mutant))
    except ValueError as error:
        if not str(error).startswith(diagnostic):
            raise ValueError('delayed temporal input failed for an unintended reason') from error
    else:
        raise ValueError('delayed temporal input mutation survived')
    return {'complete': True, 'workloads': len(observations[0]), 'repetitions': 2,
            'observations_sha256': digest(output / 'observed.json'), 'rust': rust,
            'executed_temporal_input': {'rejected': True, 'diagnostic': diagnostic}}
