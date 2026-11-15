"""Long ring-wrap runs under a withheld multi-round flood release."""
from copy import deepcopy

from p2p_contract import validate_scenario

# name -> (players, queue capacity, rounds). Counts two and four hold the real
# default ring: the confirmed frontier climbs past the 128-row queues the
# production mesh configures by default. The eight-peer full mesh emits seven
# input packets and seven acknowledgements per peer per round, so a
# default-capacity wrap would need far more scheduled operations than the
# oracle's 10000-operation scenario bound admits; that scale point instead
# wraps a 32-row ring at the full fanout (the frontier passes the whole ring
# and climbs past it) with the same flood shape.
PROFILES = {'mesh_2_wrap_flood': (2, 128, 142), 'mesh_4_wrap_flood': (4, 128, 142), 'mesh_8_wrap_flood': (8, 32, 44)}
NAMES = tuple(PROFILES)
WINDOW = 4
FLOOD_START = 8
FLOOD_ROUNDS = 6
RELEASE = FLOOD_START + FLOOD_ROUNDS
CORRECTION_MIN = 3
# Protocol time advances one microsecond per operation, so no retry or keepalive
# timer fires mid-run; the retry cases and the lifecycle corpus own timed traffic.
# The flood withholds every packet — inputs and acknowledgements alike — from
# every link for six consecutive rounds, so the confirmed frontier freezes and
# each machine then stalls silently at the prediction limit exactly as the
# pinned engine's source does (the shared normalization names those steps
# PREDICTION_STALL on both sides). The release is the flood: one back-to-back
# reversed delivery burst that heals the whole mesh through a deep LOAD
# correction, after which every confirmed frontier climbs past its ring's
# capacity and the queue wraps.


def build(binary, observe, players, capacity, rounds):
    """Each machine advances one frame per round until the starved frontier
    caps it at confirmed + window, then stalls silently; the builder models
    that cap explicitly, derives each step's payload from the modeled frame and
    re-verifies the model against every observed trace, so a wrong model fails
    the build instead of shipping an inconsistent schedule."""
    scenario = {'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': WINDOW, 'operations': [],
                'lifecycle': {'quality_us': 100000000, 'keepalive_us': 100000000, 'notify_us': 5000000,
                              'timeout_us': 10000000, 'checksum_interval': 0, 'divergent_peer': -1}}
    if capacity != 128:
        scenario['queue_capacity'] = capacity
    now = 0; latest = None; held = []; delivered = set()
    modeled = [0] * players

    def append(kind, **kwargs):
        nonlocal now
        now += 1
        scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))

    def see():
        nonlocal latest
        latest = observe(binary, scenario)
        for peer in range(players):
            record = next((r for r in reversed(latest['records']) if r['peer'] == peer), None)
            if record is not None and record['frame_after'] - modeled[peer] not in (0, 1):
                raise ValueError(f'wrap witness frame model diverged on peer {peer}: trace {record["frame_after"]} '
                                 f'modeled {modeled[peer]}')

    def step(peer):
        # The submitted sample belongs to the machine's current frame (delay
        # zero), so bytes derived from the observed frame keep every repeated
        # stalled sample identical while varying across confirmed frames.
        append('step', peer=peer, bytes=((modeled[peer] + 1) * (peer + 1) * 17 % 256 ** 4).to_bytes(4, 'little').hex())

    def deliver(packet_id):
        delivered.add(packet_id)
        append('deliver', packet=packet_id)

    for frame in range(rounds):
        if scenario['operations']:
            see()
            pending = [p for p in latest['packets'] if p['id'] not in delivered]
            if FLOOD_START <= frame < RELEASE:
                # Total silence: every emitted packet stays withheld, so the
                # frontier freezes through the missing acknowledgements and the
                # mesh runs into its prediction limit mid-stretch.
                held.extend(pending)
                delivered.update(p['id'] for p in pending)
            elif frame == RELEASE:
                # The flood: the whole withheld burst arrives back-to-back in
                # reversed order, and the newest withheld input packets are
                # re-delivered behind it as duplicates both engines must
                # tolerate identically.
                held.reverse()
                duplicates = [p['id'] for p in held if p['semantic']['kind'] == 'input'][:2]
                for packet in held + pending:
                    deliver(packet['id'])
                for packet_id in duplicates:
                    deliver(packet_id)
                held.clear()
                # The burst un-caps the frontier mid-round: re-read the trace so
                # the modeled frame follows the healed confirmation bound.
                see()
            else:
                for packet in pending:
                    deliver(packet['id'])
        for peer in range(players):
            record = next((r for r in reversed(latest['records']) if r['peer'] == peer), None) if latest else None
            modeled[peer] = record['frame_after'] if record else 0
            step(peer)
    see()
    for packet in (p for p in latest['packets'] if p['id'] not in delivered):
        deliver(packet['id'])
    for peer in range(players):
        append('poll', peer=peer)
    see()
    validate_scenario(scenario)
    return scenario


