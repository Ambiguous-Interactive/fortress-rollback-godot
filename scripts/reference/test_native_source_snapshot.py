"""Real launcher controls for the bytes a native receipt qualifies."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_source_snapshot as SNAPSHOT
from git_test_environment import fixture_environment

ROOT = Path(__file__).resolve().parents[2]


class SourceImageControls(unittest.TestCase):
    # Value: protects=source roots below system symlinks; fails_when=ancestor aliases are rejected; why_new=existing tests cover in-tree links only; seam=none
    def test_source_root_below_external_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "real/nested/repo"
            root.mkdir(parents=True)
            (root / "source").write_bytes(b"source")
            (base / "alias").symlink_to(base / "real", target_is_directory=True)
            alias = base / "alias/nested/repo"
            self.assertEqual(SNAPSHOT.inventory(alias, ["source"]), SNAPSHOT.inventory(root, ["source"]))
            (root / "link").symlink_to(root / "source")
            for selected in (root, alias):
                with self.assertRaisesRegex(ValueError, "source_symlink"):
                    SNAPSHOT.inventory(selected, ["link"])

    # Value: protects=pre-engine Git deadline; fails_when=metadata ignores its watchdog; why_new=engine timeouts do not cover source capture; seam=scripted Git process
    def test_git_query_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "git"
            executable.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(0.5)\nprint('late')\n")
            executable.chmod(0o755)
            with (patch.dict(os.environ, {"PATH": str(root)}),
                  patch.object(SNAPSHOT, "GIT_TIMEOUT", 0.05, create=True),
                  self.assertRaises(subprocess.TimeoutExpired)):
                SNAPSHOT.git(root, "rev-parse", "HEAD")

    # Value: protects=bounded source capture; fails_when=symlinks escape or copying is unbounded; why_new=launcher outcomes cannot prove capture policy; seam=none
    def test_bounded_regular_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source").write_bytes(b"abcd")
            self.assertEqual(SNAPSHOT.inventory(root, ["source"])["source"]["bytes"], 4)
            with patch.object(SNAPSHOT, "MAX_BYTES", 3), self.assertRaisesRegex(ValueError, "source_byte_limit"):
                SNAPSHOT.inventory(root, ["source"])
            with patch.object(SNAPSHOT, "MAX_FILES", 0), self.assertRaisesRegex(ValueError, "source_file_limit"):
                SNAPSHOT.inventory(root, ["source"])
            (root / "link").symlink_to(root / "source")
            with self.assertRaisesRegex(ValueError, "source_symlink"):
                SNAPSHOT.inventory(root, ["link"])
            with self.assertRaisesRegex(ValueError, "unsafe_source_path"):
                SNAPSHOT.inventory(root, ["../source"])


class SourceReceiptControls(unittest.TestCase):
    # Value: protects=caller's staged index; fails_when=fixture Git inherits an external index; why_new=earlier controls used a clean Git environment; seam=owned caller repo
    def test_fixture_preserves_callers_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            caller = Path(directory)
            environment = fixture_environment()
            subprocess.run(["git", "init", "-q"], cwd=caller, env=environment, check=True, capture_output=True, timeout=30)
            (caller / "sentinel").write_text("caller staged content\n")
            subprocess.run(["git", "add", "sentinel"], cwd=caller, env=environment, check=True, capture_output=True, timeout=30)
            index = caller / ".git/index"
            original = index.read_bytes()
            with patch.dict(os.environ, {"GIT_INDEX_FILE": str(index)}):
                self.test_executed_source_identity()
            self.assertEqual(index.read_bytes(), original, "temporary fixture changed caller's staged index")
            self.assertEqual(subprocess.check_output(["git", "diff", "--cached", "--name-only"], cwd=caller,
                                                    env=environment, text=True, timeout=30), "sentinel\n")

    # Value: protects=executed source identity; fails_when=end-only Git metadata qualifies changed bytes; why_new=runner controls only validate outcomes; seam=fake engine process
    def test_executed_source_identity(self) -> None:
        for mode in ("stable_dirty", "edit", "commit", "replace_snapshot", "transient_edit"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                environment = fixture_environment()
                for source in ("scripts/run_godot_tests.py", "scripts/host_capacity.py", "scripts/changed_suites.py",
                               "scripts/reference/engine_path.py", "scripts/native_source_snapshot.py"):
                    target = root / source
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if (ROOT / source).exists():
                        shutil.copyfile(ROOT / source, target)
                suite = root / "tests/unit/test_sample.gd"
                suite.parent.mkdir(parents=True)
                suite.write_text("original source\n")
                (root / "project.godot").write_text("config_version=5\n")
                (root / ".gitignore").write_text(".cache/\n")
                for command in (["git", "init", "-q"], ["git", "add", "."],
                                ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"]):
                    subprocess.run(command, cwd=root, env=environment, check=True, capture_output=True, timeout=30)
                suite.write_text("stable dirty source\n")
                initial_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, env=environment, text=True, timeout=30).strip()
                engine = root / ".cache/engine"
                engine.parent.mkdir()
                marker = root / ".cache/mutated"
                engine.write_text(
                    "#!" + sys.executable + "\nimport json,pathlib,subprocess,sys\n"
                    "if '--version' in sys.argv:\n print('test-engine');sys.exit(0)\n"
                    "project=pathlib.Path(sys.argv[sys.argv.index('--path')+1])\n"
                    "sample=project/'tests/unit/test_sample.gd'\n"
                    "assert sample.read_text() == 'stable dirty source\\n', 'executed moving source'\n"
                    f"original=pathlib.Path({str(suite)!r});marker=pathlib.Path({str(marker)!r})\n"
                    "if not marker.exists():\n marker.write_text('mutated')\n"
                    + (" original.write_text('changed source\\n')\n" if mode == "edit" else "")
                    + (f" subprocess.run(['git','add','.'],cwd={str(root)!r},check=True,timeout=10)\n"
                       " subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.invalid',"
                       f"'commit','-qm','intervening'],cwd={str(root)!r},check=True,timeout=10)\n"
                       if mode == "commit" else "")
                    + (" sample.write_text('replaced snapshot\\n')\n" if mode == "replace_snapshot" else "")
                    + (" original.write_text('transient source\\n');original.write_text('stable dirty source\\n')\n"
                       if mode == "transient_edit" else "")
                    + "run={'assertions':1,'failures':[],'states':[{'frame':0,'bytes':'01'}]}\n"
                    "record={'suite':'res://tests/unit/test_sample.gd','case':'pass','category':'unit','seed':'1701','runs':[run,run]}\n"
                    "print('FORTRESS_TEST_RESULT '+json.dumps({'format':1,'complete':True,'passed':True,'count':1,'errors':[],'records':[record]}))\n"
                )
                engine.chmod(0o755)
                receipt = root / ".cache/receipt.json"
                receipt.write_text('{"passed":true}')
                process = subprocess.run([sys.executable, str(root / "scripts/run_godot_tests.py"), "--godot", str(engine),
                                          "--suite", "res://tests/unit/test_sample.gd", "--jobs", "1", "--results", str(receipt)],
                                         cwd=root, env=environment, capture_output=True, text=True, timeout=30)
                report = json.loads(receipt.read_text())
                expected = mode in ("stable_dirty", "transient_edit")
                self.assertEqual(process.returncode, 0 if expected else 1, process.stderr)
                self.assertIs(report["passed"], expected, report)
                identity = report["source_snapshot"]
                self.assertEqual(report["commit"], initial_commit)
                self.assertIs(report["working_tree_dirty"], True)
                self.assertIn("tests/unit/test_sample.gd", identity["files"])
                self.assertEqual(len(identity["sha256"]), 64)
                self.assertFalse(Path(identity["path"]).exists(), "snapshot must be cleaned after qualification")
                if not expected:
                    self.assertEqual(report["failure"], "source_changed" if mode != "replace_snapshot" else "snapshot_changed")
                if mode == "commit":
                    self.assertEqual(suite.read_text(), "stable dirty source\n")
                    self.assertEqual(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, env=environment, text=True, timeout=30), "")
                    actual_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, env=environment, text=True, timeout=30).strip()
                    self.assertNotEqual(actual_commit, initial_commit)


if __name__ == "__main__":
    unittest.main()
