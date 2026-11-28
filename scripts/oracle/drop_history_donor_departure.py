"""Compare the chosen-donor departure outcome on the pinned v6 source and Godot."""
from copy import deepcopy
from struct import pack, unpack

from drop_history_contract import fields, integer, require, same
from launch import execute
from source_wire import decode_trace


MODES = ('deliver', 'hold-live', 'silence')
SUITE = 'res://tests/unit/test_peer_drop_donor_departure.gd'
GODOT_PREFIX = 'FORTRESS_DONOR_DEPARTURE '
DELIVERY_CASE = 'original_donor_chunk_arrives'
REFUSAL_CASE = 'chosen_donor_leaves_before_history'
CASES = {DELIVERY_CASE, REFUSAL_CASE}


def original_rows():
    totals = [0] * 4
    rows = []
    for frame in range(20):
        inputs = []
        for player in range(4):
            disconnected = player == 3 and frame > 8
            original_frame = 8 if disconnected else frame
            sample = bytes((original_frame * 11 + player * 7 + index) % 251 for index in range(4))
            totals[player] += sum(sample)
            inputs.append({'bytes': sample.hex(), 'status': 'disconnected' if disconnected else 'confirmed'})
        rows.append({'frame': frame, 'inputs': inputs, 'bytes': pack('<5q', frame + 1, *totals).hex()})
    return rows


def predicted_snapshot(rows, frame, local):
    previous = rows[frame - 1]
    totals = unpack('<5q', bytes.fromhex(previous['bytes']))[1:]
    inputs = [(rows[frame] if slot == local else previous)['inputs'][slot]['bytes'] for slot in range(4)]
    return pack('<5q', frame + 1, *(total + sum(bytes.fromhex(sample)) for total, sample in zip(totals, inputs, strict=True))).hex()


def check_opening(source, revision, mode, expected):
    label = 'source donor departure'
    fields(source, 'revision mode opening opening_rows held planned held_at release_at terminal before_delay_release aborts commits final_before '
           'received advance runtime_rows final_after final_rows installed commit_receipts', label)
    require(same([source['revision'], source['mode']], [revision, mode]), label + ' source and mode')
    integer(source['held_at'], 25_000, 25_000, label + ' first publication clock')
    require(type(source['opening']) is list and len(source['opening']) == 2, label + ' opening recipients')
    for address, peer in zip((0, 2), source['opening'], strict=True):
        fields(peer, 'state current confirmed target_receipt connected dropped game', label + ' opening')
        require(same([peer[key] for key in ('state', 'current', 'confirmed', 'target_receipt', 'connected', 'dropped')],
                     ['Running', 6, 4, 7, [True, True], []]), label + ' opening status and receipts')
        require(same(peer['game'], predicted_snapshot(expected, 5, address)), label + ' opening game snapshot')
    require(same(source['planned'], source['opening']), label + ' held original still missing on both recipients')
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


def check_receipts(source, mode, label):
    received = source['received']
    require(type(received) is list and len(received) == 2, label + ' socket recipient inventory')
    order = 0
    read_clock = source['release_at'] + (1000 if mode == 'silence' else 10_000)
    for packet, observations in zip(source['held'], received, strict=True):
        require(type(observations) is list and len(observations) == 1, label + ' socket delivery inventory')
        observation = observations[0]
        fields(observation, 'at received_at from to body order', label + ' socket delivery')
        integer(observation['order'], order + 1, 50_000, label + ' socket order')
        order = observation['order']
        integer(observation['received_at'], read_clock, read_clock, label + ' socket read clock')
        require(same({key: observation[key] for key in ('at', 'from', 'to', 'body')},
                     {**packet, 'body': {'DropBackfill': packet['body']}}), label + ' socket matches held packet')
    return read_clock


