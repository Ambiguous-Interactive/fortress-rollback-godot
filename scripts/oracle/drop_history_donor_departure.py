"""Compare the chosen-donor departure outcome on the pinned v6 source and Godot."""
from copy import deepcopy
from struct import pack

from drop_history_contract import fields, integer, require, same
from launch import execute
from source_wire import decode_trace


MODES = ('deliver', 'hold-live', 'silence')
SUITE = 'res://tests/unit/test_peer_drop_donor_departure.gd'
CASES = {'original_donor_chunk_arrives', 'chosen_donor_leaves_before_history'}


def original_rows():
    totals = [0] * 4
    rows = []
    for frame in range(17):
        inputs = []
        for player in range(4):
            disconnected = player == 3 and frame > 8
            original_frame = 8 if disconnected else frame
            sample = bytes((original_frame * 11 + player * 7 + index) % 251 for index in range(4))
            totals[player] += sum(sample)
            inputs.append({'bytes': sample.hex(), 'status': 'disconnected' if disconnected else 'confirmed'})
        rows.append({'frame': frame, 'inputs': inputs, 'bytes': pack('<5q', frame + 1, *totals).hex()})
    return rows


def check_opening(source, revision, mode, expected):
    label = 'source donor departure'
    fields(source, 'revision mode opening opening_rows held planned held_at release_at terminal before_delay_release aborts commits final_before '
           'late_observed advance runtime_rows final_after final_rows', label)
    require(same([source['revision'], source['mode']], [revision, mode]), label + ' source and mode')
    integer(source['held_at'], 25_000, 25_000, label + ' first publication clock')
    require(type(source['opening']) is list and len(source['opening']) == 2 and same(source['planned'], source['opening']),
            label + ' held original still missing on both recipients')
    for peer in source['opening']:
        fields(peer, 'state current confirmed target_receipt connected dropped game', label + ' opening')
        require(same([peer[key] for key in ('state', 'current', 'confirmed', 'target_receipt', 'connected', 'dropped')],
                     ['Running', 6, 4, 7, [True, True], []]), label + ' opening status and receipts')
    original = [{'frame': row['frame'], 'inputs': [item['bytes'] for item in row['inputs']]} for row in expected[:5]]
    require(same(source['opening_rows'], [original, original]), label + ' original exposed rows')
    held = source['held']
    require(type(held) is list and len(held) == 2, label + ' two addressed donor publications')
    sample = list(bytes.fromhex(expected[8]['inputs'][3]['bytes']))
    for recipient, packet in zip((0, 2), held):
        fields(packet, 'at from to body', label + ' held packet')
        require(same([packet['at'], packet['from'], packet['to']], [source['held_at'], 1, recipient]), label + ' donor route')
        body = packet['body']
        fields(body, 'bytes chunk_count chunk_index donor frame_count operation range_start start_frame', label + ' history body')
        require(same([body[key] for key in ('bytes', 'chunk_count', 'chunk_index', 'donor', 'frame_count', 'range_start', 'start_frame')],
                     [sample, 1, 0, 1, 1, 8, 8]), label + ' original held bytes and range')
        operation = body['operation']
        fields(operation, 'coordinator coordinator_generation participant_set_digest sequence target_set_digest terminal_epoch', label + ' operation')
        require(same([operation[key] for key in ('coordinator', 'coordinator_generation', 'sequence', 'terminal_epoch')], [0, 0, 1, 0]),
                label + ' opening operation')
        for key in ('participant_set_digest', 'target_set_digest'):
            integer(operation[key], 1, (1 << 64) - 1, label + ' ' + key)
    require(same(held[0]['body'], held[1]['body']), label + ' matching operation and bytes')


