"""Validate actual browser-received replay files before ownership qualification."""
import hashlib
from pathlib import Path
import re

CASES = [('interior', 301), ('terminal', 610), ('initial', 0)]


def validate_downloads(value, output=None):
    """Require exact received bytes, successful replacement and independent canonical playback."""
    if type(value) is not dict or set(value) != {'cases', 'chooser', 'download_events', 'forbidden_events', 'errors'}:
        raise ValueError('incorrect replay download fields')
    if (type(value['download_events']) is not int or value['download_events'] != 3
            or type(value['forbidden_events']) is not int or value['forbidden_events'] != 0
            or type(value['errors']) is not list or value['errors']):
        raise ValueError('replay download lifetime events differ')
    if type(value['cases']) is not list or len(value['cases']) != len(CASES):
        raise ValueError('incomplete replay download cases')
    for record, (name, frame) in zip(value['cases'], CASES):
        fields = {'case', 'frame', 'frames', 'bytes', 'sha256', 'filename', 'canonical', 'original',
                  'replaced', 'original_valid', 'disconnected_rows', 'seek_disabled', 'held_disabled'}
        if type(record) is not dict or set(record) != fields or record['case'] != name:
            raise ValueError('incorrect replay download case fields')
        if (any(type(record[key]) is not int for key in ('frame', 'frames', 'bytes'))
                or record['frame'] != frame or record['frames'] != frame or record['bytes'] <= 0):
            raise ValueError('replay download boundary differs')
        if type(record['disconnected_rows']) is not int or record['disconnected_rows'] != max(0, frame - 17):
            raise ValueError('replay download statuses differ')
        if any(record[key] is not True for key in ('replaced', 'original_valid', 'seek_disabled', 'held_disabled')):
            raise ValueError('replay download ownership gate failed')
        if (type(record['canonical']) is not str or not re.fullmatch(r'(?:[0-9a-f]{2})+', record['canonical'])
                or record['canonical'] != record['original']):
            raise ValueError('replay download canonical playback differs')
        if type(record['sha256']) is not str or not re.fullmatch(r'[0-9a-f]{64}', record['sha256']):
            raise ValueError('replay download digest malformed')
        if type(record['filename']) is not str or Path(record['filename']).name != record['filename'] or not record['filename'].endswith('.frrp'):
            raise ValueError('replay download filename malformed')
        if output is None:
            continue
        received = output / (name + '.frrp')
        if (not received.is_file() or received.is_symlink() or received.stat().st_size != record['bytes']
                or hashlib.sha256(received.read_bytes()).hexdigest() != record['sha256']):
            raise ValueError('received replay download identity differs')
        screenshot = output / (name + '.png')
        if (not screenshot.is_file() or screenshot.is_symlink() or screenshot.stat().st_size <= 8
                or screenshot.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n'):
            raise ValueError('replay download screenshot missing')
    validate_chooser(value['chooser'])
    return value


def validate_chooser(records):
    if type(records) is not list or len(records) != 2:
        raise ValueError('incomplete replay chooser cases')
    fields = {'mode', 'paused_frame', 'resumed_frame', 'speed', 'canonical', 'original',
              'canceled', 'rejected', 'replaced', 'old_retired', 'held_refused', 'expert_refused'}
    for record, (mode, frame) in zip(records, [('ordinary', 2), ('repeat', 300)]):
        if type(record) is not dict or set(record) != fields or record['mode'] != mode:
            raise ValueError('incorrect replay chooser case fields')
        if (any(type(record[key]) is not int for key in ('paused_frame', 'resumed_frame', 'speed'))
                or record['paused_frame'] != frame or record['resumed_frame'] != frame + 1 or record['speed'] != 1):
            raise ValueError('replay chooser boundary differs')
        if any(record[key] is not True for key in ('canceled', 'rejected', 'replaced', 'old_retired', 'held_refused', 'expert_refused')):
            raise ValueError('replay chooser ownership differs')
        if (type(record['canonical']) is not str or not re.fullmatch(r'(?:[0-9a-f]{2})+', record['canonical'])
                or record['canonical'] != record['original']):
            raise ValueError('replay chooser canonical state differs')
    return records


CONTROL_DIAGNOSTICS = {
    'alter-metadata': 'received replay download original evidence differs',
    'reject-reimport': 'received replay download replacement refused',
    'late-error': 'replay download forbidden events observed',
    'late-download': 'replay download forbidden events observed',
    'chooser-pause': 'replay chooser failed to pause playback',
}


def validate_controls(records):
    if type(records) is not list or len(records) != len(CONTROL_DIAGNOSTICS):
        raise ValueError('incomplete replay download controls')
    for record, (name, diagnostic) in zip(records, CONTROL_DIAGNOSTICS.items()):
        fields = {'control', 'exit_code', 'diagnostic'} | ({'mutation'} if name == 'chooser-pause' else set())
        if (type(record) is not dict or set(record) != fields
                or record['control'] != name or type(record['exit_code']) is not int or record['exit_code'] != 1
                or record['diagnostic'] != diagnostic):
            raise ValueError('replay download control differs')
        if name == 'chooser-pause':
            mutation = record['mutation']
            if (type(mutation) is not dict or set(mutation) != {'path', 'before_sha256', 'after_sha256', 'export_inventory'}
                    or mutation['path'] != 'examples/online/replay_scene.gd'
                    or any(type(mutation[key]) is not str or not re.fullmatch(r'[0-9a-f]{64}', mutation[key])
                           for key in ('before_sha256', 'after_sha256'))
                    or mutation['before_sha256'] == mutation['after_sha256']
                    or type(mutation['export_inventory']) is not dict or not mutation['export_inventory']
                    or any(type(key) is not str or not key.startswith('export/') or '..' in Path(key).parts
                           or type(value) is not str or not re.fullmatch(r'[0-9a-f]{64}', value)
                           for key, value in mutation['export_inventory'].items())):
                raise ValueError('replay chooser mutation identity differs')
    return records
