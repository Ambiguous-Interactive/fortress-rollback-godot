"""Plan the PR unit partitions and verify their fresh-process case receipts on the candidate commit."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

from changed_suites import from_base, git
from native_source_snapshot import SourceSnapshot, inventory, inventory_sha256, source_paths
from run_godot_tests import HELPERS, ROOT, discover, load_durations, validate_result, verified_cases

WEIGHTS = ROOT / "scripts/unit_suite_seconds.json"
# One repetition's suite seconds on the 4-vCPU hosted runner. Two repetitions and startup share the PR budget.
PART_SECONDS = 275
ARTIFACT = "gate-unit-part-"
RESULTS = Path(".cache/tests/latest.json")


def partitions(suites: list[str], hints: dict) -> list[list[str]]:
    weights = {}
    for suite in suites:
        value = hints.get(suite)
        weights[suite] = value if type(value) in (float, int) and math.isfinite(value) and 0 < value <= 3600 else 10
    count = min(8, len(suites), math.ceil(sum(weights.values()) / PART_SECONDS))
    groups = [[] for _ in range(count)]
    totals = [0.0] * count
    for suite in sorted(suites, key=lambda s: (-weights[s], s)):
        index = min(range(count), key=totals.__getitem__)
        groups[index].append(suite)
        totals[index] += weights[suite]
    return [sorted(group) for group in groups]


def plan(base: str) -> dict:
    suites = discover("unit")
    base = "unavailable" if not base or base == "0" * 40 else base
    receipt = from_base(base, suites, ROOT, ROOT, source_paths(ROOT))
    return dict(commit=git(ROOT, "rev-parse", "HEAD").strip(), selection=receipt, parts=partitions(receipt["suites"], load_durations(WEIGHTS)))


def validate_plan(value: dict, commit: str) -> None:
    selection, groups = value["selection"], value["parts"]
    suites = selection["suites"]
    flat = [suite for group in groups for suite in group]
    if (value["commit"] != commit or selection["selected_count"] != len(suites) or len(set(suites)) != len(suites)
            or any(not group for group in groups) or Counter(flat) != Counter(suites)
            or not set(suites) <= set(discover("unit")) or selection["inventory_count"] != len(discover("unit"))):
        raise ValueError("invalid partition plan")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned_editor() -> Path:
    from reference.fetch import CACHE, fetch, load_manifest, prepare_zip

    arch = {"aarch64": "arm64", "x86_64": "x86_64"}[platform.machine()]
    name = f"Godot_v4.3-stable_linux.{arch}.zip"
    directory = CACHE / "editors/4.3"
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / name[:-4]
    prepare_zip(fetch(load_manifest()["artifacts"][name], name, False), directory, executable_members=(binary.name,))
    binary.chmod(0o755)
    return binary


def literal_cases(text: str) -> list[str] | None:
    """Accept only a complete top-level cases method returning literal, unique, nonempty names."""
    methods = re.findall(r"^func cases\(\) -> PackedStringArray:\n(.*?)(?=^\S|\Z)", text, re.MULTILINE | re.DOTALL)
    if len(methods) != 1 or not re.fullmatch(r'\s*return PackedStringArray\(\s*\[\s*"\w+"\s*(?:,\s*"\w+"\s*)*,?\s*\]\s*\)\s*', methods[0]):
        return None
    names = re.findall(r'"(\w+)"', methods[0])
    return names if len(names) == len(set(names)) else None


def expected_cases(suites: list[str]) -> dict:
    known, dynamic = {}, []
    for suite in suites:
        names = literal_cases((ROOT / suite.removeprefix("res://")).read_text(encoding="utf-8"))
        if names is None:
            dynamic.append(suite)
        else:
            known[suite] = names
    if dynamic:
        editor = pinned_editor()
        with SourceSnapshot(ROOT) as snapshot:
            command = [str(editor), "--headless", "--path", str(snapshot.path), "--script", "res://tests/runner/run_tests.gd", "--", "--category", "unit"]
            known.update(verified_cases(command, dynamic, 120, os.cpu_count() or 1))
            snapshot.verify_image()
            if snapshot.changed():
                raise ValueError("source changed during case discovery")
    return known


def verify(value: dict, directory: Path, status: str, base: str) -> None:
    if value != plan(base):
        raise ValueError("unit plan disagrees with event base and checkout")
    commit = git(ROOT, "rev-parse", "HEAD").strip()
    validate_plan(value, commit)
    groups = value["parts"]
    expected_status = "success" if groups else "skipped"
    files = {p.parent.name: p for p in directory.glob(f"{ARTIFACT}*/latest.json")}
    if status != expected_status or set(files) != {ARTIFACT + str(i) for i in range(len(groups))}:
        raise ValueError("missing or failed unit partition")
    helpers = {name: sha(ROOT / "scripts" / name) for name in ("run_godot_tests.py", *HELPERS)}
    pin_hash = sha(ROOT / "docs/reference/pins.json")
    version = json.loads((ROOT / "docs/reference/godot-baseline.json").read_text())["records"][0]["version"]
    engine_sha = {
        "x86_64": "6e100966e49c69a2d4c163673f606eec1bafe54b4c6170eec5a6a2ee50756ddd",
        "aarch64": "8b8d7c6089d8b4238e6ec872f027ef1a4bfc5241ddb5f8aec452b058368d255b",
    }[platform.machine()]
    source_sha = inventory_sha256(inventory(ROOT, source_paths(ROOT))) if groups else None
    declared = expected_cases(value["selection"]["suites"])
    total = 0
    for i, suites in enumerate(groups):
        report = json.loads(files[ARTIFACT + str(i)].read_text(encoding="utf-8"))
        if (report["passed"] is not True or report["working_tree_dirty"] is not False or report["commit"] != commit
                or report["engine"] != version or report["seed"] != "1701" or report["pin_manifest_sha256"] != pin_hash or report["helper_sources"] != helpers):
            raise ValueError("wrong unit partition identity")
        current = (report["engine_sha256"], report["source_snapshot"]["sha256"])
        if current != (engine_sha, source_sha) or report["machine"] != platform.machine():
            raise ValueError("wrong engine or source bytes")
        first, second = report["runs"]
        if "failure" in first or "failure" in second or first["result"] != second["result"]:
            raise ValueError("incomplete or diverging fresh processes")
        result = validate_result(first["result"])
        case_inventory = {s: declared[s] for s in suites}
        if case_inventory != report["case_inventory"]:
            raise ValueError("case listing disagrees with checkout")
        expected = [(s, c) for s in suites for c in case_inventory[s]]
        actual = [(r["suite"], r["case"]) for r in result["records"]]
        if (not result["passed"] or set(suites) != set(case_inventory) or any(not names for names in case_inventory.values())
                or expected != actual or any(r["category"] != "unit" or r["seed"] != "1701" for r in result["records"])):
            raise ValueError("partition case inventory mismatch")
        total += len(actual)
    print(json.dumps(dict(value["selection"], partitions=len(groups), cases=total, fresh_processes_per_case=2)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("plan").add_argument("--base", required=True)
    worker = modes.add_parser("run")
    worker.add_argument("--part", required=True, type=int)
    worker.add_argument("--godot", help="use an already prepared minimum editor")
    verdict = modes.add_parser("verify")
    verdict.add_argument("--artifacts", type=Path, required=True)
    verdict.add_argument("--status", required=True)
    verdict.add_argument("--base", required=True)
    args = parser.parse_args()
    if args.mode == "plan":
        value = plan(args.base)
        print(json.dumps(value))
        if "GITHUB_OUTPUT" in os.environ:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as out:
                print("plan=" + json.dumps(value, separators=(",", ":")), file=out)
                # An empty Actions matrix is invalid even when the job is skipped.
                print("indices=" + json.dumps(list(range(len(value["parts"]))) or [0]), file=out)
        return
    value = json.loads(os.environ["UNIT_PLAN"])
    if args.mode == "run":
        validate_plan(value, git(ROOT, "rev-parse", "HEAD").strip())
        if not 0 <= args.part < len(value["parts"]):
            raise ValueError("unknown unit partition")
        suites = value["parts"][args.part]
        command = [sys.executable, str(ROOT / "scripts/run_godot_tests.py"), "--godot", args.godot or str(pinned_editor()), "--category", "unit",
                   "--verify-inventory", "--timeout", "180", "--results", str(RESULTS)]
        subprocess.run(command + [arg for suite in suites for arg in ("--suite", suite)], check=True)
    else:
        verify(value, args.artifacts, args.status, args.base)


if __name__ == "__main__":
    main()
