"""Validate actual browser-received replay files before ownership qualification."""
import hashlib
from pathlib import Path
import re

CASES = [('interior', 301), ('terminal', 610), ('initial', 0)]


def validate_downloads(value, output=None):
    """Require exact received bytes, successful replacement and independent canonical playback."""
    if type(value) is not dict or set(value) != {'cases', 'download_events', 'forbidden_events', 'errors'}:
        raise ValueError('incorrect replay download fields')
    if (type(value['download_events']) is not int or value['download_events'] != 3
            or type(value['forbidden_events']) is not int or value['forbidden_events'] != 0
            or type(value['errors']) is not list or value['errors']):
        raise ValueError('replay download lifetime events differ')
    if type(value['cases']) is not list or len(value['cases']) != len(CASES):
        raise ValueError('incomplete replay download cases')
    for record, (name, frame) in zip(value['cases'], CASES):
        fields = {'case', 'frame', 'frames', 'bytes', 'sha256', 'filename', 'canonical', 'original',
                  'replaced', 'disconnected_rows', 'seek_disabled', 'held_disabled'}
        if type(record) is not dict or set(record) != fields or record['case'] != name:
            raise ValueError('incorrect replay download case fields')
        if (any(type(record[key]) is not int for key in ('frame', 'frames', 'bytes'))
                or record['frame'] != frame or record['frames'] != frame or record['bytes'] <= 0):
            raise ValueError('replay download boundary differs')
        if type(record['disconnected_rows']) is not int or record['disconnected_rows'] != max(0, frame - 17):
            raise ValueError('replay download statuses differ')
        if any(record[key] is not True for key in ('replaced', 'seek_disabled', 'held_disabled')):
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
    return value


CONTROL_DIAGNOSTICS = {
    'reject-reimport': 'received replay download replacement refused',
    'late-error': 'replay download forbidden events observed',
    'late-download': 'replay download forbidden events observed',
}


def validate_controls(records):
    if type(records) is not list or len(records) != len(CONTROL_DIAGNOSTICS):
        raise ValueError('incomplete replay download controls')
    for record, (name, diagnostic) in zip(records, CONTROL_DIAGNOSTICS.items()):
        if (type(record) is not dict or set(record) != {'control', 'exit_code', 'diagnostic'}
                or record['control'] != name or type(record['exit_code']) is not int or record['exit_code'] != 1
                or record['diagnostic'] != diagnostic):
            raise ValueError('replay download control differs')
    return records
