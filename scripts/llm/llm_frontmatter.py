"""Minimal, dependency-free YAML frontmatter parsing for SKILL.md files.

We deliberately support a strict, deterministic subset of YAML:

- The file must start with `---` and contain a closing `---` fence line.
- Top-level entries are single-line `key: value` scalars.
- Optional quoting with matching single or double quotes.
- One nesting level is supported via `metadata:` followed by 2-space-indented
  `key: value` entries (string -> string map), per the Agent Skills spec.

Anything else is a hard error with a precise message. If richer YAML is ever
needed, swap this module for PyYAML behind the same interface.
"""

from __future__ import annotations

import re
from pathlib import Path

from llm import llm_paths

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_MAX_DESCRIPTION = 1024


class FrontmatterError(ValueError):
    pass


def _unquote(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def _scalar(raw: str) -> str | None:
    value = raw.strip()
    if not value:
        return None
    return _unquote(value)


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Parse `text` into (metadata dict, body). Raises FrontmatterError."""
    if not text.startswith("---"):
        raise FrontmatterError(
            "missing YAML frontmatter: file must start with '---'"
        )
    lines = text.split("\n")
    if lines[0].strip() != "---":
        raise FrontmatterError("malformed opening '---' fence")

    end: int | None = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        raise FrontmatterError(
            "unterminated frontmatter: missing closing '---' fence"
        )

    meta: dict = {}
    current_map: dict | None = None
    for line in lines[1:end]:
        if not line.strip():
            continue
        if line[0] in (" ", "\t"):
            if current_map is None:
                raise FrontmatterError(
                    f"unexpected indented line outside a mapping: {line!r}"
                )
            entry = re.match(r"^\s+([A-Za-z][A-Za-z0-9_-]*):(.*)$", line)
            if entry is None:
                raise FrontmatterError(f"invalid mapping entry: {line!r}")
            current_map[entry.group(1)] = _scalar(entry.group(2)) or ""
            continue
        entry = re.match(r"^([A-Za-z][A-Za-z0-9-]*):(.*)$", line)
        if entry is None:
            raise FrontmatterError(
                f"unsupported frontmatter line "
                f"(only single-line 'key: value' is allowed): {line!r}"
            )
        key, raw_value = entry.group(1), entry.group(2)
        value = _scalar(raw_value)
        if value is None:
            current_map = {}
            meta[key] = current_map
        else:
            current_map = None
            meta[key] = value

    return meta, "\n".join(lines[end + 1:])


def validate_skill_dir(
    skill_dir: Path,
    categories: tuple[str, ...] = llm_paths.CATEGORIES,
) -> list[str]:
    """Validate one skill directory against the Agent Skills + house rules.

    Returns a list of human-readable error strings; empty means valid.
    """
    errors: list[str] = []
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return [f"{skill_dir.name}: missing SKILL.md"]

    text = skill_md.read_text(encoding="utf-8")
    try:
        meta, body = parse_frontmatter(text)
    except FrontmatterError as exc:
        return [f"{skill_dir.name}: {exc}"]

    name = meta.get("name")
    if not name:
        errors.append(f"{skill_dir.name}: missing required `name`")
    elif not NAME_RE.match(str(name)):
        errors.append(
            f"{skill_dir.name}: `name` must be lowercase alphanumeric with "
            f"single hyphen separators (got {name!r})"
        )
    elif name != skill_dir.name:
        errors.append(
            f"{skill_dir.name}: `name` must match the directory name "
            f"(got {name!r})"
        )

    description = meta.get("description")
    if not description:
        errors.append(f"{skill_dir.name}: missing required `description`")
    elif len(str(description)) > _MAX_DESCRIPTION:
        errors.append(
            f"{skill_dir.name}: `description` exceeds "
            f"{_MAX_DESCRIPTION} characters"
        )

    metadata = meta.get("metadata")
    if metadata is not None and not isinstance(metadata, dict):
        errors.append(f"{skill_dir.name}: `metadata` must be a mapping")
    elif isinstance(metadata, dict):
        category = metadata.get("category")
        if category is not None and category not in categories:
            allowed = ", ".join(categories)
            errors.append(
                f"{skill_dir.name}: `metadata.category` must be one of "
                f"{allowed} (got {category!r})"
            )

    if not body.strip():
        errors.append(f"{skill_dir.name}: SKILL.md body is empty")

    return errors


def iter_skill_dirs(skills_dir: Path) -> list[Path]:
    if not skills_dir.is_dir():
        return []
    return sorted(p for p in skills_dir.iterdir() if p.is_dir())
