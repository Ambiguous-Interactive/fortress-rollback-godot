"""Require the exact prediction boundary in the two-peer stall schedules."""
from copy import deepcopy


CASES = {
    f'mesh_2_window_{window}_stall' if window != 4 else 'mesh_2_stall': window
    for window in range(2, 9)
}


def evidence(trace, scenario, window, *, source=False):
    """Check boundary coverage after the general canonical and packet validators."""
    if (scenario['max_prediction'], scenario['players'], scenario['input_delay']) != (window, 2, 0):
        raise ValueError('prediction witness profile')
    operations = scenario['operations']
    records = trace['records']
    steps = [record for op, record in zip(operations, records) if op['kind'] == 'step' and op['peer'] == 0]
    if len(steps) < window + 2:
        raise ValueError('prediction witness missing blocked calls')
    last, staged, retry = steps[window - 1:window + 2]
    if (last['frame_before'], last['frame_after'], last['confirmed_frame'], last['error']) != (window - 1, window, -1, None):
        raise ValueError('prediction witness missed last admissible advance')
    advances = [request for request in last['requests'] if request['kind'] == 'advance']
    if len(advances) != 1 or advances[0]['frame'] != window - 1 or advances[0]['inputs'][1]['status'] != 'predicted':
        raise ValueError('prediction witness missed last speculative row')

    # The source can successfully return a SAVE while declining to advance.
    stall_code = None if source else 'PREDICTION_STALL'
    for record in (staged, retry):
        if (record['frame_before'], record['frame_after'], record['confirmed_frame'], record['error']) != (window, window, -1, stall_code):
            raise ValueError('prediction witness missed unconfirmed cap')
        if any(request['kind'] != 'save' for request in record['requests']):
            raise ValueError('prediction witness did work beyond the unconfirmed cap')
    staged_op, retry_op = (operations[record['index']] for record in (staged, retry))
    if staged_op['bytes'] != retry_op['bytes']:
        raise ValueError('prediction witness changed the stalled sample')
    if len(staged['outgoing']) != 1:
        raise ValueError('prediction witness missed staged publication')
    packet_id = staged['outgoing'][0]
    packet = trace['packets'][packet_id]
    payload = packet['semantic']
    if ((packet['from'], packet['to'], payload['kind']) != (0, 1, 'input')
            or payload['players'] != [0]
            or payload['start_frame'] + len(payload['frames']) - 1 != window
            or payload['frames'][-1] != staged_op['bytes']):
        raise ValueError('prediction witness missed staged publication')
    if retry['outgoing']:
        raise ValueError('prediction witness repeated stalled publication')

    resumed = [record for record in steps[window + 2:] if record['confirmed_frame'] >= 0]
    if len(resumed) < 2:
        raise ValueError('prediction witness missed confirmation recovery')
    repair, continued = resumed[:2]
    if (repair['frame_before'], repair['frame_after'], repair['confirmed_frame'], repair['error']) != (window, window, 0, stall_code):
        raise ValueError('prediction witness missed frame-zero-confirmed cap')
    if repair['outgoing']:
        raise ValueError('prediction witness repeated repaired stalled publication')
    rollback = [(request['kind'], request['frame']) for request in repair['requests'] if request['kind'] != 'save']
    expected_rollback = [('load', 0), *(('advance', frame) for frame in range(window))]
    if rollback != expected_rollback:
        raise ValueError('prediction witness missed ordered cap repair')
    first_remote = next((op['bytes'] for op in operations[:repair['index']] if op['kind'] == 'step' and op['peer'] == 1), None)
    corrected = next(request for request in repair['requests'] if request['kind'] == 'advance')
    if corrected['inputs'][1] != {'player': 1, 'status': 'confirmed', 'bytes': first_remote}:
        raise ValueError('prediction witness missed original remote sample')
    if (continued['frame_before'], continued['frame_after'], continued['confirmed_frame'], continued['error']) != (window, window + 1, 1, None):
        raise ValueError('prediction witness missed first resumed advance')
    forward = [request for request in continued['requests'] if request['kind'] == 'advance' and request['frame'] == window]
    original = {'player': 0, 'status': 'confirmed', 'bytes': staged_op['bytes']}
    if len(forward) != 1 or forward[0]['inputs'][0] != original:
        raise ValueError('prediction witness did not apply the original staged sample once')
    if continued['outgoing']:
        raise ValueError('prediction witness repeated resumed publication')
    confirmed = [next(record['confirmed_frame'] for record in reversed(records) if record['peer'] == peer) for peer in (0, 1)]
    if min(confirmed) < window - 1:
        raise ValueError('prediction witness left the withheld prefix unconfirmed')
    return {
        'window': window, 'last_allowed': last['index'], 'blocked': staged['index'], 'retry': retry['index'],
        'staged_packet': packet_id, 'repair': repair['index'], 'repair_rows': window, 'continued': continued['index'],
        'confirmed': confirmed,
    }


def controls(trace, scenario, window):
    marks = evidence(trace, scenario, window)
    cases = (
        ('unconfirmed_cap_advanced', 'blocked', 'prediction witness missed unconfirmed cap', {'frame_after': window + 1}),
        ('stalled_retry_published', 'retry', 'prediction witness repeated stalled publication', {'outgoing': [marks['staged_packet']]}),
        ('confirmed_cap_advanced', 'repair', 'prediction witness missed frame-zero-confirmed cap', {'frame_after': window + 1}),
        ('cap_repair_load_removed', 'repair', 'prediction witness missed ordered cap repair',
         {'requests': [request for request in trace['records'][marks['repair']]['requests'] if request['kind'] != 'load']}),
    )
    rejected = []
    for name, mark, expected, mutation in cases:
        changed = deepcopy(trace)
        changed['records'][marks[mark]].update(mutation)
        try:
            evidence(changed, scenario, window)
        except ValueError as error:
            if str(error) != expected:
                raise ValueError(f'{name}: wrong prediction diagnostic: {error}') from error
        else:
            raise ValueError(f'prediction control survived: {name}')
        rejected.append(name)
    return rejected
