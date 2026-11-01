"""Value: received browser files cannot qualify with missing, stale or malformed evidence."""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from replay_download import CASES, CONTROL_DIAGNOSTICS, validate_controls, validate_downloads


def fixture(output=None):
    records = []
    for name, frame in CASES:
        received = (name + '-received-bytes').encode()
        if output is not None:
            (output / (name + '.frrp')).write_bytes(received)
            (output / (name + '.png')).write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        records.append({'case': name, 'frame': frame, 'frames': frame, 'bytes': len(received),
                        'sha256': hashlib.sha256(received).hexdigest(), 'filename': name + '.frrp',
                        'canonical': '010203', 'original': '010203', 'replaced': True,
                        'seek_disabled': True, 'held_disabled': True})
    return {'cases': records, 'download_events': 3, 'forbidden_events': 0, 'errors': []}


class ReplayDownloadTests(unittest.TestCase):
    def test_received_files_and_all_three_boundaries_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            value = fixture(output)
            self.assertEqual(validate_downloads(value, output), value)

    def test_table_rejects_wrong_values_and_scalar_type_aliases(self):
        mutations = [(key, value) for key, values in {
            'frame': [True, 301.0, -1, 0, '301'], 'frames': [True, 301.0, 610, '301'],
            'bytes': [True, 1.0, 0, -1], 'sha256': ['', 'a' * 63, 'A' * 64, None],
            'filename': ['../x.frrp', '/x.frrp', 'x', None], 'canonical': ['', '00', '0', None],
            'original': ['00', None], 'replaced': [False, 1], 'seek_disabled': [False, 1],
            'held_disabled': [False, 1], 'case': ['terminal', 0],
        }.items() for value in values]
        mutations += [('download_events', value) for value in [True, 3.0, 2, 4]]
        mutations += [('forbidden_events', value) for value in [False, 0.0, 1]]
        mutations += [('errors', value) for value in [False, None, ['late']]]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            original = fixture(output)
            for key, value in mutations:
                with self.subTest(key=key, value=value):
                    altered = copy.deepcopy(original)
                    target = altered if key in ('download_events', 'forbidden_events', 'errors') else altered['cases'][0]
                    target[key] = value
                    with self.assertRaises(ValueError):
                        validate_downloads(altered, output)
            for name in ('missing', 'duplicate', 'order', 'unknown', 'missing-field'):
                with self.subTest(name=name):
                    altered = copy.deepcopy(original)
                    if name == 'missing':
                        altered['cases'].pop()
                    elif name == 'duplicate':
                        altered['cases'][1] = copy.deepcopy(altered['cases'][0])
                    elif name == 'order':
                        altered['cases'].reverse()
                    elif name == 'unknown':
                        altered['cases'][0]['unknown'] = True
                    else:
                        altered['cases'][0].pop('replaced')
                    with self.assertRaises(ValueError):
                        validate_downloads(altered, output)

    def test_controls_require_exact_complete_failing_inventories(self):
        valid = [{'control': name, 'exit_code': 1, 'diagnostic': diagnostic} for name, diagnostic in CONTROL_DIAGNOSTICS.items()]
        self.assertEqual(validate_controls(valid), valid)
        for name in ('missing', 'duplicate', 'order', 'code', 'bool', 'diagnostic'):
            with self.subTest(name=name):
                altered = copy.deepcopy(valid)
                if name == 'missing':
                    altered.pop()
                elif name == 'duplicate':
                    altered[1] = altered[0]
                elif name == 'order':
                    altered.reverse()
                elif name in ('code', 'bool'):
                    altered[0]['exit_code'] = 0 if name == 'code' else True
                else:
                    altered[0]['diagnostic'] = 'unrelated failure'
                with self.assertRaises(ValueError):
                    validate_controls(altered)

    def test_actual_received_artifact_and_screenshot_are_required(self):
        for mutation in ('missing', 'changed', 'symlink', 'screenshot-missing', 'screenshot-empty'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                value = fixture(output)
                target = output / 'interior.frrp'
                if mutation == 'missing':
                    target.unlink()
                elif mutation == 'changed':
                    target.write_bytes(b'changed')
                elif mutation == 'symlink':
                    target.unlink()
                    target.symlink_to(output / 'terminal.frrp')
                elif mutation == 'screenshot-missing':
                    (output / 'interior.png').unlink()
                else:
                    (output / 'interior.png').write_bytes(b'')
                with self.assertRaises(ValueError):
                    validate_downloads(value, output)


if __name__ == '__main__':
    unittest.main()
