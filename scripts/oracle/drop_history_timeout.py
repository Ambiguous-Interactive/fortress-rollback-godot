"""Check original history when every actual donor publication is lost."""
import copy

from drop_history_contract import (
    REVISION, check_before, check_delivery, check_godot_packet, check_godot_prepare, check_rows, check_source_content, check_source_operation,
    fields, history_bytes, integer, original_history, require, same,
)
from drop_history_inventory_controls import check_godot_inventory, check_godot_observation_order, check_source_observation_order


def check_source_packets(source):
    label = 'source donor timeout'
    emissions = source['controls']
    receipts = source['received_controls']
    history = []
    aborts = []
    require(type(emissions) is list and type(receipts) is list, label + ' packet banks')
    for bank in (emissions, receipts):
        for packet in bank:
            fields(packet, 'from to body emission order', label + ' packet')
            integer(packet['from'], 0, 1, label + ' sender')
            integer(packet['to'], 0, 1, label + ' recipient')
            require(packet['to'] != packet['from'], label + ' addressed packet')
            integer(packet['emission'], 0, 4095, label + ' emission identity')
            integer(packet['order'], 1, 8192, label + ' observation order')
            body = packet['body']
            require(type(body) is dict and len(body) == 1, label + ' packet body')
            kind, content = next(iter(body.items()))
            require(kind in ('DropPrepare', 'DropReport', 'DropBackfill', 'DropAbort')
                    and type(content) is dict, label + ' no COMMIT')
            check_source_operation(content.get('operation'), label + ' operation', 2)
            if kind == 'DropAbort':
                fields(content, 'operation reason', label + ' abort')
                require(content['reason'] == 'Timeout', label + ' abort reason')
                if bank is emissions:
                    aborts.append(packet)
            else:
                check_source_content(kind, content, label, 4, 2, True)
                if kind == 'DropReport':
                    require(content['stage'] != 'Committed', label + ' no COMMITTED report')
                if kind == 'DropBackfill':
                    require(same([packet['from'], packet['to']], [1, 0]), label + ' donor route')
                    history.append(packet)
                    require(bank is emissions, label + ' dropped history received')
                    expected = {'chunk_index': 0, 'chunk_count': 1, 'start_frame': 8, 'frame_count': 4, 'bytes': list(history_bytes(4, 2))}
                    require(same({key: content[key] for key in expected}, expected), label + ' original donor payload')
    require(len(history) >= 2 and same(source['lost_history'], history), label + ' discarded original retries')
    require(same(sorted([packet['from'], packet['to']] for packet in aborts), [[0, 1], [1, 0]])
            and min(packet['order'] for packet in aborts) > history[-1]['order'], label + ' both abort after donor retries')
    check_delivery(emissions, history, receipts, 'source donor timeout', grouped=True)
    check_source_observation_order(source)
    entering = [packet for packet in receipts if packet['order'] < history[0]['order']]
    require(any('DropPrepare' in packet['body'] and packet['from'] == 0 for packet in entering), label + ' delivered coordinator prepare')
    inventories = {packet['from'] for packet in entering if
                   packet['body'].get('DropReport', {}).get('stage') == 'Inventory'
                   and packet['body']['DropReport']['participant'] == packet['from'] * 2}
    require(inventories == {0, 1}, label + ' delivered direct inventories')
    return len(history)


def check_godot_history_publications(godot):
    label = 'Godot donor timeout'
    history = godot['history_emissions']
    publications = godot['history_publications']
    routing = godot['history_routing']
    require(type(publications) is list and type(routing) is list and len(history) == len(publications) == len(routing),
            label + ' accepted publication and routing count')
    for packet, publication, route in zip(history, publications, routing):
        fields(publication, 'from to packet order at_us', label + ' accepted publication')
        fields(route, 'emission order at_us', label + ' routing')
        integer(publication['order'], 1, 8192, label + ' publication identity')
        integer(publication['at_us'], 1, 800000, label + ' publication clock')
        integer(route['at_us'], publication['at_us'], publication['at_us'] + 1000, label + ' routing clock')
        require(same([publication[key] for key in ('from', 'to', 'packet')], [packet[key] for key in ('from', 'to', 'packet')])
                and same([publication['order'], packet['emission']], [route['order'], route['emission']]), label + ' match accepted publication')
    orders = [packet['order'] for packet in publications]
    require(orders == sorted(set(orders)), label + ' unique accepted publications')
    times = [packet['at_us'] for packet in publications]
    require(all(right - left == 50_000 for left, right in zip(times, times[1:])), label + ' distinct retry rounds')
    return times


