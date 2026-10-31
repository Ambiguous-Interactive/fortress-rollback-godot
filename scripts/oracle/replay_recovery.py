"""Require actual source final receipts without claiming an unavailable recovery service."""
import copy


def observe(binary, output, execute, observations):
    """A real omitted final delivery must fail the original-input read, before exporting."""
    rejected = []
    for neutral in (False, True):
        mode = '--remote-recording-asymmetric' + ('-neutral' if neutral else '') + '-final-missing'
        log = output / (mode[2:] + '-rust.log')
        try:
            execute([str(binary), mode], log)
        except ValueError:
            text = log.read_text()
            if text.strip() != 'Error: "source final original input unavailable: peer=0 frame=256"':
                raise ValueError('wrong source final-receipt rejection')
            rejected.append('rust-' + ('neutral-' if neutral else '') + 'missing-final-receipt')
        else:
            raise ValueError('source missing final receipt accepted')
    from replay_asymmetric import validate
    for fault, field in [('receipt', 'receipt_frame'), ('confirmation', 'confirmed_frame'),
                         ('forward-frame', 'current_frame'), ('new-callback', 'callback_count'), ('original-input', 'last_inputs')]:
        changed = copy.deepcopy(observations['corrected']['rust'])
        row = changed['recovery'][0]['frontiers'][1]
        if field == 'last_inputs':
            row[field][0] ^= 1
        else:
            row[field] += 1
        try:
            validate(changed, True)
        except ValueError as error:
            if not str(error).startswith(f'asymmetric.rust.recovery[0].frontiers[1].{field}'):
                raise ValueError(f'wrong source {fault} rejection: {error}') from error
        else:
            raise ValueError(f'source {fault} mutation accepted')
        rejected.append('rust-final-' + fault)
    return dict(negative_controls=rejected)
