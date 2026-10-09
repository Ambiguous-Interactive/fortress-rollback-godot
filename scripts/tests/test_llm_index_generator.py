"""Self-tests for the deterministic skills-index generator."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import generate_llm_index as indexer


def write_skill(root: Path, name: str, description: str, category: str) -> None:
    skill_dir = root / ".llm" / "skills" / name
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        "---\n"
        f"name: {name}\n"
        f'description: "{description}"\n'
        "metadata:\n"
        f"  category: {category}\n"
        "---\n\n"
        f"# {name}\n\nBody.\n",
        encoding="utf-8",
    )


class RenderIndexTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _skills(self):
        write_skill(self.root, "beta-core", "Beta core.", "core")
        write_skill(self.root, "alpha-core", "Alpha core.", "core")
        write_skill(self.root, "zulu-feature", "Zulu feature.", "feature")
        write_skill(self.root, "mid-performance", "Perf.", "performance")
        metas, errors = indexer.collect_skills(self.root)
        self.assertEqual(errors, [])
        return metas

    def test_sections_ordered_core_performance_feature(self):
        text = indexer.render_index(self._skills())
        i_core = text.index("## Core Skills")
        i_perf = text.index("## Performance Skills")
        i_feat = text.index("## Feature Skills")
        self.assertLess(i_core, i_perf)
        self.assertLess(i_perf, i_feat)

    def test_rows_sorted_by_name_within_section(self):
        text = indexer.render_index(self._skills())
        self.assertLess(text.index("alpha-core"), text.index("beta-core"))

    def test_deterministic_output(self):
        metas = self._skills()
        self.assertEqual(indexer.render_index(metas), indexer.render_index(metas))

    def test_output_is_lf_only_ascii_banner(self):
        text = indexer.render_index(self._skills())
        self.assertNotIn("\r", text)
        self.assertTrue(text.startswith("<!-- DO NOT EDIT"))

    def test_invalid_skill_surfaces_error(self):
        bad = self.root / ".llm" / "skills" / "bad-skill"
        bad.mkdir(parents=True)
        (bad / "SKILL.md").write_text("no frontmatter here\n", encoding="utf-8")
        _, errors = indexer.collect_skills(self.root)
        self.assertTrue(errors)


class CheckModeTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_write_then_check_is_green(self):
        write_skill(self.root, "some-skill", "Some skill.", "core")
        self.assertEqual(indexer.main([str(self.root), "--write"]), 0)
        self.assertEqual(indexer.main([str(self.root), "--check"]), 0)

    def test_stale_index_detected(self):
        write_skill(self.root, "some-skill", "Some skill.", "core")
        indexer.main([str(self.root), "--write"])
        stale = (self.root / ".llm" / "skills" / "index.md")
        stale.write_text(stale.read_text(encoding="utf-8").replace("Some", "Other"), encoding="utf-8")
        self.assertEqual(indexer.main([str(self.root), "--check"]), 1)


if __name__ == "__main__":
    unittest.main()