def evidence(value, scenario):
    """Require, per machine: the wrapped confirmation, a withheld-stretch
    prediction and a silent stall; plus the deep flood correction, the single
    burst delivery run and the duplicates."""
    players = scenario['players']
    capacity = scenario.get('queue_capacity', 128)
    if players not in {spec[0] for spec in PROFILES.values()} or scenario['max_prediction'] != WINDOW or scenario['input_delay'] != 0:
        raise ValueError('wrap witness profile')
    if not any(spec[0] == players and spec[1] == capacity for spec in PROFILES.values()):
        raise ValueError('wrap witness profile')
    counts = {'pending_advances': 0, 'correction_rows': 0, 'burst_delivers': 0, 'duplicate_deliveries': 0,
              'silent_stalls': 0}
    # Static schedule shape: the flood release is one run of deliver operations
    # between two step operations carrying the withheld rounds' packets, and at
    # least two packets are delivered twice.
    run = 0; seen = set()
    for op in scenario['operations']:
        if op['kind'] != 'deliver':
            run = 0
            continue
        run += 1
        counts['burst_delivers'] = max(counts['burst_delivers'], run)
        if op['packet'] in seen:
            counts['duplicate_deliveries'] += 1
        seen.add(op['packet'])
    if counts['burst_delivers'] < players * 2:
        raise ValueError('wrap witness missing burst run')
    if counts['duplicate_deliveries'] < 2:
        raise ValueError('wrap witness missing duplicate delivery')
    # Differential evidence: every machine predicted through the starved
    # stretch and stalled silently at the limit, the release re-runs that
    # stretch from one LOAD with confirmed rows, and every peer's confirmed
    # frontier passes its ring's capacity.
    boundaries = [set() for _ in range(players)]
    pending = [0] * players
    stalls = [0] * players
    correction = 0
    for record, op in zip(value['records'], scenario['operations']):
        if op['kind'] == 'step':
            for boundary in range(record['confirmed_frame'] + 1):
                boundaries[record['peer']].add(boundary)
            # Godot names the stall; the raw source trace leaves the refused
            # advance unnamed, and the shared normalization maps the silent
            # frame-frozen step to the same PREDICTION_STALL diagnostic.
            if record['error'] == 'PREDICTION_STALL' or (record['error'] is None
                                                         and record['frame_before'] == record['frame_after']):
                stalls[record['peer']] += 1
        run = 0; after_load = False
        for request in record['requests']:
            if request['kind'] == 'load':
                after_load = True; run = 0
            if request['kind'] != 'advance':
                continue
            statuses = {entry['status'] for entry in request['inputs']}
            if 'predicted' in statuses:
                pending[record['peer']] += 1
            if after_load and statuses == {'confirmed'}:
                run += 1
                correction = max(correction, run)
            else:
                run = 0
    counts = {'pending_advances': pending, 'silent_stalls': stalls, 'correction_rows': correction,
              'burst_delivers': counts['burst_delivers'], 'duplicate_deliveries': counts['duplicate_deliveries'],
              'confirmed_boundaries': [len(frames) for frames in boundaries]}
    if min(pending) < 1:
        raise ValueError('wrap witness missing pending advances')
    if min(stalls) < 1:
        raise ValueError('wrap witness missing silent stalls')
    if correction < CORRECTION_MIN:
        raise ValueError('wrap witness missing flood correction')
    if min(counts['confirmed_boundaries']) < capacity + 1:
        raise ValueError('wrap witness missing confirmed wrap')
    return counts


def controls(value, scenario):
    """Keep the per-machine stalls and predictions, the correction and the wrap
    gates fail closed."""
    evidence(value, scenario)
    mutants = {}
    stripped = deepcopy(value)
    capacity = scenario.get('queue_capacity', 128)
    for record in stripped['records']:
        record['confirmed_frame'] = min(record['confirmed_frame'], capacity - 2)
    mutants['confirmed_wrap_clamped'] = (stripped, 'wrap witness missing confirmed wrap')
    uncorrected = deepcopy(value)
    for record in uncorrected['records']:
        record['requests'] = [q for q in record['requests'] if q['kind'] != 'load']
    mutants['flood_load_removed'] = (uncorrected, 'wrap witness missing flood correction')
    unnormalized = deepcopy(value)
    for record in unnormalized['records']:
        # Defeat both stall shapes at once: Godot names the refused advance and
        # the raw source leaves it silent with frozen frames.
        if record['error'] == 'PREDICTION_STALL' or record['frame_before'] == record['frame_after']:
            record['error'] = 'MISSING_LOCAL_INPUT'
            record['frame_after'] = record['frame_before'] + 1
    mutants['stall_error_removed'] = (unnormalized, 'wrap witness missing silent stalls')
    # One machine's witnesses vanish while every aggregate count stays large:
    # the per-machine floors must hold on their own.
    hidden = deepcopy(value)
    for record in hidden['records']:
        if record['peer'] != 0:
            continue
        if record['error'] == 'PREDICTION_STALL' or record['frame_before'] == record['frame_after']:
            record['error'] = 'MISSING_LOCAL_INPUT'
            record['frame_after'] = record['frame_before'] + 1
        for request in record['requests']:
            if request['kind'] != 'advance':
                continue
            for entry in request['inputs']:
                if entry['status'] == 'predicted':
                    entry['status'] = 'confirmed'
    mutants['one_peer_witness_hidden'] = (hidden, 'wrap witness missing pending advances')
    stashed = deepcopy(value)
    for record in stashed['records']:
        if record['peer'] != 0:
            continue
        if record['error'] == 'PREDICTION_STALL' or record['frame_before'] == record['frame_after']:
            record['error'] = 'MISSING_LOCAL_INPUT'
            record['frame_after'] = record['frame_before'] + 1
    mutants['one_peer_stall_hidden'] = (stashed, 'wrap witness missing silent stalls')
    result = []
    for name, (mutant, diagnostic) in mutants.items():
        try:
            evidence(mutant, scenario)
        except ValueError as error:
            if str(error) != diagnostic:
                raise ValueError('wrap witness control wrong boundary: ' + name + ': ' + str(error)) from error
            result.append(name)
        else:
            raise ValueError('wrap witness control survived: ' + name)
    return result
