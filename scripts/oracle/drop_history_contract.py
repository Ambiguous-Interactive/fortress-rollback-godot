"""Independent original-history checks for the scoped three-peer donor witness."""
import copy
import json
import struct

from source_wire import REVIEWED_REVISION as REVISION, checksum_basis, header, wire_version


def roster_digest(identities):
    """The Godot barrier payload's roster digest: the shipped FNV over the ASCII
    lowercase hex of each live roster identity, in roster order. The oracle
    fixture's three-peer mesh keeps `_slots` slots per peer, and the roster is
    per-slot (`_id(slot / _slots)`), so each surviving peer's identity repeats
    once per slot and the departed peer's entries drop out."""
    value = 0x14650fb0739d0383
    for byte in ''.join(identities).encode('ascii'):
        value = ((value ^ byte) * 1099511628211) & 0x3fffffffffffffff
    return value or 1


def fixture_roster_digest(target_slots):
    """The live roster of the fixture's drop: peers zero and one, one entry per
    slot; the departed peer two contributes nothing. These are exactly the two
    survivors the pinned DropPrepare names (its participant handles zero and
    target_slots are those peers' first slots), so the carried digest on every
    Godot barrier payload fingerprints the pinned prepare's participant list."""
    identities = []
    for peer in range(2):
        identities.extend(['%02x00000000000000' % (peer + 1)] * target_slots)
    return roster_digest(identities)


def require(condition, label):
    if not condition:
        raise ValueError('drop history: ' + label)


def same(actual, expected):
    return json.dumps(actual, sort_keys=True, separators=(',', ':')) == json.dumps(expected, sort_keys=True, separators=(',', ':'))


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + ' schema')


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, label)


def carry_roster(raw, target_slots):
    """Every barrier payload ends with the carried roster digest, so the
    extended field fails under its own diagnostic before the exact bytes."""
    require(len(raw) >= 8, 'Godot barrier roster digest')
    require(struct.unpack_from('<Q', raw, len(raw) - 8)[0] == fixture_roster_digest(target_slots),
            'Godot barrier roster digest')


def history_bytes(missing_rows, target_slots, warmup=0):
    return bytes((frame * 11 + player * 7 + index) % 251 for frame in range(warmup + 8, warmup + 8 + missing_rows)
                 for player in range(2 * target_slots, 3 * target_slots) for index in range(4))


def original_history(missing_rows=1, target_slots=1, warmup=0):
    cut = warmup + 7 + missing_rows
    values = [0] * (3 * target_slots)
    result = []
    for frame in range(warmup + 20):
        inputs = [bytes((min(frame, cut) * 11 + player * 7 + index) % 251 if player >= 2 * target_slots
                        else (frame * 11 + player * 7 + index) % 251 for index in range(4)) for player in range(3 * target_slots)]
        for player, data in enumerate(inputs):
            values[player] += sum(data)
        details = [{'bytes': data.hex(), 'status': 'disconnected' if player >= 2 * target_slots and frame > cut else 'confirmed'}
                   for player, data in enumerate(inputs)]
        result.append({'frame': frame, 'inputs': [data.hex() for data in inputs],
                       'state': {'frame': frame, 'bytes': struct.pack('<' + 'q' * (len(values) + 1), frame + 1, *values).hex(), 'inputs': details}})
    return result[warmup:]


def check_rows(value, label, missing_rows, target_slots, unequal=False, warmup=0):
    require(type(value) is list and len(value) == 2, label + ' survivors')
    expected = original_history(missing_rows, target_slots, warmup)
    for peer, survivor in enumerate(value):
        fields(survivor, 'peer current_frame confirmed_frame rows', label + ' survivor')
        require(same(survivor['peer'], peer), label + ' peer')
        integer(survivor['current_frame'], warmup + 22 + int(unequal and peer == 0), warmup + 22 + int(unequal and peer == 0), label + ' continuation')
        integer(survivor['confirmed_frame'], warmup + 20, warmup + 21, label + ' confirmation')
        require(same(survivor['rows'], expected), label + ' original rows, statuses or canonical states')


def check_before(value, label, missing_rows, target_slots, unequal=False, warmup=0):
    require(type(value) is list and len(value) == 2, label + ' inventory count')
    for peer, inventory in enumerate(value):
        fields(inventory, 'confirmed targets', label + ' inventory')
        integer(inventory['confirmed'], warmup + 4 + int(unequal and peer == 1), warmup + 4 + int(unequal and peer == 1), label + ' exposed confirmation')
        require(type(inventory['targets']) is list and len(inventory['targets']) == target_slots, label + ' target count')
        for offset, target in enumerate(inventory['targets']):
            fields(target, 'slot first last', label + ' target')
            require(same(target['slot'], 2 * target_slots + offset), label + ' target slot')
            first = warmup + 2 + int(unequal and peer == 0) if label == 'source' else max(0, warmup - 2 + int(unequal and peer == 0))
            integer(target['first'], first, first, label + ' retained start')
            integer(target['last'], warmup + 7 + peer * missing_rows, warmup + 7 + peer * missing_rows, label + ' physical missing row')


