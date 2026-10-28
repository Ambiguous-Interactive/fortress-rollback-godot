"""Independent original-history checks for the scoped three-peer donor witness."""
import copy
import json
import struct

REVISION = 'd124c89080004d96971a629bb0427056ee1805e3'


def require(condition, label):
    if not condition:
        raise ValueError('drop history: ' + label)


def same(actual, expected):
    return json.dumps(actual, sort_keys=True, separators=(',', ':')) == json.dumps(expected, sort_keys=True, separators=(',', ':'))


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + ' schema')


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, label)


def history_bytes(missing_rows, target_slots):
    return bytes((frame * 11 + player * 7 + index) % 251 for frame in range(8, 8 + missing_rows)
                 for player in range(2 * target_slots, 3 * target_slots) for index in range(4))


def original_history(missing_rows=1, target_slots=1):
    cut = 7 + missing_rows
    values = [0] * (3 * target_slots)
    result = []
    for frame in range(20):
        inputs = [bytes((min(frame, cut) * 11 + player * 7 + index) % 251 if player >= 2 * target_slots
                        else (frame * 11 + player * 7 + index) % 251 for index in range(4)) for player in range(3 * target_slots)]
        for player, data in enumerate(inputs):
            values[player] += sum(data)
        details = [{'bytes': data.hex(), 'status': 'disconnected' if player >= 2 * target_slots and frame > cut else 'confirmed'}
                   for player, data in enumerate(inputs)]
        result.append({'frame': frame, 'inputs': [data.hex() for data in inputs],
                       'state': {'frame': frame, 'bytes': struct.pack('<' + 'q' * (len(values) + 1), frame + 1, *values).hex(), 'inputs': details}})
    return result


def check_rows(value, label, missing_rows, target_slots, unequal=False):
    require(type(value) is list and len(value) == 2, label + ' survivors')
    expected = original_history(missing_rows, target_slots)
    for peer, survivor in enumerate(value):
        fields(survivor, 'peer current_frame confirmed_frame rows', label + ' survivor')
        require(same(survivor['peer'], peer), label + ' peer')
        integer(survivor['current_frame'], 22 + int(unequal and peer == 0), 22 + int(unequal and peer == 0), label + ' continuation')
        integer(survivor['confirmed_frame'], 20, 21, label + ' confirmation')
        require(same(survivor['rows'], expected), label + ' original rows, statuses or canonical states')


def check_before(value, label, missing_rows, target_slots, unequal=False):
    require(type(value) is list and len(value) == 2, label + ' inventory count')
    for peer, inventory in enumerate(value):
        fields(inventory, 'confirmed targets', label + ' inventory')
        integer(inventory['confirmed'], 4 + int(unequal and peer == 1), 4 + int(unequal and peer == 1), label + ' exposed confirmation')
        require(type(inventory['targets']) is list and len(inventory['targets']) == target_slots, label + ' target count')
        for offset, target in enumerate(inventory['targets']):
            fields(target, 'slot first last', label + ' target')
            require(same(target['slot'], 2 * target_slots + offset), label + ' target slot')
            integer(target['first'], 0, 7, label + ' retained start')
            integer(target['last'], 7 + peer * missing_rows, 7 + peer * missing_rows, label + ' physical missing row')


def check_source_operation(operation, label, target_slots):
    fields(operation, 'coordinator coordinator_generation sequence target_set_digest', label)
    for field, maximum in [('coordinator', 65535), ('coordinator_generation', 65535),
                           ('sequence', 4294967295), ('target_set_digest', 18446744073709551615)]:
        integer(operation[field], 0, maximum, label + ' ' + field)
    # Pinned p2p_session.rs hashes each target's little-endian u16 handle and generation.
    digest = 0xcbf29ce484222325
    for byte in b''.join(struct.pack('<HH', slot, 0) for slot in range(2 * target_slots, 3 * target_slots)):
        digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    require(same(operation, {'coordinator': 0, 'coordinator_generation': 0, 'sequence': 1,
                             'target_set_digest': digest}), label + ' identity')


