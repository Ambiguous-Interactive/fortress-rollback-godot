"""Self-test: machine-local directories must stay out of git forever.

`progress/` holds per-session working notes. It is deliberately machine-local:
the value is in the live history on one machine, not in a shared tree, and the
files churn on every session. Committing them would bloat history and make the
tracked surface misleading.

This test fails if anyone re-adds the directory, whether by deleting the
ignore rule or by force-adding past it (`git add -f`).
"""

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import llm_paths

# Share the link linter's local-only directory inventory; Git itself validates
# the effective ignore behavior below.
MACHINE_LOCAL = llm_paths.LOCAL_ONLY_DIRS


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=llm_paths.REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


class MachineLocalContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (llm_paths.REPO_ROOT / ".git").exists():
            raise unittest.SkipTest("not a git checkout; nothing is tracked here")
        cls.tracked = git("ls-files", "-z").split("\0")

    def test_no_machine_local_path_is_tracked(self):
        tracked = [
            path
            for path in self.tracked
            if any(path == d or path.startswith(f"{d}/") for d in MACHINE_LOCAL)
        ]
        self.assertEqual(
            tracked,
            [],
            f"machine-local paths are tracked; untrack them: {tracked}",
        )

    def test_git_reports_machine_local_paths_as_ignored(self):
        """Belt-and-braces: confirm git itself agrees, not just the rule text."""
        for name in MACHINE_LOCAL:
            with self.subTest(dir=name):
                probe = f"{name}/.gitignore-contract-probe.md"
                result = subprocess.run(
                    ["git", "check-ignore", "-q", probe],
                    cwd=llm_paths.REPO_ROOT,
                    capture_output=True,
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    f"git does not ignore {probe}",
                )


if __name__ == "__main__":
    unittest.main()