def source_digest(data):
    digest = 0xcbf29ce484222325
    for byte in data:
        digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    return digest


def check_checksum_reports(packets, cut, target_slots, warmup, wire):
    label = 'source checksum'
    require(type(packets) is list and 1 <= len(packets) <= 12288, label + ' inventory')
    floor = cut + 1
    basis = sum(source_digest(b'fortress.checksum.freeze_floor.v2' + struct.pack('<iI', floor, slot))
                for slot in range(2 * target_slots, 3 * target_slots)) & ((1 << 64) - 1)
    # The interval-one witness stops advancing the target during setup.
    # The 16 continuation rounds bring the two surviving senders to warmup + 18.
    frontiers = (warmup + 18, warmup + 18, warmup + 4)
    # Each seeded source endpoint uses one connection ID on both addressed routes.
    connections = (3955875504, 1183501648, 748250720)
    last_frame = {(sender, str(recipient)): 0 for sender in range(3) for recipient in range(3) if sender != recipient}
    for packet in packets:
        fields(packet, 'from to raw', label + ' packet')
        sender, recipient = packet['from'], packet['to']
        integer(sender, 0, 2, label + ' sender')
        require(type(recipient) is str and (sender, recipient) in last_frame, label + ' route')
        raw = packet['raw']
        fields(raw, 'header body', label + ' raw packet')
        fields(raw['body'], 'ChecksumReport', label + ' body')
        report = raw['body']['ChecksumReport']
        try:
            header(raw, wire)
            token = checksum_basis(report, wire)
        except ValueError as error:
            raise ValueError(f'drop history: {label} {error}') from error
        integer(raw['header']['conn_id'], connections[sender], connections[sender], label + ' sender connection')
        wanted_frame = last_frame[sender, recipient] + 1
        integer(report['frame'], wanted_frame, wanted_frame, label + ' frame')
        integer(report['checksum'], 0, 0, label + ' fixture checksum')
        require(token == (basis if sender < 2 and wanted_frame >= floor else 0), label + ' freeze basis')
        last_frame[sender, recipient] = wanted_frame
    require(all(last == frontiers[sender] for (sender, _), last in last_frame.items())
            and min(frontiers[:2]) >= floor and frontiers[2] < floor, label + ' complete routes')


def check_source_operation(operation, label, target_slots, wire):
    names = 'coordinator coordinator_generation sequence target_set_digest'
    if wire == 6:
        names += ' participant_set_digest terminal_epoch'
    fields(operation, names, label)
    for field, maximum in [('coordinator', 65535), ('coordinator_generation', 65535),
                           ('sequence', 4294967295), ('target_set_digest', 18446744073709551615)]:
        integer(operation[field], 0, maximum, label + ' ' + field)
    # Pinned p2p_session.rs hashes each target's little-endian u16 handle and generation.
    targets = range(2 * target_slots, 3 * target_slots)
    digest = source_digest(b''.join(struct.pack('<HH', slot, 0) for slot in targets))
    require(all(same(operation[key], value) for key, value in (
        ('coordinator', 0), ('coordinator_generation', 0), ('sequence', 1), ('target_set_digest', digest))), label + ' identity')
    if wire == 6:
        integer(operation['participant_set_digest'], 0, (1 << 64) - 1, label + ' participant_set_digest')
        require(operation['participant_set_digest'] == source_digest(struct.pack('<HH', 0, target_slots)), label + ' participant_set_digest')
        integer(operation['terminal_epoch'], 0, 0, label + ' terminal_epoch')


