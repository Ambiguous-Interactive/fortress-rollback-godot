"""Independent original-history checks for the scoped three-peer donor witness."""
import copy
import json
import struct

REVISION = 'f13cd5c0f2815926785a395947e18da0dbea0dd8'


def require(condition, label):
    if not condition:
        raise ValueError('drop history: ' + label)


def same(actual, expected):
    return json.dumps(actual, sort_keys=True, separators=(',', ':')) == json.dumps(expected, sort_keys=True, separators=(',', ':'))


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + ' schema')


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, label)


def original_history():
    values = [0, 0, 0]
    result = []
    for frame in range(20):
        inputs = [bytes((min(frame, 8) * 11 + player * 7 + index) % 251 if player == 2
                        else (frame * 11 + player * 7 + index) % 251 for index in range(4)) for player in range(3)]
        for player, data in enumerate(inputs):
            values[player] += sum(data)
        details = [{'bytes': data.hex(), 'status': 'disconnected' if player == 2 and frame > 8 else 'confirmed'}
                   for player, data in enumerate(inputs)]
        result.append({'frame': frame, 'inputs': [data.hex() for data in inputs],
                       'state': {'frame': frame, 'bytes': struct.pack('<4q', frame + 1, *values).hex(), 'inputs': details}})
    return result


def check_rows(value, label):
    require(type(value) is list and len(value) == 2, label + ' survivors')
    expected = original_history()
    for peer, survivor in enumerate(value):
        fields(survivor, 'peer current_frame confirmed_frame rows', label + ' survivor')
        require(same(survivor['peer'], peer), label + ' peer')
        integer(survivor['current_frame'], 22, 22, label + ' continuation')
        integer(survivor['confirmed_frame'], 20, 21, label + ' confirmation')
        require(same(survivor['rows'], expected), label + ' original rows, statuses or canonical states')


def check_before(value, label):
    require(type(value) is list and len(value) == 2, label + ' inventory count')
    for peer, inventory in enumerate(value):
        fields(inventory, 'confirmed target_first target_last', label + ' inventory')
        integer(inventory['confirmed'], 4, 4, label + ' exposed confirmation')
        integer(inventory['target_first'], 0, 7, label + ' retained start')
        integer(inventory['target_last'], 7 + peer, 7 + peer, label + ' physical missing row')


def check_source_operation(operation, label):
    fields(operation, 'coordinator coordinator_generation sequence target_set_digest', label)
    for field, maximum in [('coordinator', 65535), ('coordinator_generation', 65535),
                           ('sequence', 4294967295), ('target_set_digest', 18446744073709551615)]:
        integer(operation[field], 0, maximum, label + ' ' + field)
    # Pinned p2p_session.rs hashes each target's little-endian u16 handle and generation.
    digest = 0xcbf29ce484222325
    for byte in struct.pack('<HH', 2, 0):
        digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    require(same(operation, {'coordinator': 0, 'coordinator_generation': 0, 'sequence': 1,
                             'target_set_digest': digest}), label + ' identity')


def check_source_controls(controls, label):
    require(type(controls) is list and 1 <= len(controls) <= 4096, label + ' count')
    donor = False
    commit = False
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
        check_source_operation(content.get('operation'), label + ' operation')
        if kind == 'DropBackfill' and packet['from'] == 1 and packet['to'] == 0:
            require(same(content.get('start_frame'), 8) and same(content.get('frame_count'), 1)
                    and same(content.get('chunk_index'), 0) and same(content.get('chunk_count'), 1)
                    and same(content.get('bytes'), [102, 103, 104, 105]), label + ' original donor backfill')
            donor = True
        if kind == 'DropCommit':
            require(same(content.get('cut'), 8), label + ' receipt-raised commit')
            commit = True
    require(donor, label + ' missing donor backfill')
    require(commit, label + ' missing commit')