def check_source(source, revision, mode):
    label = 'source donor departure'
    expected = original_rows()
    check_opening(source, revision, mode, expected)
    require(same(source['aborts'], []), label + ' no emitted abort')
    expected_release = source['held_at'] + {'deliver': 0, 'hold-live': 300_000, 'silence': 400_000}[mode]
    integer(source['release_at'], expected_release, expected_release, label + ' original delivery clock')
    if mode == 'silence':
        require(source['before_delay_release'] is None and same(source['commits'], []), label + ' no release or commit before terminal')
        fields(source['terminal'], '0 2', label + ' terminal recipients')
        states = []
        for index, address in enumerate(('0', '2')):
            transition = source['terminal'][address]
            fields(transition, 'offset state rows', label + ' terminal transition')
            integer(transition['offset'], 220_000, 220_000, label + ' first terminal sample')
            target = {**source['opening'][index], 'state': 'Synchronizing'}
            require(same(transition['state'], target) and same(transition['rows'], source['opening_rows'][index]),
                    label + ' terminal preserves exposed original history')
            states.append(target)
        require(same(source['final_before'], states) and same(source['final_after'], states)
                and same(source['final_rows'], source['opening_rows']), label + ' late delivery preserves state and original rows')
        require(same(source['advance'], [{'Err': 'NotSynchronized'}] * 2) and same(source['runtime_rows'], []), label + ' terminal rejects advancement')
        require(type(source['late_observed']) is list and len(source['late_observed']) == 2, label + ' late recipient inventory')
        for packet, observations in zip(source['held'], source['late_observed'], strict=True):
            require(type(observations) is list and len(observations) == 1, label + ' late socket delivery inventory')
            observation = observations[0]
            fields(observation, 'at from to body order', label + ' late socket delivery')
            integer(observation['order'], 1, 50_000, label + ' late socket order')
            require(same({key: observation[key] for key in ('at', 'from', 'to', 'body')},
                         {**packet, 'body': {'DropBackfill': packet['body']}}), label + ' late socket matches held packet')
        return
    require(same(source['terminal'], {}) and same(source['advance'], []) and same(source['late_observed'], [[], []]), label + ' delivery stays running')
    require(same(source['before_delay_release'], source['opening'] if mode == 'hold-live' else None),
            label + ' live delayed donor preserves pending recipients')
    require(type(source['commits']) is list and bool(source['commits']), label + ' delivery commit publications')
    for packet in source['commits']:
        fields(packet, 'at from to body', label + ' commit publication')
        integer(packet['at'], source['release_at'], 440_000, label + ' commit after original delivery')
        require(same(packet['body']['cut'], 8) and same(packet['body']['operation'], source['held'][0]['body']['operation']),
                label + ' certified cut and operation')
    require(type(source['runtime_rows']) is list and len(source['runtime_rows']) == 3
            and all(type(rows) is list and same(rows, expected) for rows in source['runtime_rows']),
            label + ' three canonical continuations and statuses')


def controls(cases, revision):
    names = []
    for mode, name, mutate, diagnostic in (
        ('silence', 'wrong_terminal_sample', lambda data: data['terminal']['0'].update(offset=210_000), 'first terminal sample'),
        ('silence', 'substituted_late_byte', lambda data: data['late_observed'][1][0]['body']['DropBackfill']['bytes'].__setitem__(0, 0), 'late socket matches'),
        ('silence', 'changed_original_row', lambda data: data['final_rows'][0][0]['inputs'].__setitem__(0, 'ffffffff'), 'late delivery preserves'),
        ('deliver', 'changed_post_cut_status', lambda data: data['runtime_rows'][1][9]['inputs'][3].update(status='confirmed'), 'canonical continuations'),
        ('hold-live', 'premature_receipt', lambda data: data['before_delay_release'][0].update(target_receipt=8), 'preserves pending recipients'),
        ('hold-live', 'premature_commit_emission', lambda data: data['commits'][0].update(at=data['release_at'] - 1), 'commit after original delivery'),
    ):
        data = deepcopy(cases[mode])
        mutate(data)
        try:
            check_source(data, revision, mode)
        except ValueError as error:
            require(diagnostic in str(error), 'donor departure control failed at the wrong assertion: ' + name)
        else:
            raise ValueError('donor departure control accepted: ' + name)
        names.append('donor-departure:' + name)
    return names


def observe(engine, binary, root, output, revision, parse_godot):
    runs = []
    for repeat in (1, 2):
        cases = {}
        for mode in MODES:
            stdout, stderr = execute([str(binary), '--donor-departure', mode], output / f'source-donor-departure-{mode}-{repeat}.log')
            require(not stderr.strip(), 'source donor departure stderr')
            cases[mode] = decode_trace(stdout)
            check_source(cases[mode], revision, mode)
        require(all(same(cases['silence']['held'], cases[mode]['held']) for mode in MODES), 'donor departure shared original publication')
        stdout, stderr = execute([str(engine), '--headless', '--path', str(root), '--script', 'res://tests/runner/run_tests.gd',
                                  '--', '--category', 'unit', '--suite', SUITE, '--seed', '1701'], output / f'godot-donor-departure-{repeat}.log')
        godot = parse_godot(stdout, stderr, 'FORTRESS_TEST_RESULT ')
        require(godot.get('passed') is True and godot.get('complete') is True and same(godot.get('count'), 2)
                and same(godot.get('errors'), []) and len(godot['records']) == 2
                and {record['case'] for record in godot['records']} == CASES, 'Godot donor departure case inventory')
        for record in godot['records']:
            require(record['suite'] == SUITE and record['seed'] == '1701' and len(record['runs']) == 2
                    and same(*record['runs']) and record['runs'][0]['assertions'] > 0 and same(record['runs'][0]['failures'], []),
                    'Godot donor departure repeat and assertions')
        runs.append({'source': cases, 'godot': godot})
    require(same(*runs), 'donor departure fresh-process repeat mismatch')
    return runs[0], controls(runs[0]['source'], revision)