def check_source_content(kind, content, label, missing_rows, target_slots, unequal=False, warmup=0, *, wire):
    names = {
        'DropPrepare': 'operation targets participants',
        'DropReport': 'operation participant stage exposed_confirmed cut cut_digest receipts',
        'DropBackfill': 'operation chunk_index chunk_count start_frame frame_count bytes',
        'DropCommit': 'operation cut cut_digest',
        'DropAbort': 'operation reason',
    }
    if wire == 6:
        names['DropBackfill'] += ' donor range_start'
        names['DropAbort'] += ' targets terminal_epoch'
    fields(content, names[kind], label + ' ' + kind)
    check_source_operation(content['operation'], label + ' operation', target_slots, wire)
    targets = [{'handle': slot, 'generation': 0} for slot in range(2 * target_slots, 3 * target_slots)]
    if kind == 'DropAbort':
        require(content['reason'] == 'Timeout', label + ' abort reason')
        if wire == 6:
            require(same(content['targets'], targets), label + ' abort targets')
            integer(content['terminal_epoch'], 1, 1, label + ' abort terminal_epoch')
    if kind == 'DropBackfill' and wire == 6:
        integer(content['donor'], target_slots, target_slots, label + ' donor')
        integer(content['range_start'], warmup + 8, warmup + 8, label + ' range_start')
    if kind == 'DropPrepare':
        require(same(content['targets'], targets), label + ' targets')
        require(same(content['participants'], [0, target_slots]), label + ' participants')
    if kind in ('DropReport', 'DropCommit'):
        cut = warmup + 7 + missing_rows
        digest = source_digest(b''.join(struct.pack('<H', slot) + bytes((cut * 11 + slot * 7 + index) % 251 for index in range(4))
                                        for slot in range(2 * target_slots, 3 * target_slots)))
        if kind == 'DropCommit':
            require(same(content['cut_digest'], digest), label + ' cut digest')
            return
        participant = content['participant']
        require(any(same(participant, slot) for slot in (0, target_slots)), label + ' participant')
        stage = content['stage']
        require(stage in ('Inventory', 'Ready', 'Committed'), label + ' report stage')
        if stage == 'Inventory':
            # Version 6 broadcasts the chosen cut during backfill as an empty inventory report.
            if wire == 6 and same(content['receipts'], []):
                require(same([participant, content['exposed_confirmed'], content['cut'], content['cut_digest']],
                             [0, -1, cut, 0]), label + ' backfill cut announcement')
                return
            receipts = [{'target': target['handle'], 'available_from': warmup + (3 if unequal and participant == 0 else 2),
                         'contiguous_through': warmup + 7 if participant == 0 else cut} for target in targets]
            require(same(content['receipts'], receipts), label + ' receipts')
            require(same(content['exposed_confirmed'], warmup + 4 + int(unequal and participant == target_slots)) and same(content['cut'], -1)
                    and same(content['cut_digest'], 0), label + ' inventory values')
        else:
            require(same(content['exposed_confirmed'], -1) and same(content['cut'], cut)
                    and same(content['cut_digest'], digest) and same(content['receipts'], []), label + ' certificate values')


def is_direct_cut_announcement(packet):
    report = packet['body'].get('DropReport', {})
    return packet['from'] == 0 and report.get('stage') == 'Inventory' and same(report.get('receipts'), [])


def check_source_controls(controls, label, missing_rows, target_slots, unequal=False, complete=True, warmup=0, *, wire):
    cut = warmup + 7 + missing_rows
    donor_bytes = list(history_bytes(missing_rows, target_slots, warmup))
    require(type(controls) is list and 1 <= len(controls) <= 4096, label + ' count')
    donor_order = cut_order = 8193
    commit = False
    inventories = set()
    for packet in controls:
        fields(packet, 'from to body emission order', label)
        integer(packet['order'], 1, 8192, label + ' observation order')
        integer(packet['emission'], 0, 4095, label + ' emission')
        integer(packet['from'], 0, 1, label + ' sender')
        integer(packet['to'], 0, 1, label + ' recipient')
        require(packet['from'] != packet['to'], label + ' remote recipient')
        body = packet['body']
        require(type(body) is dict and len(body) == 1, label + ' body')
        kind, content = next(iter(body.items()))
        require(kind in ('DropPrepare', 'DropReport', 'DropBackfill', 'DropCommit', 'DropAbort') and type(content) is dict, label + ' kind')
        require(kind != 'DropAbort', label + ' source aborted')
        check_source_content(kind, content, label, missing_rows, target_slots, unequal, warmup, wire=wire)
        if kind == 'DropReport' and content['stage'] == 'Inventory' and content['receipts']:
            inventories.add(content['participant'])
        if is_direct_cut_announcement(packet):
            cut_order = min(cut_order, packet['order'])
        if kind == 'DropBackfill':
            require(same(content.get('start_frame'), warmup + 8) and same(content.get('frame_count'), missing_rows)
                    and same(content.get('chunk_index'), 0) and same(content.get('chunk_count'), 1)
                    and same(content.get('bytes'), donor_bytes), label + ' original donor backfill')
            if packet['from'] == 1 and packet['to'] == 0:
                donor_order = min(donor_order, packet['order'])
        if kind == 'DropCommit':
            require(same(content.get('cut'), cut), label + ' receipt-raised commit')
            commit = True
    require(donor_order <= 8192, label + ' missing donor backfill')
    require(commit, label + ' missing commit')
    if complete:
        require(inventories == {0, target_slots}, label + ' missing participant inventory')
        if wire == 6:
            require(cut_order < donor_order, label + ' cut announced before backfill')



def check_godot_packet(raw, missing_rows, target_slots, warmup=0):
    cut = warmup + 7 + missing_rows
    donor_bytes = history_bytes(missing_rows, target_slots, warmup)
    require(type(raw) is str and len(raw) == 212 + target_slots * 6 + missing_rows * target_slots * 8
            and all(character in '0123456789abcdef' for character in raw), 'Godot packet bytes')
    packet = bytes.fromhex(raw)
    carry_roster(packet, target_slots)
    require(packet[:8] == b'FRGP\x03\x00\x0c\x00' and packet[8:24] == bytes([91]) + bytes(15)
            and packet[24:32] == bytes([2]) + bytes(7) and packet[32:40] == bytes([22]) + bytes(7), 'Godot packet identity')
    require(struct.unpack_from('<I', packet, 40)[0] == 62 + target_slots * 3 + missing_rows * target_slots * 4
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
            and struct.unpack_from('<i', packet, 68)[0] == warmup + 8 and struct.unpack_from('<i', packet, 72)[0] == target_slots,
            'Godot history packet range')
    require(struct.unpack_from('<3H', packet, 84) == (0, 1, 0) and struct.unpack_from('<I', packet, 90)[0] == len(targets)
            and struct.unpack_from('<I', packet, 94 + len(targets))[0] == len(donor_bytes)
            and packet[98 + len(targets):] == donor_bytes + struct.pack('<Q', fixture_roster_digest(target_slots)),
            'Godot history packet original bytes')


