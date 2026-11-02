"""Check omitted inventory answers and reject fabricated delivery/retry evidence."""
import copy
import struct

from drop_history_contract import check_delivery, fields, integer, payload, require, same


def follower_inventory(packet, target_slots):
    report = packet['body'].get('DropReport', {})
    return packet['from'] == 1 and packet['to'] == 0 and report.get('stage') == 'Inventory' and same(report.get('participant'), target_slots)


def check_godot_inventory(packet, missing_rows, target_slots, unequal, warmup=0):
    fields(packet, 'from to packet emission order', 'Godot inventory')
    integer(packet['order'], 1, 8192, 'Godot inventory order')
    require(same(packet['from'], 1) and same(packet['to'], 0), 'Godot inventory sender')
    raw = packet['packet']
    require(type(raw) is str and len(raw) == 200 + target_slots * 24
            and all(character in '0123456789abcdef' for character in raw), 'Godot inventory bytes')
    era = 23 << 8
    targets = b''.join(struct.pack('<BH', slot, era) for slot in range(2 * target_slots, 3 * target_slots))
    digest = 0x14650fb0739d0383
    for byte in targets:
        digest = ((digest ^ byte) * 1099511628211) & 0x3fffffffffffffff
    receipts = bytes([1, target_slots]) + b''.join(struct.pack('<Bii', slot, max(0, warmup - 2), warmup + 7 + missing_rows)
                                                                for slot in range(2 * target_slots, 3 * target_slots))
    expected = (b'FRGP\x02\x00\x0c\x00' + bytes([91]) + bytes(15) + bytes([2]) + bytes(7) + bytes([22]) + bytes(7)
                + struct.pack('<I4BHHIQiiiQHHHI', 54 + len(targets) + len(receipts), 2, 1, 0, 0, 0, 21 << 8,
                              era + 1, digest, warmup + 4 + int(unequal), max(0, warmup - 2), warmup + 7 + missing_rows, 0, 0, 64, 0, len(targets))
                + targets + struct.pack('<I', len(receipts)) + receipts)
    require(bytes.fromhex(raw) == expected, 'Godot exact original inventory')



def check_source_observation_order(source):
    events = source['controls'] + source['received_controls']
    orders = [packet['order'] for packet in events]
    require(len(set(orders)) == len(orders), 'source unique observation order')
    emitted = {packet['emission']: packet for packet in source['controls']}
    require(all(packet['order'] > emitted[packet['emission']]['order'] for packet in source['received_controls']),
            'source receipt follows emission')
    for bank, identity in [('controls', 'from'), ('received_controls', 'to')]:
        for peer in (0, 1):
            observed = [packet['order'] for packet in source[bank] if packet[identity] == peer]
            require(observed == sorted(observed), 'source participant observation order')



def check_godot_observation_order(godot):
    events = [packet for kind in ('inventory', 'commit', 'ack') for action in ('emissions', 'receipts') for packet in godot[kind + '_' + action]]
    for packet in events:
        integer(packet['order'], 1, 8192, 'Godot observation order')
    orders = [packet['order'] for packet in events]
    require(len(set(orders)) == len(orders), 'Godot unique observation order')
    for kind in ('inventory', 'commit', 'ack'):
        emissions = godot[kind + '_emissions']
        receipts = godot[kind + '_receipts']
        require(all(packet['order'] > emissions[packet['emission']]['order'] for packet in receipts), 'Godot receipt follows publication')
        for bank in (emissions, receipts):
            orders = [packet['order'] for packet in bank]
            require(orders == sorted(orders), 'Godot action observation order')



def check_inventory(source, godot, loss, missing_rows, target_slots, unequal, warmup=0):
    require(type(godot['inventory_emissions']) is list and 1 <= len(godot['inventory_emissions']) <= 4096, 'Godot inventory emissions')
    for packet in godot['inventory_emissions']:
        check_godot_inventory(packet, missing_rows, target_slots, unequal, warmup)
    check_delivery(godot['inventory_emissions'], godot['lost_inventory'], godot['inventory_receipts'], 'Godot inventory', observed=True)
    if not loss:
        return
    first = next(packet for packet in source['controls'] if follower_inventory(packet, target_slots))
    require(same(source['lost_inventory'][0], first), 'source first inventory emission lost')
    retries = [packet for packet in source['received_controls']
               if same(payload(packet), payload(first)) and packet['emission'] > first['emission']]
    require(bool(retries), 'source exact inventory retry receipt')
    first_commit = min(packet['emission'] for packet in source['controls'] if 'DropCommit' in packet['body'])
    require(min(packet['emission'] for packet in retries) < first_commit, 'source inventory retry precedes commit')
    first_commit_order = min(packet['order'] for packet in source['controls'] if 'DropCommit' in packet['body'])
    require(min(packet['order'] for packet in retries) < first_commit_order, 'source inventory consumed before commit')
    first = godot['inventory_emissions'][0]
    require(same(godot['lost_inventory'][0], first), 'Godot first inventory emission lost')
    require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                for packet in godot['inventory_receipts']), 'Godot exact inventory retry receipt')
    require(min(packet['order'] for packet in godot['inventory_receipts']) < godot['commit_emissions'][0]['order'],
            'Godot inventory retry precedes commit')



