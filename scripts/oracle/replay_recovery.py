"""Require exact source final receipts, correction callbacks and decoded history."""
import copy
import json


def source_observation(messages, rows, records, corrections, *, receipts=None):
    boundary = len(rows)
    if receipts is None:
        receipts = [boundary - 1, boundary - 1]
    result = dict(messages=messages, frames=[boundary, boundary],
                  frontiers=[dict(peer=slot, current_before=boundary, current_frame=boundary, confirmed_frame=receipt,
                                  receipt_frame=receipt, last_inputs=rows[-1] if receipt == boundary - 1 else None,
                                  callback_count=len(history)) for slot, (history, receipt) in enumerate(zip(records, receipts))])
    if corrections is None:
        result['errors'] = ['Invalid Request: missing local input for one or more players'] * 2
    else:
        result.update(corrections=corrections, repeated_saves=[1, 1])
    return result


def withheld_receipt_controls(binary, output, execute, expected, *, recovery):
    """Require incomplete source exports and the original missing-input error."""
    from replay_launch import compare

    rejected, exports = [], {}
    for neutral in (False, True):
        mode = '--remote-recording-asymmetric' + ('-neutral' if neutral else '') + '-final-missing'
        log = output / (mode[2:] + '-rust.log')
        try:
            execute([str(binary), mode], log)
        except ValueError:
            lines = log.read_text().splitlines()
            if len(lines) != 2 or lines[-1] != 'Error: "source final original input unavailable: peer=0 frame=256"':
                raise ValueError('wrong source final-receipt rejection')
            actual = json.loads(lines[0])
            row_counts = [len(peer['frames']) for peer in actual['peers']]
            compare(row_counts, [256, 255], 'asymmetric.withheld.exported_rows')
            compare(actual, expected(True, neutral, source_recovery=recovery, omit_final=True), 'asymmetric.withheld')
            exports['neutral' if neutral else 'corrected'] = [
                dict(peer=peer['peer'], receipt_frame=frontier['receipt_frame'], confirmed_frame=frontier['confirmed_frame'],
                     final_input_received=frontier['last_inputs'] is not None, exported_rows=len(peer['frames']),
                     last_playback_frame=peer['playback']['current_frame'])
                for peer, frontier in zip(actual['peers'], actual['recovery'][0]['frontiers'])
            ]
            rejected.append('rust-' + ('neutral-' if neutral else '') + 'missing-final-receipt')
        else:
            raise ValueError('source missing final receipt accepted')
    return dict(negative_controls=rejected, withheld_exports=exports)


def controls(observations, validate, schedule, *, recovery):
    """Reject changes to the final recovery evidence."""
    original = observations['corrected']['rust']
    faults = [('receipt', ('recovery', 0, 'frontiers', 1, 'receipt_frame'), 257),
              ('confirmation', ('recovery', 0, 'frontiers', 1, 'confirmed_frame'), 257),
              ('forward-frame', ('recovery', 0, 'frontiers', 1, 'current_frame'), 258),
              ('new-callback', ('recovery', 0, 'frontiers', 1, 'callback_count'), original['recovery'][0]['frontiers'][1]['callback_count'] + 1),
              ('original-input', ('recovery', 0, 'frontiers', 1, 'last_inputs', 0), original['recovery'][0]['frontiers'][1]['last_inputs'][0] ^ 1)]
    if recovery:
        faults.extend([
            ('missing-correction', ('recovery', 0, 'corrections', 0), 0),
            ('repeated-save', ('recovery', 0, 'repeated_saves', 0), 0),
            ('exported-row', ('peers', 0, 'frames', 256, 0), original['peers'][0]['frames'][256][0] ^ 1),
            ('exported-checksum', ('peers', 0, 'checksums', 256), '00' * 16),
            ('canonical-boundary', ('peers', 0, 'bytes'), '00' * 16),
        ])
    from replay_launch import reject_mutations

    def check(changed, _wanted):
        validate(changed, True, source_recovery=recovery)

    return reject_mutations(original, original, [('rust-final-' + name, path, value) for name, path, value in faults],
                            compare_result=check, prefix=f'{schedule}.rust')
