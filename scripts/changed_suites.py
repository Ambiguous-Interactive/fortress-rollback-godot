"""Select the test suites that can observe files changed since a base revision."""
from __future__ import annotations

from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = re.compile(r"res://([A-Za-z0-9_./-]+)")
CLASS_NAME = re.compile(r"(?m)^(?:@\w+\s+)*class_name\s+(\w+)")
SOURCES = ("addons", "tests", "examples")
SCANNED = (".gd", ".tscn", ".tres", ".json", ".cfg")


def changed_files(base: str, root: Path = ROOT) -> list[str]:
    """Committed changes since the merge base, plus staged, unstaged and untracked source files.

    Untracked files outside the Godot source directories (editor or agent settings) cannot reach a suite."""
    def git(*arguments: str) -> list[str]:
        return subprocess.run(["git", *arguments], cwd=root, capture_output=True, text=True, check=True).stdout.splitlines()
    merge_base = git("merge-base", "HEAD", base)[0]
    return sorted(set(git("diff", "--name-only", "--no-renames", merge_base)) | set(git("ls-files", "--others", "--exclude-standard", "--", *SOURCES)))


def select(suites: list[str], changed: list[str], root: Path = ROOT) -> list[str]:
    """Return the suites (res:// paths) to run; every suite when a change cannot be traced."""
    # A rename reports both paths (--no-renames); a .uid sidecar stands for its resource.
    relevant = [path.removesuffix(".uid") for path in changed if not path.endswith(".md")]
    if any(path.split("/")[0] not in SOURCES or path.startswith("tests/runner/") for path in relevant):
        return list(suites)
    files = [path for directory in SOURCES for path in (root / directory).rglob("*") if path.suffix in SCANNED and path.is_file()]
    texts = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8", errors="replace") for path in files}
    classes = {name: path for path, text in texts.items() for name in CLASS_NAME.findall(text)}
    # Over-approximate: any res:// string or class name mentioned in a file is a dependency.
    dependents: dict[str, set[str]] = {}
    for path, text in texts.items():
        used = set(RESOURCE.findall(text))
        used |= {target for name, target in classes.items() if target != path and re.search(r"\b" + name + r"\b", text)}
        for target in used:
            dependents.setdefault(target, set()).add(path)
    # A directory reference (a res:// string ending in /) depends on every file under it, including new ones.
    directories = [target for target in dependents if target.endswith("/")]
    reached, pending = set(relevant), list(relevant)
    while pending:
        path = pending.pop()
        for dependent in dependents.get(path, set()).union(*(dependents[d] for d in directories if path.startswith(d))):
            if dependent not in reached:
                reached.add(dependent)
                pending.append(dependent)
    return [suite for suite in suites if suite.removeprefix("res://") in reached]
