"""Strict queue artifact schemas and exact, first-divergence comparison."""
from contract import fields, integer

REVISION = 'f13cd5c0f2815926785a395947e18da0dbea0dd8'


def validate_bundle(value):
    fields(value, 'format upstream_revision cases', 'queue bundle')
    integer(value['format'], 1, 1, 'queue format')
    if value['upstream_revision'] != REVISION:
        raise ValueError('stale queue revision')
    cases = value['cases']
    if not isinstance(cases, list) or not 1 <= len(cases) <= 1000:
        raise ValueError('queue bundle needs 1..1000 cases')
    names = set()
    for case in cases:
        fields(case, 'name capacity input_width player operations', 'queue case')
        name = case['name']
        if not isinstance(name, str) or not name or name in names:
            raise ValueError('missing or duplicate case name')
        names.add(name)
        integer(case['capacity'], 2, 128, 'queue capacity')
        integer(case['input_width'], 1, 32, 'queue width')
        integer(case['player'], 0, 7, 'queue player')
        operations = case['operations']
        if not isinstance(operations, list) or not 1 <= len(operations) <= 10000:
            raise ValueError('queue case needs 1..10000 operations')
        for operation in operations:
            if not isinstance(operation, dict):
                raise ValueError('invalid queue operation')
            kind = operation.get('kind')
            if kind in ('read', 'confirmed', 'discard'):
                fields(operation, 'kind frame', 'queue operation')
                integer(operation['frame'], 0, 100000, 'queue frame')
            elif kind == 'add':
                fields(operation, 'kind frame bytes', 'queue operation')
                integer(operation['frame'], 0, 100000, 'queue frame')
                text = operation['bytes']
                if not isinstance(text, str) or len(text) != case['input_width'] * 2 or any(c not in '0123456789abcdef' for c in text):
                    raise ValueError('invalid queue input bytes')
            elif kind == 'delay':
                fields(operation, 'kind value', 'queue operation')
                integer(operation['value'], 0, 128, 'queue delay')
            elif kind == 'reset':
                fields(operation, 'kind', 'queue operation')
            else:
                raise ValueError('unknown queue operation')
    return value


def compare(expected, actual, names, counts):
    for trace in (expected, actual):
        fields(trace, 'format upstream_revision complete cases', 'queue trace')
        integer(trace['format'], 1, 1, 'queue trace format')
        if trace['upstream_revision'] != REVISION or trace['complete'] is not True:
            raise ValueError('queue trace revision or incomplete execution')
        if not isinstance(trace['cases'], list) or len(trace['cases']) != len(names):
            raise ValueError('queue trace missing or extra cases')
        for case, name, count in zip(trace['cases'], names, counts):
            fields(case, 'name records', 'queue trace case')
            if case['name'] != name or not isinstance(case['records'], list) or len(case['records']) != count:
                raise ValueError(f'{name}: missing, extra or reordered queue records')
            for index, record in enumerate(case['records']):
                location = f'{name}: operation {index}'
                fields(record, 'index kind accepted frame bytes status first_incorrect delay', location)
                integer(record['index'], index, index, location)
                integer(record['frame'], -1, 100000, location)
                integer(record['first_incorrect'], -1, 100001, location)
                integer(record['delay'], 0, 127, location)
                if type(record['accepted']) is not bool or not isinstance(record['bytes'], str):
                    raise ValueError(f'{location}: invalid accepted or bytes type')
                if record['kind'] not in ('add', 'read', 'confirmed', 'delay', 'discard', 'reset') or record['status'] not in ('none', 'confirmed', 'predicted'):
                    raise ValueError(f'{location}: unknown kind or status')
    for left, right, name in zip(expected['cases'], actual['cases'], names):
        for index, (first, second) in enumerate(zip(left['records'], right['records'])):
            if first != second:
                raise ValueError(f'{name}: operation {index}: queue divergence\nRust: {first}\nGodot: {second}')
