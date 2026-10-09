"""Integration self-tests: the REAL repository state must satisfy every rule.

These fail (red) until .llm/ content, the generated index, and the agent
stubs are authored/generated. They keep the repo honest forever after.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import check_llm_file_lengths as checker
from llm import generate_llm_index as indexer
from llm import generate_skill_stubs as stubs
from llm import lint_llm_instructions as lint
from llm import llm_frontmatter
from llm import llm_paths


class RepoStateTest(unittest.TestCase):
    def setUp(self):
        self.root = llm_paths.REPO_ROOT

    def test_context_exists_within_limit_with_single_h1(self):
        ctx = llm_paths.CONTEXT_PATH
        self.assertTrue(ctx.is_file(), ".llm/context.md must exist")
        text = ctx.read_text(encoding="utf-8")
        self.assertEqual(
            len([ln for ln in text.splitlines() if ln.startswith("# ")]),
            1,
            "context.md must have exactly one H1",
        )
        self.assertLessEqual(
            len(text.splitlines()), llm_paths.MAX_LINES, "context.md over 300 lines"
        )
        self.assertIn("./skills/index.md", text, "context.md must link the index")

    def test_every_skill_dir_is_a_valid_agentskills_skill(self):
        skill_dirs = [
            p for p in llm_paths.SKILLS_DIR.iterdir() if p.is_dir()
        ]
        self.assertGreater(len(skill_dirs), 0, "expected at least one skill")
        for skill_dir in skill_dirs:
            with self.subTest(skill=skill_dir.name):
                self.assertEqual(
                    llm_frontmatter.validate_skill_dir(skill_dir),
                    [],
                    f"invalid skill: {skill_dir.name}",
                )

    def test_index_is_fresh(self):
        self.assertEqual(indexer.main([str(self.root), "--check"]), 0)

    def test_stubs_are_fresh_with_no_orphans(self):
        self.assertEqual(stubs.main([str(self.root), "--check"]), 0)

    def test_meta_lint_clean(self):
        errors = [f for f in lint.run_all(self.root) if f.level == "error"]
        self.assertEqual(errors, [])

    def test_length_linter_clean_over_whole_repo(self):
        self.assertEqual(checker.main([str(self.root)]), 0)

    def test_index_covers_exactly_the_skill_set(self):
        text = (llm_paths.INDEX_PATH).read_text(encoding="utf-8")
        skill_dirs = sorted(p.name for p in llm_paths.SKILLS_DIR.iterdir() if p.is_dir())
        for name in skill_dirs:
            self.assertIn(
                f"](./{name}/SKILL.md)", text, f"index missing row for {name}"
            )
        self.assertEqual(text.count("| [`"), len(skill_dirs), "index has extra rows")


if __name__ == "__main__":
    unittest.main()