def check_godot_packet(raw):
    require(type(raw) is str and len(raw) == 210 and all(character in '0123456789abcdef' for character in raw), 'Godot packet bytes')
    packet = bytes.fromhex(raw)
    require(packet[:8] == b'FRGP\x02\x00\x0c\x00' and packet[8:24] == bytes([91]) + bytes(15)
            and packet[24:32] == bytes([2]) + bytes(7) and packet[32:40] == bytes([22]) + bytes(7), 'Godot packet identity')
    require(struct.unpack_from('<I', packet, 40)[0] == 61 and packet[44:48] == bytes([3, 5, 0, 0]), 'Godot history packet kind')
    # Fixture connection IDs start with 21/23 then zero; Godot eras read those bytes as big-endian hex.
    target_era = 23 << 8
    digest = 0x14650fb0739d0383
    for byte in struct.pack('<BH', 2, target_era):
        digest = ((digest ^ byte) * 1099511628211) & 0x3fffffffffffffff
    require(struct.unpack_from('<HHIQ', packet, 48) == (0, 21 << 8, target_era + 1, digest)
            and packet[94:97] == struct.pack('<BH', 2, target_era), 'Godot history packet operation')
    require(struct.unpack_from('<H', packet, 48)[0] == 0 and struct.unpack_from('<i', packet, 64)[0] == 8
            and struct.unpack_from('<i', packet, 68)[0] == 8 and struct.unpack_from('<i', packet, 72)[0] == 1,
            'Godot history packet range')
    require(struct.unpack_from('<3H', packet, 84) == (0, 1, 0) and struct.unpack_from('<I', packet, 90)[0] == 3
            and packet[94] == 2 and struct.unpack_from('<I', packet, 97)[0] == 4 and packet[101:] == bytes([102, 103, 104, 105]),
            'Godot history packet original bytes')


def check_delivery(emissions, lost, receipts, label, grouped=False):
    require(type(emissions) is list and 1 <= len(emissions) <= 4096, label + ' emissions')
    for index, packet in enumerate(emissions):
        require(type(packet) is dict and type(packet.get('emission')) is int and packet['emission'] == index, label + ' emission order')
    expected = [packet for packet in emissions if not any(same(packet, dropped) for dropped in lost)]
    if grouped:
        expected = [packet for recipient in range(2) for packet in expected if packet['to'] == recipient]
    require(same(receipts, expected), label + ' emission/loss/receipt accounting')


def payload(packet):
    return {key: value for key, value in packet.items() if key != 'emission'}


