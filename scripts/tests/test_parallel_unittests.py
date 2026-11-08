"""Self-test: the parallel unittest runner must fail closed.

The runner replaces a direct ``unittest discover`` call in CI, so its
aggregation is the gate. These tests pin:

* a tree whose files all pass exits zero and reports every file;
* a failing file fails the whole run and surfaces its own output;
* a file exceeding the per-file timeout fails the run as a timeout;
* only files matching the pattern execute; helpers are never run;
* discovery on a directory without matching files raises.

Each case exercises the real script end to end through a temporary tree.
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import parallel_unittests

RUNNER = Path(parallel_unittests.__file__).resolve()


def run_runner(*arguments):
    completed = subprocess.run([sys.executable, str(RUNNER), *arguments], capture_output=True, text=True, timeout=120)
    return completed


class ParallelRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix='frg-parallel-tests-'))
        self.addCleanup(shutil.rmtree, self.directory, True)

    def write(self, name, body):
        path = self.directory / name
        path.write_text(body, encoding='utf-8')
        return path

    def passing(self, name='test_ok.py'):
        return self.write(name, 'import unittest\n\nclass Ok(unittest.TestCase):\n'
                                '    def test_passes(self):\n        self.assertTrue(True)\n')

    def test_all_passing_files_exit_zero(self):
        self.passing('test_a.py')
        self.passing('test_b.py')
        completed = run_runner('--start-dir', str(self.directory), '--jobs', '2')
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        for name in ('test_a.py', 'test_b.py'):
            self.assertIn(f'pass {name}', completed.stdout)
        self.assertIn('2 files, 0 failed, 0 missing', completed.stdout)

    def test_failing_file_fails_the_run_and_prints_its_output(self):
        self.passing('test_good.py')
        self.write('test_bad.py', 'import unittest\n\nclass Bad(unittest.TestCase):\n'
                                  '    def test_marker_failure(self):\n        self.fail("expected marker")\n')
        completed = run_runner('--start-dir', str(self.directory), '--jobs', '2')
        self.assertEqual(completed.returncode, 1)
        self.assertIn('FAIL test_bad.py', completed.stdout)
        self.assertIn('expected marker', completed.stdout + completed.stderr)
        self.assertIn('1 failed, 0 missing', completed.stdout)

    def test_timeout_fails_the_run(self):
        self.passing('test_quick.py')
        self.write('test_slow.py', 'import time, unittest\n\nclass Slow(unittest.TestCase):\n'
                                   '    def test_sleeps(self):\n        time.sleep(30)\n')
        completed = run_runner('--start-dir', str(self.directory), '--jobs', '2', '--timeout', '3')
        self.assertEqual(completed.returncode, 1)
        self.assertIn('FAIL test_slow.py', completed.stdout)
        self.assertIn('per-file timeout', completed.stdout)

    def test_pattern_excludes_helper_modules(self):
        self.passing()
        self.write('helper.py', 'raise SystemExit("helper modules must never execute")\n')
        completed = run_runner('--start-dir', str(self.directory), '--pattern', 'test_*.py', '--jobs', '1')
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertNotIn('helper.py', completed.stdout)

    def test_discovery_without_matches_raises(self):
        with self.assertRaises(ValueError):
            parallel_unittests.discover(self.directory, 'test_*.py')


if __name__ == '__main__':
    unittest.main()