def check_godot_prepare(packet, missing_rows, target_slots, warmup=0, unequal=False, *, opening_cut=None):
    """The coordinator's survivor-link proposal: the opening window offer and the
    donor plan (stage HISTORY), each retried byte-identical, the plan re-emitted
    when the frozen value's digest becomes known. The plan carries the
    receipt-raised cut and the first missing frame, like the transfer it names."""
    fields(packet, 'from to packet emission order', 'Godot prepare')
    integer(packet['order'], 1, 8192, 'Godot prepare order')
    # The fixture captures the coordinator's survivor-link proposals only, so
    # the sender fields are part of the trace schema, not a separate refusal.
    raw = packet['packet']
    require(type(raw) is str and len(raw) in (212 + target_slots * 6, 218 + target_slots * 6)
            and all(character in '0123456789abcdef' for character in raw), 'Godot prepare bytes')
    data = bytes.fromhex(raw)
    carry_roster(data, target_slots)
    cut = warmup + 7 + missing_rows
    target_era = 23 << 8
    targets = b''.join(struct.pack('<BH', slot, target_era) for slot in range(2 * target_slots, 3 * target_slots))
    def digest(value):
        number = 0x14650fb0739d0383
        for byte in value:
            number = ((number ^ byte) * 1099511628211) & 0x3fffffffffffffff
        return number or 1
    frozen = bytes((cut * 11 + slot * 7 + index) % 251 for slot in range(2 * target_slots, 3 * target_slots)
                   for index in range(4))
    def body(stage, op_cut, op_bound, op_digest, plan):
        return (b'FRGP\x03\x00\x0c\x00' + bytes([91]) + bytes(15) + bytes([1]) + bytes(7) + bytes([21]) + bytes(7)
                + struct.pack('<I4BHHIQiiiQHH2BI', 62 + len(targets) + len(plan), 1, stage, 0, 0, 0, 21 << 8,
                              target_era + 1, digest(targets), op_cut, op_bound, warmup + 7, op_digest,
                              0, 0, 0, 0, len(targets))
                + targets + struct.pack('<I', len(plan)) + plan
                + struct.pack('<Q', fixture_roster_digest(target_slots)))
    donor_plan = struct.pack('<BH', target_slots, 1024)
    opening = body(0, warmup + 4 if opening_cut is None else opening_cut, max(0, warmup - 2 + int(unequal)), 0, b'')
    uncertified = body(5, cut, warmup + 8, 0, donor_plan)
    certified = body(5, cut, warmup + 8, digest(frozen), donor_plan)
    require(data in (opening, uncertified, certified), 'Godot exact original prepare')
    return data == certified


def check_godot_commit(packet, missing_rows, target_slots, acknowledgement=False, warmup=0, unequal=False):
    fields(packet, 'from to packet emission order', 'Godot commit')
    integer(packet['order'], 1, 8192, 'Godot commit order')
    require(same(packet['from'], int(acknowledgement)) and same(packet['to'], int(not acknowledgement)), 'Godot commit sender')
    raw = packet['packet']
    require(type(raw) is str and len(raw) == 212 + target_slots * 6
            and all(character in '0123456789abcdef' for character in raw), 'Godot commit bytes')
    carry_roster(bytes.fromhex(raw), target_slots)
    cut = warmup + 7 + missing_rows
    target_era = 23 << 8
    targets = b''.join(struct.pack('<BH', slot, target_era) for slot in range(2 * target_slots, 3 * target_slots))
    def digest(data):
        value = 0x14650fb0739d0383
        for byte in data:
            value = ((value ^ byte) * 1099511628211) & 0x3fffffffffffffff
        return value or 1
    value = bytes((cut * 11 + slot * 7 + index) % 251 for slot in range(2 * target_slots, 3 * target_slots) for index in range(4))
    # The report's trailer carries the sender's departure attestation on the
    # two consumed report stages: the certified acknowledgement is not one of
    # them, so it sends witnessed=0 like the commit.
    expected = (b'FRGP\x03\x00\x0c\x00' + bytes([91]) + bytes(15) + bytes([2 if acknowledgement else 1]) + bytes(7) + bytes([22 if acknowledgement else 21]) + bytes(7)
                + struct.pack('<I4BHHIQiiiQHH2BI', 62 + len(targets), 2 if acknowledgement else 4, 3 if acknowledgement else 0, 0, 0, 0, 21 << 8,
                              target_era + 1, digest(targets), cut, max(0, warmup - 2 + int(unequal and not acknowledgement)),
                              cut if acknowledgement else warmup + 7, digest(value), 0, 0, 0, 0, len(targets))
                + targets + struct.pack('<I', 0) + struct.pack('<Q', fixture_roster_digest(target_slots)))
    require(bytes.fromhex(raw) == expected, 'Godot exact certified acknowledgement' if acknowledgement else 'Godot exact certified commit')