def check_source_content(kind, content, label, missing_rows, target_slots, unequal=False):
    names = {
        'DropPrepare': 'operation targets participants',
        'DropReport': 'operation participant stage exposed_confirmed cut cut_digest receipts',
        'DropBackfill': 'operation chunk_index chunk_count start_frame frame_count bytes',
        'DropCommit': 'operation cut cut_digest',
    }
    fields(content, names[kind], label + ' ' + kind)
    targets = [{'handle': slot, 'generation': 0} for slot in range(2 * target_slots, 3 * target_slots)]
    if kind == 'DropPrepare':
        require(same(content['targets'], targets), label + ' targets')
        require(same(content['participants'], [0, target_slots]), label + ' participants')
    if kind in ('DropReport', 'DropCommit'):
        cut = 7 + missing_rows
        digest = 0xcbf29ce484222325
        for slot in range(2 * target_slots, 3 * target_slots):
            data = struct.pack('<H', slot) + bytes((cut * 11 + slot * 7 + index) % 251 for index in range(4))
            for byte in data:
                digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
        if kind == 'DropCommit':
            require(same(content['cut_digest'], digest), label + ' cut digest')
            return
        participant = content['participant']
        require(any(same(participant, slot) for slot in (0, target_slots)), label + ' participant')
        stage = content['stage']
        require(stage in ('Inventory', 'Ready', 'Committed'), label + ' report stage')
        if stage == 'Inventory':
            receipts = [{'target': target['handle'], 'available_from': 3 if unequal and participant == 0 else 2,
                         'contiguous_through': 7 if participant == 0 else cut} for target in targets]
            require(same(content['receipts'], receipts), label + ' receipts')
            require(same(content['exposed_confirmed'], 4 + int(unequal and participant == target_slots)) and same(content['cut'], -1)
                    and same(content['cut_digest'], 0), label + ' inventory values')
        else:
            require(same(content['exposed_confirmed'], -1) and same(content['cut'], cut)
                    and same(content['cut_digest'], digest) and same(content['receipts'], []), label + ' certificate values')


def check_source_controls(controls, label, missing_rows, target_slots, unequal=False, complete=True):
    cut = 7 + missing_rows
    donor_bytes = list(history_bytes(missing_rows, target_slots))
    require(type(controls) is list and 1 <= len(controls) <= 4096, label + ' count')
    donor = False
    commit = False
    inventories = set()
    for packet in controls:
        fields(packet, 'from to body emission', label)
        integer(packet['emission'], 0, 4095, label + ' emission')
        integer(packet['from'], 0, 1, label + ' sender')
        integer(packet['to'], 0, 1, label + ' recipient')
        require(packet['from'] != packet['to'], label + ' remote recipient')
        body = packet['body']
        require(type(body) is dict and len(body) == 1, label + ' body')
        kind, content = next(iter(body.items()))
        require(kind in ('DropPrepare', 'DropReport', 'DropBackfill', 'DropCommit', 'DropAbort') and type(content) is dict, label + ' kind')
        require(kind != 'DropAbort', label + ' source aborted')
        check_source_operation(content.get('operation'), label + ' operation', target_slots)
        check_source_content(kind, content, label, missing_rows, target_slots, unequal)
        if kind == 'DropReport' and content['stage'] == 'Inventory':
            inventories.add(content['participant'])
        if kind == 'DropBackfill':
            require(same(content.get('start_frame'), 8) and same(content.get('frame_count'), missing_rows)
                    and same(content.get('chunk_index'), 0) and same(content.get('chunk_count'), 1)
                    and same(content.get('bytes'), donor_bytes), label + ' original donor backfill')
            donor = donor or (packet['from'] == 1 and packet['to'] == 0)
        if kind == 'DropCommit':
            require(same(content.get('cut'), cut), label + ' receipt-raised commit')
            commit = True
    require(donor, label + ' missing donor backfill')
    require(commit, label + ' missing commit')
    if complete:
        require(inventories == {0, target_slots}, label + ' missing participant inventory')



