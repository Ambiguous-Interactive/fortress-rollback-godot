"""Self-tests for the mandatory retrospective loop (red-green harness change).

Red until these exist and cross-link:
  - `.llm/skills/retrospective/SKILL.md`  (the mandatory post-work loop)
  - `.llm/templates/RETROSPECTIVE.template.md` (retro artifact skeleton)
  - `.llm/knowledge/` (distilled operational facts, with a contract)
  - `.llm/retrospectives/` (episodic retro artifacts; at least one recorded)
  - `.llm/research/agent-self-improvement-2026.md` (evidence base)
  - `context.md` hooks making the loop mandatory at the rules level.

They keep the loop honest forever after.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import llm_frontmatter
from llm import llm_paths

ROOT = llm_paths.REPO_ROOT
SKILL = ROOT / ".llm" / "skills" / "retrospective" / "SKILL.md"
TEMPLATE = ROOT / ".llm" / "templates" / "RETROSPECTIVE.template.md"
KNOWLEDGE_README = ROOT / ".llm" / "knowledge" / "README.md"
RETROS_DIR = ROOT / ".llm" / "retrospectives"
RESEARCH_NOTE = ROOT / ".llm" / "research" / "agent-self-improvement-2026.md"


class RetrospectiveLoopTest(unittest.TestCase):
    def setUp(self):
        self.skill_text = (
            SKILL.read_text(encoding="utf-8") if SKILL.is_file() else ""
        )

    def test_skill_exists_is_valid_and_core(self):
        self.assertTrue(SKILL.is_file(), "retrospective skill is missing")
        problems = llm_frontmatter.validate_skill_dir(SKILL.parent)
        self.assertEqual(problems, [], "retrospective skill is invalid")
        self.assertIn(
            "category: core",
            self.skill_text,
            "the retro loop is a core skill",
        )

    def test_skill_defines_triggers_gates_and_lifecycle(self):
        for needle in (
            "Mandatory",  # explicit trigger section
            "Waiver",  # explicit skip path (fails closed, never silent)
            "Curation",  # evidence gate before any write
            "Retire",  # lifecycle: prune/merge/fix, not only append
            "make lint-llm",  # verification step
            "make test-llm",  # verification step
        ):
            self.assertIn(needle, self.skill_text, f"skill must define: {needle}")

    def test_skill_routes_knowledge_to_canonical_stores(self):
        for needle in (
            "../knowledge/",
            "../research/",
            "../retrospectives/",
            "../templates/RETROSPECTIVE.template.md",
        ):
            self.assertIn(
                needle, self.skill_text, f"skill must route to {needle}"
            )

    def test_template_exists_and_points_at_stores(self):
        self.assertTrue(TEMPLATE.is_file(), "retrospective template is missing")
        text = TEMPLATE.read_text(encoding="utf-8")
        for needle in ("../knowledge/", "../retrospectives/"):
            self.assertIn(needle, text, f"template must reference {needle}")

    def test_knowledge_store_exists_with_contract(self):
        self.assertTrue(KNOWLEDGE_README.is_file(), "knowledge/README.md missing")
        text = KNOWLEDGE_README.read_text(encoding="utf-8")
        for needle in ("Evidence", "Retire", "../retrospectives/"):
            self.assertIn(needle, text, f"knowledge contract must state: {needle}")

    def test_evidence_note_exists_and_cited_by_skill(self):
        self.assertTrue(RESEARCH_NOTE.is_file(), "research note is missing")
        self.assertIn(
            "../research/agent-self-improvement-2026.md",
            self.skill_text,
            "skill must cite its evidence base",
        )

    def test_at_least_one_retrospective_recorded(self):
        self.assertTrue(
            RETROS_DIR.is_dir() and any(RETROS_DIR.glob("*.md")),
            "at least one retrospective artifact must be recorded",
        )

    def test_context_md_makes_the_loop_mandatory(self):
        text = llm_paths.CONTEXT_PATH.read_text(encoding="utf-8")
        for needle in (
            "./skills/retrospective/SKILL.md",
            "./knowledge/README.md",
            "./retrospectives/",
        ):
            self.assertIn(needle, text, f"context.md must link {needle}")


if __name__ == "__main__":
    unittest.main()
