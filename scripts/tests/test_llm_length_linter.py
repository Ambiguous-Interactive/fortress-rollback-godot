"""Self-tests for the 300-line hard-limit checker (red-green discipline)."""

import os
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import check_llm_file_lengths as checker
from llm import llm_paths
from git_test_environment import fixture_environment


def write_lines(path: Path, n: int) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"line {i}\n" for i in range(n)), encoding="utf-8")
    return path


class CheckFileTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_under_limit_is_clean(self):
        path = write_lines(self.root / "a.md", llm_paths.MAX_LINES - 1)
        self.assertEqual(checker.check_file(path), [])

    def test_at_limit_is_critical_not_error(self):
        path = write_lines(self.root / "a.md", llm_paths.MAX_LINES)
        findings = checker.check_file(path)
        self.assertEqual([f.level for f in findings], ["critical"])

    def test_over_limit_is_error(self):
        path = write_lines(self.root / "a.md", llm_paths.MAX_LINES + 1)
        findings = checker.check_file(path)
        self.assertEqual([f.level for f in findings], ["error"])

    def test_soft_warning_only_when_verbose(self):
        path = write_lines(self.root / "a.md", llm_paths.SOFT_WARN_LINES + 1)
        self.assertEqual(checker.check_file(path, verbose=False), [])
        findings = checker.check_file(path, verbose=True)
        self.assertEqual([f.level for f in findings], ["warning"])

    def test_missing_file_is_error(self):
        findings = checker.check_paths([self.root / "ghost.md"])
        self.assertEqual([f.level for f in findings], ["error"])

    def test_exit_codes(self):
        ok = write_lines(self.root / "ok.md", 10)
        self.assertEqual(checker.main([str(ok)]), 0)

        critical = write_lines(self.root / "critical.md", llm_paths.MAX_LINES)
        self.assertEqual(checker.main([str(critical)]), 0)
        self.assertEqual(checker.main([str(critical), "--fail-on-critical"]), 1)

        bad = write_lines(self.root / "bad.md", llm_paths.MAX_LINES + 5)
        self.assertEqual(checker.main([str(bad)]), 1)

    def test_crlf_file_is_counted_without_crashing(self):
        path = self.root / "crlf.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"line\r\n" * 5)
        self.assertEqual(checker.check_file(path), [])

    def test_generated_index_is_excluded_from_scope(self):
        index = self.root / ".llm" / "skills" / "index.md"
        write_lines(index, llm_paths.MAX_LINES + 50)
        skills_dir = self.root / ".llm" / "skills" / "some-skill"
        write_lines(skills_dir / "SKILL.md", 10)
        scope = checker.check_scope(root=self.root)
        # The oversized generated index must not appear; the SKILL.md is clean.
        self.assertFalse(any(f.path == index for f in scope))
        self.assertEqual(scope, [])


class StagedModeTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        environment = patch.dict(os.environ, fixture_environment(), clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.good = write_lines(self.root / ".llm" / "good.md", 5)
        self.bad = write_lines(self.root / ".llm" / "bad.md", llm_paths.MAX_LINES + 1)

    def tearDown(self):
        self._tmp.cleanup()

    def _git(self, *cmd):
        import subprocess

        subprocess.run(["git", "-C", str(self.root), *cmd], check=True, capture_output=True)

    def test_git_staged_files_on_unborn_head(self):
        # First-commit scenario: files staged, no commit exists yet.
        self._git("init")
        self._git("add", ".llm/good.md")
        staged = checker.git_staged_files(self.root)
        self.assertEqual([p.as_posix() for p in staged], [".llm/good.md"])

    def test_git_staged_files_after_first_commit(self):
        import subprocess

        self._git("init")
        self._git("add", ".llm/good.md")
        self._git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init")
        self._git("add", ".llm/bad.md")
        staged = checker.git_staged_files(self.root)
        self.assertEqual([p.as_posix() for p in staged], [".llm/bad.md"])

    def test_staged_mode_only_checks_staged_files(self):
        original = checker.git_staged_files

        def fake_staged(root):
            return [Path(".llm/good.md")]

        checker.git_staged_files = fake_staged
        try:
            findings = checker.main([str(self.root), "--staged"])
        finally:
            checker.git_staged_files = original
        self.assertEqual(findings, 0)

        def fake_staged_bad(root):
            return [Path(".llm/bad.md")]

        checker.git_staged_files = fake_staged_bad
        try:
            findings = checker.main([str(self.root), "--staged"])
        finally:
            checker.git_staged_files = original
        self.assertEqual(findings, 1)


if __name__ == "__main__":
    unittest.main()
