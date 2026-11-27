"""Check original history when every actual donor publication is lost."""
import copy

from drop_history_contract import (
    REVISION, check_before, check_delivery, check_godot_packet, check_rows, check_source_content, check_source_operation,
    fields, history_bytes, integer, original_history, require, same,
)
from drop_history_inventory_controls import check_source_observation_order


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
    return len(history)


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
    require(same(godot['reasons'], ['timeout', 'timeout']) and same(godot['failures'], []), label + ' terminal causes')
    return len(history)


def check_timeout(source, godot):
    fields(source, 'upstream_revision before controls received_controls lost_history survivors', 'source donor timeout')
    fields(godot, 'before survivors reasons drop_events history_emissions history_receipts lost_history commit_emissions failures', 'Godot donor timeout')
    require(source['upstream_revision'] == REVISION, 'source donor timeout revision')
    check_before(source['before'], 'source', 4, 2, True)
    check_before(godot['before'], 'Godot', 4, 2, True)
    retry_counts = {'source': check_source_packets(source), 'godot': check_godot_packets(godot)}
    original = original_history(4, 2)
    for label, trace in [('source', source), ('Godot', godot)]:
        require(type(trace['survivors']) is list and len(trace['survivors']) == 2, label + ' donor timeout survivors')
        for peer, row in enumerate(trace['survivors']):
            fields(row, 'peer rows_before rows_after frame_before frame_after game_before game_after advance target_receipts '
                   + ('state dropped connected' if label == 'source' else 'lifecycle cuts confirmed_after'), label + ' donor timeout survivor')
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
    return retry_counts


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
    check_rows(delivered['survivors'], label, 4, 2, True)



def timeout_controls(source, godot):
    # Value: protects=the uninstalled original suffix can expire without rewriting exposed rows; fails_when=terminal receipts accept omissions or rewrites;
    # why_new=deadline tests hold the decision after history transfer, and loss tests subsequently deliver a retry; seam=none
    cases = {
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