def check_delivery(emissions, lost, receipts, label, grouped=False, observed=False):
    require(type(emissions) is list and 1 <= len(emissions) <= 4096, label + ' emissions')
    for index, packet in enumerate(emissions):
        require(type(packet) is dict and type(packet.get('emission')) is int and packet['emission'] == index, label + ' emission order')
    expected = [packet for packet in emissions if not any(same(packet, dropped) for dropped in lost)]
    if grouped:
        expected = [packet for recipient in range(2) for packet in expected if packet['to'] == recipient]
    if grouped or observed:
        expected = [{key: value for key, value in packet.items() if key != 'order'} for packet in expected]
        receipts = [{key: value for key, value in packet.items() if key != 'order'} for packet in receipts]
    require(same(receipts, expected), label + ' emission/loss/receipt accounting')


def payload(packet):
    return {key: value for key, value in packet.items() if key not in ('emission', 'order')}


def compare(source, godot, loss=False, missing_rows=1, target_slots=1, unequal=False, commit_loss=False, ack_loss=False,
            inventory_loss=False, warmup=0, prepare_loss=False, *, source_revision=REVISION):
    wire = wire_version(source_revision)
    require(type(missing_rows) is int and missing_rows in (1, 4), 'scenario missing rows')
    require(type(target_slots) is int and target_slots in (1, 2), 'scenario target slots')
    cut = warmup + 7 + missing_rows
    require(type(warmup) is int and warmup in (0, 251), 'scenario warmup')
    if warmup:
        for label, value in [('source', source), ('Godot', godot)]:
            require(same(value.get('warmup'), warmup), label + ' executed warmup')
            require(same(value.get('expired_original_rows'), [True, True]), label + ' expired original rows')
        source = {key: value for key, value in source.items() if key not in ('warmup', 'expired_original_rows')}
        godot = {key: value for key, value in godot.items() if key not in ('warmup', 'expired_original_rows')}
    source_fields = ('format complete missing_rows target_slots upstream_revision before dropped controls '
                     'received_controls survivors lost_history lost_commit lost_ack lost_inventory lost_prepare')
    fields(source, source_fields + (' checksums' if wire == 6 else ''), 'source')
    fields(godot, 'format complete missing_rows target_slots before cuts history_packets donors history_emissions history_receipts '
           'prepare_emissions prepare_receipts survivors failures lost_history lost_commit commit_emissions commit_receipts '
           'lost_ack ack_emissions ack_receipts lost_inventory inventory_emissions inventory_receipts lost_prepare', 'Godot')
    for label, value in [('source', source), ('Godot', godot)]:
        require(same(value['format'], 6) and value['complete'] is True, label + ' completion')
        require(same(value['missing_rows'], missing_rows), label + ' missing rows')
        require(same(value['target_slots'], target_slots), label + ' target slots')
        check_before(value['before'], label, missing_rows, target_slots, unequal, warmup)
        check_rows(value['survivors'], label, missing_rows, target_slots, unequal, warmup)
    require(source['upstream_revision'] == source_revision, 'source revision')
    require(same(source['dropped'], [target_slots, target_slots]), 'source drops')
    check_source_controls(source['controls'], 'source emitted controls', missing_rows, target_slots, unequal, warmup=warmup, wire=wire)
    check_source_controls(source['received_controls'], 'source received controls', missing_rows, target_slots, unequal, warmup=warmup, wire=wire)
    if wire == 6:
        check_checksum_reports(source['checksums'], cut, target_slots, warmup, wire)
    # The pinned prepare's participant list is pinned by check_source_content and
    # the carried Godot digest by carry_roster; the equivalence of the two rosters
    # is fixture_roster_digest's documented derivation, not a separate check.
    require(same(godot['cuts'], [[cut] * target_slots, [cut] * target_slots]) and same(godot['donors'], [1]), 'Godot cut or donor')
    integer(godot['history_packets'], 1, 4096, 'Godot historical transfer')
    require(godot['failures'] == [], 'Godot assertion failures')
    donor_bytes = history_bytes(missing_rows, target_slots, warmup).hex()
    receipts = godot['history_receipts']
    require(type(receipts) is list and len(receipts) == godot['history_packets'], 'Godot history receipt count')
    for receipt in receipts:
        fields(receipt, 'from to bytes packet emission', 'Godot history receipt')
        require(same(receipt['from'], 1) and same(receipt['to'], 0) and receipt['bytes'] == donor_bytes, 'Godot original donor receipt')
        check_godot_packet(receipt['packet'], missing_rows, target_slots, warmup)
    require(type(source['lost_history']) is list and len(source['lost_history']) == int(loss), 'source loss count')
    require(type(godot['lost_history']) is list and len(godot['lost_history']) == int(loss), 'Godot loss count')
    require(type(source['lost_commit']) is list and len(source['lost_commit']) == int(commit_loss), 'source commit loss count')
    require(type(godot['lost_commit']) is list and len(godot['lost_commit']) == int(commit_loss), 'Godot commit loss count')
    require(type(source['lost_ack']) is list and len(source['lost_ack']) == int(ack_loss), 'source acknowledgement loss count')
    require(type(godot['lost_ack']) is list and len(godot['lost_ack']) == int(ack_loss), 'Godot acknowledgement loss count')
    for label, value in [('source', source), ('Godot', godot)]:
        require(type(value['lost_inventory']) is list and len(value['lost_inventory']) == int(inventory_loss), label + ' inventory loss count')
        require(type(value['lost_prepare']) is list and len(value['lost_prepare']) == int(prepare_loss), label + ' prepare loss count')
    source_losses = source['lost_history'] + source['lost_commit'] + source['lost_ack'] + source['lost_inventory'] + source['lost_prepare']
    check_delivery(source['controls'], source_losses, source['received_controls'], 'source', grouped=True)
    from drop_history_inventory_controls import check_inventory, check_source_observation_order, check_godot_observation_order
    check_source_observation_order(source)
    check_delivery(godot['history_emissions'], godot['lost_history'], receipts, 'Godot')
    require(type(godot['commit_emissions']) is list and 1 <= len(godot['commit_emissions']) <= 4096, 'Godot commit emissions')
    for packet in godot['commit_emissions']:
        check_godot_commit(packet, missing_rows, target_slots, warmup=warmup, unequal=unequal)
    check_delivery(godot['commit_emissions'], godot['lost_commit'], godot['commit_receipts'], 'Godot commit', observed=True)
    require(type(godot['ack_emissions']) is list and 1 <= len(godot['ack_emissions']) <= 4096, 'Godot acknowledgement emissions')
    for packet in godot['ack_emissions']:
        check_godot_commit(packet, missing_rows, target_slots, acknowledgement=True, warmup=warmup, unequal=unequal)
    check_delivery(godot['ack_emissions'], godot['lost_ack'], godot['ack_receipts'], 'Godot acknowledgement', observed=True)
    check_inventory(source, godot, inventory_loss, missing_rows, target_slots, unequal, warmup)
    require(type(godot['prepare_emissions']) is list and 1 <= len(godot['prepare_emissions']) <= 4096, 'Godot prepare emissions')
    certified = [packet for packet in godot['prepare_emissions'] if check_godot_prepare(packet, missing_rows, target_slots, warmup, unequal)]
    require(bool(certified), 'Godot digest-bearing prepare plan')
    check_delivery(godot['prepare_emissions'], godot['lost_prepare'], godot['prepare_receipts'], 'Godot prepare', observed=True)
    require(min(packet['order'] for packet in certified) < godot['commit_emissions'][0]['order'], 'Godot digest-bearing prepare precedes commit')
    check_godot_observation_order(godot)
    if prepare_loss:
        first = godot['prepare_emissions'][0]
        require(same(godot['lost_prepare'][0], first), 'Godot first prepare emission lost')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in godot['prepare_receipts']), 'Godot exact prepare retry receipt')
        first = source['lost_prepare'][0]
        require(first['from'] == 0 and first['to'] == 1 and 'DropPrepare' in first['body'], 'source first prepare emission lost')
        require(any(same(payload(packet), payload(first)) and packet['emission'] > first['emission']
                    for packet in source['received_controls']), 'source exact prepare retry receipt')
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
                              'source lost packet', missing_rows, target_slots, unequal, complete=False, warmup=warmup, wire=wire)
        first_source = next(packet for packet in source['controls'] if packet['from'] == 1 and packet['to'] == 0 and 'DropBackfill' in packet['body'])
        require(same(lost_source, first_source), 'source first donor emission lost')
        require(sum(same(payload(packet), payload(lost_source)) for packet in source['controls']) >= 2, 'source exact donor retry emission')
        require(any(same(payload(packet), payload(lost_source)) and packet['emission'] > lost_source['emission']
                    for packet in source['received_controls']), 'source exact donor retry receipt')
        lost_godot = godot['lost_history'][0]
        require(same(lost_godot, godot['history_emissions'][0]), 'Godot first donor emission lost')
        require(any(same(payload(packet), payload(lost_godot)) and packet['emission'] > lost_godot['emission']
                    for packet in receipts), 'Godot exact donor retry receipt')
    return {'cut': cut, 'warmup_frames': warmup, 'unequal_exposure': unequal, 'missing_rows': missing_rows, 'target_slots': target_slots,
            'compared_frames': 20, 'survivors': 2, 'original_history_validated': True,
            'lost_first_history_recovered': loss, 'lost_first_commit_recovered': commit_loss, 'lost_first_acknowledgement_recovered': ack_loss,
            'lost_first_inventory_recovered': inventory_loss, 'lost_first_prepare_recovered': prepare_loss, 'source_donor_emission_and_receipt': True, 'Godot_donor_receipt': True}


