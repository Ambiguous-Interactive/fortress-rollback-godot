"""Asymmetric three-player recovery through the fixed 128-row queue ring."""
from copy import deepcopy
from p2p_contract import validate_scenario
from contract import initial_game_state, advance_game_state

NAME = 'mesh_3_asymmetric_recovery_wrap'
ROUNDS = 132


def build(binary, observe):
    scenario = {'format': 1, 'players': 3, 'input_delay': 0, 'max_prediction': 8, 'operations': [],
                'lifecycle': {'quality_us': 100000000, 'keepalive_us': 100000000, 'notify_us': 5000000,
                              'timeout_us': 10000000, 'checksum_interval': 0, 'divergent_peer': -1}}
    now = 0; latest = None; delivered = set()
    def append(kind, **kwargs):
        nonlocal now
        now += 1; scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))
    def flush(release):
        nonlocal latest
        for _ in range(10):
            pending = [p for p in latest['packets'] if p['id'] not in delivered
                       and (release or not (p['from'] == 2 and p['to'] == 0))]
            if not pending:
                return
            pending.sort(key=lambda p: (p['from'] == 2 and p['to'] == 0, -p['id'] if p['from'] == 2 and p['to'] == 0 else p['id']))
            for packet in pending:
                delivered.add(packet['id']); append('deliver', packet=packet['id'])
            latest = observe(binary, scenario)
        raise ValueError('asymmetric recovery flush bound')
    for frame in range(ROUNDS):
        for peer in range(3):
            append('step', peer=peer, bytes=((frame + 1) * (peer + 1) * 17).to_bytes(4, 'little').hex())
        latest = observe(binary, scenario)
        flush(frame % 3 == 2)
    flush(True)
    for peer in range(3):
        append('step', peer=peer, bytes=((ROUNDS + 1) * (peer + 1) * 17).to_bytes(4, 'little').hex())
    latest = observe(binary, scenario); flush(True)
    validate_scenario(scenario)
    return scenario


def evidence(value, scenario):
    """Require actual late multi-row delivery, correction and wrapped canonical history."""
    if scenario['players'] != 3 or scenario['max_prediction'] != 8 or scenario['input_delay'] != 0:
        raise ValueError('asymmetric recovery profile')
    counts = {'loads': [0, 0, 0], 'steps': [0, 0, 0], 'late_batches': 0, 'wrapped_loads': 0}
    received = [-1, -1, -1]
    canonical = [initial_game_state(3, 2)]
    for frame in range(ROUNDS + 1):
        canonical.append(advance_game_state(canonical[-1], [(frame + 1) * (peer + 1) * 17 for peer in range(3)], 2))
    boundaries = [{0: canonical[0]} for _ in range(3)]
    verified = [set() for _ in range(3)]
    for op, record in zip(scenario['operations'], value['records']):
        peer = record['peer']
        if op['kind'] == 'step':
            if record['error'] is not None or record['frame_after'] != record['frame_before'] + 1:
                raise ValueError('asymmetric recovery forward progress')
            counts['steps'][peer] += 1
        if op['kind'] == 'deliver':
            packet = value['packets'][op['packet']]
            body = packet['semantic']
            if packet['to'] == 0 and body['kind'] == 'input':
                sender = packet['from']; previous = received[sender]
                received[sender] = max(previous, body['start_frame'] + len(body['frames']) - 1)
                if sender == 2 and received[1] >= previous + 3 and received[2] >= previous + 3:
                    counts['late_batches'] += 1
        for request in record['requests']:
            boundary = request['frame'] + int(request['kind'] == 'advance')
            boundaries[peer][boundary] = bytes.fromhex(request['state_bytes'])
            if request['kind'] == 'load':
                counts['loads'][peer] += 1
                counts['wrapped_loads'] += int(peer == 0 and request['frame'] >= 128)
        if op['kind'] == 'step':
            for boundary in range(record['confirmed_frame'] + 2):
                if boundaries[peer].get(boundary) != canonical[boundary]:
                    raise ValueError('asymmetric recovery canonical confirmed boundary')
                verified[peer].add(boundary)
    counts['canonical_boundaries'] = [len(frames) for frames in verified]
    if min(counts['canonical_boundaries']) < 129:
        raise ValueError('asymmetric recovery missing canonical wrap')
    if counts['steps'] != [ROUNDS + 1] * 3 or counts['loads'][0] < 40 or counts['late_batches'] < 40 or counts['wrapped_loads'] < 1:
        raise ValueError('asymmetric recovery missing exercised history')
    return counts


def controls(value, scenario):
    """Keep named exercise and independent-history gates fail closed."""
    evidence(value, scenario)
    mutants = {}
    skipped = deepcopy(value)
    for record in skipped['records']:
        record['requests'] = [q for q in record['requests'] if not (q['kind'] == 'load' and q['frame'] >= 128)]
    mutants['wrapped_correction_removed'] = (skipped, 'asymmetric recovery missing exercised history')
    corrupted = deepcopy(value)
    record = next(r for r in corrupted['records'] if r['peer'] == 0 and r['confirmed_frame'] >= 128 and r['requests'])
    request = next(q for q in reversed(record['requests']) if q['frame'] + int(q['kind'] == 'advance') <= record['confirmed_frame'] + 1)
    raw = bytearray.fromhex(request['state_bytes']); raw[4] ^= 1; request['state_bytes'] = raw.hex()
    mutants['corrected_boundary_corrupted'] = (corrupted, 'asymmetric recovery canonical confirmed boundary')
    for name, (mutant, diagnostic) in mutants.items():
        try:
            evidence(mutant, scenario)
        except ValueError as error:
            if str(error) != diagnostic:
                raise ValueError('asymmetric recovery control wrong boundary: ' + name + ': ' + str(error)) from error
        else:
            raise ValueError('asymmetric recovery control survived: ' + name)
    return list(mutants)
