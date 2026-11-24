"""Changed-suite selection follows res:// references and class names, and runs everything when unsure."""
from pathlib import Path
import sys
import subprocess
import tempfile
from unittest import mock
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changed_suites import ROOT, changed_files, from_base, previous_class_names, select, selection  # noqa: E402

from git_test_environment import fixture_environment  # noqa: E402
from run_godot_tests import discover  # noqa: E402

FILES = {
    "addons/a.gd": "@tool\nclass_name Alpha\n",
    "addons/b.gd": 'const A = preload("res://addons/a.gd")\n',
    "addons/c.gd": "var unused: int = 0\n",
    "examples/scene.tscn": '[ext_resource type="Script" path="res://addons/b.gd" id="1"]\n',
    "tests/fixtures/data.json": "{}\n",
    "tests/unit/test_class.gd": "var alpha: Alpha\n",
    "tests/unit/test_substring.gd": "var alpha: AlphaExtended\nvar other: PrefixAlpha\nvar snake: Alpha_value\n",
    "tests/unit/test_scene.gd": 'var scene = load("res://examples/scene.tscn")\n',
    "tests/unit/test_fixture.gd": 'const PATH = "res://tests/fixtures/data.json"\n',
    "tests/unit/test_listing.gd": 'const DIRECTORY = "res://tests/listed/"\n',
    "tests/listed/one.json": "{}\n",
}
SUITES = ["res://tests/unit/test_class.gd", "res://tests/unit/test_fixture.gd", "res://tests/unit/test_listing.gd",
          "res://tests/unit/test_scene.gd"]