def negative_controls(source, godot, loss=False, missing_rows=1, target_slots=1, unequal=False, commit_loss=False, ack_loss=False,
                      inventory_loss=False, warmup=0, prepare_loss=False, *, source_revision=REVISION):
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
        'corrupt_donor_packet': ('Godot barrier roster digest', lambda s, g: g['history_receipts'][0].update(
            packet=g['history_receipts'][0]['packet'][:-2] + '00')),
        'foreign_donor': ('Godot original donor receipt', lambda s, g: g['history_receipts'][0].update(**{'from': 0})),
        'bool_frame': ('Godot original rows, statuses or canonical states', lambda s, g: g['survivors'][0]['rows'][0].update(frame=False)),
    }
    if warmup:
        for label, bank in [('source', 'source'), ('Godot', 'godot')]:
            mutations[label + '_wrong_warmup'] = (label + ' executed warmup',
                lambda s, g, bank=bank: (s if bank == 'source' else g).update(warmup=0))
            mutations[label + '_invented_eviction'] = (label + ' expired original rows',
                lambda s, g, bank=bank: (s if bank == 'source' else g).update(expired_original_rows=[False, True]))
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
            content['receipts'][-1].update(target=0) if content['stage'] == 'Inventory' and content['receipts'] else None))
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

    if wire_version(source_revision) == 6:
        for field, value in [('participant_set_digest', 0), ('terminal_epoch', 1)]:
            mutations['source_' + field] = ('source emitted controls operation ' + field, lambda s, g, field=field, value=value:
                                            source_operation_mutation(s, g, field, value))
        for field, value in [('donor', 0), ('range_start', 0)]:
            mutations['source_backfill_' + field] = ('source emitted controls ' + field, lambda s, g, field=field, value=value:
                                                     source_content_mutation(s, g, 'DropBackfill', lambda body: body.update({field: value})))
        mutations['source_wrong_backfill_cut'] = ('source emitted controls backfill cut announcement', lambda s, g:
            source_content_mutation(s, g, 'DropReport', lambda body:
                body.update(cut=-1) if body['stage'] == 'Inventory' and not body['receipts'] else None))
        mutations['source_missing_backfill_cut'] = ('source emitted controls cut announced before backfill', lambda s, g:
            s.update(controls=[packet for packet in s['controls'] if not is_direct_cut_announcement(packet)]))
        mutations['source_missing_checksum'] = ('source checksum complete routes', lambda s, g: s['checksums'].pop())
        mutations['source_wrong_checksum_wire'] = ('source checksum protocol version: invalid integer', lambda s, g:
                                                   s['checksums'][0]['raw']['header'].update(protocol_version=2))
        mutations['source_wrong_checksum_sender'] = ('source checksum sender connection', lambda s, g:
                                                     s['checksums'][0]['raw']['header'].update(conn_id=748250720))
        mutations['source_wrong_freeze_basis'] = ('source checksum freeze basis', lambda s, g:
            next(body for p in s['checksums'] if (body := p['raw']['body']['ChecksumReport'])['basis_token']).update(basis_token=0))

    def godot_operation_mutation(source, godot, offset, width):
        for bank in ('history_emissions', 'lost_history', 'history_receipts'):
            for packet in godot[bank]:
                raw = bytearray.fromhex(packet['packet'])
                raw[offset:offset + width] = (1).to_bytes(width, 'little')
                packet['packet'] = raw.hex()

    def godot_byte_mutation(banks, offset):
        def mutate(source, godot):
            for bank in banks:
                for packet in godot[bank]:
                    raw = bytearray.fromhex(packet['packet'])
                    raw[offset] ^= 1
                    packet['packet'] = raw.hex()
        return mutate

    mutations['Godot_history_roster_digest'] = ('Godot barrier roster digest', godot_byte_mutation(
        ('history_emissions', 'lost_history', 'history_receipts'), -1))
    mutations['Godot_prepare_roster_digest'] = ('Godot barrier roster digest',
        godot_byte_mutation(('prepare_emissions', 'prepare_receipts', 'lost_prepare'), -1))
    mutations['Godot_inventory_roster_digest'] = ('Godot barrier roster digest', godot_byte_mutation(
        ('inventory_emissions', 'inventory_receipts', 'lost_inventory'), -1))
    mutations['Godot_commit_roster_digest'] = ('Godot barrier roster digest', godot_byte_mutation(
        ('commit_emissions', 'commit_receipts', 'lost_commit'), -1))
    mutations['Godot_acknowledgement_roster_digest'] = ('Godot barrier roster digest', godot_byte_mutation(
        ('ack_emissions', 'ack_receipts', 'lost_ack'), -1))
    # The trailer flips above leave the donor bytes, the inventory receipts and
    # the prepare body without their own named mutation, so each keeps one.
    mutations['Godot_history_donor_byte'] = ('Godot history packet original bytes',
        godot_byte_mutation(('history_emissions', 'lost_history', 'history_receipts'), 98 + 3 * target_slots))
    mutations['Godot_prepare_phase_byte'] = ('Godot exact original prepare',
        godot_byte_mutation(('prepare_emissions', 'prepare_receipts', 'lost_prepare'), 44))
    mutations['Godot_inventory_receipt_byte'] = ('Godot exact original inventory',
        godot_byte_mutation(('inventory_emissions', 'inventory_receipts', 'lost_inventory'), -9))

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
    mutations['bool_source_observation_order'] = ('source emitted controls observation order', lambda s, g: s['controls'][0].update(order=False))
    mutations['duplicate_source_observation_order'] = ('source unique observation order', lambda s, g:
        s['received_controls'][0].update(order=s['controls'][0]['order']))
    def reverse_source_receipt_order(source, godot):
        receipt = source['received_controls'][0]
        emitted = source['controls'][receipt['emission']]
        receipt['order'], emitted['order'] = emitted['order'], receipt['order']
    mutations['source_receipt_before_emission'] = ('source receipt follows emission', reverse_source_receipt_order)
    mutations['malformed_source_inventory_loss'] = ('source inventory loss count', lambda s, g: s.update(lost_inventory=None))
    mutations['malformed_Godot_inventory_emissions'] = ('Godot inventory emissions', lambda s, g: g.update(inventory_emissions=None))
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
    if prepare_loss:
        def remove_source_prepare_retries(source, godot):
            first = source['lost_prepare'][0]
            retained = [packet for packet in source['controls']
                        if packet['emission'] == first['emission'] or not same(payload(packet), payload(first))]
            indices = {packet['emission']: index for index, packet in enumerate(retained)}
            for bank in ('controls', 'received_controls', 'lost_prepare', 'lost_history', 'lost_commit', 'lost_ack', 'lost_inventory'):
                source[bank] = [{**packet, 'emission': indices[packet['emission']]}
                                for packet in source[bank] if packet['emission'] in indices]

        def remove_godot_prepare_retries(source, godot):
            first = godot['lost_prepare'][0]
            retained = [packet for packet in godot['prepare_emissions']
                        if packet['emission'] == first['emission'] or not same(payload(packet), payload(first))]
            indices = {packet['emission']: index for index, packet in enumerate(retained)}
            for bank in ('prepare_emissions', 'prepare_receipts', 'lost_prepare'):
                godot[bank] = [{**packet, 'emission': indices[packet['emission']]}
                               for packet in godot[bank] if packet['emission'] in indices]

        mutations['missing_source_prepare_loss'] = ('source prepare loss count', lambda s, g: s.update(lost_prepare=[]))
        mutations['missing_Godot_prepare_loss'] = ('Godot prepare loss count', lambda s, g: g.update(lost_prepare=[]))
        mutations['delivered_lost_Godot_prepare'] = ('Godot prepare emission/loss/receipt accounting', lambda s, g:
            g['prepare_receipts'].insert(0, copy.deepcopy(g['lost_prepare'][0])))
        mutations['delivered_lost_source_prepare'] = ('source emission/loss/receipt accounting', lambda s, g:
            s['received_controls'].insert(0, copy.deepcopy(s['lost_prepare'][0])))
        mutations['missing_source_prepare_retry'] = ('source exact prepare retry receipt', remove_source_prepare_retries)
        mutations['missing_Godot_prepare_retry'] = ('Godot exact prepare retry receipt', remove_godot_prepare_retries)
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
            compare(candidate_source, candidate_godot, loss, missing_rows, target_slots, unequal, commit_loss, ack_loss, inventory_loss, warmup, prepare_loss,
                    source_revision=source_revision)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return list(mutations)