def check_godot_negotiation(godot):
    label = 'Godot donor timeout'
    for kind, validate in [
            ('prepare', lambda packet: check_godot_prepare(packet, 4, 2, unequal=True, opening_cut=5)),
            ('inventory', lambda packet: check_godot_inventory(packet, 4, 2, True))]:
        emissions = godot[kind + '_emissions']
        receipts = godot[kind + '_receipts']
        check_delivery(emissions, [], receipts, label + ' ' + kind, observed=True)
        for packet in emissions:
            validate(packet)
            require(same([packet['from'], packet['to']], [0, 1] if kind == 'prepare' else [1, 0]), label + ' negotiation route')
    observations = {**godot, 'ack_emissions': [], 'ack_receipts': [], 'commit_receipts': []}
    check_godot_observation_order(observations)
    all_orders = [packet['order'] for key in ('prepare_emissions', 'prepare_receipts', 'inventory_emissions', 'inventory_receipts', 'history_publications')
                  for packet in godot[key]]
    require(len(set(all_orders)) == len(all_orders), label + ' unique negotiation and publication order')
    first_publication = godot['history_publications'][0]['order']
    first_inventory = godot['inventory_receipts'][0]['order']
    received = {bytes.fromhex(packet['packet'])[45]: packet['order'] for packet in reversed(godot['prepare_receipts'])}
    require(0 < received.get(0, 0) < first_inventory < received.get(5, 0) < first_publication, label + ' negotiated before donor publication')



def check_godot_packets(godot):
    label = 'Godot donor timeout'
    history = godot['history_emissions']
    require(type(history) is list and len(history) >= 2 and same(godot['lost_history'], history), label + ' discarded original retries')
    require(same(godot['history_receipts'], []), label + ' dropped history received')
    check_delivery(history, history, godot['history_receipts'], label)
    for packet in history:
        fields(packet, 'from to bytes packet emission', label + ' packet')
        require(same([packet['from'], packet['to'], packet['bytes']], [1, 0, history_bytes(4, 2).hex()]), label + ' donor route or bytes')
        check_godot_packet(packet['packet'], 4, 2)
    require(same(godot['commit_emissions'], []) and same(godot['drop_events'], {}), label + ' no commit or drop event')
    require(same(godot['failures'], []), label + ' fixture assertions')
    times = check_godot_history_publications(godot)
    check_godot_negotiation(godot)
    return times


def check_timeout(source, godot):
    fields(source, 'upstream_revision before controls received_controls lost_history survivors', 'source donor timeout')
    fields(godot, 'before survivors terminal_events drop_events history_emissions history_receipts lost_history commit_emissions failures '
           'prepare_emissions prepare_receipts inventory_emissions inventory_receipts history_publications history_routing', 'Godot donor timeout')
    require(source['upstream_revision'] == REVISION, 'source donor timeout revision')
    check_before(source['before'], 'source', 4, 2, True)
    check_before(godot['before'], 'Godot', 4, 2, True)
    source_retries = check_source_packets(source)
    godot_times = check_godot_packets(godot)
    terminals = godot['terminal_events']
    require(type(terminals) is list and len(terminals) == 2 and all(type(event) is dict for event in terminals)
            and same([event.get('peer') for event in terminals], [1, 0]), 'Godot donor timeout terminal peers')
    original = original_history(4, 2)
    for label, trace in [('source', source), ('Godot', godot)]:
        require(type(trace['survivors']) is list and len(trace['survivors']) == 2, label + ' donor timeout survivors')
        for peer, row in enumerate(trace['survivors']):
            fields(row, 'peer rows_before rows_after frame_before frame_after game_before game_after advance target_receipts '
                   + ('state dropped connected' if label == 'source' else 'lifecycle cuts confirmed_after started_us'), label + ' donor timeout survivor')
            require(same(row['peer'], peer), label + ' donor timeout survivor identity')
            expected = [{'frame': r['frame'], 'inputs': r['inputs']} for r in original[3 - peer:5 + peer]] if label == 'source' else [
                {'frame': r['frame'], 'inputs': r['state']['inputs'], 'state': r['state']} for r in original[:5 + peer]]
            require(same(row['rows_before'], expected) and same(row['rows_after'], expected), label + ' donor timeout original exposed history')
            require(same([row['frame_before'], row['frame_after']], [7 - peer] * 2)
                    and same(row['game_before'], row['game_after'])
                    and type(row['game_before']) is str and len(row['game_before']) == 112
                    and all(character in '0123456789abcdef' for character in row['game_before'])
                    and row['game_before'].startswith((7 - peer).to_bytes(8, 'little').hex()), label + ' donor timeout no gameplay advance')
            require(same(row['target_receipts'], [7 + peer * 4] * 2), label + ' donor timeout retained target receipts')
            if label == 'source':
                require(same([row['state'], row['advance'], row['dropped'], row['connected']],
                             ['Synchronizing', 'not_synchronized', [], [True, True]]), label + ' donor timeout fail-closed state')
            else:
                require(same([row['lifecycle'], row['advance'], row['cuts'], row['confirmed_after']], [1, 19, [-1, -1], 5]),
                        label + ' donor timeout fail-closed state')
                started = row['started_us']
                integer(started, 1, 800000, label + ' donor timeout barrier clock')
                require(godot_times[0] > started and godot_times[-1] < started + 250_000, label + ' donor timeout donor retries before expiry')
                require(same(terminals[1 - peer], {'peer': peer, 'target': '0300000000000000', 'reason': 'timeout', 'at_us': started + 250_000}),
                        label + ' donor timeout exact terminal attribution')
    return {'source': source_retries, 'godot': len(godot_times)}


