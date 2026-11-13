"""The tests/unit/test_rollback.gd::global_floor schedule as oracle scenario data.

The generator encodes the schedule's construction semantics: which receipts each
frame delivers, which boundary operations exercise the floor (the refused
above-floor add, retained floor repeats, the stale floor after the advance), and
the expected accept flag every implementation must report. It also simulates the
true input history independently, so the contract can compare confirmed canonical
states against uninterrupted original inputs rather than trusting either engine.
"""
import json

UPSTREAM_REVISION = 'd124c89080004d96971a629bb0427056ee1805e3'
PLAYERS = 3
MAX_PREDICTION = 4
QUEUE_CAPACITY = 9
INPUT_WIDTH = 1
INPUT_DELAY = 0
ADVANCE_FRAMES = 41


def value(player, frame):
    return (frame * 17 + player * 7 + 1) & 255


def delayed_local(frame):
    return value(0, frame) if frame < 20 else value(0, max(19, frame - 2))


def state_bytes(frame, rng, pending, total):
    return frame.to_bytes(4, 'little') + rng.to_bytes(4, 'little') + pending.to_bytes(4, 'little') + total.to_bytes(4, 'little')


def simulate(state, values):
    """One deterministic frame of the rollback test game over packed state bytes."""
    frame, rng, pending, total = (int.from_bytes(state[index * 4:(index + 1) * 4], 'little') for index in range(4))
    rng = (rng * 1664525 + 1013904223) & 4294967295
    total = (total + pending + (rng & 255)) & 4294967295
    pending = sum((player + 1) * byte for player, byte in enumerate(values))
    return state_bytes(frame + 1, rng, pending, total)


def baseline_states():
    """Canonical state after each confirmed frame, from true inputs only."""
    state = state_bytes(0, 8173, 0, 0)
    states = [state]
    for frame in range(ADVANCE_FRAMES - 1):
        state = simulate(state, [delayed_local(frame), value(1, frame), value(2, frame)])
        states.append(state)
    return states


def hex_input(byte):
    return f'{byte:02x}'


def scenario():
    """Operations for the global-floor schedule; receive/submit/delay carry expected results."""
    operations = []
    delivered = [-1, -1, -1]

    def receive(player, frame, expected):
        operations.append({'kind': 'receive', 'player': player, 'frame': frame,
                           'bytes': hex_input(value(player, frame)), 'accepted': expected})

    for frame in range(ADVANCE_FRAMES):
        targets = [-1, frame - 1 if frame < 10 else (8 if frame < 12 else frame + 5), frame - 3 if frame < 40 else 39]
        for player in (1, 2):
            while delivered[player] < targets[player]:
                delivered[player] += 1
                receive(player, delivered[player], True)
        floor = max(0, frame - 4)
        if frame >= 12:
            # One row above the fast queue's pinned frontier: the ring cannot reclaim past the floor.
            receive(1, delivered[1] + 1, False)
            # Retained floor repeats stay readable through the side slot before the advance.
            receive(1, floor, True)
            receive(2, floor, True)
        if frame == 20:
            operations.append({'kind': 'delay', 'player': 0, 'value': 2, 'ok': True})
        operations.append({'kind': 'submit', 'player': 0, 'frame': frame,
                           'bytes': hex_input(value(0, frame)), 'accepted': True})
        operations.append({'kind': 'observe'})
        operations.append({'kind': 'advance'})
        operations.append({'kind': 'observe'})
        if frame >= 12:
            # The completion discard released the old floor; the repeat is now below the new floor.
            receive(1, floor, False)
    return {
        'format': 1,
        'upstream_revision': UPSTREAM_REVISION,
        'players': PLAYERS,
        'max_prediction': MAX_PREDICTION,
        'queue_capacity': QUEUE_CAPACITY,
        'input_width': INPUT_WIDTH,
        'input_delay': INPUT_DELAY,
        'operations': operations,
    }


def bundle():
    return {'scenario': scenario(), 'baseline': [state.hex() for state in baseline_states()]}


def validate_bundle(data):
    if not isinstance(data, dict) or set(data) != {'scenario', 'baseline'}:
        raise ValueError('floor bundle must hold scenario and baseline')
    scenario_data = json.loads(json.dumps(data['scenario']))
    expected = scenario()
    if scenario_data != expected:
        raise ValueError('floor bundle scenario must be the canonical global-floor schedule')
    baseline = data['baseline']
    states = baseline_states()
    if not isinstance(baseline, list) or len(baseline) != len(states) or any(
            not isinstance(item, str) or len(item) != 32 or any(character not in '0123456789abcdef' for character in item)
            for item in baseline):
        raise ValueError('floor bundle baseline must hold the canonical state digests')
    if [bytes.fromhex(item) for item in baseline] != states:
        raise ValueError('floor bundle baseline states diverge from the independent simulation')
    return data
