"""Validate the addressed five-endpoint coordinator-silence witness."""

from struct import pack

from drop_history_contract import fields, integer, require, same
from source_wire import RECOVERY_REVISION, header

SCHEDULE_FIELDS = 'peers warmup target coordinator target_silence_us tick_us delay_us disconnect_us deadline_us coordinator_silence_us through_us'
SURVIVORS = [1, 2, 3]
SOURCE_KINDS = {'DropPrepare': 18, 'DropReport': 19, 'DropCommit': 21}


def check_schedule(schedule):
    fields(schedule, SCHEDULE_FIELDS, 'failover schedule')
    for key, value in schedule.items():
        integer(value, 0, 10_000_000, key)
    require([schedule[key] for key in ('peers', 'warmup', 'target', 'coordinator', 'target_silence_us')] == [5, 6, 4, 0, 0],
            'five-endpoint failover topology')
    tick = schedule['tick_us']
    delay = schedule['delay_us']
    cutoff = schedule['coordinator_silence_us']
    disconnect = schedule['disconnect_us']
    deadline = schedule['deadline_us']
    end = schedule['through_us']
    require(1_000 <= tick <= delay and disconnect + delay < cutoff < disconnect + deadline < end < cutoff + disconnect,
            'bounded failover timing')
    require(all(value % tick == 0 for value in (delay, cutoff, disconnect, deadline, end)), 'aligned failover timing')


def expected_history():
    sums = [0] * 5
    rows = []
    for frame in range(5):
        samples = [bytes((frame * 11 + player * 7 + index) % 251 for index in range(4)) for player in range(5)]
        sums = [total + sum(sample) for total, sample in zip(sums, samples)]
        rows.append({'frame': frame, 'inputs': [sample.hex() for sample in samples], 'bytes': pack('<6q', frame + 1, *sums).hex()})
    return rows


def check_history(before, after):
    require([row['peer'] for row in before] == list(range(5)), 'all original endpoints sampled')
    require([row['peer'] for row in after] == SURVIVORS, 'all reachable survivors sampled')
    expected = expected_history()
    for snapshot in before + after:
        require(snapshot['confirmed'] == 4 and snapshot['frame'] == 6, 'original gameplay frontier')
        require(same(snapshot['rows'], expected), 'original five-slot input and canonical state prefix')
    require(same(after, before[1:4]), 'fault preserves each exposed snapshot and current game bytes')


def active(peer, now, schedule):
    return (peer != schedule['target'] or now < schedule['target_silence_us']) and (
        peer != schedule['coordinator'] or now < schedule['coordinator_silence_us'])


def source_control(record):
    raw = record['raw']
    header(raw, 6)
    require(len(raw['body']) == 1, 'one source body')
    kind, body = next(iter(raw['body'].items()))
    require(kind in SOURCE_KINDS, 'source barrier body')
    operation = body['operation']
    fields(operation, 'coordinator coordinator_generation sequence target_set_digest participant_set_digest terminal_epoch', 'source operation')
    require(operation['coordinator'] == 0 and operation['coordinator_generation'] == 0
            and operation['sequence'] == 1 and operation['terminal_epoch'] == 0, 'first source operation identity')
    if kind == 'DropPrepare':
        require(body['participants'] == [0, 1, 2, 3] and body['targets'] == [{'generation': 0, 'handle': 4}], 'source prepare roster')
    wire = pack('<4BIIHHIQQI', *raw['header']['sentinel'], 6, 0, raw['header']['conn_id'], SOURCE_KINDS[kind],
                operation['coordinator'], operation['coordinator_generation'], operation['sequence'],
                operation['target_set_digest'], operation['participant_set_digest'], operation['terminal_epoch'])
    if kind == 'DropCommit':
        wire += pack('<iQ', body['cut'], body['cut_digest'])
    elif kind == 'DropPrepare':
        wire += pack('<QHHQ4H', 1, 4, 0, 4, *body['participants'])
    else:
        stages = {'Inventory': 0, 'Ready': 1, 'Committed': 2}
        wire += pack('<HIiiQQ', body['participant'], stages[body['stage']], body['exposed_confirmed'],
                     body['cut'], body['cut_digest'], len(body['receipts']))
        wire += b''.join(pack('<Hii', row['target'], row['available_from'], row['contiguous_through']) for row in body['receipts'])
    require(bytes.fromhex(record['bytes']) == wire, 'source encoded barrier metadata')
    return kind, body


