"""Real launcher controls for the bytes a native receipt qualifies."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_source_snapshot as SNAPSHOT

ROOT = Path(__file__).resolve().parents[2]


class SourceImageControls(unittest.TestCase):
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
    # Value: protects=executed source identity; fails_when=end-only Git metadata qualifies changed bytes; why_new=runner controls only validate outcomes; seam=fake engine process
    def test_executed_source_identity(self) -> None:
        for mode in ("stable_dirty", "edit", "commit", "replace_snapshot", "transient_edit"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
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
                for command in (["git", "init", "-q"], ["git", "add", "."],
                                ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"]):
                    subprocess.run(command, cwd=root, check=True, capture_output=True)
                suite.write_text("stable dirty source\n")
                initial_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
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
                    + (" original.write_text('changed source\\n')\n" if mode in ("edit", "commit") else "")
                    + (f" subprocess.run(['git','add','.'],cwd={str(root)!r},check=True)\n"
                       f" subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','intervening'],cwd={str(root)!r},check=True)\n"
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
                                         cwd=root, capture_output=True, text=True, timeout=30)
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


if __name__ == "__main__":
    unittest.main()
