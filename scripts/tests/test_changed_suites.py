"""Changed-suite selection follows res:// references and class names, and runs everything when unsure."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changed_suites import select  # noqa: E402

FILES = {
    "addons/a.gd": "class_name Alpha\n",
    "addons/b.gd": 'const A = preload("res://addons/a.gd")\n',
    "addons/c.gd": "var unused: int = 0\n",
    "examples/scene.tscn": '[ext_resource type="Script" path="res://addons/b.gd" id="1"]\n',
    "tests/fixtures/data.json": "{}\n",
    "tests/unit/test_class.gd": "var alpha: Alpha\n",
    "tests/unit/test_scene.gd": 'var scene = load("res://examples/scene.tscn")\n',
    "tests/unit/test_fixture.gd": 'const PATH = "res://tests/fixtures/data.json"\n',
}
SUITES = ["res://tests/unit/test_class.gd", "res://tests/unit/test_fixture.gd", "res://tests/unit/test_scene.gd"]


class SelectTests(unittest.TestCase):
    def test_selection(self) -> None:
        rows = [
            (["addons/a.gd"], SUITES[::2]),            # class name directly, preload then scene transitively
            (["addons/b.gd"], SUITES[2:]),
            (["tests/fixtures/data.json"], SUITES[1:2]),
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


if __name__ == "__main__":
    unittest.main()
