"""Validate raw recorder values before semantic normalization can erase malformed evidence."""
from contract import fields, integer

DISPOSITIONS = {
    'activated': {None}, 'begin': {None}, 'report_timeout': {None},
    'send_request': {'fresh', 'collision'},
    'handle_request': {'observed', 'incompatible', 'alreadyincompatible', 'answeredonly'},
    'handle_reply': {'accepted', 'incompatible', 'duplicate', 'unknown', 'notsynchronizing', 'alreadyincompatible', 'ambiguousrequestidcollision'},
}
MISMATCH_FIELDS = {'min_compat_version', 'player_count', 'input_width', 'fps', 'max_prediction', 'desync_interval', 'features', 'config_digest'}


def hexadecimal(value, size, label):
    if type(value) is not str or len(value) != size * 2 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError(label + ': invalid canonical hex')


def mismatch(value):
    if type(value) is not dict:
        raise ValueError('raw mismatch must be dictionary')
    if not value:
        return
    fields(value, 'field ours theirs', 'raw mismatch')
    if type(value['field']) is not str or value['field'] not in MISMATCH_FIELDS:
        raise ValueError('raw mismatch field')
    for key in ('ours', 'theirs'):
        if value['field'] == 'config_digest':
            hexadecimal(value[key], 8, 'raw mismatch digest')
        else:
            high = 255 if value['field'] == 'min_compat_version' else 65535 if value['field'] in {'player_count', 'input_width', 'max_prediction'} else 0xffffffff
            integer(value[key], 0, high, 'raw mismatch ' + key)


def transition(value, record_index, transition_index):
    fields(value, 'action token disposition state remaining outstanding remote_connection timeout_sent mismatch elapsed_ms', 'upstream transition')
    action = value['action']
    if type(action) is not str or action not in DISPOSITIONS:
        raise ValueError('raw transition action')
    if action in {'activated', 'begin'} and (record_index != 0 or transition_index != (0 if action == 'activated' else 1)):
        raise ValueError('raw transition activation/begin position')
    if type(value['state']) is not str or value['state'] not in {'initializing', 'synchronizing', 'running'}:
        raise ValueError('raw transition state')
    for key in ('remaining', 'outstanding'):
        integer(value[key], 0, 128, 'raw transition ' + key)
    if type(value['timeout_sent']) is not bool:
        raise ValueError('raw transition timeout type')
    mismatch(value['mismatch'])
    if value['remote_connection'] is not None:
        hexadecimal(value['remote_connection'], 8, 'raw remote connection')
    if action in {'activated', 'begin', 'report_timeout'}:
        if value['token'] is not None or value['disposition'] is not None:
            raise ValueError('raw transition requires null token/disposition')
    else:
        hexadecimal(value['token'], 16, 'raw transition token')
        if type(value['disposition']) is not str or value['disposition'] not in DISPOSITIONS[action]:
            raise ValueError('raw transition disposition')
    integer(value['elapsed_ms'], 0 if action == 'report_timeout' else -1, 10000 if action == 'report_timeout' else -1, 'raw elapsed_ms')
