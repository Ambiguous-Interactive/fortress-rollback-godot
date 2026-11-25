"""Value: failed preflight invalidates stale success without damaging an active cache owner."""
from contextlib import nullcontext
import os
import py_compile
import shutil
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

    # Value: protects=CLI helper execution and receipt invalidation; fails_when=helpers run cached code or load before ownership; seam=real CLI
    def test_cli_loads_helper_source_after_invalidating_receipts(self):
        for case in ('clean', 'stale-cache', 'missing-source', 'source-change', 'missing-lock-helper', 'busy-missing-lock-helper', 'exiting-lock-helper'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                reference = root / 'scripts/reference'
                names = ('scripts/reference/ownership_probes.py', 'docs/reference/pins.json', *probes.HELPER_PATHS.values())
                if case == 'source-change':
                    names = probes.source_inventory()
                for relative in names:
                    target = root / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / relative, target)
                cache = root / '.cache/reference'
                results = cache / 'results'
                results.mkdir(parents=True)
                receipts = (results / 'ownership.json', results / 'ownership-rounds.json')
                original = '{"status":"passed"}\n'
                for receipt in receipts:
                    receipt.write_text(original)
                helper = reference / 'fetch.py'
                busy = case == 'busy-missing-lock-helper'
                missing_lock_helper = busy or case == 'missing-lock-helper'
                missing_file = reference / 'local_ownership.py' if missing_lock_helper else helper
                argument = '--help'
                if case == 'stale-cache':
                    source = helper.read_bytes()
                    metadata = helper.stat()
                    stale = b'raise RuntimeError("stale helper cache executed")\n'
                    helper.write_bytes(stale.ljust(len(source), b' '))
                    os.utime(helper, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
                    py_compile.compile(str(helper), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP)
                    helper.write_bytes(source)
                    os.utime(helper, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
                    ordinary = subprocess.run([sys.executable, '-c', 'import fetch'], cwd=reference,
                                              capture_output=True, encoding='utf-8', timeout=10)
                    self.assertIn('RuntimeError: stale helper cache executed', ordinary.stderr)
                elif case == 'missing-source' or missing_lock_helper:
                    missing_file.unlink()
                elif case == 'exiting-lock-helper':
                    (reference / 'local_ownership.py').write_text('raise SystemExit(0)\n')
                elif case == 'source-change':
                    argument = '--offline'
                    with helper.open('a') as output:
                        output.write('\nPath(__file__).write_bytes(Path(__file__).read_bytes() + b"\\n")\n')
                    with (root / 'scripts/host_capacity.py').open('a') as output:
                        output.write('\ndef acquire_when_free(*args):\n    return True\n')
                with claim('ownership', directory=cache / 'locks') if busy else nullcontext() as active:
                    lock_record = active.path.read_bytes() if active else None
                    child = subprocess.run([sys.executable, str(reference / 'ownership_probes.py'), argument],
                                           capture_output=True, encoding='utf-8', timeout=10)
                    if active:
                        self.assertEqual(active.path.read_bytes(), lock_record)
                        for receipt in receipts:
                            self.assertEqual(receipt.read_text(), original)
                missing_diagnostic = f"FileNotFoundError: [Errno 2] No such file or directory: '{missing_file}'"
                failures = {
                    'missing-source': missing_diagnostic,
                    'source-change': 'ValueError: ownership compiled helper source differs from inventory: scripts/reference/fetch.py',
                    'missing-lock-helper': missing_diagnostic,
                    'busy-missing-lock-helper': missing_diagnostic,
                    'exiting-lock-helper': 'RuntimeError: ownership claim helper exited during import',
                }
                if case in failures:
                    self.assertEqual(child.returncode, 1, child.stderr)
                    self.assertEqual(child.stderr.splitlines()[-1], failures[case])
                    if not busy:
                        for receipt in receipts:
                            self.assertFalse(receipt.exists(), str(receipt))
                else:
                    self.assertEqual(child.returncode, 0, child.stderr)
                    self.assertIn('usage: ownership_probes.py', child.stdout)
                    for receipt in receipts:
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