def check_delivery_control(delivered, timeout):
    label = 'Godot donor delivery control'
    require(same(delivered['failures'], []) and same(delivered['before'], timeout['before']), label + ' same retained inventory')
    opening = [{key: survivor[key] for key in ('peer', 'rows_before', 'frame_before', 'game_before')} for survivor in timeout['survivors']]
    require(same(delivered['opening'], opening), label + ' same exposed history and game state')
    history = delivered['history_emissions']
    require(same(delivered['lost_history'], []) and bool(delivered['history_receipts']), label + ' original donor delivered')
    check_delivery(history, [], delivered['history_receipts'], label)
    for packet in history:
        require(same([packet['from'], packet['to'], packet['bytes']], [1, 0, history_bytes(4, 2).hex()]), label + ' donor route or bytes')
        check_godot_packet(packet['packet'], 4, 2)
    require(same(delivered['cuts'], [[11, 11], [11, 11]]), label + ' both original cutoff rows froze')
    check_godot_history_publications(delivered)
    check_godot_negotiation(delivered)
    check_rows(delivered['survivors'], label, 4, 2, True)



def omit_source_negotiation(trace, kinds=('DropPrepare', 'DropReport')):
    emitted = trace['controls']
    removed = {packet['emission'] for packet in emitted if any(kind in packet['body'] for kind in kinds)}
    kept = [packet for packet in emitted if packet['emission'] not in removed]
    renumber = {packet['emission']: index for index, packet in enumerate(kept)}
    trace['controls'] = kept
    trace['received_controls'] = [packet for packet in trace['received_controls'] if packet['emission'] not in removed]
    for key in ('controls', 'received_controls', 'lost_history'):
        trace[key] = [{**packet, 'emission': renumber[packet['emission']]} for packet in trace[key]]


def clone_godot_routing(trace):
    history = trace['history_emissions']
    clone = {**history[-1], 'emission': len(history)}
    history.append(clone)
    trace['lost_history'].append(clone)
    trace['history_routing'].append({**trace['history_routing'][-1], 'emission': clone['emission']})


def timeout_controls(source, godot):
    # Value: protects=the uninstalled original suffix can expire without rewriting exposed rows; fails_when=terminal receipts accept omissions or rewrites;
    # why_new=deadline tests hold the decision after history transfer, and loss tests subsequently deliver a retry; seam=none
    cases = {
        'source_omitted_negotiation': ('source', 'delivered coordinator prepare', omit_source_negotiation),
        'source_omitted_inventories': ('source', 'delivered direct inventories', lambda row: omit_source_negotiation(row, ('DropReport',))),
        'godot_cloned_routing': ('Godot', 'accepted publication and routing count', clone_godot_routing),
        'godot_omitted_inventory': ('Godot', 'inventory emissions',
                                     lambda row: row.update(inventory_emissions=[], inventory_receipts=[])),
        'godot_same_round_retry': ('Godot', 'distinct retry rounds', lambda row: (
            row['history_publications'][1].update(at_us=row['history_publications'][0]['at_us']),
            row['history_routing'][1].update(at_us=row['history_routing'][0]['at_us']))),
        'godot_early_terminal_event': ('Godot', 'exact terminal attribution',
                                       lambda row: row['terminal_events'][0].update(at_us=row['terminal_events'][0]['at_us'] - 1)),
        'source_missing_retry': ('source', 'discarded original retries', lambda row: row['lost_history'].pop()),
        'source_restored_retry': ('source', 'dropped history received', lambda row: row['received_controls'].append(row['lost_history'][0])),
        'source_wrong_abort_reason': ('source', 'abort reason', lambda row: next(
            packet['body']['DropAbort'] for packet in row['controls'] if 'DropAbort' in packet['body']).update(reason='MissingHistory')),
        'source_rewritten_donor_frontier': ('source', 'original exposed history',
                                              lambda row: row['survivors'][1]['rows_after'][-1]['inputs'].__setitem__(0, '00000000')),
        'godot_restored_retry': ('Godot', 'dropped history received', lambda row: row['history_receipts'].append(row['lost_history'][0])),
        'godot_false_freeze': ('Godot', 'fail-closed state', lambda row: row['survivors'][0]['cuts'].__setitem__(1, 11)),
        'godot_rewritten_donor_status': ('Godot', 'original exposed history', lambda row: row['survivors'][1]['rows_after'][-1]['inputs'][0].update(status='predicted')),
        'godot_rewritten_canonical_prefix': ('Godot', 'original exposed history', lambda row: row['survivors'][1]['rows_after'][-1]['state'].update(bytes='00')),
        'godot_advanced_callbacks': ('Godot', 'no gameplay advance', lambda row: row['survivors'][0].update(game_after='00')),
    }
    for name, (runtime, diagnostic, mutate) in cases.items():
        candidate = copy.deepcopy(source if runtime == 'source' else godot)
        mutate(candidate)
        try:
            check_timeout(candidate, godot) if runtime == 'source' else check_timeout(source, candidate)
        except ValueError as error:
            require(str(error) == f'drop history: {runtime} donor timeout {diagnostic}', name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return list(cases)
