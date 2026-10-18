"""Meta-linter for the whole .llm harness.

Checks (in order):
1. Pointer files: exist, contain the exact delegation link, stay thin.
2. context.md: exists, exactly one H1, links the generated index, and does
   not embed generated content.
3. Skill frontmatter: every `.llm/skills/*/SKILL.md` is a valid Agent Skill.
4. Encoding contract: UTF-8 without BOM, LF-only, for every scoped file.
5. Link integrity: every relative markdown link inside `.llm/**` resolves,
   except links into machine-local, never-committed directories.

Usage: python3 scripts/llm/lint_llm_instructions.py [root]
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from llm import check_llm_file_lengths  # noqa: E402
from llm import llm_frontmatter  # noqa: E402
from llm import llm_paths  # noqa: E402

_MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
_SKIP_PREFIXES = ("http://", "https://", "mailto:", "#")


@dataclass(frozen=True)
class Finding:
    level: str
    path: Path
    message: str

    def __str__(self) -> str:
        return f"[llm-lint] {self.level.upper()}: {self.message}"


def check_pointers(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for rel, link in llm_paths.POINTER_FILES.items():
        path = root / rel
        if not path.is_file():
            findings.append(
                Finding("error", path, f"pointer file missing: {rel}")
            )
            continue
        text = path.read_text(encoding="utf-8")
        if f"]({link})" not in text:
            findings.append(
                Finding(
                    "error",
                    path,
                    f"pointer file {rel} must delegate via ]({link})",
                )
            )
        n_lines = len(text.splitlines())
        if n_lines > llm_paths.THIN_POINTER_MAX_LINES:
            findings.append(
                Finding(
                    "error",
                    path,
                    f"pointer file {rel} must stay thin "
                    f"(<= {llm_paths.THIN_POINTER_MAX_LINES} lines, "
                    f"got {n_lines})",
                )
            )
    return findings


def check_context(root: Path) -> list[Finding]:
    path = root / ".llm" / "context.md"
    if not path.is_file():
        return [Finding("error", path, f"{path} is missing")]
    text = path.read_text(encoding="utf-8")
    findings: list[Finding] = []

    h1_count = len([ln for ln in text.splitlines() if ln.startswith("# ")])
    if h1_count != 1:
        findings.append(
            Finding(
                "error",
                path,
                f"context.md must have exactly one H1 (found {h1_count})",
            )
        )
    if "./skills/index.md" not in text:
        findings.append(
            Finding(
                "error",
                path,
                "context.md must link the generated skills index "
                "(./skills/index.md)",
            )
        )
    for marker in ("BEGIN GENERATED", "END GENERATED"):
        if marker in text:
            findings.append(
                Finding(
                    "error",
                    path,
                    f"context.md must not embed generated content "
                    f"({marker}); link ./skills/index.md instead",
                )
            )
    return findings


def check_skill_frontmatter(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    skills_dir = root / ".llm" / "skills"
    for skill_dir in llm_frontmatter.iter_skill_dirs(skills_dir):
        for problem in llm_frontmatter.validate_skill_dir(skill_dir):
            findings.append(Finding("error", skill_dir, problem))
    return findings


def check_encoding(scope_files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in scope_files:
        data = path.read_bytes()
        rel = path.relative_to(root)
        if data.startswith(b"\xef\xbb\xbf"):
            findings.append(
                Finding("error", path, f"{rel}: UTF-8 BOM is forbidden")
            )
        if b"\r\n" in data or b"\r" in data.replace(b"\r\n", b""):
            findings.append(
                Finding("error", path, f"{rel}: CRLF line endings are forbidden (use LF)")
            )
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append(
                Finding("error", path, f"{rel}: file is not valid UTF-8")
            )
    return findings


def _is_local_only(resolved: Path, root: Path) -> bool:
    """True when a link target lives in a machine-local, never-committed dir.

    `progress/` session logs stay on the authoring machine and are git-ignored,
    so a fresh checkout has none of them. Pointers into that directory are a
    deliberate local convenience, not a broken link.
    """
    try:
        relative = resolved.relative_to(root.resolve())
    except ValueError:  # escapes the repo entirely
        return False
    return bool(relative.parts) and relative.parts[0] in llm_paths.LOCAL_ONLY_DIRS


def check_links(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    llm_dir = root / ".llm"
    if not llm_dir.is_dir():
        return findings
    for path in sorted(llm_dir.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        for match in _MD_LINK_RE.finditer(text):
            target = match.group(1)
            if target.startswith(_SKIP_PREFIXES):
                continue
            resolved = (path.parent / target.split("#", 1)[0]).resolve()
            if _is_local_only(resolved, root) or resolved.exists():
                continue
            findings.append(
                Finding(
                    "error",
                    path,
                    f"{path.relative_to(root)}: broken relative link "
                    f"-> {target}",
                )
            )
    return findings


def run_all(root: Path | None = None) -> list[Finding]:
    base = llm_paths.resolve_root(root)
    scope = llm_paths.size_scope_files(base)
    return [
        *check_pointers(base),
        *check_context(base),
        *check_skill_frontmatter(base),
        *check_encoding(scope, base),
        *check_links(base),
        *check_length_findings(base),
    ]


def check_length_findings(root: Path) -> list[Finding]:
    """Surface over-limit files as meta-lint errors too (defense in depth)."""
    return [
        Finding(f.level, f.path, f.message.replace("[llm-sizes] ", ""))
        for f in check_llm_file_lengths.check_scope(root)
        if f.level == "error"
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=None)
    args = parser.parse_args(argv)

    base = llm_paths.resolve_root(Path(args.root) if args.root else None)
    findings = run_all(base)
    for finding in findings:
        print(finding, file=sys.stderr)
    errors = [f for f in findings if f.level == "error"]
    if errors:
        print(
            f"[llm-lint] FAILED with {len(errors)} error(s)", file=sys.stderr
        )
        return 1
    print("[llm-lint] OK: harness instructions valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
