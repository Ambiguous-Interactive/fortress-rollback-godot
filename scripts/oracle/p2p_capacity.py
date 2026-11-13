"""Deep late-flight correction at a non-power-of-two queue capacity through public P2P delivery."""
from copy import deepcopy
from p2p_contract import validate_scenario

NAME = 'mesh_3_capacity9_late_flight'
ROUNDS = 44
WITHHOLD_START = 6
RELEASE = 16
CAPACITY = 9
WRAPS = 3
# Protocol time advances one microsecond per operation, so no input retry timer
# fires mid-run; the mesh retry cases already own retransmission timing.


def build(binary, observe):
    """Peer 2 stops reaching peer 0 for ten rounds while peers 0 and 1 keep
    producing, so the released flight forces one deep correction through rows that
    arrived during the withheld stretch, and the ring wraps the nine-row capacity
    several times before and after it. Runtime delay changes compare at the
    capacity-aware bounds: the only comparable raise is refused by both peers."""
    scenario = {'format': 1, 'players': 3, 'input_delay': 0, 'max_prediction': 4, 'queue_capacity': CAPACITY, 'operations': []}
    now = 0; latest = None; delivered = set()
    def append(kind, refresh=True, **kwargs):
        nonlocal now, latest
        now += 1; scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))
        if refresh:
            latest = observe(binary, scenario)
    def step(peer):
        frame = next((r['frame_after'] for r in reversed(latest['records']) if r['peer'] == peer), 0) if latest else 0
        append('step', peer=peer, bytes=((frame + 1) * (peer + 1) * 17).to_bytes(4, 'little').hex())
    def flush(whole=True):
        nonlocal now, latest
        for _ in range(10):
            if latest is None:
                return
            pending = [p for p in latest['packets'] if p['id'] not in delivered
                       and (whole or not (p['from'] == 2 and p['to'] == 0))]
            if not pending:
                return
            pending.sort(key=lambda p: (not (p['from'] == 2 and p['to'] == 0),
                                        -p['id'] if p['from'] == 2 and p['to'] == 0 else p['id']))
            for packet in pending:
                delivered.add(packet['id']); append('deliver', refresh=False, packet=packet['id'])
            latest = observe(binary, scenario)
        raise ValueError('capacity witness flush bound')
    for frame in range(ROUNDS):
        whole = frame < WITHHOLD_START or (RELEASE <= frame and (frame - RELEASE) % 3 == 0)
        flush(whole)
        step(0); step(1); step(2)
        flush(whole)
    flush(True)
    append('poll', peer=0)
    # Both bounds refuse this raise at capacity nine: upstream's running span
    # (delay + prediction) exceeds queue - 1 and Godot's peer bound is zero.
    scenario['operations'].append({'kind': 'delay', 'peer': 0, 'delay': 6}); latest = observe(binary, scenario)
    for peer in range(3):
        append('poll', peer=peer)
    flush(True)
    validate_scenario(scenario)
    return scenario


def evidence(value, scenario):
    """Require the deep withheld-flight correction, corrections pending through the
    withheld stretch, wrapped confirmation on every peer and the refused raise."""
    if scenario['players'] != 3 or scenario['max_prediction'] != 4 or scenario['queue_capacity'] != CAPACITY or scenario['input_delay'] != 0:
        raise ValueError('capacity witness profile')
    counts = {'pending_advances': 0, 'correction_rows': 0, 'refused_raise': 0}
    for record, op in zip(value['records'], scenario['operations']):
        # The raw source trace names upstream's structured error; Godot's names the code.
        if op['kind'] == 'delay' and record['error'] in ('INVALID_CONFIGURATION', 'ConfigValueOutOfRange'):
            counts['refused_raise'] += 1
        pending = 0; confirmed2 = set(); after_load = False
        for request in record['requests']:
            if request['kind'] == 'load':
                after_load = True
                confirmed2 = set()
            if request['kind'] != 'advance':
                continue
            statuses = {entry['player']: entry['status'] for entry in request['inputs']}
            if statuses.get(2) == 'predicted':
                pending += 1
            if after_load and statuses.get(2) == 'confirmed':
                confirmed2.add(request['frame'])
        counts['pending_advances'] += pending
        # The release record re-runs the withheld stretch from its load with every
        # slot's actual input, so the ring held each row across the whole stretch.
        if record['peer'] == 0 and confirmed2:
            runs, run = [], []
            for frame in sorted(confirmed2):
                if run and frame == run[-1] + 1:
                    run.append(frame)
                else:
                    runs.append(run); run = [frame]
            if run:
                runs.append(run)
            if runs:
                counts['correction_rows'] = max(counts['correction_rows'], max(len(run) for run in runs))
    if counts['pending_advances'] < 4:
        raise ValueError('capacity witness missing pending corrections')
    if counts['correction_rows'] < 3:
        raise ValueError('capacity witness missing deep correction')
    if counts['refused_raise'] != 1:
        raise ValueError('capacity witness missing refused raise')
    boundaries = [set() for _ in range(3)]
    for record, op in zip(value['records'], scenario['operations']):
        if op['kind'] == 'step':
            for boundary in range(record['confirmed_frame'] + 1):
                boundaries[record['peer']].add(boundary)
    counts['confirmed_boundaries'] = [len(frames) for frames in boundaries]
    if min(counts['confirmed_boundaries']) < CAPACITY * WRAPS:
        raise ValueError('capacity witness missing confirmed wrap')
    return counts


def controls(value, scenario):
    """Keep the deep-correction, pending-correction and refused-raise gates fail closed."""
    evidence(value, scenario)
    mutants = {}
    stripped = deepcopy(value)
    for record in stripped['records']:
        if record['peer'] == 0:
            record['requests'] = [q for q in record['requests'] if q['kind'] != 'load']
    mutants['correction_load_removed'] = (stripped, 'capacity witness missing deep correction')
    unpending = deepcopy(value)
    for record in unpending['records']:
        for request in record['requests']:
            if request['kind'] == 'advance':
                for entry in request['inputs']:
                    if entry['player'] == 2 and entry['status'] == 'predicted':
                        entry['status'] = 'confirmed'
                        entry['bytes'] = '00000000'
    mutants['pending_correction_hidden'] = (unpending, 'capacity witness missing pending corrections')
    excused = deepcopy(value)
    for record, op in zip(excused['records'], scenario['operations']):
        if op['kind'] == 'delay' and record['error'] in ('INVALID_CONFIGURATION', 'ConfigValueOutOfRange'):
            record['error'] = None
    mutants['refused_raise_excused'] = (excused, 'capacity witness missing refused raise')
    result = []
    for name, (mutant, diagnostic) in mutants.items():
        try:
            evidence(mutant, scenario)
        except ValueError as error:
            if str(error) != diagnostic:
                raise ValueError('capacity witness control wrong boundary: ' + name + ': ' + str(error)) from error
            result.append(name)
        else:
            raise ValueError('capacity witness control survived: ' + name)
    return result
