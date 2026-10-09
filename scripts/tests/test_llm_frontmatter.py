"""Self-tests for the minimal YAML frontmatter parser + skill validator.

These are written *before* the implementation (red-green discipline).
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from llm import llm_frontmatter as fm


class ParseFrontmatterTest(unittest.TestCase):
    def test_simple_frontmatter(self):
        text = "---\nname: foo\ndescription: Does things.\n---\n\n# Body\n"
        meta, body = fm.parse_frontmatter(text)
        self.assertEqual(meta["name"], "foo")
        self.assertEqual(meta["description"], "Does things.")
        self.assertIn("# Body", body)

    def test_quoted_values_are_unquoted(self):
        text = '---\nname: foo\ndescription: "Quoted \'text\' here"\n---\nbody'
        meta, _ = fm.parse_frontmatter(text)
        self.assertEqual(meta["description"], "Quoted 'text' here")

    def test_metadata_map_is_parsed(self):
        text = (
            "---\nname: foo\ndescription: d\nmetadata:\n"
            '  category: core\n  version: "1.0"\n---\nbody'
        )
        meta, _ = fm.parse_frontmatter(text)
        self.assertEqual(meta["metadata"], {"category": "core", "version": "1.0"})

    def test_missing_frontmatter_raises(self):
        with self.assertRaises(fm.FrontmatterError):
            fm.parse_frontmatter("just some text, no frontmatter")

    def test_unterminated_frontmatter_raises(self):
        with self.assertRaises(fm.FrontmatterError):
            fm.parse_frontmatter("---\nname: foo\nno closing fence")

    def test_multiline_scalar_raises(self):
        # A continuation line that is neither key: value nor a nested map line.
        with self.assertRaises(fm.FrontmatterError):
            fm.parse_frontmatter(
                "---\nname: foo\ndescription: this continues\non another line\n---\n"
            )


class ValidateSkillDirTest(unittest.TestCase):
    def _write_skill(self, root, name, frontmatter, body="# Skill\n\nContent."):
        skill_dir = root / name
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            f"---\n{frontmatter}---\n\n{body}", encoding="utf-8"
        )
        return skill_dir

    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_valid_skill_has_no_errors(self):
        skill = self._write_skill(
            self.root,
            "my-skill",
            'name: my-skill\ndescription: "Does a thing. Use when doing things."\n'
            "metadata:\n  category: core\n",
        )
        self.assertEqual(fm.validate_skill_dir(skill), [])

    def test_name_must_match_directory(self):
        skill = self._write_skill(
            self.root, "wrong-dir", "name: other-name\ndescription: d\n"
        )
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("must match the directory" in e for e in errors))

    def test_invalid_name_characters_rejected(self):
        skill = self._write_skill(
            self.root, "Bad_Name", "name: Bad_Name\ndescription: d\n"
        )
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("name" in e.lower() for e in errors))

    def test_missing_description_rejected(self):
        skill = self._write_skill(self.root, "no-desc", "name: no-desc\n")
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("description" in e for e in errors))

    def test_overlong_description_rejected(self):
        desc = "x" * 1025
        skill = self._write_skill(
            self.root, "long-desc", f"name: long-desc\ndescription: {desc}\n"
        )
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("1024" in e for e in errors))

    def test_unknown_category_rejected(self):
        skill = self._write_skill(
            self.root,
            "cat-skill",
            "name: cat-skill\ndescription: d\nmetadata:\n  category: banana\n",
        )
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("category" in e for e in errors))

    def test_empty_body_rejected(self):
        skill = self._write_skill(self.root, "empty", "name: empty\ndescription: d\n", body="")
        errors = fm.validate_skill_dir(skill)
        self.assertTrue(any("body" in e.lower() for e in errors))

    def test_missing_skill_md_rejected(self):
        skill_dir = self.root / "ghost"
        skill_dir.mkdir(parents=True)
        errors = fm.validate_skill_dir(skill_dir)
        self.assertTrue(len(errors) == 1 and "SKILL.md" in errors[0])


if __name__ == "__main__":
    unittest.main()
