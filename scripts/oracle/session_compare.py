"""Compare independently executed production-session traces with pinned Rust requests."""
import copy
import json
import re

from contract import fields, integer, validate_trace

PREFIX = 'FORTRESS_ORACLE_SESSION_RESULT '


def error_category(error, production, player=None, players=None):
    if error is None:
        return None
    if production:
        if error in ('INVALID_PLAYER', 'MISSING_LOCAL_INPUT'):
            return error
    elif isinstance(error, str):
        if error == 'InvalidRequestStructured { kind: MissingLocalInput }':
            return 'MISSING_LOCAL_INPUT'
        match = re.fullmatch(
            r'InvalidRequestStructured \{ kind: InvalidLocalPlayerHandle \{ handle: PlayerHandle\((0|[1-9][0-9]*)\), '
            r'num_players: (0|[1-9][0-9]*) \} \}', error)
        if match is not None:
            handle, count = (int(value) for value in match.groups())
            if 2 <= count <= 8 and count <= handle <= 255:
                if (player is None or player == handle) and (players is None or players == count):
                    return 'INVALID_PLAYER'
    raise ValueError('session: unrecognized error projection: ' + str(error))


def compare_result(stdout, stderr, expected):
    if any(marker in stdout + stderr for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
        raise ValueError('session: Godot engine error')
    records = [line[len(PREFIX):] for line in stdout.splitlines() if line.startswith(PREFIX)]
    if len(records) != 1:
        raise ValueError('session: missing or duplicate completion')
    value = json.loads(records[0])
    fields(value, 'format complete passed engine_version errors trace', 'session result')
    integer(value['format'], 1, 1, 'session result format')
    if value['complete'] is not True or value['passed'] is not True or value['errors'] != []:
        raise ValueError('session: execution failed or incomplete')
    if not isinstance(value['engine_version'], str) or not value['engine_version']:
        raise ValueError('session: missing engine identity')
    scenario = expected['scenario']
    validate_trace(expected, scenario)
    # Validate independently before equality: bool/float aliases must not pass.
    actual = validate_trace(value['trace'], scenario)
    for index, (observed, reference) in enumerate(zip(actual['operations'], expected['operations'])):
        source = scenario['operations'][index]
        if error_category(observed['error'], True) != error_category(
                reference['error'], False, source.get('player'), scenario['players']):
            raise ValueError(f'session operation {index}: error category mismatch')
        for field in ('index', 'kind', 'result', 'frame_before', 'frame_after', 'requests', 'events'):
            if observed[field] != reference[field]:
                raise ValueError(f'session operation {index}: {field} mismatch')
    if actual['final_state'] != expected['final_state']:
        raise ValueError('session: final canonical state mismatch')
    return value


def negative_controls(value, expected):
    """Production evidence cannot pass after omitted callbacks or altered input/state."""
    advance = next(op for op in value['trace']['operations'] if op['requests'])
    operation_index = advance['index']
    request_index = next(i for i, request in enumerate(advance['requests']) if request['kind'] == 'advance')
    mutations = {
        'missing_completion': lambda x: x.update(complete=False),
        'missing_operation': lambda x: x['trace']['operations'].pop(),
        'missing_request': lambda x: x['trace']['operations'][operation_index]['requests'].pop(request_index),
        'wrong_input_status': lambda x: x['trace']['operations'][operation_index]['requests'][request_index]['inputs'][0].update(status='predicted'),
        'unknown_error': lambda x: x['trace']['operations'][operation_index].update(result='error', error='BUSY', requests=[], frame_after=0),
        'wrong_final_state': lambda x: x['trace']['final_state'].update(checksum='0' * 32),
    }
    for name, mutate in mutations.items():
        changed = copy.deepcopy(value)
        mutate(changed)
        try:
            compare_result(PREFIX + json.dumps(changed), '', expected)
        except ValueError as error:
            if name == 'wrong_input_status' and f'operation {operation_index}: requests mismatch' not in str(error):
                raise ValueError('session status control failed outside request comparison') from error
        else:
            raise ValueError('session negative control accepted: ' + name)
    return list(mutations)
