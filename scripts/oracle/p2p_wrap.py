"""Long ring-wrap runs under a withheld multi-round flood release."""
from copy import deepcopy

from p2p_contract import validate_scenario

# name -> (players, queue capacity, rounds, prediction window, per-peer construction
# delays, endpoint layout). A None layout stays one local slot per endpoint; a list
# gives each machine's local slot count and omits the lifecycle section (the shared
# grammar refuses that combination; the engines' defaults keep every timer inert).
# Every count two through eight holds the real default ring: the confirmed frontier climbs past
# the 128-row queues the production mesh configures by default, so the named
# count cases compare the default-capacity wrap at every supported roster size.
# The oracle's 20000-operation scenario bound admits the eight-peer default case
# at its measured 16324 operations (129 boundaries at two packets per peer pair
# per round); the named 32-row eight-peer scale point stays as the full-fanout
# small-ring witness — the frontier passes the whole reduced ring and climbs
# past it under the same flood shape — with the per-case capacity kept in its
# committed profile. `mesh_4_wrap_flood_window_8` binds the same flood at the
# deepest supported prediction window, so the wrap axis is covered at the
# shallow family window and at the boundary window eight in one corpus. The
# two `*_delays_*` profiles carry the heterogeneous per-peer construction
# schedules of the delay-profile family through the same withheld flood: the
# band's extremes and every distinct delay wrap their rings while their
# delayed construction stamps stay compared end to end.
# `mesh_4_wrap_flood_capacity_9` is the family's non-power-of-two scale point:
# the full-fanout four-peer flood on the nine-row ring, so the healed frontier
# passes the whole reduced ring several rows deep instead of grazing the
# 128-row default — the complement of the partial-outage capacity-nine case
# (`mesh_3_capacity9_late_flight`), which wraps the same ring under a single
# withheld link instead of the total-silence flood.
# `mesh_4_wrap_flood_couch_2x2` carries the local-slot layout axis through the
# same flood: two couch machines each own two local slots, so every confirmed
# row folds two local samples per machine and the withheld burst releases both
# machines' shared-address flights through one deep LOAD heal. An explicit
# layout cannot carry a lifecycle section (the shared grammar refuses it), and
# it does not need one: the engines' omitted-section defaults (quality and
# keepalive 100 s, disconnect timeout 100 s, notify 50 s) are the same inert
# no-timer-fires shape the explicit solo values pin.
# The launchers load the committed schedules from scripts/oracle/fixtures/wrap_flood
# instead of building them: the builder reruns the whole growing scenario once per
# round, and that quadratic cost inside every CI launch blew the merge queue's
# 30-minute check-response timeout. build() stays the deliberate regeneration
# path (scripts/oracle/p2p_wrap_regenerate.py); its per-round model checks keep
# failing the regeneration on divergence, and every launch still runs the full
# differential gates against the committed bytes.
PROFILES = {'mesh_2_wrap_flood': (2, 128, 142, 4, None, None), 'mesh_3_wrap_flood': (3, 128, 142, 4, None, None),
            'mesh_4_wrap_flood': (4, 128, 142, 4, None, None),
            'mesh_5_wrap_flood': (5, 128, 142, 4, None, None), 'mesh_6_wrap_flood': (6, 128, 142, 4, None, None),
            'mesh_7_wrap_flood': (7, 128, 142, 4, None, None), 'mesh_8_wrap_flood': (8, 128, 142, 4, None, None),
            'mesh_8_wrap_flood_32': (8, 32, 44, 4, None, None), 'mesh_4_wrap_flood_window_8': (4, 128, 142, 8, None, None),
            'mesh_3_wrap_flood_delays_2_1_0': (3, 128, 142, 4, [2, 1, 0], None),
            'mesh_4_wrap_flood_delays_2_0': (4, 128, 142, 4, [2, 0, 2, 0], None),
            'mesh_4_wrap_flood_capacity_9': (4, 9, 24, 4, None, None),
            'mesh_4_wrap_flood_couch_2x2': (4, 128, 142, 4, None, [2, 2])}
NAMES = tuple(PROFILES)
# The family's default window; each profile carries its own in PROFILES[name][3].
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