def check_godot_packet(raw, missing_rows, target_slots):
    cut = 7 + missing_rows
    donor_bytes = history_bytes(missing_rows, target_slots)
    require(type(raw) is str and len(raw) == 196 + target_slots * 6 + missing_rows * target_slots * 8
            and all(character in '0123456789abcdef' for character in raw), 'Godot packet bytes')
    packet = bytes.fromhex(raw)
    require(packet[:8] == b'FRGP\x02\x00\x0c\x00' and packet[8:24] == bytes([91]) + bytes(15)
            and packet[24:32] == bytes([2]) + bytes(7) and packet[32:40] == bytes([22]) + bytes(7), 'Godot packet identity')
    require(struct.unpack_from('<I', packet, 40)[0] == 54 + target_slots * 3 + missing_rows * target_slots * 4
            and packet[44:48] == bytes([3, 5, 0, 0]), 'Godot history packet kind')
    # Fixture connection IDs start with 21/23 then zero; Godot eras read those bytes as big-endian hex.
    target_era = 23 << 8
    digest = 0x14650fb0739d0383
    targets = b''.join(struct.pack('<BH', slot, target_era) for slot in range(2 * target_slots, 3 * target_slots))
    for byte in targets:
        digest = ((digest ^ byte) * 1099511628211) & 0x3fffffffffffffff
    require(struct.unpack_from('<HHIQ', packet, 48) == (0, 21 << 8, target_era + 1, digest)
            and packet[94:94 + len(targets)] == targets, 'Godot history packet operation')
    require(struct.unpack_from('<H', packet, 48)[0] == 0 and struct.unpack_from('<i', packet, 64)[0] == cut
            and struct.unpack_from('<i', packet, 68)[0] == 8 and struct.unpack_from('<i', packet, 72)[0] == target_slots,
            'Godot history packet range')
    require(struct.unpack_from('<3H', packet, 84) == (0, 1, 0) and struct.unpack_from('<I', packet, 90)[0] == len(targets)
            and struct.unpack_from('<I', packet, 94 + len(targets))[0] == len(donor_bytes) and packet[98 + len(targets):] == donor_bytes,
            'Godot history packet original bytes')


def check_godot_commit(packet, missing_rows, target_slots, acknowledgement=False):
    fields(packet, 'from to packet emission order', 'Godot commit')
    integer(packet['order'], 1, 4096, 'Godot commit order')
    require(same(packet['from'], int(acknowledgement)) and same(packet['to'], int(not acknowledgement)), 'Godot commit sender')
    raw = packet['packet']
    require(type(raw) is str and len(raw) == 196 + target_slots * 6
            and all(character in '0123456789abcdef' for character in raw), 'Godot commit bytes')
    cut = 7 + missing_rows
    target_era = 23 << 8
    targets = b''.join(struct.pack('<BH', slot, target_era) for slot in range(2 * target_slots, 3 * target_slots))
    def digest(data):
        value = 0x14650fb0739d0383
        for byte in data:
            value = ((value ^ byte) * 1099511628211) & 0x3fffffffffffffff
        return value or 1
    value = bytes((cut * 11 + slot * 7 + index) % 251 for slot in range(2 * target_slots, 3 * target_slots) for index in range(4))
    expected = (b'FRGP\x02\x00\x0c\x00' + bytes([91]) + bytes(15) + bytes([2 if acknowledgement else 1]) + bytes(7) + bytes([22 if acknowledgement else 21]) + bytes(7)
                + struct.pack('<I4BHHIQiiiQHHHI', 54 + len(targets), 2 if acknowledgement else 4, 3 if acknowledgement else 0, 0, 0, 0, 21 << 8,
                              target_era + 1, digest(targets), cut, 0, cut if acknowledgement else 7, digest(value), 0, 0, 0, len(targets))
                + targets + struct.pack('<I', 0))
    require(bytes.fromhex(raw) == expected, 'Godot exact certified acknowledgement' if acknowledgement else 'Godot exact certified commit')


def check_delivery(emissions, lost, receipts, label, grouped=False):
    require(type(emissions) is list and 1 <= len(emissions) <= 4096, label + ' emissions')
    for index, packet in enumerate(emissions):
        require(type(packet) is dict and type(packet.get('emission')) is int and packet['emission'] == index, label + ' emission order')
    expected = [packet for packet in emissions if not any(same(packet, dropped) for dropped in lost)]
    if grouped:
        expected = [packet for recipient in range(2) for packet in expected if packet['to'] == recipient]
    require(same(receipts, expected), label + ' emission/loss/receipt accounting')


def payload(packet):
    return {key: value for key, value in packet.items() if key not in ('emission', 'order')}


