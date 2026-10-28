"""Reject fabricated ACK loss, absent retries and invented commit/ACK chronology."""
import copy

from drop_history_contract import compare, payload, require, same


def follower_ack(packet, target_slots=2):
    report = packet['body'].get('DropReport', {})
    return packet['from'] == 1 and packet['to'] == 0 and report.get('stage') == 'Committed' and report.get('participant') == target_slots


def remove_source_ack_retries(source):
    first = source['lost_ack'][0]
    retained = [packet for packet in source['controls']
                if packet['emission'] == first['emission'] or not same(payload(packet), payload(first))]
    indices = {packet['emission']: index for index, packet in enumerate(retained)}
    for bank in ('controls', 'received_controls', 'lost_history', 'lost_commit', 'lost_ack'):
        source[bank] = [{**packet, 'emission': indices[packet['emission']]}
                        for packet in source[bank] if packet['emission'] in indices]


def insert_godot_ack_retry(godot, before_repeated_commit):
    for bank in ('commit_emissions', 'lost_commit', 'commit_receipts', 'ack_emissions', 'lost_ack', 'ack_receipts'):
        for packet in godot[bank]:
            packet['order'] *= 2
    retry = copy.deepcopy(godot['ack_emissions'][0])
    retry.update(emission=1, order=godot['commit_receipts'][1]['order'] + (-1 if before_repeated_commit else 1))
    for bank in ('ack_emissions', 'ack_receipts'):
        for packet in godot[bank]:
            if packet['emission'] >= 1:
                packet['emission'] += 1
    godot['ack_emissions'].insert(1, retry)
    godot['ack_receipts'].insert(0, copy.deepcopy(retry))


def controls(clean, lost):
    # Value: protects=real follower ACK retry; fails_when=forwarded or delivered certificates masquerade as loss; why_new=COMMIT loss cannot cover ACKs; seam=none
    fabricated = copy.deepcopy(clean)
    fabricated['source']['lost_ack'] = [copy.deepcopy(next(packet for packet in fabricated['source']['controls'] if follower_ack(packet)))]
    fabricated['godot']['lost_ack'] = [copy.deepcopy(fabricated['godot']['ack_emissions'][0])]
    fabricated_godot = copy.deepcopy(lost)
    fabricated_godot['godot'] = copy.deepcopy(fabricated['godot'])
    no_source_retry = copy.deepcopy(lost)
    remove_source_ack_retries(no_source_retry['source'])
    no_godot_retry = copy.deepcopy(lost)
    no_godot_retry['godot'].update(ack_emissions=no_godot_retry['godot']['ack_emissions'][:1], ack_receipts=[])
    no_repeat_commit = copy.deepcopy(lost)
    no_repeat_commit['godot'].update(commit_emissions=no_repeat_commit['godot']['commit_emissions'][:1],
                                    commit_receipts=no_repeat_commit['godot']['commit_receipts'][:1])
    bad_order = copy.deepcopy(lost)
    for bank in ('ack_emissions', 'ack_receipts'):
        for packet in bad_order['godot'][bank]:
            if packet['emission'] > 0:
                packet['order'] = bad_order['godot']['ack_emissions'][0]['order']
    # Value: protects=first delivered ACK follows repeated COMMIT; fails_when=later retry masks early delivery; why_new=all-early mutation misses this; seam=none
    valid_extra_retry = copy.deepcopy(lost)
    insert_godot_ack_retry(valid_extra_retry['godot'], False)
    compare(valid_extra_retry['source'], valid_extra_retry['godot'], False, 4, 2, True, False, True)
    early_extra_retry = copy.deepcopy(lost)
    insert_godot_ack_retry(early_extra_retry['godot'], True)
    cases = [('fabricated_source_ack_loss', fabricated, 'source emission/loss/receipt accounting'),
             ('fabricated_Godot_ack_loss', fabricated_godot, 'Godot acknowledgement emission/loss/receipt accounting'),
             ('missing_source_ack_retry', no_source_retry, 'source exact acknowledgement retry receipt'),
             ('missing_Godot_ack_retry', no_godot_retry, 'Godot exact acknowledgement retry receipt'),
             ('missing_Godot_repeated_commit', no_repeat_commit, 'Godot acknowledgement requires repeated commit receipt'),
             ('Godot_ack_before_repeated_commit', bad_order, 'Godot acknowledgement follows repeated commit receipt'),
             ('Godot_first_ack_early_with_later_retry', early_extra_retry, 'Godot acknowledgement follows repeated commit receipt')]
    for name, candidate, diagnostic in cases:
        try:
            compare(candidate['source'], candidate['godot'], False, 4, 2, True, False, True)
        except ValueError as error:
            require(str(error) == 'drop history: ' + diagnostic, name + ' unrelated failure: ' + str(error))
        else:
            raise ValueError('drop history: negative control survived: ' + name)
    return [name for name, _, _ in cases]
