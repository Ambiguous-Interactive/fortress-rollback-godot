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


def collapsed(text: str) -> str:
    """Normalize Markdown wrapping so phrase checks are layout-independent."""
    return " ".join(text.split())


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

    def test_plan_is_present_and_within_its_own_limit(self):
        self.assertTrue(llm_paths.PLAN_PATH.is_file(), "PLAN.md must exist")
        self.assertEqual(checker.check_plan(), [])

    def test_index_covers_exactly_the_skill_set(self):
        text = (llm_paths.INDEX_PATH).read_text(encoding="utf-8")
        skill_dirs = sorted(p.name for p in llm_paths.SKILLS_DIR.iterdir() if p.is_dir())
        for name in skill_dirs:
            self.assertIn(
                f"](./{name}/SKILL.md)", text, f"index missing row for {name}"
            )
        self.assertEqual(text.count("| [`"), len(skill_dirs), "index has extra rows")

    def test_goal_is_present_within_budget_and_single_h1(self):
        goal = llm_paths.GOAL_PATH
        self.assertTrue(goal.is_file(), "GOAL.md must exist")
        data = goal.read_bytes()
        self.assertFalse(
            data.startswith(b"\xef\xbb\xbf"), "GOAL.md must not have a BOM"
        )
        self.assertNotIn(b"\r\n", data, "GOAL.md must use LF")
        text = data.decode("utf-8")
        self.assertEqual(
            len([ln for ln in text.splitlines() if ln.startswith("# ")]),
            1,
            "GOAL.md must have exactly one H1",
        )
        self.assertLessEqual(
            len(text.splitlines()),
            llm_paths.GOAL_MAX_LINES,
            "GOAL.md must stay a concise session contract",
        )
        for heading in (
            "## Objective",
            "## Work Style",
            "## Fix Philosophy",
            "## Quality Bar",
            "## Review",
            "## Progress Tracking",
            "## Sub-agent Loop",
        ):
            with self.subTest(heading=heading):
                self.assertIn(heading, text)

    def test_goal_keeps_the_upstream_contract(self):
        text = collapsed(llm_paths.GOAL_PATH.read_text(encoding="utf-8"))
        for phrase in (
            "Complete all objectives",
            "fully green state",
            "all required CI checks pass",
            "all reviewer feedback is addressed",
            "Task-based, red-green, data-backed, exploratory, science-driven",
            "Small, coherent commits",
            "Structurally simple",
            "code judo",
            "zero revisions",
            "progress/session-NNN",
            "adversarial sub-agent",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_goal_keeps_the_repository_delivery_contract(self):
        text = collapsed(llm_paths.GOAL_PATH.read_text(encoding="utf-8"))
        for phrase in (
            "one PR",
            "Gate",
            "merge queue",
            "feedback scan",
            "ship-session",
            "user-copy",
            "180",
            "two hours",
            "worktree",
            "fresh context",
            "one fix round",
            "evidence-backed",
            "regression test",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_goal_keeps_the_quality_bar(self):
        text = collapsed(llm_paths.GOAL_PATH.read_text(encoding="utf-8"))
        for phrase in (
            "Robust and reliable",
            "Complete",
            "Non-bloating",
            "data-driven",
            "diagnostics",
            "sweep",
            "Simplify aggressively",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_code_review_keeps_the_structural_pass(self):
        text = collapsed(
            (llm_paths.SKILLS_DIR / "code-review" / "SKILL.md").read_text(
                encoding="utf-8"
            )
        )
        for phrase in (
            "## Structural Pass",
            "Reduce, do not relocate",
            "No spaghetti growth",
            "Abstractions must earn their keep",
            "Respect the boundary",
            "Keep type contracts honest",
            "Watch total size",
            "Keep orchestration atomic",
            "Presumptive blockers",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_testing_keeps_characterization_before_refactor(self):
        text = collapsed(
            (llm_paths.SKILLS_DIR / "testing" / "SKILL.md").read_text(
                encoding="utf-8"
            )
        )
        for phrase in (
            "## Characterization Before Refactor",
            "records what the code does",
            "run it green before the first refactor",
            "make the change easy",
            "targeted mutation",
            "surviving mutant",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_research_note_cites_the_sources(self):
        path = llm_paths.RESEARCH_DIR / "goal-and-code-quality-2026.md"
        self.assertTrue(path.is_file(), "research note must exist")
        text = collapsed(path.read_text(encoding="utf-8"))
        for phrase in (
            "https://github.com/wallstop/llm-knowledge/blob/main/prompts/goal.md",
            "https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md",
            "https://github.com/ChrisLucian-HunterIndustries/Kite-Flying-Plate-Spinning",
            "https://dora.dev/capabilities/working-in-small-batches/",
            "https://stryker-mutator.io/docs/",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)


if __name__ == "__main__":
    unittest.main()
