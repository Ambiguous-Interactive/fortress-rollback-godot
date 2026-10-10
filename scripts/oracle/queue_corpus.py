"""Fixed and exhaustive bounded queue operations, with explicit differential scope."""
import itertools
from queue_contract import REVISION


def bundle():
    cases = []

    def case(name, operations, capacity=8, width=4, player=0):
        cases.append({'name': name, 'capacity': capacity, 'input_width': width, 'player': player, 'operations': operations})

    def add(frame, value=1, width=4):
        return {'kind': 'add', 'frame': frame, 'bytes': value.to_bytes(width, 'little').hex()}

    def read(frame):
        return {'kind': 'read', 'frame': frame}

    def confirmed(frame):
        return {'kind': 'confirmed', 'frame': frame}

    def discard(frame):
        return {'kind': 'discard', 'frame': frame}

    def delay(value):
        return {'kind': 'delay', 'value': value}

    reset = {'kind': 'reset'}
    for player in range(8):
        case(f'prediction-slot-{player}', [read(3), add(0, 0), read(3), add(1, 7), read(1),
             confirmed(1), add(2, 9), read(3), reset, read(1), read(3), add(3, 9), read(3)], player=player)
    for width in (1, 4, 8, 32):
        operations = []
        for frame in range(40):
            operations += [add(frame, frame + 1, width), read(frame), discard(frame)]
            if frame >= 4:
                operations += [confirmed(frame - 4), read(frame - 4), reset]
        case(f'wrap-width-{width}', operations, capacity=4, width=width)
    for initial in range(4):
        case(f'delay-{initial}', [delay(initial), add(0, 11), confirmed(0), confirmed(initial),
             read(initial + 2), delay(4), add(1, 12), delay(1), delay(8), reset, read(4),
             discard(100), confirmed(0)], capacity=8)
    case('matching-episode', [add(0, 4), read(3), add(1, 4), read(0), add(2, 4),
         add(3, 4), read(3), read(4), add(4, 5), read(4), reset, read(4)])
    case('initial-skipped', [add(2, 9), confirmed(0), confirmed(1), read(2), add(4), add(3),
         add(3), add(3, 2), read(3)])
    case('capacity-setter-atomic', [add(0), add(1, 2), delay(3), confirmed(2), read(1),
         discard(1), delay(2), confirmed(2), confirmed(3), add(2, 3), reset, read(3)], capacity=4)
    # Exhaust every depth-three sequence after a valid initial add, avoiding the
    # documented upstream partial initial-gap insertion defect.
    alphabet = [add(1, 2), add(0, 3), read(0), read(2), delay(1), discard(2), reset]
    for capacity in (2, 3):
        for index, sequence in enumerate(itertools.product(alphabet, repeat=3)):
            case(f'exhaust-{capacity}-{index}', [add(0)] + list(sequence) + [
                confirmed(0), confirmed(1), confirmed(2), read(2), reset, read(0)], capacity=capacity)
    # Preserve the original 705 cases verbatim above. Reclaiming needs its own
    # asymmetric local mismatch/global floor and physical/recoverable witnesses.
    def reclaim(frame, floor, value=7):
        return {'kind': 'add_reclaim', 'frame': frame, 'floor': floor, 'bytes': value.to_bytes(4, 'little').hex()}

    def retained(frame):
        return {'kind': 'retained', 'frame': frame}

    def reclaim_delay(value, floor):
        return {'kind': 'delay_reclaim', 'value': value, 'floor': floor}

    for capacity in (3, 4, 7):
        operations = [add(0, 7), add(1, 7), read(capacity)]
        operations += [reclaim(frame, 1, frame + 8) for frame in range(2, capacity + 2)]
        operations += [retained(0), retained(1), confirmed(1), read(1), reclaim(capacity + 2, 1),
                       reset, read(capacity + 2), read(1), discard(100), retained(1), reset,
                       discard(100), retained(1), confirmed(capacity), retained(capacity)]
        for frame in range(capacity + 2, capacity * 6):
            operations += [reclaim(frame, frame - capacity, frame), retained(frame - capacity),
                           retained(frame), confirmed(frame - capacity - 1)]
        case(f'reclaim-asymmetric-wrap-{capacity}', operations, capacity=capacity)
        operations = [add(frame, 7) for frame in range(capacity)]
        operations += [read(capacity + 1), reclaim_delay(2, 0), retained(0), confirmed(capacity),
                       read(0), reclaim_delay(2, 1), retained(1), read(1), delay(1),
                       reclaim(capacity, 1), reclaim(capacity, 2), retained(2), retained(1),
                       reclaim(capacity + 1, 5), confirmed(2), retained(2), reset, read(2)]
        case(f'reclaim-delay-atomic-{capacity}', operations, capacity=capacity)
    return {'format': 1, 'upstream_revision': REVISION, 'cases': cases}
