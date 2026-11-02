"""Protect the source-width gate at its command-line boundary."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / 'check_source_line_lengths.py'
sys.path.insert(0, str(CHECKER.parent))
from git_test_environment import fixture_environment


class SourceLineLengthsTest(unittest.TestCase):
    # Value: protects=180-column gate; fails_when=boundary or source scope drifts; why_new=no source-width gate exists; seam=none
    def test_source_boundary_and_data_exclusion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = fixture_environment()
            subprocess.run(['git', 'init', '-q', str(root)], check=True, env=environment, timeout=30)
            source = root / 'sample.py'
            source.write_text('#' * 180 + '\n', encoding='utf-8')
            data = root / 'docs/reference/parity-ledger.json'
            data.parent.mkdir(parents=True)
            data.write_text('"' + 'x' * 200 + '"\n', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True, env=environment, timeout=30)
            command = [sys.executable, str(CHECKER), '--root', str(root)]
            result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            source.write_text('#' * 181 + '\n', encoding='utf-8')
            result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('sample.py:1: 181 columns exceeds 180', result.stdout)

    # Value: protects=new source files checked before commit; fails_when=scan omits untracked files; why_new=tracked-only scans miss additions; seam=none
    def test_untracked_source_and_extensionless_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = fixture_environment()
            subprocess.run(['git', 'init', '-q', str(root)], check=True, env=environment, timeout=30)
            hook = root / '.githooks/pre-push'
            hook.parent.mkdir()
            hook.write_text('#!/bin/sh\n#' + 'x' * 180 + '\n', encoding='utf-8')
            result = subprocess.run([sys.executable, str(CHECKER), '--root', str(root)], capture_output=True, text=True, env=environment, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('.githooks/pre-push:2: 181 columns exceeds 180', result.stdout)


if __name__ == '__main__':
    unittest.main()