def delay_source_inventory_retries(source):
    first = source['lost_inventory'][0]
    retries = [packet for packet in source['controls'] if packet['emission'] > first['emission'] and same(payload(packet), payload(first))]
    retry_ids = {packet['emission'] for packet in retries}
    events = sorted(source['controls'] + source['received_controls'], key=lambda packet: packet['order'])
    reordered_events = [packet for packet in events if packet['emission'] not in retry_ids] + [packet for packet in events if packet['emission'] in retry_ids]
    for order, packet in enumerate(reordered_events, 1):
        packet['order'] = order
    orders = {packet['emission']: packet['order'] for packet in source['controls']}
    for bank in ('lost_inventory', 'lost_history', 'lost_commit', 'lost_ack'):
        for packet in source[bank]:
            packet['order'] = orders[packet['emission']]
    reordered = [packet for packet in source['controls'] if packet['emission'] not in retry_ids] + retries
    indices = {packet['emission']: index for index, packet in enumerate(reordered)}
    source['controls'] = [{**packet, 'emission': indices[packet['emission']]} for packet in reordered]
    for bank in ('received_controls', 'lost_inventory', 'lost_history', 'lost_commit', 'lost_ack'):
        source[bank] = [{**packet, 'emission': indices[packet['emission']]} for packet in source[bank]]
    source['received_controls'].sort(key=lambda packet: (packet['to'], packet['emission']))



def delay_source_inventory_consumption(source):
    first = source['lost_inventory'][0]
    earliest = min(packet['order'] for packet in source['received_controls'] if same(payload(packet), payload(first)))
    maximum = max(packet['order'] for packet in source['controls'] + source['received_controls'])
    for packet in source['received_controls']:
        if packet['to'] == first['to'] and packet['order'] >= earliest:
            maximum += 1
            packet['order'] = maximum



def scale_godot_order(godot):
    for kind in ('inventory', 'commit', 'ack'):
        for bank in (kind + '_emissions', kind + '_receipts', 'lost_' + kind):
            for packet in godot[bank]:
                packet['order'] *= 4


def controls(clean, lost):
    # Value: protects=actual answer loss and exact recovery; fails_when=clean traces or missing retries pass; why_new=other loss stages differ; seam=none
    from drop_history_contract import compare
    fabricated_source = copy.deepcopy(clean)
    source = fabricated_source['source']
    source['lost_inventory'] = [copy.deepcopy(next(packet for packet in source['controls'] if follower_inventory(packet, 2)))]
    fabricated_source['godot'] = copy.deepcopy(lost['godot'])
    fabricated_godot = copy.deepcopy(lost)
    fabricated_godot['godot'] = copy.deepcopy(clean['godot'])
    fabricated_godot['godot']['lost_inventory'] = [copy.deepcopy(fabricated_godot['godot']['inventory_emissions'][0])]
    no_source_retry = copy.deepcopy(lost)
    source = no_source_retry['source']
    first = source['lost_inventory'][0]
    retained = [packet for packet in source['controls'] if packet['emission'] == first['emission'] or not same(payload(packet), payload(first))]
    indices = {packet['emission']: index for index, packet in enumerate(retained)}
    for bank in ('controls', 'received_controls', 'lost_inventory', 'lost_history', 'lost_commit', 'lost_ack'):
        source[bank] = [{**packet, 'emission': indices[packet['emission']]} for packet in source[bank] if packet['emission'] in indices]
    no_godot_retry = copy.deepcopy(lost)
    no_godot_retry['godot'].update(inventory_emissions=no_godot_retry['godot']['inventory_emissions'][:1], inventory_receipts=[])
    wrong_packet = copy.deepcopy(lost)
    for bank in ('inventory_emissions', 'inventory_receipts', 'lost_inventory'):
        for packet in wrong_packet['godot'][bank]:
            raw = bytearray.fromhex(packet['packet'])
            raw[-1] ^= 1
            packet['packet'] = raw.hex()
    late_source_retry = copy.deepcopy(lost)
    delay_source_inventory_retries(late_source_retry['source'])
    late_source_consumption = copy.deepcopy(lost)
    delay_source_inventory_consumption(late_source_consumption['source'])
    duplicate_godot_order = copy.deepcopy(lost)
    duplicate_godot_order['godot']['inventory_emissions'][1]['order'] = duplicate_godot_order['godot']['inventory_emissions'][0]['order']
    early_godot_receipt = copy.deepcopy(lost)
    scale_godot_order(early_godot_receipt['godot'])
    receipt = early_godot_receipt['godot']['inventory_receipts'][0]
    receipt['order'] = early_godot_receipt['godot']['inventory_emissions'][receipt['emission']]['order'] - 1
    late_godot_receipt = copy.deepcopy(lost)
    scale_godot_order(late_godot_receipt['godot'])
    late_godot_receipt['godot']['inventory_receipts'][0]['order'] = late_godot_receipt['godot']['commit_emissions'][0]['order'] + 1
    cases = [('Godot_duplicate_publication_order', duplicate_godot_order, 'Godot unique observation order'),
             ('Godot_inventory_receipt_before_publication', early_godot_receipt, 'Godot receipt follows publication'),
             ('Godot_commit_before_inventory_consumption', late_godot_receipt, 'Godot inventory retry precedes commit'),
             ('source_inventory_consumed_after_commit', late_source_consumption, 'source inventory consumed before commit'),
             ('source_inventory_retry_after_commit', late_source_retry, 'source inventory retry precedes commit'),
             ('fabricated_source_inventory_loss', fabricated_source, 'source emission/loss/receipt accounting'),
             ('fabricated_Godot_inventory_loss', fabricated_godot, 'Godot inventory emission/loss/receipt accounting'),
             ('missing_source_inventory_retry', no_source_retry, 'source exact inventory retry receipt'),
             ('missing_Godot_inventory_retry', no_godot_retry, 'Godot exact inventory retry receipt'),
             ('changed_Godot_inventory_retry', wrong_packet, 'Godot exact original inventory')]
    for name, candidate, diagnostic in cases:
        try:
            compare(candidate['source'], candidate['godot'], False, 4, 2, True, False, False, True)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in cases]