def check_delivery(source, expected, read_clock, label):
    require(type(source['commits']) is list and bool(source['commits']), label + ' delivery commit publications')
    publications = {}
    digest = None
    for packet in source['commits']:
        fields(packet, 'at from to body publication_order', label + ' commit publication')
        integer(packet['at'], read_clock + 1, 440_000, label + ' commit after original delivery')
        integer(packet['from'], 0, 2, label + ' commit route sender')
        integer(packet['to'], 0, 3, label + ' commit route recipient')
        require(packet['from'] != packet['to'], label + ' commit route loops')
        order = packet['publication_order']
        integer(order, 1, 50_000, label + ' commit publication order')
        require(order not in publications, label + ' unique commit publication order')
        publications[order] = packet
        body = packet['body']
        fields(body, 'cut cut_digest operation', label + ' commit body')
        require(same(body['cut'], 8) and same(body['operation'], source['held'][0]['body']['operation']),
                label + ' certified cut and operation')
        integer(body['cut_digest'], 1, (1 << 64) - 1, label + ' cut digest')
        if digest is None:
            digest = body['cut_digest']
        require(body['cut_digest'] == digest, label + ' shared cut digest')
    first_clock = min(packet['at'] for packet in publications.values())
    first = [packet for packet in publications.values() if packet['at'] == first_clock]
    require(sorted((packet['from'], packet['to']) for packet in first) == [(0, 1), (0, 2), (0, 3)],
            label + ' first commit coordinator and recipients')
    first_addressed = next(packet for packet in first if packet['to'] == 2)
    receipt = check_commit_receipts(source['commit_receipts'], first_addressed, publications, label)
    certified = [{**peer, 'confirmed': 3, 'target_receipt': 8, 'connected': [False, True],
                  'dropped': [{'address': '3', 'handle': 3}]} for peer in source['opening']]
    fields(source['installed'], '0 2', label + ' public installation samples')
    for peer, before, clock, order in zip(('0', '2'), certified,
            (first_clock, receipt['received_at']), (max(packet['publication_order'] for packet in first), receipt['order']), strict=True):
        installed = source['installed'][peer]
        fields(installed, 'at order state', label + ' public installation')
        integer(installed['at'], clock, source['held_at'] + 400_000, label + ' commit before public installation clock')
        integer(installed['order'], order + 1, 50_000, label + ' commit before public installation order')
        require(same(installed['state'], before), label + ' installed target receipt and public drop')
    require(same(source['final_before'], [{**peer, 'confirmed': 5, 'dropped': []} for peer in certified]), label + ' installed before continuation')
    require(same(source['final_after'], [{**before, 'confirmed': 16, 'current': 18, 'dropped': [],
                                         'game': predicted_snapshot(expected, 17, peer)}
                                        for peer, before in zip((0, 2), certified, strict=True)]), label + ' continued public status')
    require(same(source['runtime_rows'], [expected[:17]] * 3), label + ' three canonical continuations and statuses')
    rows = [{'frame': row['frame'], 'inputs': [item['bytes'] for item in row['inputs']]} for row in expected[:17]]
    require(same(source['final_rows'], [rows, rows]), label + ' continued exposed original rows')


def check_commit_receipts(receipts, first, publications, label):
    require(type(receipts) is list and bool(receipts), label + ' remote commit receipts')
    order = 0
    for receipt in receipts:
        fields(receipt, 'at received_at from to body publication_order order', label + ' commit receipt')
        number = receipt['publication_order']
        integer(number, 1, 50_000, label + ' received commit publication order')
        publication = publications.get(number)
        require(publication is not None and same([receipt['from'], receipt['to']], [0, 2])
                and same({key: receipt[key] for key in ('at', 'from', 'to', 'publication_order', 'body')},
                         {**publication, 'body': {'DropCommit': publication['body']}}), label + ' socket matches coordinator commit')
        integer(receipt['received_at'], publication['at'], 440_000, label + ' commit socket clock')
        integer(receipt['order'], max(order, number) + 1, 50_000, label + ' commit socket order')
        order = receipt['order']
    require(receipts[0]['publication_order'] == first['publication_order'], label + ' first coordinator commit reached remote recipient')
    return receipts[0]


