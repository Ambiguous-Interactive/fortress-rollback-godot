"""Strict projection of actual upstream handshake records, preserving token relationships."""
from copy import deepcopy
from contract import fields, integer
from handshake_schema import transition as validate_transition


def wide(value, width):
    integer(value, 0, (1 << (width * 8)) - 1, 'wide integer')
    return value.to_bytes(width, 'little').hex()


def version(value):
    integer(value, 2, 3, 'semantic version')
    if value not in (2, 3):
        raise ValueError('unmodeled upstream semantic version')
    return {2: 1, 3: 2}[value]


def packet(raw, sender='0100000000000000'):
    fields(raw, 'header body', 'upstream packet')
    fields(raw['header'], 'conn_id flags protocol_version sentinel', 'upstream header')
    integer(raw['header']['protocol_version'], 2, 2, 'header version')
    integer(raw['header']['flags'], 0, 0, 'header flags')
    if type(raw['header']['sentinel']) is not list or len(raw['header']['sentinel']) != 2:
        raise ValueError('header sentinel inventory')
    for byte, expected in zip(raw['header']['sentinel'], [245, 82]):
        integer(byte, expected, expected, 'header sentinel')
    integer(raw['header']['conn_id'], 0, 0xffffffff, 'header connection')
    body = raw['body']
    if len(body) != 1 or next(iter(body)) not in ('SyncRequest', 'SyncReply'):
        raise ValueError('unexpected upstream packet kind')
    kind = next(iter(body)); value = body[kind]
    token = 'random_request' if kind == 'SyncRequest' else 'random_reply'
    fields(value, f'{token} min_compat_version features config config_digest', 'sync body')
    fields(value['config'], 'num_players input_bytes_per_player fps max_prediction desync_interval', 'sync config')
    integer(value[token], 0, 0xffffffff, 'upstream u32 token')
    result = {'kind': 'request' if kind == 'SyncRequest' else 'reply', 'token': wide(value[token], 16),
              'sender': sender, 'connection': wide(raw['header']['conn_id'], 8), 'min_compat_version': version(value['min_compat_version']),
              'features': value['features'], 'config_digest': wide(value['config_digest'], 8)}
    integer(value['features'], 0, 0xffffffff, 'features')
    for key, high in {'num_players': 65535, 'input_bytes_per_player': 65535, 'fps': 0xffffffff, 'max_prediction': 65535, 'desync_interval': 0xffffffff}.items():
        integer(value['config'][key], 0, high, 'config ' + key)
    result.update({{'num_players': 'player_count', 'input_bytes_per_player': 'input_width'}.get(key, key): val
                   for key, val in value['config'].items()})
    return result