def compare(source, godot, loss=False):
    fields(source, 'format complete upstream_revision before dropped controls received_controls survivors lost_history', 'source')
    fields(godot, 'format complete before cuts history_packets donors history_emissions history_receipts survivors failures lost_history', 'Godot')
    for label, value in [('source', source), ('Godot', godot)]:
        require(same(value['format'], 1) and value['complete'] is True, label + ' completion')
        check_before(value['before'], label)
        check_rows(value['survivors'], label)
    require(source['upstream_revision'] == REVISION, 'source revision')
    require(same(source['dropped'], [1, 1]), 'source drops')
    check_source_controls(source['controls'], 'source emitted controls')
    check_source_controls(source['received_controls'], 'source received controls')
    require(same(godot['cuts'], [8, 8]) and same(godot['donors'], [1]), 'Godot cut or donor')
    integer(godot['history_packets'], 1, 4096, 'Godot historical transfer')
    require(godot['failures'] == [], 'Godot assertion failures')
    receipts = godot['history_receipts']
    require(type(receipts) is list and len(receipts) == godot['history_packets'], 'Godot history receipt count')
    for receipt in receipts:
        fields(receipt, 'from to bytes packet emission', 'Godot history receipt')
        require(same(receipt['from'], 1) and same(receipt['to'], 0) and receipt['bytes'] == '66676869', 'Godot original donor receipt')
        check_godot_packet(receipt['packet'])
    require(type(source['lost_history']) is list and len(source['lost_history']) == int(loss), 'source loss count')
    require(type(godot['lost_history']) is list and len(godot['lost_history']) == int(loss), 'Godot loss count')
    check_delivery(source['controls'], source['lost_history'], source['received_controls'], 'source', grouped=True)
    check_delivery(godot['history_emissions'], godot['lost_history'], receipts, 'Godot')
    if loss:
        lost_source = source['lost_history'][0]
        check_source_controls([lost_source, next(packet for packet in source['controls'] if 'DropCommit' in packet['body'])], 'source lost packet')
        first_source = next(packet for packet in source['controls'] if packet['from'] == 1 and packet['to'] == 0 and 'DropBackfill' in packet['body'])
        require(same(lost_source, first_source), 'source first donor emission lost')
        require(sum(same(payload(packet), payload(lost_source)) for packet in source['controls']) >= 2, 'source exact donor retry emission')
        require(any(same(payload(packet), payload(lost_source)) and packet['emission'] > lost_source['emission']
                    for packet in source['received_controls']), 'source exact donor retry receipt')
        lost_godot = godot['lost_history'][0]
        require(same(lost_godot, godot['history_emissions'][0]), 'Godot first donor emission lost')
        require(any(same(payload(packet), payload(lost_godot)) and packet['emission'] > lost_godot['emission']
                    for packet in receipts), 'Godot exact donor retry receipt')
    return {'cut': 8, 'compared_frames': 20, 'survivors': 2, 'original_history_validated': True,
            'lost_first_history_recovered': loss, 'source_donor_emission_and_receipt': True, 'Godot_donor_receipt': True}


def negative_controls(source, godot, loss=False):
    def shared_wrong_history(source, godot):
        for trace in (source, godot):
            trace['survivors'][0]['rows'][8]['inputs'][2] = '00000000'

    mutations = {
        'shared_wrong_history': ('source original rows, statuses or canonical states', shared_wrong_history),
        'missing_source_donor': ('source emitted controls missing donor backfill', lambda s, g: s.update(
            controls=[packet for packet in s['controls'] if not (packet['from'] == 1 and 'DropBackfill' in packet['body'])])),
        'missing_source_receipt': ('source received controls missing donor backfill', lambda s, g: s.update(
            received_controls=[packet for packet in s['received_controls'] if not (packet['from'] == 1 and 'DropBackfill' in packet['body'])])),
        'wrong_source_cut': ('source emitted controls receipt-raised commit', lambda s, g: next(
            packet['body']['DropCommit'] for packet in s['controls'] if 'DropCommit' in packet['body']).update(cut=4)),
        'lost_original_row': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][8]['inputs'].__setitem__(2, '00000000')),
        'wrong_canonical_state': ('source original rows, statuses or canonical states', lambda s, g: s['survivors'][1]['rows'][9]['state'].update(bytes='00' * 32)),
        'lost_status': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][9]['state']['inputs'][2].update(status='confirmed')),
        'truncated_donor_packet': ('Godot packet bytes', lambda s, g: g['history_receipts'][0].update(packet='00')),
        'corrupt_donor_packet': ('Godot history packet original bytes', lambda s, g: g['history_receipts'][0].update(
            packet=g['history_receipts'][0]['packet'][:-2] + '00')),
        'foreign_donor': ('Godot original donor receipt', lambda s, g: g['history_receipts'][0].update(**{'from': 0})),
        'bool_frame': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][0].update(frame=False)),
    }
    def source_operation_mutation(source, godot, field, value):
        for bank in ('controls', 'lost_history', 'received_controls'):
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
    for name, (diagnostic, mutate) in mutations.items():
        candidate_source, candidate_godot = copy.deepcopy(source), copy.deepcopy(godot)
        mutate(candidate_source, candidate_godot)
        try:
            compare(candidate_source, candidate_godot, loss)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return list(mutations)


def loss_evidence_controls(clean, lost):
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
            compare(candidate['source'], candidate['godot'], True)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in controls]
