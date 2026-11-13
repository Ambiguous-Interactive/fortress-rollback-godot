"""Exact comparison and independent validation for the sync-floor oracle traces.

Both engines must produce identical operation records for the canonical
global-floor schedule. Beyond trace equality, this module re-derives the
schedule's receipt frontiers to pin every recorded confirmed frame, checks every
recorded accept flag against the schedule's construction semantics, and compares
the final resimulation of each confirmed frame against canonical states computed
from the true input history alone.
"""
import json

from contract import checksum as state_checksum, fields, hex_bytes, integer

REQUEST_KINDS = {'save', 'load', 'advance'}
INPUT_STATUSES = {'confirmed', 'predicted', 'disconnected'}
RECORD_KINDS = {'receive', 'submit', 'delay', 'observe', 'advance'}


def validate_record(record, source):
    integer(record.get('index'), 0, len(source['operations']) - 1, 'record index')
    kind = record.get('kind')
    if kind not in RECORD_KINDS:
        raise ValueError(f'unknown floor record kind {kind}')
    operation = source['operations'][record['index']]
    if kind != operation['kind']:
        raise ValueError(f'record {record["index"]} kind {kind} does not match scheduled {operation["kind"]}')
    if kind in ('receive', 'submit'):
        fields(record, 'index kind player frame bytes accepted' + (' scheduled' if kind == 'submit' else ''), f'{kind} record')
        integer(record['player'], 0, source['players'] - 1, 'record player')
        integer(record['frame'], 0, 2147483647, 'record frame')
        hex_bytes(record['bytes'], source['input_width'], 'record bytes')
        if (record['player'], record['frame'], record['bytes']) != (operation['player'], operation['frame'], operation['bytes']):
            raise ValueError(f'record {record["index"]}: receipt identity does not match the scheduled operation')
        if record['accepted'] is not operation['accepted']:
            raise ValueError(f'record {record["index"]}: accepted {record["accepted"]} violates the scheduled expectation')
        if kind == 'submit':
            integer(record['scheduled'], 0, 2147483647, 'record scheduled frame')
            if record['scheduled'] != record['frame'] + _local_delay(source, record['frame']):
                raise ValueError(f'record {record["index"]}: submit scheduling violated')
    elif kind == 'delay':
        fields(record, 'index kind player value ok frame_delay last_added', 'delay record')
        integer(record['player'], 0, source['players'] - 1, 'record player')
        integer(record['value'], 1, source['queue_capacity'] - 1, 'record delay value')
        if record['ok'] is not True:
            raise ValueError(f'record {record["index"]}: delay raise must succeed')
        integer(record['frame_delay'], 0, source['queue_capacity'] - 1, 'record frame_delay')
        integer(record['last_added'], 0, 2147483647, 'record last_added')
    elif kind == 'observe':
        fields(record, 'index kind floor players', 'observe record')
        integer(record['floor'], 0, 2147483647, 'record floor')
        if record['floor'] != max(0, _current_frame(source, record['index']) - source['max_prediction']):
            raise ValueError(f'record {record["index"]}: observed floor is not the global rollback floor')
        players = record['players']
        if not isinstance(players, list) or len(players) != source['players']:
            raise ValueError('observe record must observe every player')
        for player, observed in enumerate(players):
            fields(observed, 'range confirmed_floor retained_floor', 'observation')
            span = observed['range']
            if span is not None and (not isinstance(span, list) or len(span) != 2
                                     or any(not isinstance(item, int) or item < 0 for item in span) or span[0] > span[1]):
                raise ValueError(f'observation {player}: retained range malformed')
            for edge in ('confirmed_floor', 'retained_floor'):
                if observed[edge] is not None:
                    hex_bytes(observed[edge], source['input_width'], f'observation {player} {edge}')
            if observed['retained_floor'] is not None and observed['confirmed_floor'] is None:
                raise ValueError(f'observation {player}: recoverable floor row without a confirmed read')
    else:
        fields(record, 'index kind advanced confirmed_frame requests', 'advance record')
        if record['advanced'] is not True:
            raise ValueError(f'record {record["index"]}: the schedule must advance every frame')
        integer(record['confirmed_frame'], -1, 2147483647, 'record confirmed frame')
        requests = record['requests']
        if not isinstance(requests, list) or not requests:
            raise ValueError('advance record must hold at least one request')
        for request in requests:
            fields(request, 'kind frame state_bytes checksum inputs', 'request record')
            if request['kind'] not in REQUEST_KINDS:
                raise ValueError(f'unknown request kind {request["kind"]}')
            integer(request['frame'], 0, 2147483647, 'request frame')
            state = hex_bytes(request['state_bytes'], 16, 'request state_bytes')
            if request['checksum'] != state_checksum(state):
                raise ValueError('request checksum does not bind the recorded state bytes')
            inputs = request['inputs']
            if not isinstance(inputs, list) or len(inputs) != (0 if request['kind'] != 'advance' else source['players']):
                raise ValueError('request inputs must name every player exactly once on advance')
            for player, row in enumerate(inputs):
                fields(row, 'player bytes status', 'input row')
                if row['player'] != player:
                    raise ValueError('input rows must be ascending dense slots')
                hex_bytes(row['bytes'], source['input_width'], 'input bytes')
                if row['status'] not in INPUT_STATUSES:
                    raise ValueError(f'unknown input status {row["status"]}')