def check_source(source, revision, mode):
    label = 'source donor departure'
    expected = original_rows()
    check_opening(source, revision, mode, expected)
    require(same(source['aborts'], []), label + ' no emitted abort')
    expected_release = source['held_at'] + {'deliver': 0, 'hold-live': 300_000, 'silence': 400_000}[mode]
    integer(source['release_at'], expected_release, expected_release, label + ' original delivery clock')
    read_clock = check_receipts(source, mode, label)
    if mode == 'silence':
        require(source['before_delay_release'] is None and same([source['commits'], source['commit_receipts'], source['installed']], [[], [], {}]),
                label + ' no release, commit or installation before terminal')
        fields(source['terminal'], '0 2', label + ' terminal recipients')
        states = []
        for index, address in enumerate(('0', '2')):
            transition = source['terminal'][address]
            fields(transition, 'offset state rows', label + ' terminal transition')
            integer(transition['offset'], 220_000, 220_000, label + ' first terminal sample')
            require(source['held_at'] + transition['offset'] < source['release_at'] < read_clock, label + ' terminal before late socket read')
            target = {**source['opening'][index], 'state': 'Synchronizing'}
            require(same(transition['state'], target) and same(transition['rows'], source['opening_rows'][index]),
                    label + ' terminal preserves exposed original history')
            states.append(target)
        require(same(source['final_before'], states) and same(source['final_after'], states)
                and same(source['final_rows'], source['opening_rows']), label + ' late delivery preserves state and original rows')
        require(same(source['advance'], [{'Err': 'NotSynchronized'}] * 2) and same(source['runtime_rows'], []), label + ' terminal rejects advancement')
        return
    require(same(source['terminal'], {}) and same(source['advance'], []), label + ' delivery stays running')
    require(same(source['before_delay_release'], source['opening'] if mode == 'hold-live' else None),
            label + ' live delayed donor preserves pending recipients')
    check_delivery(source, expected, read_clock, label)


def read_godot_evidence(stdout):
    records = {case: [] for case in CASES}
    for line in stdout.splitlines():
        if not line.startswith(GODOT_PREFIX):
            continue
        record = decode_trace(line[len(GODOT_PREFIX):])
        fields(record, 'case opening outcome', 'Godot donor departure case')
        require(type(record['case']) is str and record['case'] in records, 'Godot donor departure case name')
        records[record['case']].append(record)
    require(all(len(runs) == 2 and same(*runs) for runs in records.values()), 'Godot donor departure evidence inventory and repeat')
    return {case: runs[0] for case, runs in records.items()}


def check_godot(evidence):
    label = 'Godot donor departure'
    expected = original_rows()
    sample = expected[8]['inputs'][3]['bytes']
    delivery = evidence[DELIVERY_CASE]
    refusal = evidence[REFUSAL_CASE]
    require(same(delivery['opening'], refusal['opening']), label + ' shared original plan')
    opening = delivery['opening']
    require(type(opening) is list and len(opening) == 2, label + ' opening recipients')
    operation = opening[0].get('operation') if type(opening[0]) is dict else None
    integer(operation, 1, (1 << 53) - 1, label + ' operation')
    require(same(opening, [{'peer': peer, 'donor': 1, 'coordinator': 0, 'receipt': 7, 'first': 8,
                            'cut': 8, 'operation': operation, 'bytes': sample} for peer in (0, 2)]), label + ' original held plan')
    accepted = delivery['outcome']
    fields(accepted, 'cuts installed canonical', label + ' delivery')
    require(same(accepted['cuts'], {'0': 8, '1': 8, '2': 8})
            and same(accepted['installed'], [{'peer': peer, 'cut': 8, 'bytes': sample} for peer in (0, 1, 2)]), label + ' certified cut and bytes')
    require(same(accepted['canonical'], [{'frame': row['frame'], 'states': [row['bytes']] * 3} for row in expected]), label + ' canonical continuation')
    stopped = refusal['outcome']
    fields(stopped, 'goodbye goodbye_at late_at failures peers cuts', label + ' refusal')
    require(same(stopped['goodbye'], [0, 2]) and same(stopped['cuts'], {}), label + ' Goodbye routes and no cuts')
    integer(stopped['goodbye_at'], 1, 100_000, label + ' Goodbye clock')
    integer(stopped['late_at'], stopped['goodbye_at'] + 1000, stopped['goodbye_at'] + 1000, label + ' late delivery clock')
    require(same(stopped['failures'], [{'at_us': stopped['goodbye_at'], 'peer': peer,
                                       'reason': 'participant_lost', 'target': '0400000000000000'} for peer in (0, 2)]), label + ' failure on Goodbye')
    require(type(stopped['peers']) is list and len(stopped['peers']) == 2, label + ' terminal recipients')
    for peer, row in zip((0, 2), stopped['peers'], strict=True):
        fields(row, 'peer before terminal after replay lifecycle receive step frozen', label + ' terminal peer')
        require(same([row[key] for key in ('peer', 'lifecycle', 'receive', 'step', 'frozen')],
                     [peer, 'TERMINATED', 'TERMINATED', 'TERMINATED', [-1, -1]]), label + ' terminal refuses late chunk and advancement')
        snapshot = [6, 4, predicted_snapshot(expected, 5, peer), 5]
        require(all(same(row[key], snapshot) for key in ('before', 'terminal', 'after')), label + ' preserved original snapshot')
        require(same(row['replay'], [{key: row[key] for key in ('frame', 'inputs')} for row in expected[:5]]), label + ' preserved original replay')


