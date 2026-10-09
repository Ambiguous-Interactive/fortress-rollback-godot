"""Self-tests for the meta-linter: pointers, context, encodings, link integrity."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import lint_llm_instructions as lint
from llm import llm_paths


def make_min_repo(root: Path) -> None:
    """Create the smallest repo state that must pass the meta-lint."""
    skill_dir = root / ".llm" / "skills" / "demo-skill"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(
        "---\n"
        "name: demo-skill\n"
        'description: "Demo skill. Use when demoing."\n'
        "metadata:\n"
        "  category: core\n"
        "---\n\n"
        "# Demo Skill\n\nSee [context](../../context.md).\n",
        encoding="utf-8",
    )
    (root / ".llm" / "context.md").write_text(
        "# LLM Agent Instructions\n\n"
        "See the [skills index](./skills/index.md).\n",
        encoding="utf-8",
    )
    # Generated index exists in any real repo; a placeholder keeps the
    # context.md -> index.md link resolvable in the minimal fixture.
    (root / ".llm" / "skills" / "index.md").write_text(
        "<!-- generated placeholder -->\n", encoding="utf-8"
    )
    for rel, link in llm_paths.POINTER_FILES.items():
        pointer = root / rel
        pointer.parent.mkdir(parents=True, exist_ok=True)
        pointer.write_text(f"# Pointer\n\nSee [context]({link}).\n", encoding="utf-8")


class MetaLintTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        make_min_repo(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def errors(self):
        return [f for f in lint.run_all(self.root) if f.level == "error"]

    def test_min_repo_is_clean(self):
        self.assertEqual(self.errors(), [])

    def test_missing_pointer_file_is_error(self):
        (self.root / "CLAUDE.md").unlink()
        self.assertTrue(any("CLAUDE.md" in f.message for f in self.errors()))

    def test_pointer_without_delegation_link_is_error(self):
        (self.root / "AGENTS.md").write_text("# No link here\n", encoding="utf-8")
        self.assertTrue(any("AGENTS.md" in f.message for f in self.errors()))

    def test_bloated_pointer_is_error(self):
        path = self.root / "CLAUDE.md"
        path.write_text(
            "# Pointer\n\n" + "\n".join(f"filler {i}" for i in range(80)) + "\n",
            encoding="utf-8",
        )
        self.assertTrue(self.errors())

    def test_context_with_two_h1s_is_error(self):
        ctx = self.root / ".llm" / "context.md"
        ctx.write_text(
            "# One\n\n# Two\n\n[skills index](./skills/index.md)\n", encoding="utf-8"
        )
        self.assertTrue(any("H1" in f.message for f in self.errors()))

    def test_context_missing_index_link_is_error(self):
        ctx = self.root / ".llm" / "context.md"
        ctx.write_text("# Only\n\nNo links.\n", encoding="utf-8")
        self.assertTrue(any("index" in f.message.lower() for f in self.errors()))

    def test_crlf_is_error(self):
        ctx = self.root / ".llm" / "context.md"
        ctx.write_bytes(ctx.read_bytes().replace(b"\n", b"\r\n"))
        self.assertTrue(any("CRLF" in f.message for f in self.errors()))

    def test_bom_is_error(self):
        ctx = self.root / ".llm" / "context.md"
        ctx.write_bytes(b"\xef\xbb\xbf" + ctx.read_bytes())
        self.assertTrue(any("BOM" in f.message for f in self.errors()))

    def test_broken_relative_link_is_error(self):
        skill = self.root / ".llm" / "skills" / "demo-skill" / "SKILL.md"
        skill.write_text(
            "---\nname: demo-skill\ndescription: d\nmetadata:\n  category: core\n---\n\n"
            "[missing](../nope/missing.md)\n",
            encoding="utf-8",
        )
        self.assertTrue(any("missing.md" in f.message for f in self.errors()))

    def test_skill_with_invalid_frontmatter_is_error(self):
        skill = self.root / ".llm" / "skills" / "demo-skill" / "SKILL.md"
        skill.write_text(
            "---\nname: other-name\ndescription: d\n---\n\n# Wrong name\n",
            encoding="utf-8",
        )
        self.assertTrue(any("demo-skill" in f.message for f in self.errors()))


if __name__ == "__main__":
    unittest.main()