def compare(source, godot, loss=False, missing_rows=1, target_slots=1, unequal=False, commit_loss=False, ack_loss=False):
    require(type(missing_rows) is int and missing_rows in (1, 4), 'scenario missing rows')
    require(type(target_slots) is int and target_slots in (1, 2), 'scenario target slots')
    cut = 7 + missing_rows
    fields(source, 'format complete missing_rows target_slots upstream_revision before dropped controls '
           'received_controls survivors lost_history lost_commit lost_ack', 'source')
    fields(godot, 'format complete missing_rows target_slots before cuts history_packets donors history_emissions history_receipts '
           'survivors failures lost_history lost_commit commit_emissions commit_receipts lost_ack ack_emissions ack_receipts', 'Godot')
    for label, value in [('source', source), ('Godot', godot)]:
        require(same(value['format'], 4) and value['complete'] is True, label + ' completion')
        require(same(value['missing_rows'], missing_rows), label + ' missing rows')
        require(same(value['target_slots'], target_slots), label + ' target slots')
        check_before(value['before'], label, missing_rows, target_slots, unequal)
        check_rows(value['survivors'], label, missing_rows, target_slots, unequal)
    require(source['upstream_revision'] == REVISION, 'source revision')
    require(same(source['dropped'], [target_slots, target_slots]), 'source drops')
    check_source_controls(source['controls'], 'source emitted controls', missing_rows, target_slots, unequal)
    check_source_controls(source['received_controls'], 'source received controls', missing_rows, target_slots, unequal)
    require(same(godot['cuts'], [[cut] * target_slots, [cut] * target_slots]) and same(godot['donors'], [1]), 'Godot cut or donor')
    integer(godot['history_packets'], 1, 4096, 'Godot historical transfer')
    require(godot['failures'] == [], 'Godot assertion failures')
    donor_bytes = history_bytes(missing_rows, target_slots).hex()
    receipts = godot['history_receipts']
    require(type(receipts) is list and len(receipts) == godot['history_packets'], 'Godot history receipt count')
    for receipt in receipts:
        fields(receipt, 'from to bytes packet emission', 'Godot history receipt')
        require(same(receipt['from'], 1) and same(receipt['to'], 0) and receipt['bytes'] == donor_bytes, 'Godot original donor receipt')
        check_godot_packet(receipt['packet'], missing_rows, target_slots)
    require(type(source['lost_history']) is list and len(source['lost_history']) == int(loss), 'source loss count')
    require(type(godot['lost_history']) is list and len(godot['lost_history']) == int(loss), 'Godot loss count')
    require(type(source['lost_commit']) is list and len(source['lost_commit']) == int(commit_loss), 'source commit loss count')
    require(type(godot['lost_commit']) is list and len(godot['lost_commit']) == int(commit_loss), 'Godot commit loss count')
    require(type(source['lost_ack']) is list and len(source['lost_ack']) == int(ack_loss), 'source acknowledgement loss count')
    require(type(godot['lost_ack']) is list and len(godot['lost_ack']) == int(ack_loss), 'Godot acknowledgement loss count')
    check_delivery(source['controls'], source['lost_history'] + source['lost_commit'] + source['lost_ack'], source['received_controls'], 'source', grouped=True)
    check_delivery(godot['history_emissions'], godot['lost_history'], receipts, 'Godot')
    require(type(godot['commit_emissions']) is list and 1 <= len(godot['commit_emissions']) <= 4096, 'Godot commit emissions')
    for packet in godot['commit_emissions']:
        check_godot_commit(packet, missing_rows, target_slots)
    check_delivery(godot['commit_emissions'], godot['lost_commit'], godot['commit_receipts'], 'Godot commit')
    require(type(godot['ack_emissions']) is list and 1 <= len(godot['ack_emissions']) <= 4096, 'Godot acknowledgement emissions')
    for packet in godot['ack_emissions']:
        check_godot_commit(packet, missing_rows, target_slots, acknowledgement=True)
    check_delivery(godot['ack_emissions'], godot['lost_ack'], godot['ack_receipts'], 'Godot acknowledgement')
    if ack_loss:
        first = next(packet for packet in source['controls'] if packet['from'] == 1 and packet['to'] == 0
                     and packet['body'].get('DropReport', {}).get('stage') == 'Committed'
                     and same(packet['body']['DropReport']['participant'], target_slots))
        require(same(source['lost_ack'][0], first), 'source first acknowledgement emission lost')
        require(first['from'] == 1 and first['to'] == 0, 'source lost follower acknowledgement')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in source['received_controls']), 'source exact acknowledgement retry receipt')
        first = godot['ack_emissions'][0]
        require(same(godot['lost_ack'][0], first), 'Godot first acknowledgement emission lost')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in godot['ack_receipts']), 'Godot exact acknowledgement retry receipt')
        require(len(godot['commit_receipts']) >= 2
                and same(payload(godot['commit_receipts'][0]), payload(godot['commit_receipts'][1])),
                'Godot acknowledgement requires repeated commit receipt')
        commits = godot['commit_receipts']
        require(commits[0]['order'] < first['order'] < commits[1]['order']
                and min(packet['order'] for packet in godot['ack_receipts']) > commits[1]['order'],
                'Godot acknowledgement follows repeated commit receipt')
    if commit_loss:
        first = next(packet for packet in source['controls'] if 'DropCommit' in packet['body'])
        require(same(source['lost_commit'][0], first), 'source first commit emission lost')
        require(first['from'] == 0 and first['to'] == 1, 'source lost coordinator commit')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in source['received_controls']), 'source exact commit retry receipt')
        first = godot['commit_emissions'][0]
        require(same(godot['lost_commit'][0], first), 'Godot first commit emission lost')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in godot['commit_receipts']), 'Godot exact commit retry receipt')
    if loss:
        lost_source = source['lost_history'][0]
        check_source_controls([lost_source, next(packet for packet in source['controls'] if 'DropCommit' in packet['body'])],
                              'source lost packet', missing_rows, target_slots, unequal, complete=False)
        first_source = next(packet for packet in source['controls'] if packet['from'] == 1 and packet['to'] == 0 and 'DropBackfill' in packet['body'])
        require(same(lost_source, first_source), 'source first donor emission lost')
        require(sum(same(payload(packet), payload(lost_source)) for packet in source['controls']) >= 2, 'source exact donor retry emission')
        require(any(same(payload(packet), payload(lost_source)) and packet['emission'] > lost_source['emission']
                    for packet in source['received_controls']), 'source exact donor retry receipt')
        lost_godot = godot['lost_history'][0]
        require(same(lost_godot, godot['history_emissions'][0]), 'Godot first donor emission lost')
        require(any(same(payload(packet), payload(lost_godot)) and packet['emission'] > lost_godot['emission']
                    for packet in receipts), 'Godot exact donor retry receipt')
    return {'cut': cut, 'unequal_exposure': unequal, 'missing_rows': missing_rows, 'target_slots': target_slots,
            'compared_frames': 20, 'survivors': 2, 'original_history_validated': True,
            'lost_first_history_recovered': loss, 'lost_first_commit_recovered': commit_loss, 'lost_first_acknowledgement_recovered': ack_loss,
            'source_donor_emission_and_receipt': True, 'Godot_donor_receipt': True}