def reject_control(check, name, diagnostic):
    try:
        check()
    except ValueError as error:
        require(diagnostic in str(error), 'donor departure control failed at the wrong assertion: ' + name)
    else:
        raise ValueError('donor departure control accepted: ' + name)
    return 'donor-departure:' + name


def controls(cases, revision, godot, stdout):
    names = []
    for mode, name, mutate, diagnostic in (
        ('silence', 'wrong_terminal_sample', lambda data: data['terminal']['0'].update(offset=210_000), 'first terminal sample'),
        ('silence', 'substituted_late_byte', lambda data: data['received'][1][0]['body']['DropBackfill']['bytes'].__setitem__(0, 0), 'socket matches'),
        ('silence', 'changed_original_row', lambda data: data['final_rows'][0][0]['inputs'].__setitem__(0, 'ffffffff'), 'late delivery preserves'),
        ('silence', 'duplicate_socket_order', lambda data: data['received'][1][0].update(order=data['received'][0][0]['order']), 'socket order'),
        ('silence', 'early_socket_read', lambda data: data['received'][0][0].update(received_at=data['release_at']), 'socket read clock'),
        ('deliver', 'changed_post_cut_status', lambda data: data['runtime_rows'][1][9]['inputs'][3].update(status='confirmed'), 'canonical continuations'),
        ('deliver', 'foreign_commit_route', lambda data: data['commits'][0].update({'from': 99}), 'commit route sender'),
        ('deliver', 'uninstalled_target_receipt', lambda data: data['installed']['2']['state'].update(target_receipt=7), 'installed target receipt'),
        ('deliver', 'installation_before_commit', lambda data: data['installed']['0'].update(at=data['commits'][0]['at'] - 1), 'public installation clock'),
        ('deliver', 'installation_before_remote_receipt', lambda data: data['installed']['2'].update(order=data['commit_receipts'][0]['order']),
         'public installation order'),
        ('silence', 'changed_opening_game', lambda data: data['opening'][0].update(game='00' * 40), 'opening game snapshot'),
        ('hold-live', 'premature_receipt', lambda data: data['before_delay_release'][0].update(target_receipt=8), 'preserves pending recipients'),
        ('hold-live', 'premature_commit_emission', lambda data: data['commits'][0].update(at=data['release_at']), 'commit after original delivery'),
    ):
        data = deepcopy(cases[mode])
        mutate(data)
        names.append(reject_control(lambda: check_source(data, revision, mode), name, diagnostic))
    without_evidence = '\n'.join(line for line in stdout.splitlines() if not line.startswith(GODOT_PREFIX))
    names.append(reject_control(lambda: read_godot_evidence(without_evidence), 'godot_missing_evidence', 'evidence inventory'))
    altered = deepcopy(godot)
    altered[REFUSAL_CASE]['outcome']['failures'][0]['reason'] = 'timeout'
    names.append(reject_control(lambda: check_godot(altered), 'godot_substituted_failure', 'failure on Goodbye'))
    altered = deepcopy(godot)
    for key in ('before', 'terminal', 'after'):
        altered[REFUSAL_CASE]['outcome']['peers'][0][key][2] = '00' * 40
    names.append(reject_control(lambda: check_godot(altered), 'godot_changed_game', 'preserved original snapshot'))
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
        evidence = read_godot_evidence(stdout)
        check_godot(evidence)
        runs.append({'source': cases, 'godot': godot, 'godot_evidence': evidence})
    require(same(*runs), 'donor departure fresh-process repeat mismatch')
    return runs[0], controls(runs[0]['source'], revision, runs[0]['godot_evidence'], stdout)