def project(raw, scenario):
    fields(raw, 'format complete upstream_revision records', 'upstream result')
    integer(raw['format'], 1, 1, 'upstream format')
    if raw['format'] != 1 or raw['complete'] is not True or raw['upstream_revision'] != 'f13cd5c0f2815926785a395947e18da0dbea0dd8':
        raise ValueError('upstream identity/completion')
    if len(raw['records']) != len(scenario['operations']) + 1:
        raise ValueError('partial upstream operations')
    sent = []; operations = []; expected = []
    local = packet(raw['records'][0]['packets'][0])
    for index, row in enumerate(raw['records']):
        fields(row, 'operation packets transitions events', 'upstream operation')
        if index:
            integer(row['operation'], index - 1, index - 1, 'operation index')
        if row['operation'] != (None if index == 0 else index - 1):
            raise ValueError('operation order')
        if type(row['transitions']) is not list:
            raise ValueError('raw transitions inventory')
        for position, transition in enumerate(row['transitions']):
            validate_transition(transition, index, position)
        if index == 0 and [t.get('action') if type(t) is dict else None for t in row['transitions']] != ['activated', 'begin', 'send_request']:
            raise ValueError('raw initial transition order')
        next_tokens = [t['token'] for t in row['transitions'] if t['action'] == 'send_request']
        if len(next_tokens) > 1:
            raise ValueError('unmodeled multiple requests')
        operation = {'kind': 'begin', 'now_us': 0, 'next_token': next_tokens[0] if next_tokens else ''}
        if index:
            source = scenario['operations'][index - 1]
            operation.update(kind='poll', now_us=source['now_us'])
            if source['kind'] != 'poll':
                message = packet(sent[source['token_index']], '0200000000000000')
                message['kind'] = source['kind'];
                if 'echo' in source:
                    message['token'] = wide(source['echo'], 16)
                message['connection'] = wide(source.get('connection', 77), 8)
                for key, value in source.get('changes', {}).items():
                    target = {'num_players': 'player_count', 'input_bytes_per_player': 'input_width'}.get(key, key)
                    message[target] = version(value) if key == 'min_compat_version' else wide(value, 8) if key == 'config_digest' else value
                operation.update(kind='receive', message=message, source='0300000000000000' if source.get('source') == 'stranger' else '0200000000000000')
        operations.append(operation)
        transitions = []
        for transition_index, transition in enumerate(row['transitions']):
            fields(transition, 'action token disposition state remaining outstanding remote_connection timeout_sent mismatch elapsed_ms', 'upstream transition')
            for key in ('remaining', 'outstanding'):
                integer(transition[key], 0, 128, 'transition ' + key)
            if type(transition['timeout_sent']) is not bool:
                raise ValueError('transition timeout_sent type')
            integer(transition['elapsed_ms'], -1, 10000, 'transition elapsed_ms')
            if transition['action'] == 'activated':
                continue
            normalized = {key: transition[key] for key in ('token', 'disposition', 'state', 'remaining', 'timeout_sent', 'elapsed_ms')}
            normalized.update(action='begin_synchronization' if transition['action'] == 'begin' else transition['action'],
                              token=transition['token'] or '',
                              disposition={'notsynchronizing': 'not_synchronizing', 'alreadyincompatible': 'already_incompatible',
                                           'answeredonly': 'answered_only'}.get(transition['disposition'], transition['disposition'] or ''),
                              outstanding_request_count=transition['outstanding'], remote_connection=transition['remote_connection'] or '',
                              mismatch=transition['mismatch'])
            if normalized['mismatch'].get('field') == 'min_compat_version':
                normalized['mismatch'] = dict(normalized['mismatch'], ours=version(normalized['mismatch']['ours']), theirs=version(normalized['mismatch']['theirs']))
            transitions.append(normalized)
        events = deepcopy(row['events'])
        for event in events:
            event_schema(event)
        for event in events:
            if event['kind'] == 'incompatible' and event['reason']['field'] == 'min_compat_version':
                event['reason'] = dict(event['reason'], ours=version(event['reason']['ours']), theirs=version(event['reason']['theirs']))
        code = 4 if operation.get('source') == '0300000000000000' else 5 if index and scenario['operations'][index - 1].get('connection') == 78 else 0
        expected.append({'code': code, 'transitions': transitions, 'events': events, 'packets': [packet(p) for p in row['packets']]})
        sent.extend(row['packets'])
    return {'format': 1, 'local': local, 'operations': operations}, expected


def compare(actual, expected):
    fields(actual, 'format complete records', 'Godot result')
    integer(actual['format'], 1, 1, 'Godot format')
    if actual['format'] != 1 or actual['complete'] is not True or len(actual['records']) != len(expected):
        raise ValueError('Godot partial completion')
    for index, (record, wanted) in enumerate(zip(actual['records'], expected)):
        fields(record, 'code transitions events packets', 'Godot operation')
        integer(record['code'], 0, 9, 'Godot code')
        transitions = []
        for row in record['transitions']:
            fields(row, 'action token disposition state remaining outstanding_request_count remote_connection timeout_sent mismatch elapsed_ms', 'Godot transition')
            normalized = {key: row[key] for key in ('action', 'token', 'disposition', 'state', 'remaining',
                          'outstanding_request_count', 'remote_connection', 'timeout_sent', 'elapsed_ms')}
            normalized['mismatch'] = row['mismatch']
            transitions.append(normalized)
        events = deepcopy(record['events'])
        normalized = {'code': record['code'], 'transitions': transitions, 'events': events, 'packets': record['packets']}
        strict_shape(normalized, wanted, f'operation {index}')
        if normalized != wanted:
            raise ValueError(f'handshake mismatch operation {index}: {normalized!r} != {wanted!r}')
    return True


def strict_shape(value, expected, label):
    """Type and inventory validation precedes comparison (bool and integral float are not ints)."""
    if type(value) is not type(expected):
        raise ValueError(f'{label}: wrong type')
    if isinstance(expected, dict):
        if set(value) != set(expected):
            raise ValueError(f'{label}: unknown/missing fields')
        for key in expected:
            strict_shape(value[key], expected[key], f'{label}.{key}')
    elif isinstance(expected, list):
        if len(value) != len(expected):
            raise ValueError(f'{label}: missing/extra records')
        for index, (item, wanted) in enumerate(zip(value, expected)):
            strict_shape(item, wanted, f'{label}[{index}]')