class SelectTests(unittest.TestCase):
    def test_selection(self) -> None:
        rows = [
            (["addons/a.gd"], [SUITES[0], SUITES[3]]),  # annotated class name directly, preload then scene transitively
            (["addons/b.gd"], SUITES[3:]),
            (["addons/b.gd.uid"], SUITES[3:]),          # a sidecar stands for its resource
            (["addons/old.gd", "addons/b.gd"], SUITES[3:]),
            (["tests/fixtures/data.json"], SUITES[1:2]),
            (["tests/listed/one.json"], SUITES[2:3]),   # directory reference
            (["tests/listed/new.json"], SUITES[2:3]),   # new file under a referenced directory
            (["tests/unit/test_class.gd"], SUITES[:1]),
            (["addons/c.gd", "docs/guide.md"], []),
            (["scripts/run_godot_tests.py"], SUITES),  # untraceable change runs everything
            (["tests/runner/run_tests.gd"], SUITES),
            (["project.godot", "addons/c.gd"], SUITES),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in FILES.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            for changed, expected in rows:
                with self.subTest(changed=changed):
                    self.assertEqual(select(SUITES, changed, root), expected)
            substring = "res://tests/unit/test_substring.gd"
            self.assertEqual(select([substring], ["addons/a.gd"], root), [])
            # A renamed or removed class name still reaches files that use the old name.
            (root / "addons/a.gd").write_text("class_name Renamed\n")
            self.assertEqual(select(SUITES, ["addons/a.gd"], root), SUITES[3:])
            self.assertEqual(select(SUITES, ["addons/a.gd"], root, {"Alpha"}), [SUITES[0], SUITES[3]])
            self.assertEqual(select([substring], ["addons/a.gd"], root, {"Alpha"}), [])
            (root / "tests/unit/test_substring.gd").write_text("# Alpha.member and (Alpha) both name a complete class\n")
            self.assertEqual(select([substring], ["addons/a.gd"], root, {"Alpha"}), [substring])


    # Value: protects=online lobby dependency selection; fails_when=optional transport hides the paths; why_new=synthetic fixtures miss checkout drift; seam=none
    def test_lobby_keeps_only_its_reachable_suites(self):
        suites = discover("unit", ROOT)
        unrelated = selection(suites, ["PLAN.md"], ROOT)
        self.assertEqual((unrelated["reason"], unrelated["suites"]), ("documentation_only", []), unrelated.get("path"))
        for resource in ("addons/signal_fish/transport/sf_websocket_transport.gd",
                         "addons/fortress_rollback/transport/signalfish_webrtc_connection.gd"):
            with self.subTest(resource=resource):
                affected = selection(suites, [resource], ROOT)
                self.assertEqual(affected["reason"], "resource_dependency", affected.get("path"))
                self.assertIn("res://tests/unit/test_online_example.gd", affected["suites"])
                self.assertNotIn("res://tests/unit/test_input_queue.gd", affected["suites"])

    # Value: protects=Markdown data consumers; fails_when=changes are skipped or run all; why_new=no file-lifecycle cases for docs; seam=none
    def test_document_selection_keeps_consumers_on_add_delete_and_rename(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict("os.environ", fixture_environment(), clear=True):
            root = Path(directory)

            def git(*args):
                subprocess.run(["git", *args], cwd=root, capture_output=True, check=True)

            git("init")
            (root / "reader.gd").write_text('var content = FileAccess . get_file_as_string("res://100%{fixture}.md")')
            (root / "other.gd").write_text('# FileAccess.get_file_as_string("res://unused.md")\nprint("See unused.md")')
            (root / "unused.md").touch()
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "-m", "base")
            suites = ["res://reader.gd", "res://other.gd"]

            def receipt():
                return from_base("HEAD", suites, root, root, ["reader.gd", "other.gd", "100%{fixture}.md", "unused.md"])

            (root / "unused.md").write_text("unrelated")
            self.assertEqual(receipt()["suites"], [])
            (root / "100%{fixture}.md").write_text("added")
            self.assertEqual(receipt()["suites"], suites[:1])
            git("add", "100%{fixture}.md")
            git("-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "-m", "add fixture")
            (root / "100%{fixture}.md").write_text("edited")
            self.assertEqual(receipt()["suites"], suites[:1])
            (root / "100%{fixture}.md").unlink()
            self.assertEqual(receipt()["suites"], suites[:1])
            git("restore", "100%{fixture}.md")
            git("mv", "100%{fixture}.md", "renamed.md")
            self.assertEqual(receipt()["suites"], suites[:1])

    def test_external_transitive_consumers_and_fail_closed_inputs(self):
        suite = "res://tests/unit/test_only.gd"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                suite[6:]: 'const Bridge = preload("res://scripts/reference/bridge.gd")',
                "scripts/reference/bridge.gd": 'const Helper = preload("helper with space.gd")',
                "scripts/reference/helper with space.gd": 'const DATA = "res://docs/example.json"',
                "docs/example.json": "{}",
            }
            for path, value in files.items():
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(value)
            for path in files:
                self.assertEqual(selection([suite], [path], root)["suites"], [suite])
            for path in ("scripts/reference/browser/webrtc.cjs", "scripts/oracle/p2p_lifecycle.py"):
                self.assertEqual(selection([suite], [path], root)["selected_count"], 0)
                self.assertEqual(select([suite], [path, "docs/example.json"], root), [suite])
            for path in ("scripts/new_agent.py", "scripts/reference/new_settings.cfg", "addons/data.unknown", "project.godot"):
                self.assertEqual(selection([suite], [path], root)["reason"], "unknown_input")
            # Both a scene and a constant can name a file with an apostrophe inside double quotes.
            resource = r"res://addons/reader's/\u0061.gd"
            for relative, code in (("scripts/reference/bridge.gd", f'const PATH = "{resource}"\nfunc read():\n load(PATH)'),
                                   ("examples/reader.tscn", f'[ext_resource path="{resource}"]')):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text(code)
                (root / suite[6:]).write_text(f'const Resource = preload("res://{relative}")')
                self.assertEqual(selection([suite], ["addons/reader's/a.gd"], root)["reason"], "unresolved_resource")
            (root / suite[6:]).write_text(files[suite[6:]])
            for expression in ('load(dynamic_path)', 'ResourceLoader.load_threaded_request(path)',
                               'FileAccess . get_file_as_string(path)', 'FileAccess.get_sha256(path)', 'Image.load_from_file(path)',
                               'script . source_code = source',
                               'func read(path: String):\n print("""Help\n# Markdown heading""", FileAccess.get_file_as_string(path))',
                               'DirAccess.dir_exists_absolute(path)', 'config.load(path)', 'load("res://scenes/" + filename)',
                               r'load("res://addons/\u0061.gd")', r'const PATH = "res://addons/\u0061.gd"' + '\nload(PATH)',
                               'load("uid://unknown")', 'load("res://prefix" + suffix)'):
                with self.subTest(expression=expression):
                    (root / "scripts/reference/bridge.gd").write_text(expression)
                    self.assertEqual(selection([suite], ["scripts/oracle/p2p_lifecycle.py"], root)["reason"], "unresolved_resource")

    def test_opaque_resource_and_project_autoload_reach_the_full_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/global.gd").write_text('const G = preload("res://scripts/transitive.gd")')
            (root / "project.godot").write_text('[autoload]\nGlobal="*res://scripts/global.gd"')
            self.assertEqual(selection(SUITES, ["scripts/transitive.gd"], root)["suites"], SUITES)
            (root / "project.godot").unlink()
            suite = "res://observes.gd"
            (root / "observes.gd").write_text('const NODE = preload("res://scripts/opaque.scn")')
            self.assertEqual(selection([suite], ["scripts/another.gd"], root)["reason"], "unresolved_resource")
            (root / "scripts/manifest.md").touch()
            (root / "observes.gd").write_text('var resource = ResourceLoader.load("res://scripts/manifest.md")')
            self.assertEqual(selection([suite], ["scripts/another.gd"], root)["reason"], "unresolved_resource")

    def test_directory_operations_cover_new_descendants_with_either_spelling(self):
        suite = "res://test.gd"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for operation in ("DirAccess.open", "DirAccess.get_files_at", "DirAccess.get_directories_at", "dir.change_dir"):
                for slash in ("", "/"):
                    with self.subTest(operation=operation, slash=slash):
                        (root / "test.gd").write_text(f'const DIR = "res://addons/resources{slash}"\nfunc run():\n {operation}(DIR)')
                        self.assertEqual(select([suite], ["addons/resources/new/nested.gd"], root), [suite])
                        self.assertEqual(select([suite], ["addons/resources_other/nested.gd"], root), [])
            for arg in ('"res://"', 'opaque_path', '"uid://dynamic"'):
                (root / "test.gd").write_text(f"func run():\n dir.change_dir({arg})")
                self.assertEqual(selection([suite], ["addons/data.gd"], root)["reason"], "unresolved_resource")

    def test_git_changes_include_renames_untracked_paths_and_every_dirty_layer(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict("os.environ", fixture_environment(), clear=True):
            root = Path(directory)
            def git(*args):
                subprocess.run(["git", *args], cwd=root, capture_output=True, check=True)
            git("init")
            gd = root / "original.gd"
            gd.write_text("class_name OldName")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "-m", "base")
            git("mv", "original.gd", "renamed.gd")
            (root / "renamed.gd").write_text("class_name StagedName")
            git("add", "renamed.gd")
            (root / "renamed.gd").write_text("class_name LiveName")
            odd = "untracked script\nwith spaces.gd"
            (root / odd).touch()
            changed = changed_files("HEAD", root)
            self.assertEqual(changed, sorted(["original.gd", "renamed.gd", odd]))
            self.assertEqual(previous_class_names("HEAD", changed, root), {"OldName", "StagedName"})
            r = from_base("unavailable", SUITES, root, root, [])
            self.assertEqual((r["reason"], r["selected_count"]), ("unresolved_diff_or_source", len(SUITES)))


if __name__ == "__main__":
    unittest.main()
