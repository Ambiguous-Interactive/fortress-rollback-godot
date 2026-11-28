"""Require the exact prediction boundary in the two-peer stall schedules."""
from copy import deepcopy


WINDOWS = range(2, 9)
CASES = {
    f'mesh_2_window_{window}_stall' if window != 4 else 'mesh_2_stall': window
    for window in WINDOWS
}


def require_complete_windows(windows):
    if sorted(windows) != list(WINDOWS):
        raise ValueError('prediction witness inventory must cover each window from 2 through 8 once')


def _input_row(packet, sender, frame):
    payload = packet['semantic']
    if ((packet['from'], packet['to'], payload['kind']) != (sender, 1 - sender, 'input')
            or payload['players'] != [sender]):
        return None
    offset = frame - payload['start_frame']
    return payload['frames'][offset] if 0 <= offset < len(payload['frames']) else None


def _received_frame_zero(trace, operations, after_retry, before_repair, window):
    records = trace['records']
    packets = trace['packets']
    submission = next((index for index, op in enumerate(operations)
                       if op['kind'] == 'step' and op['peer'] == 1), None)
    if submission is None or not after_retry < submission < before_repair:
        raise ValueError('prediction witness missed peer-one frame-zero step after retry')
    submitted_bytes = operations[submission]['bytes']
    origin = records[submission]
    if (origin['frame_before'], origin['frame_after'], origin['error']) != (0, 1, None):
        raise ValueError('prediction witness missed peer-one frame-zero advance')
    emissions = [packet_id for packet_id in origin['outgoing']
                 if _input_row(packets[packet_id], 1, 0) == submitted_bytes]
    if len(emissions) != 1:
        raise ValueError('prediction witness missed original frame-zero publication')
    emission = emissions[0]
    deliveries = [index for index, op in enumerate(operations[:before_repair])
                  if op['kind'] == 'deliver' and op['packet'] == emission]
    if len(deliveries) != 1 or deliveries[0] <= submission:
        raise ValueError('prediction witness missed original frame-zero delivery')
    delivery = deliveries[0]
    delivered = records[delivery]
    if (delivered['peer'], delivered['frame_before'], delivered['frame_after'],
            delivered['confirmed_frame'], delivered['error']) != (0, window, window, 0, None):
        raise ValueError('prediction witness missed receiver confirmation at frame-zero delivery')
    acks = [packet_id for packet_id in delivered['outgoing'] if
            (packets[packet_id]['from'], packets[packet_id]['to'], packets[packet_id]['semantic'])
            == (0, 1, {'kind': 'input_ack', 'ack_frame': 0})]
    if len(acks) != 1:
        raise ValueError('prediction witness missed frame-zero receipt acknowledgement')
    return submitted_bytes, emission, delivery, acks[0]


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
    if (_input_row(packet, 0, window) != staged_op['bytes']
            or payload['start_frame'] + len(payload['frames']) - 1 != window):
        raise ValueError('prediction witness missed staged publication')
    if any(_input_row(packet, 0, window) is not None for packet in trace['packets'][:packet_id]):
        raise ValueError('prediction witness carried the blocked sample before the stall')
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
    first_remote, remote_packet, remote_delivery, remote_ack = _received_frame_zero(
        trace, operations, retry['index'], repair['index'], window)
    rollback = [(request['kind'], request['frame']) for request in repair['requests'] if request['kind'] != 'save']
    expected_rollback = [('load', 0), *(('advance', frame) for frame in range(window))]
    if rollback != expected_rollback:
        raise ValueError('prediction witness missed ordered cap repair')
    corrected = next(request for request in repair['requests'] if request['kind'] == 'advance')
    if corrected['inputs'][1] != {'player': 1, 'status': 'confirmed', 'bytes': first_remote}:
        raise ValueError('prediction witness missed original remote sample')
    if (continued['frame_before'], continued['frame_after'], continued['confirmed_frame'], continued['error']) != (window, window + 1, 1, None):
        raise ValueError('prediction witness missed first resumed advance')
    resumed_requests = [request for request in continued['requests'] if request['kind'] != 'save']
    expected_resume = [('load', 1), *(('advance', frame) for frame in range(1, window + 1))]
    if ([(request['kind'], request['frame']) for request in resumed_requests] != expected_resume
            or continued['requests'][-1]['kind'] != 'advance'):
        raise ValueError('prediction witness missed ordered resumed advance')
    original = {'player': 0, 'status': 'confirmed', 'bytes': staged_op['bytes']}
    if resumed_requests[-1]['inputs'][0] != original:
        raise ValueError('prediction witness did not apply the original staged sample once')
    if continued['outgoing']:
        raise ValueError('prediction witness repeated resumed publication')
    confirmed = [next(record['confirmed_frame'] for record in reversed(records) if record['peer'] == peer) for peer in (0, 1)]
    if min(confirmed) < window - 1:
        raise ValueError('prediction witness left the withheld prefix unconfirmed')
    return {
        'window': window, 'last_allowed': last['index'], 'blocked': staged['index'], 'retry': retry['index'],
        'staged_packet': packet_id, 'repair': repair['index'], 'repair_rows': window, 'continued': continued['index'],
        'remote_packet': remote_packet, 'remote_delivery': remote_delivery, 'remote_ack': remote_ack,
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

    def reject(name, expected, changed_trace, changed_scenario=scenario):
        try:
            evidence(changed_trace, changed_scenario, window)
        except ValueError as error:
            if str(error) != expected:
                raise ValueError(f'{name}: wrong prediction diagnostic: {error}') from error
        else:
            raise ValueError(f'prediction control survived: {name}')
        rejected.append(name)

    for name, mark, expected, mutation in cases:
        changed = deepcopy(trace)
        changed['records'][marks[mark]].update(mutation)
        reject(name, expected, changed)

    early = deepcopy(trace)
    previous_packet = trace['records'][marks['last_allowed']]['outgoing'][0]
    early['packets'][previous_packet]['semantic'] = deepcopy(trace['packets'][marks['staged_packet']]['semantic'])
    reject('blocked_sample_sent_early', 'prediction witness carried the blocked sample before the stall', early)

    missing_delivery = deepcopy(scenario)
    missing_delivery['operations'][marks['remote_delivery']]['packet'] = marks['staged_packet']
    reject('original_frame_zero_delivery_substituted', 'prediction witness missed original frame-zero delivery', trace, missing_delivery)

    over_advance = deepcopy(trace)
    requests = over_advance['records'][marks['continued']]['requests']
    requests.append({**requests[-1], 'frame': window + 1})
    reject('resumed_over_advance', 'prediction witness missed ordered resumed advance', over_advance)
    return rejected