def godot_control(record):
    raw = bytes.fromhex(record['bytes'])
    prefix = pack('<2B2xHHIQi', record['phase'], record['stage'], record['coordinator'], record['coordinator_generation'],
                  int(record['operation']), int(record['target_set_digest']) % (1 << 64), record['cut'])
    require(raw.startswith(b'FRGP\x03\x00\x0c\x00') and raw[44:46] == prefix[:2] and raw[47:68] == prefix[3:]
            and raw[76:84] == pack('<Q', int(record['cut_digest']) % (1 << 64)),
            'Godot encoded barrier metadata')
    require(raw[24:32].hex() == record['sender_id'] == pack('<Q', record['from'] + 1).hex() and
            record['recipient_id'] == pack('<Q', record['to'] + 1).hex(), 'Godot addressed identities')
    return record['phase'], record['stage']


def check_delivery(emissions, receipts, withheld, schedule, *, source):
    id_key, send_key, receive_key = ('id', 'sent_us', 'received_us') if source else ('ordinal', 'emitted_at_us', 'at_us')
    by_id = {}
    eligible = set()
    held = set()
    for packet in emissions:
        packet_id, sent = packet[id_key], packet[send_key]
        integer(packet_id, 0, 32768, 'bounded control ID')
        integer(sent, 0, schedule['through_us'], 'control emission clock')
        for endpoint in (packet['from'], packet['to']):
            integer(endpoint, 0, schedule['peers'] - 1, 'control endpoint')
        require(packet['from'] != packet['to'] and packet_id not in by_id, 'unique directed emission')
        by_id[packet_id] = packet
        ready = source_control(packet)[1].get('stage') == 'Ready' if source else godot_control(packet) == (2, 2)
        if not all(active(packet[key], sent, schedule) for key in ('from', 'to')):
            continue
        if ready and packet['to'] == schedule['coordinator']:
            held.add(packet_id)
            continue
        arrival = sent + schedule['delay_us']
        if arrival <= schedule['through_us'] and all(active(packet[key], arrival, schedule) for key in ('from', 'to')):
            eligible.add(packet_id)
    require(held and sorted(held) == sorted(withheld), 'actual direct READY withheld before coordinator silence')
    observed = set()
    for receipt in receipts:
        packet_id = receipt[id_key]
        require(packet_id in eligible and packet_id not in observed, 'unique eligible control receipt')
        sent = by_id[packet_id]
        require(all(receipt[key] == value for key, value in sent.items()), 'receipt retains original addressed emission and bytes')
        require(receipt[receive_key] == sent[send_key] + schedule['delay_us'], 'constant link delay')
        if source:
            require(receipt['body'] == sent['raw']['body'] and receipt['order'] > packet_id, 'actual source socket consumption')
        else:
            require(receipt['code'] in (0, 13), 'actual Godot receive result')
        observed.add(packet_id)
    require(observed == eligible, 'every eligible control consumed')
    return len(held)


def check_direct(controls, schedule, *, source):
    receive_key = 'received_us' if source else 'at_us'
    for peer in SURVIVORS:
        initial = [row for row in controls if row['to'] == peer and row[receive_key] < schedule['coordinator_silence_us']]
        if source:
            prepares = [row for row in initial if row['from'] == 0 and 'DropPrepare' in row['body']]
            inventories = [row for row in initial if row['from'] == 0 and row['body'].get('DropReport', {}).get('stage') == 'Inventory'
                           and row['body']['DropReport']['participant'] == 0]
        else:
            prepares = [row for row in initial if row['from'] == 0 and row['phase'] == 1 and row['cut_digest'] == '0' and row['code'] == 0]
            inventories = [row for row in initial if row['from'] in SURVIVORS and godot_control(row) == (2, 1) and row['code'] == 0]
        origin = schedule['disconnect_us'] + schedule['tick_us']
        require(prepares and min(row[receive_key] for row in prepares) == origin + schedule['delay_us'], 'direct opening PREPARE received')
        require(inventories and min(row[receive_key] for row in inventories) == origin + schedule['delay_us'] * (1 if source else 2),
                'direct original INVENTORY received before cutoff')
        if not source:
            require({row['operation'] for row in prepares + inventories} == {prepares[0]['operation']}, 'Godot original operation continuity')