def loss_evidence_controls(clean, lost, missing_rows=1, target_slots=1, unequal=False, *, source_revision=REVISION):
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
            compare(candidate['source'], candidate['godot'], True, missing_rows, target_slots, unequal, source_revision=source_revision)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in controls]


def commit_loss_evidence_controls(clean, lost, *, source_revision=REVISION):
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
            compare(candidate['source'], candidate['godot'], False, 4, 2, True, True, source_revision=source_revision)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in controls]


def wrapped_evidence_controls(short, wrapped, *, source_revision=REVISION):
    controls = []
    for label, bank in [('source', 'source'), ('Godot', 'godot')]:
        source, godot = copy.deepcopy(wrapped['source']), copy.deepcopy(wrapped['godot'])
        replacement = copy.deepcopy(short[bank])
        replacement.update(warmup=251, expired_original_rows=[True, True])
        if bank == 'source':
            source = replacement
        else:
            godot = replacement
        try:
            compare(source, godot, False, 4, 2, True, warmup=251, source_revision=source_revision)
        except ValueError as error:
            require(str(error) == 'drop history: ' + label + ' exposed confirmation', label + ' relabeled short trace diagnostic')
        else:
            raise ValueError('drop history: relabeled short trace survived: ' + label)
        controls.append(label + '_short_trace_cannot_claim_wrap')
    return controls
