"""Bounded deterministic sync-test scenarios; no session algorithm lives here."""
import struct

from contract import REVISION


def scenarios():
    for players in range(2, 9):
        for distance, delay in ((0, 0), (2, 2), (7, 7)):
            operations = [{'kind': 'events'}, {'kind': 'advance'},
                          {'kind': 'input', 'player': 255, 'bytes': '00000000'}]
            for frame in range(20):
                if frame in (4, 9):
                    operations.append({'kind': 'advance'})
                for player in range(players):
                    # Overflow, zeros and distinct player histories expose wrong order and restore.
                    value = (0xffffffff, 0, (frame + 1) * (player + 1))[frame % 3]
                    operations.append({'kind': 'input', 'player': player,
                                       'bytes': struct.pack('<I', value).hex()})
                operations.extend([{'kind': 'advance'}, {'kind': 'events'}])
            yield f'players-{players}-distance-{distance}-delay-{delay}', {
                'format': 1, 'upstream_revision': REVISION, 'players': players,
                'input_width': 4, 'check_distance': distance, 'input_delay': delay,
                'operations': operations}


def expected_final(scenario):
    """Independent offline game from submitted histories, for the fixed corpus only."""
    players, delay = scenario['players'], scenario['input_delay']
    histories = [[] for _ in range(players)]
    for operation in scenario['operations']:
        if operation['kind'] == 'input' and operation['player'] < players:
            histories[operation['player']].append(struct.unpack('<I', bytes.fromhex(operation['bytes']))[0])
    # Corpus has one complete sample per player for each of twenty successful frames.
    if any(len(history) != 20 for history in histories):
        raise ValueError('independent oracle requires the complete fixed corpus history')
    return struct.pack('<i' + 'I' * players, 20,
                       *(sum(history[:20 - delay]) & 0xffffffff for history in histories)).hex()


def validate_history(trace, scenario):
    """Compare every request to independently reconstructed submitted frame prefixes."""
    players, delay = scenario['players'], scenario['input_delay']
    histories = [[] for _ in range(players)]
    for operation in scenario['operations']:
        if operation['kind'] == 'input' and operation['player'] < players:
            histories[operation['player']].append(operation['bytes'])
    if any(len(history) != 20 for history in histories):
        raise ValueError('submitted history is not the complete fixed corpus')
    scheduled = [['00000000'] * delay + history for history in histories]
    states = []
    totals = [0] * players
    for frame in range(21):
        states.append(struct.pack('<i' + 'I' * players, frame, *totals).hex())
        if frame < 20:
            totals = [(total + struct.unpack('<I', bytes.fromhex(history[frame]))[0]) & 0xffffffff
                      for total, history in zip(totals, scheduled)]
    for operation in trace['operations']:
        for request in operation['requests']:
            frame = request['frame']
            state_frame = frame + int(request['kind'] == 'advance')
            if state_frame >= len(states) or request['state_bytes'] != states[state_frame]:
                raise ValueError(f'submitted history: canonical prefix mismatch at frame {state_frame}')
            if request['kind'] == 'advance':
                for player, item in enumerate(request['inputs']):
                    if item['bytes'] != scheduled[player][frame] or item['status'] != 'confirmed':
                        raise ValueError(f'submitted history: input mismatch at frame {frame}, player {player}')
    if trace['final_state']['bytes'] != states[20]:
        raise ValueError('submitted history: final state mismatch')
    return trace