def check_source(trace, schedule):
    require(trace['upstream_revision'] == RECOVERY_REVISION and same(trace['schedule'], schedule), 'exact source and shared schedule')
    check_history(trace['before'], trace['after'])
    require(all(row['state'] == 'Running' for row in trace['after']), 'source survivors keep running')
    held = check_delivery(trace['controls'], trace['received'], trace['withheld_ready'], schedule, source=True)
    check_direct(trace['received'], schedule, source=True)
    operations = {tuple(sorted(next(iter(row['raw']['body'].values()))['operation'].items())) for row in trace['controls']}
    require(len(operations) == 1, 'single original source operation before and after failover')
    commits = [(row, row['raw']['body']['DropCommit']) for row in trace['controls'] if 'DropCommit' in row['raw']['body']]
    require(commits, 'source published a certified cut')
    first = min(row['sent_us'] for row, _ in commits)
    require(first > schedule['coordinator_silence_us'], 'no commit before silence')
    require({row['from'] for row, _ in commits if row['sent_us'] == first} == {1}, 'endpoint 1 first acting coordinator')
    last = max(row['received_us'] for row in trace['received'] if row['from'] == 0 and row['to'] == 1)
    require(first - last == 1_000_000, 'source fallback published after one second without coordinator control')
    certified = commits[0][1]
    require(certified['cut'] == 5 and certified['cut_digest'] > 0 and all(same(body, certified) for _, body in commits), 'one source certified cut')
    arrival = first + schedule['delay_us']
    require({row['to'] for row in trace['received'] if row['from'] == 1 and row['received_us'] == arrival
             and row['body'].get('DropCommit') == certified} == {2, 3}, 'both remaining followers received the fallback commit')
    expect = [{'peer': peer, 'at_us': first if peer == 1 else arrival, 'target': schedule['target'], 'cut': certified['cut'], 'connected': False}
              for peer in SURVIVORS]
    require(same(trace['dropped'], expect), 'all three source survivors committed the original target')
    return {'authority': 1, 'cut': certified['cut'], 'terminal_epoch': certified['operation']['terminal_epoch'],
            'first_commit_us': first, 'last_coordinator_control_us': last, 'withheld_ready': held}


def check_godot(trace, schedule):
    require(same(trace['schedule'], schedule) and trace['assertions'] > 0 and trace['assertion_failures'] == [], 'Godot schedule and assertions')
    check_history(trace['starting'], trace['ending'])
    require(all(row['frozen_frame'] == -1 for row in trace['ending']), 'Godot survivors leave the original target unfrozen')
    held = check_delivery(trace['emissions'], trace['receipts'], trace['withheld_ready'], schedule, source=False)
    check_direct(trace['receipts'], schedule, source=False)
    barriers = trace['before_cut']
    require([row['peer'] for row in barriers] == [0, *SURVIVORS], 'Godot snapshots original pending barrier on all participants')
    start = schedule['disconnect_us'] + schedule['tick_us']
    require(all(row['state'] == 'pending' and row['coordinator'] == 0 and row['certificates'] == 0 and row['cut'] == 5
                and row['started_at_us'] == start for row in barriers), 'Godot pending candidate at coordinator cutover')
    require(len({row['operation'] for row in barriers}) == 1 and len({row['coordinator_generation'] for row in barriers}) == 1,
            'Godot participants still hold the same named operation')
    require(all(row['operation'] == barriers[0]['operation'] and row['coordinator_generation'] == barriers[0]['coordinator_generation']
                for row in trace['emissions']), 'Godot control identity matches the original barrier')
    require(not trace['drops'] and all(row['phase'] != 4 for row in trace['emissions']), 'Godot never publishes or commits a cut')
    deadline = start + schedule['deadline_us']
    require(same(trace['terminal'], {str(peer): {'at_us': deadline, 'reason': 23} for peer in SURVIVORS}), 'Godot terminal protocol failure')
    require(same(trace['failures'], [{'at_us': deadline, 'peer': peer, 'target': schedule['target'], 'reason': 'timeout'}
                                     for peer in SURVIVORS]), 'Godot original barrier times out')
    return {'terminal_us': deadline, 'reason': 'peer_drop_unconfirmed/timeout', 'withheld_ready': held}