def negative_controls(actual, expected):
    controls = []
    def reject(name, mutant, marker):
        try:
            compare(mutant, expected)
        except ValueError as error:
            if marker not in str(error):
                raise ValueError(f'{name}: unrelated rejection {error}') from error
            controls.append(name)
        else:
            raise ValueError(f'{name}: mutation survived')
    mutant = deepcopy(actual); mutant['records'].pop(); reject('partial', mutant, 'partial completion')
    mutant = deepcopy(actual); mutant['records'][0]['extra'] = 1; reject('unknown_field', mutant, 'Godot operation')
    for value, name in ((True, 'bool_remaining'), (2.0, 'float_remaining'), (1, 'decrement_remaining')):
        mutant = deepcopy(actual); mutant['records'][0]['transitions'][0]['remaining'] = value
        reject(name, mutant, 'operation 0')
    mutant = deepcopy(actual); mutant['records'][0]['transitions'][1]['token'] = '00' * 16; reject('token_identity', mutant, 'operation 0')
    mutant = deepcopy(actual); mutant['records'][0]['events'].append({'kind': 'synchronized'}); reject('unexpected_event', mutant, 'operation 0')
    mutant = deepcopy(actual); mutant['records'][0]['packets'][0]['fps'] += 1; reject('packet_field', mutant, 'operation 0')
    event_index = next((i for i, row in enumerate(actual['records']) if row['events']), None)
    if event_index is not None:
        mutant = deepcopy(actual); mutant['records'][event_index]['events'].pop()
        reject('missing_event', mutant, f'operation {event_index}')
    timeout_index = next((i for i, row in enumerate(actual['records']) if any(t['action'] == 'report_timeout' for t in row['transitions'])), None)
    if timeout_index is not None:
        mutant = deepcopy(actual)
        next(t for t in mutant['records'][timeout_index]['transitions'] if t['action'] == 'report_timeout')['elapsed_ms'] += 1
        reject('timeout_elapsed', mutant, f'operation {timeout_index}')
    return controls


def event_schema(event):
    if not isinstance(event, dict):
        raise ValueError('upstream event type')
    kind = event.get('kind')
    if kind == 'synchronized':
        fields(event, 'kind', 'upstream event')
    elif kind == 'synchronizing':
        fields(event, 'kind total count total_requests_sent elapsed_ms', 'upstream event')
        for key in ('total', 'count', 'total_requests_sent', 'elapsed_ms'):
            integer(event[key], 0, 10000, 'upstream event ' + key)
    elif kind == 'sync_timeout':
        fields(event, 'kind elapsed_ms', 'upstream event')
        integer(event['elapsed_ms'], 0, 10000, 'upstream event elapsed_ms')
    elif kind == 'incompatible':
        fields(event, 'kind reason', 'upstream event')
        fields(event['reason'], 'field ours theirs', 'upstream mismatch')
        if event['reason']['field'] == 'config_digest':
            for key in ('ours', 'theirs'):
                value = event['reason'][key]
                if not isinstance(value, str) or len(value) != 16 or any(c not in '0123456789abcdef' for c in value):
                    raise ValueError('upstream mismatch digest')
        else:
            for key in ('ours', 'theirs'):
                integer(event['reason'][key], 0, 0xffffffff, 'upstream mismatch ' + key)
    else:
        raise ValueError('unknown upstream event')


def raw_negative_controls(raw, scenario):
    names = []
    for field, value, marker in [('token', False, 'null'), ('disposition', False, 'null'), ('remote_connection', False, 'canonical hex'),
                                 ('action', 'unknown', 'transition action'), ('state', False, 'transition state'), ('remaining', True, 'raw transition remaining')]:
        mutated = deepcopy(raw); mutated['records'][0]['transitions'][1][field] = value
        try:
            project(mutated, scenario)
        except ValueError as error:
            if marker not in str(error):
                raise ValueError('raw control unrelated rejection: ' + field) from error
            names.append('raw_' + field)
        else:
            raise ValueError('raw corruption survived: ' + field)
    mutated = deepcopy(raw); mutated['records'][1]['transitions'].append(deepcopy(raw['records'][0]['transitions'][0]))
    try:
        project(mutated, scenario)
    except ValueError as error:
        if 'position' not in str(error):
            raise ValueError('activation control unrelated rejection') from error
        names.append('raw_mid_history_activation')
    else:
        raise ValueError('mid-history activation survived')
    return names