def negative_controls(source, godot, loss=False, missing_rows=1, target_slots=1, unequal=False, commit_loss=False, ack_loss=False):
    def shared_wrong_history(source, godot):
        for trace in (source, godot):
            trace['survivors'][0]['rows'][8]['inputs'][2] = '00000000'

    mutations = {
        'missing_source_inventory': ('source emitted controls missing participant inventory', lambda s, g: s.update(
            controls=[packet for packet in s['controls'] if not ('DropReport' in packet['body']
                and packet['body']['DropReport']['stage'] == 'Inventory')])),
        'missing_received_inventory': ('source received controls missing participant inventory', lambda s, g: s.update(
            received_controls=[packet for packet in s['received_controls'] if not ('DropReport' in packet['body']
                and packet['body']['DropReport']['stage'] == 'Inventory' and packet['body']['DropReport']['participant'] == target_slots)])),
        'wrong_source_targets': ('source target slots', lambda s, g: s.update(target_slots=3 - target_slots)),
        'wrong_Godot_targets': ('Godot target slots', lambda s, g: g.update(target_slots=3 - target_slots)),
        'wrong_source_scenario': ('source missing rows', lambda s, g: s.update(missing_rows=4 if missing_rows == 1 else 1)),
        'wrong_Godot_scenario': ('Godot missing rows', lambda s, g: g.update(missing_rows=4 if missing_rows == 1 else 1)),
        'shared_wrong_history': ('source original rows, statuses or canonical states', shared_wrong_history),
        'missing_source_donor': ('source emitted controls missing donor backfill', lambda s, g: s.update(
            controls=[packet for packet in s['controls'] if not (packet['from'] == 1 and 'DropBackfill' in packet['body'])])),
        'missing_source_receipt': ('source received controls missing donor backfill', lambda s, g: s.update(
            received_controls=[packet for packet in s['received_controls'] if not (packet['from'] == 1 and 'DropBackfill' in packet['body'])])),
        'wrong_source_cut': ('source emitted controls receipt-raised commit', lambda s, g: next(
            packet['body']['DropCommit'] for packet in s['controls'] if 'DropCommit' in packet['body']).update(cut=4)),
        'lost_original_row': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][8]['inputs'].__setitem__(2, '00000000')),
        'wrong_canonical_state': ('source original rows, statuses or canonical states', lambda s, g: s['survivors'][1]['rows'][9]['state'].update(bytes='00' * 32)),
        'lost_status': ('Godot original rows, statuses or canonical states', lambda s, g:
            g['survivors'][0]['rows'][8 + missing_rows]['state']['inputs'][2 * target_slots].update(status='confirmed')),
        'truncated_donor_packet': ('Godot packet bytes', lambda s, g: g['history_receipts'][0].update(packet='00')),
        'corrupt_donor_packet': ('Godot history packet original bytes', lambda s, g: g['history_receipts'][0].update(
            packet=g['history_receipts'][0]['packet'][:-2] + '00')),
        'foreign_donor': ('Godot original donor receipt', lambda s, g: g['history_receipts'][0].update(**{'from': 0})),
        'bool_frame': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][0].update(frame=False)),
    }
    if unequal:
        for label, bank in [('source', 'source'), ('Godot', 'godot')]:
            mutations[label + '_equalized_exposure'] = (label + ' exposed confirmation',
                lambda s, g, bank=bank: (s if bank == 'source' else g)['before'][1].update(confirmed=4))
    if target_slots > 1:
        mutations['wrong_second_target_cut'] = ('Godot cut or donor', lambda s, g: g['cuts'][0].__setitem__(1, 4))
        mutations['lost_second_target'] = ('Godot original rows, statuses or canonical states', lambda s, g:
            g['survivors'][0]['rows'][8]['inputs'].__setitem__(3 * target_slots - 1, '00000000'))
        mutations['missing_second_inventory'] = ('source target count', lambda s, g: s['before'][0]['targets'].pop())
    if missing_rows > 1:
        mutations['truncated_source_history_tail'] = ('source emitted controls original donor backfill', lambda s, g: next(
            packet['body']['DropBackfill'] for packet in s['controls'] if 'DropBackfill' in packet['body']).update(
                frame_count=1, bytes=[102, 103, 104, 105]))

    def source_content_mutation(source, godot, kind, mutate):
        for bank in ('controls', 'lost_history', 'lost_commit', 'lost_ack', 'received_controls'):
            for packet in source[bank]:
                if kind in packet['body']:
                    mutate(packet['body'][kind])

    mutations['source_prepare_target_generation'] = ('source emitted controls targets', lambda s, g:
        source_content_mutation(s, g, 'DropPrepare', lambda content: content['targets'][-1].update(generation=1)))

    mutations['source_prepare_participants'] = ('source emitted controls participants', lambda s, g:
        source_content_mutation(s, g, 'DropPrepare', lambda content: content.update(participants=[0])))
    mutations['source_report_target'] = ('source emitted controls receipts', lambda s, g:
        source_content_mutation(s, g, 'DropReport', lambda content:
            content['receipts'][-1].update(target=0) if content['stage'] == 'Inventory' else None))
    mutations['source_commit_digest'] = ('source emitted controls cut digest', lambda s, g:
        source_content_mutation(s, g, 'DropCommit', lambda content: content.update(cut_digest=0)))
    for kind in ('DropPrepare', 'DropReport', 'DropBackfill', 'DropCommit'):
        mutations['source_extra_' + kind] = ('source emitted controls ' + kind + ' schema', lambda s, g, kind=kind:
            source_content_mutation(s, g, kind, lambda content: content.update(extra=0)))

    def source_operation_mutation(source, godot, field, value):
        for bank in ('controls', 'lost_history', 'lost_commit', 'lost_ack', 'received_controls'):
            for packet in source[bank]:
                if 'DropBackfill' in packet['body']:
                    content = packet['body']['DropBackfill']
                    if field is None:
                        content['operation'] = value
                    else:
                        content['operation'][field] = value

    def godot_operation_mutation(source, godot, offset, width):
        for bank in ('history_emissions', 'lost_history', 'history_receipts'):
            for packet in godot[bank]:
                raw = bytearray.fromhex(packet['packet'])
                raw[offset:offset + width] = (1).to_bytes(width, 'little')
                packet['packet'] = raw.hex()

    for name, offset, width in [('generation', 50, 2), ('sequence', 52, 4), ('digest', 56, 8), ('target_generation', 95, 2)]:
        mutations['Godot_operation_' + name] = ('Godot history packet operation',
            lambda s, g, offset=offset, width=width: godot_operation_mutation(s, g, offset, width))
    if target_slots > 1:
        mutations['Godot_second_target_generation'] = ('Godot history packet operation', lambda s, g: godot_operation_mutation(s, g, 98, 2))
    operation_cases = [('missing', None, None, 'schema'), ('bool_sequence', 'sequence', False, 'sequence'),
                       ('foreign_sequence', 'sequence', 2, 'identity'), ('foreign_coordinator', 'coordinator', 1, 'identity'),
                       ('foreign_generation', 'coordinator_generation', 1, 'identity'),
                       ('foreign_target_digest', 'target_set_digest', 0, 'identity')]
    for name, field, value, diagnostic in operation_cases:
        mutations['source_operation_' + name] = ('source emitted controls operation ' + diagnostic,
            lambda s, g, field=field, value=value: source_operation_mutation(s, g, field, value))
    if loss:
        def remove_source_retries(source, godot):
            lost = source['lost_history'][0]
            seen = False
            retained = []
            for packet in source['controls']:
                if same(payload(packet), payload(lost)):
                    if seen:
                        continue
                    seen = True
                retained.append(packet)
            source['controls'] = retained

        mutations['missing_source_retry'] = ('source emission order', remove_source_retries)
        mutations['changed_Godot_lost_packet'] = ('Godot emission/loss/receipt accounting', lambda s, g: g['lost_history'][0].update(
            packet=g['lost_history'][0]['packet'][:100] + '01' + g['lost_history'][0]['packet'][102:]))
        mutations['missing_source_loss'] = ('source loss count', lambda s, g: s.update(lost_history=[]))
        mutations['missing_Godot_loss'] = ('Godot loss count', lambda s, g: g.update(lost_history=[]))
    mutations['malformed_source_commit_loss'] = ('source commit loss count', lambda s, g: s.update(lost_commit=None))
    mutations['malformed_Godot_commit_emissions'] = ('Godot commit emissions', lambda s, g: g.update(commit_emissions=None))
    mutations['corrupt_Godot_commit'] = ('Godot exact certified commit', lambda s, g: g['commit_emissions'][0].update(
        packet=g['commit_emissions'][0]['packet'][:128] + '00' + g['commit_emissions'][0]['packet'][130:]))
    if commit_loss:
        mutations['missing_source_commit_loss'] = ('source commit loss count', lambda s, g: s.update(lost_commit=[]))
        mutations['missing_Godot_commit_loss'] = ('Godot commit loss count', lambda s, g: g.update(lost_commit=[]))
        mutations['delivered_lost_Godot_commit'] = ('Godot commit emission/loss/receipt accounting', lambda s, g:
            g['commit_receipts'].insert(0, copy.deepcopy(g['lost_commit'][0])))
        mutations['delivered_lost_source_commit'] = ('source emission/loss/receipt accounting', lambda s, g:
            s['received_controls'].insert(0, copy.deepcopy(s['lost_commit'][0])))
    mutations['malformed_source_acknowledgement_loss'] = ('source acknowledgement loss count', lambda s, g: s.update(lost_ack=None))
    mutations['malformed_Godot_acknowledgement_emissions'] = ('Godot acknowledgement emissions', lambda s, g: g.update(ack_emissions=None))
    mutations['corrupt_Godot_acknowledgement'] = ('Godot exact certified acknowledgement', lambda s, g: g['ack_emissions'][0].update(
        packet=g['ack_emissions'][0]['packet'][:128] + '00' + g['ack_emissions'][0]['packet'][130:]))
    if ack_loss:
        mutations['missing_source_acknowledgement_loss'] = ('source acknowledgement loss count', lambda s, g: s.update(lost_ack=[]))
        mutations['missing_Godot_acknowledgement_loss'] = ('Godot acknowledgement loss count', lambda s, g: g.update(lost_ack=[]))
        mutations['delivered_lost_Godot_acknowledgement'] = ('Godot acknowledgement emission/loss/receipt accounting', lambda s, g:
            g['ack_receipts'].insert(0, copy.deepcopy(g['lost_ack'][0])))
        mutations['delivered_lost_source_acknowledgement'] = ('source emission/loss/receipt accounting', lambda s, g:
            s['received_controls'].insert(0, copy.deepcopy(s['lost_ack'][0])))
    for name, (diagnostic, mutate) in mutations.items():
        candidate_source, candidate_godot = copy.deepcopy(source), copy.deepcopy(godot)
        mutate(candidate_source, candidate_godot)
        try:
            compare(candidate_source, candidate_godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return list(mutations)


def loss_evidence_controls(clean, lost, missing_rows=1, target_slots=1, unequal=False):
    # Value: protects=actual first-emission loss; fails_when=loss is relabeled or delivered twice; why_new=payload equality hid receipt multiplicity; seam=none
    fabricated = copy.deepcopy(clean)
    fabricated['source']['lost_history'] = [copy.deepcopy(next(packet for packet in fabricated['source']['controls']
        if packet['from'] == 1 and packet['to'] == 0 and 'DropBackfill' in packet['body']))]
    fabricated['godot']['lost_history'] = [copy.deepcopy(fabricated['godot']['history_receipts'][0])]
    fabricated_godot = copy.deepcopy(lost)
    fabricated_godot['godot'] = copy.deepcopy(fabricated['godot'])
    extra_source = copy.deepcopy(lost)
    extra_source['source']['received_controls'].append(copy.deepcopy(extra_source['source']['lost_history'][0]))
    extra_godot = copy.deepcopy(lost)
    extra_godot['godot']['history_receipts'].append(copy.deepcopy(extra_godot['godot']['lost_history'][0]))
    extra_godot['godot']['history_packets'] += 1
    reordered = copy.deepcopy(lost)
    reordered['source']['received_controls'].reverse()
    controls = [('fabricated_loss_on_clean', fabricated, 'source emission/loss/receipt accounting'),
                ('fabricated_Godot_loss_on_clean', fabricated_godot, 'Godot emission/loss/receipt accounting'),
                ('delivered_lost_source_emission', extra_source, 'source emission/loss/receipt accounting'),
                ('delivered_lost_Godot_emission', extra_godot, 'Godot emission/loss/receipt accounting'),
                ('reordered_source_receipts', reordered, 'source emission/loss/receipt accounting')]
    for name, candidate, diagnostic in controls:
        try:
            compare(candidate['source'], candidate['godot'], True, missing_rows, target_slots, unequal)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in controls]


def commit_loss_evidence_controls(clean, lost):
    # Value: protects=first COMMIT physically lost; fails_when=clean delivery is relabeled; why_new=history loss controls cannot qualify COMMIT loss; seam=none
    fabricated = copy.deepcopy(clean)
    fabricated['source']['lost_commit'] = [copy.deepcopy(next(packet for packet in fabricated['source']['controls']
        if 'DropCommit' in packet['body']))]
    fabricated['godot']['lost_commit'] = [copy.deepcopy(fabricated['godot']['commit_emissions'][0])]
    fabricated_godot = copy.deepcopy(lost)
    fabricated_godot['godot'] = copy.deepcopy(fabricated['godot'])
    controls = [('fabricated_source_commit_loss', fabricated, 'source emission/loss/receipt accounting'),
                ('fabricated_Godot_commit_loss', fabricated_godot, 'Godot commit emission/loss/receipt accounting')]
    for name, candidate, diagnostic in controls:
        try:
            compare(candidate['source'], candidate['godot'], False, 4, 2, True, True)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in controls]