def _local_delay(source, frame):
    """The local player's configured delay after the schedule's single raise."""
    return 2 if frame >= 20 else 0


def _current_frame(source, index):
    """Session frame the operation at `index` runs in, from the advance count before it."""
    return sum(1 for operation in source['operations'][:index] if operation['kind'] == 'advance')


def _frontiers(source):
    """Receipt frontiers the schedule delivers, per operation index."""
    delivered = [-1] * source['players']
    frontiers = []
    for operation in source['operations']:
        if operation['kind'] == 'receive':
            delivered[operation['player']] = max(delivered[operation['player']], operation['frame'])
        elif operation['kind'] == 'submit':
            delivered[operation['player']] = operation['frame'] + _local_delay(source, operation['frame'])
        frontiers.append(tuple(delivered))
    return frontiers


def validate_records(trace, source, complete=True):
    """Validate every record's shape, scheduled flag and confirmed frame.

    A prefix trace validates its own records only; complete traces must cover the schedule.
    """
    operations = trace['operations']
    if not isinstance(operations, list) or (complete and len(operations) != len(source['operations'])):
        raise ValueError('floor trace must record every scheduled operation')
    if len(operations) > len(source['operations']):
        raise ValueError('floor trace records more operations than the schedule holds')
    frontiers = _frontiers(source)
    for position, record in enumerate(operations):
        if record.get('index') != position:
            raise ValueError('floor trace records must follow the scheduled order')
        validate_record(record, source)
        if record['kind'] == 'advance':
            # The receipt minimum covers every slot; a slot that never received a row
            # pins the frontier at -1 exactly like the engines' own bookkeeping.
            expected = min(frontiers[record['index']], default=-1)
            if record['confirmed_frame'] != expected:
                raise ValueError(f'record {record["index"]}: confirmed frame {record["confirmed_frame"]} '
                                 f'is not the receipt minimum {expected}')


def validate_confirmed_history(trace, baseline):
    """The final resimulation of every confirmed frame must match the true-input history."""
    last_state = {}
    for record in trace['operations']:
        if record['kind'] == 'advance':
            for request in record['requests']:
                if request['kind'] == 'advance':
                    last_state[request['frame']] = request['state_bytes']
    for frame, state in enumerate(baseline[1:]):
        recorded = last_state.get(frame)
        if recorded is None:
            raise ValueError(f'no advance record resimulated confirmed frame {frame}')
        if recorded != state.hex():
            raise ValueError(f'confirmed frame {frame} diverged from the independent original-input history')


def validate_against_scenario(trace, source, baseline):
    validate_records(trace, source)
    validate_confirmed_history(trace, baseline)


def compare(rust, godot, source, baseline):
    """Validate both traces independently, then require exact record equality."""
    validate_against_scenario(rust, source, baseline)
    validate_against_scenario(godot, source, baseline)
    return compare_records(rust, godot, source)


def compare_records(rust, godot, source):
    """Require exact record equality between independently produced traces."""
    for index, (pinned, produced) in enumerate(zip(rust['operations'], godot['operations'])):
        if pinned != produced:
            keys = sorted(set(pinned) | set(produced))
            detail = next((key for key in keys if pinned.get(key) != produced.get(key)), '?')
            raise ValueError(f'sync floor: operation {index} diverges in {detail}')
    if rust == godot:
        return rust
    raise ValueError('sync floor: trace envelope mismatch')


def first_acceptance_divergence(clean, mutant):
    """Index of the first operation whose acceptance result the mutant flips."""
    for index, (pinned, produced) in enumerate(zip(clean['operations'], mutant['operations'])):
        if pinned.get('accepted') != produced.get('accepted') or pinned.get('ok') != produced.get('ok'):
            return index
    if len(clean['operations']) != len(mutant['operations']):
        return min(len(clean['operations']), len(mutant['operations']))
    return None


def read_artifact(path):
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)
