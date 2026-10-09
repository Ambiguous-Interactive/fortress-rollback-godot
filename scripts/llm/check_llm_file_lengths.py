"""Enforce the 300-line hard limit across the .llm harness.

Three-tier ladder (mirrors the unity-helpers design):
- >  MAX_LINES       -> error   (must split; CI and git hooks fail)
- == MAX_LINES       -> critical (at the boundary; fails with --fail-on-critical)
- >  SOFT_WARN_LINES -> warning (only shown with --verbose)

Usage:
    python3 scripts/llm/check_llm_file_lengths.py [--verbose]
            [--fail-on-critical] [--staged] [paths...]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from llm import llm_paths  # noqa: E402


@dataclass(frozen=True)
class Finding:
    level: str  # "error" | "critical" | "warning"
    path: Path
    message: str

    def __str__(self) -> str:
        return f"[llm-sizes] {self.level.upper()}: {self.message}"


def count_lines(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="replace").splitlines())


def check_file(path: Path, verbose: bool = False) -> list[Finding]:
    n = count_lines(path)
    findings: list[Finding] = []
    if n > llm_paths.MAX_LINES:
        findings.append(
            Finding(
                "error",
                path,
                f"{path}: {n} lines exceeds the {llm_paths.MAX_LINES}-line "
                f"hard limit - split this file",
            )
        )
    elif n == llm_paths.MAX_LINES:
        findings.append(
            Finding(
                "critical",
                path,
                f"{path}: AT the {llm_paths.MAX_LINES}-line limit - "
                f"one more line breaks the build",
            )
        )
    elif verbose and n > llm_paths.SOFT_WARN_LINES:
        findings.append(
            Finding(
                "warning",
                path,
                f"{path}: {n} lines (soft threshold "
                f"{llm_paths.SOFT_WARN_LINES})",
            )
        )
    return findings


def check_paths(paths: list[Path], verbose: bool = False) -> list[Finding]:
    findings: list[Finding] = []
    for path in paths:
        if not path.is_file():
            findings.append(
                Finding("error", path, f"{path}: file does not exist")
            )
            continue
        findings.extend(check_file(path, verbose=verbose))
    return findings


def check_scope(
    root: Path | None = None, verbose: bool = False
) -> list[Finding]:
    base = llm_paths.resolve_root(root)
    return check_paths(llm_paths.size_scope_files(base), verbose=verbose)


def git_staged_files(root: Path) -> list[Path]:
    """Files staged for commit, relative to `root`.

    Falls back to the full index when the repo has no commits yet (unborn
    HEAD), so the very first commit is guarded too.
    """
    def git(*cmd: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(root), *cmd],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    # Unborn HEAD (no commits yet) makes --verify exit non-zero; probe with
    # check=False instead of raising.
    probe = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", "--quiet", "HEAD"],
        check=False,
        capture_output=True,
    )
    has_head = probe.returncode == 0
    output = (
        git("diff", "--cached", "--name-only", "-z")
        if has_head
        else git("ls-files", "-z", "--cached")
    )
    return [Path(part) for part in output.split("\0") if part.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="Files/dirs to check; with --staged, the first path is the repo root.",
    )
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--fail-on-critical", action="store_true")
    parser.add_argument(
        "--staged",
        action="store_true",
        help="Check only git-staged files that are inside the harness scope.",
    )
    args = parser.parse_args(argv)

    if args.staged:
        base = Path(args.paths[0]) if args.paths else llm_paths.REPO_ROOT
        staged = git_staged_files(base)
        scoped = set(llm_paths.size_scope_files(base))
        in_scope = [base / rel for rel in staged if (base / rel) in scoped]
        findings = check_paths(in_scope, verbose=args.verbose)
    else:
        explicit: list[Path] = []
        for raw in args.paths:
            path = Path(raw)
            if path.is_dir():
                explicit.extend(llm_paths.size_scope_files(path))
            else:
                explicit.append(path)
        findings = (
            check_paths(explicit, verbose=args.verbose)
            if explicit
            else check_scope(verbose=args.verbose)
        )

    for finding in findings:
        print(finding, file=sys.stderr)

    has_error = any(f.level == "error" for f in findings)
    has_critical = any(f.level == "critical" for f in findings)
    if has_error or (args.fail_on_critical and has_critical):
        return 1
    if not findings:
        print("[llm-sizes] OK: all harness files within limits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