def build(binary, observe, players, capacity, rounds, window=WINDOW, delays=None, layout=None):
    """Each machine advances one frame per round until the starved frontier
    caps it at confirmed + window, then stalls silently; the builder models
    that cap explicitly, derives each step's payload from the modeled frame and
    re-verifies the model against every observed trace, so a wrong model fails
    the build instead of shipping an inconsistent schedule. Heterogeneous
    per-peer construction delays stamp each machine's own early samples without
    changing the one-frame-per-round advance the model tracks. An explicit
    layout gives machines several local slots: steps address one slot, a
    machine's advance happens on the op that completes its row, and every slot
    of a machine derives its bytes from that machine's modeled frame."""
    scenario = {'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': window, 'operations': []}
    if layout is not None and (type(layout) is not list or len(layout) < 2
                               or any(type(size) is not int or size < 1 for size in layout)
                               or sum(layout) != players):
        # Fail with the grammar's own rejection before any machine indexing can
        # index an empty or overfull machine list.
        raise ValueError('wrap witness profile layout')
    if layout is None:
        # Only solo meshes carry the explicit lifecycle section: the shared grammar
        # refuses lifecycle with an explicit layout, and the engines' omitted-section
        # defaults (quality/keepalive 100 s, disconnect timeout 100 s, notify 50 s)
        # are the same inert no-timer-fires shape these values pin.
        scenario['lifecycle'] = {'quality_us': 100000000, 'keepalive_us': 100000000, 'notify_us': 5000000,
                                 'timeout_us': 10000000, 'checksum_interval': 0, 'divergent_peer': -1}
    if capacity != 128:
        scenario['queue_capacity'] = capacity
    if delays is not None:
        scenario['delays'] = list(delays)
    if layout is not None:
        scenario['layout'] = list(layout)
    now = 0; latest = None; held = []; delivered = set()
    machines = []
    start = 0
    for size in (layout if layout is not None else [1] * players):
        machines.append(list(range(start, start + size))); start += size
    owner = [machine for machine, slots in enumerate(machines) for _ in slots]
    modeled = [0] * len(machines)

    def append(kind, **kwargs):
        nonlocal now
        now += 1
        scenario['operations'].append(dict(kind=kind, now_us=now, **kwargs))

    def see():
        nonlocal latest
        latest = observe(binary, scenario)
        for machine in range(len(machines)):
            record = next((r for r in reversed(latest['records']) if r['peer'] == machine), None)
            if record is not None and record['frame_after'] - modeled[machine] not in (0, 1):
                raise ValueError(f'wrap witness frame model diverged on machine {machine}: trace '
                                 f'{record["frame_after"]} modeled {modeled[machine]}')

    def step(slot):
        # The submitted sample belongs to the owning machine's current frame (delay
        # zero), so bytes derived from the modeled frame keep every repeated
        # stalled sample identical while varying across confirmed frames; every
        # slot of one machine shares that frame because a multi-local machine
        # samples one row per confirmed frame.
        machine = owner[slot]
        append('step', peer=slot, bytes=((modeled[machine] + 1) * (slot + 1) * 17 % 256 ** 4).to_bytes(4, 'little').hex())

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
        for slots in machines:
            record = next((r for r in reversed(latest['records']) if r['peer'] == owner[slots[0]]), None) if latest else None
            modeled[owner[slots[0]]] = record['frame_after'] if record else 0
            for slot in slots:
                step(slot)
    see()
    for packet in (p for p in latest['packets'] if p['id'] not in delivered):
        deliver(packet['id'])
    for slots in machines:
        append('poll', peer=slots[0])
    see()
    validate_scenario(scenario)
    return scenario


def evidence(value, scenario):
    """Require, per machine: the wrapped confirmation, a withheld-stretch
    prediction, a silent stall and the deep flood correction; plus the single
    burst delivery run and the duplicates."""
    players = scenario['players']
    capacity = scenario.get('queue_capacity', 128)
    delays = scenario.get('delays')
    layout = scenario.get('layout')
    machines = len(layout) if layout is not None else players
    if not any(spec[0] == players and spec[1] == capacity and spec[3] == scenario['max_prediction']
               and spec[4] == delays and spec[5] == layout for spec in PROFILES.values()):
        raise ValueError('wrap witness profile')
    if scenario['input_delay'] != 0:
        raise ValueError('wrap witness profile')
    counts = {'correction_rows': 0, 'burst_delivers': 0, 'duplicate_deliveries': 0}
    # Differential evidence is per machine: records address machines, so an
    # explicit layout floors its witnesses over machines, not slots.
    # Static schedule shape: at least two packets are delivered twice, and the
    # release run — the deliver run that ends at the last duplicated
    # re-delivery — carries at least the withheld stretch's own input share
    # (one input flight per machine for every withheld round but the first).
    run = 0; seen = set()
    for op in scenario['operations']:
        if op['kind'] != 'deliver':
            run = 0
            continue
        run += 1
        if op['packet'] in seen:
            counts['duplicate_deliveries'] += 1
            counts['burst_delivers'] = run
        seen.add(op['packet'])
    if counts['duplicate_deliveries'] < 2:
        raise ValueError('wrap witness missing duplicate delivery')
    if counts['burst_delivers'] < machines * (FLOOD_ROUNDS - 1):
        raise ValueError('wrap witness missing burst run')
    # Differential evidence: every machine predicted through the starved
    # stretch and stalled silently at the limit, the release re-runs that
    # stretch from one LOAD with confirmed rows, and every peer's confirmed
    # frontier passes its ring's capacity.
    boundaries = [set() for _ in range(machines)]
    pending = [0] * machines
    stalls = [0] * machines
    corrections = [0] * machines
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
                corrections[record['peer']] = max(corrections[record['peer']], run)
            else:
                run = 0
    counts = {'pending_advances': pending, 'silent_stalls': stalls, 'correction_rows': corrections,
              'burst_delivers': counts['burst_delivers'], 'duplicate_deliveries': counts['duplicate_deliveries'],
              'confirmed_boundaries': [len(frames) for frames in boundaries]}
    if min(pending) < 1:
        raise ValueError('wrap witness missing pending advances')
    if min(stalls) < 1:
        raise ValueError('wrap witness missing silent stalls')
    if min(corrections) < CORRECTION_MIN:
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
    # One machine's LOAD disappears while every aggregate stays large: the
    # correction floor must hold on each machine's own healed run.
    unhealed = deepcopy(value)
    for record in unhealed['records']:
        if record['peer'] == 1:
            record['requests'] = [q for q in record['requests'] if q['kind'] != 'load']
    mutants['one_peer_correction_hidden'] = (unhealed, 'wrap witness missing flood correction')
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
