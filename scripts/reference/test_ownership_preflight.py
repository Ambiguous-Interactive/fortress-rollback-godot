"""Value: failed preflight invalidates stale success without damaging an active cache owner."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import ownership_probes as probes
from local_ownership import claim

ROOT = Path(__file__).resolve().parents[2]


class OwnershipPreflightTests(unittest.TestCase):
    def test_failed_host_capacity_removes_old_success_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            results = cache / 'results'
            results.mkdir()
            receipt = results / 'ownership.json'
            receipt.write_text('{"status":"passed"}\n')
            with (mock.patch.object(probes, 'CACHE', cache),
                  mock.patch.object(probes.host_capacity, 'acquire_when_free', return_value=False),
                  mock.patch.object(probes, 'run_probes') as execute,
                  mock.patch('sys.argv', ['ownership_probes.py', '--offline'])):
                with self.assertRaisesRegex(ValueError, 'host stayed busy'):
                    probes.main()
                execute.assert_not_called()
            self.assertFalse(receipt.exists(), 'failed preflight retained stale success')

    def test_concurrent_real_claimant_preserves_active_receipt_even_on_bad_arguments(self):
        for arguments in ([], ['--unknown-option']):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                cache = Path(directory)
                results = cache / 'results'
                results.mkdir()
                receipt = results / 'ownership.json'
                original = '{"status":"passed","owner":"active"}\n'
                receipt.write_text(original)
                code = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import ownership_probes as probes
probes.CACHE = Path(sys.argv[2])
sys.argv = ['ownership_probes.py'] + sys.argv[3:]
probes.host_capacity.acquire_when_free = lambda *args: False
probes.main()
'''
                with claim('ownership', directory=cache / 'locks'):
                    child = subprocess.run([sys.executable, '-c', code, str(ROOT / 'scripts/reference'), str(cache), *arguments],
                                           capture_output=True, encoding='utf-8', timeout=10)
                    self.assertNotEqual(child.returncode, 0)
                    self.assertIn('reference cache is owned by another local run', child.stderr)
                    self.assertEqual(child.stdout, '')
                    self.assertEqual(receipt.read_text(), original)

    def test_main_manifest_failure_invalidates_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            receipt = cache / 'results/ownership.json'
            receipt.parent.mkdir()
            receipt.write_text('{"status":"passed"}\n')
            with (mock.patch.object(probes, 'CACHE', cache),
                  mock.patch.object(probes, 'load_manifest', side_effect=ValueError('invalid pin manifest')),
                  mock.patch('sys.argv', ['ownership_probes.py'])):
                with self.assertRaisesRegex(ValueError, 'invalid pin manifest'):
                    probes.main()
            self.assertFalse(receipt.exists())


if __name__ == '__main__':
    unittest.main()
