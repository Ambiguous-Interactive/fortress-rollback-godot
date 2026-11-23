#!/usr/bin/env python3
"""Measure verified local edits in a temporary detached worktree. Print a summary and retain one JSONL row per completed command."""
import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time
from typing import NamedTuple

from git_test_environment import fixture_environment
from reference import owned_process

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / ".cache/scratch"


class Edit(NamedTuple):
    path: str
    suite: str
    case: str
    original: str
    green: str
    red: str
    failure_label: str
    changed: bool = False


EDITS = (
    Edit("addons/fortress_rollback/core/input_queue.gd", "input_queue", "validation",
         "capacity < 2", "capacity <= 1", "capacity < 1", "capacity bounds"),
    Edit("addons/fortress_rollback/core/snapshot_writer.gd", "snapshot_history", "wide_writes", "_cursor if _is_live else 0",
         "(_cursor + 0) if _is_live else 0", "(_cursor + 1) if _is_live else 0", "width 1 chunks 1 advance the cursor"),
    Edit("tests/unit/test_protocol_codec.gd", "protocol_codec", "golden",
         '0, "golden encode', '(0 + 0), "golden encode', '1, "golden encode', "golden encode 1", changed=True),
    Edit("examples/online/replay_viewer.gd", "replay_speed", "cadence", "_playback_quarters += _speed_quarters",
         "_playback_quarters += (_speed_quarters + 0)", "_playback_quarters += (_speed_quarters + 1)", "quarter-rate 1 tick 2"),
    Edit("tests/unit/test_frame_inputs.gd", "frame_inputs", "validation", '8, 9]), 0, "invalid player preserves destination"',
         '8, 9 + 0]), 0, "invalid player preserves destination"', '8, 9 + 1]), 0, "invalid player preserves destination"', "invalid player preserves destination"),
)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def git(directory, environment, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=directory, env=environment, encoding="utf-8", timeout=60).strip()


@contextmanager
def worktree(commit, environment):
    with tempfile.TemporaryDirectory(dir=SCRATCH, prefix="iteration-tree-") as temporary:
        tree = Path(temporary) / "project"
        git(ROOT, environment, "worktree", "add", "--detach", str(tree), commit)
        try:
            (tree / ".cache").mkdir()  # A revision must not supply the study's private cache or a symlink to it.
            yield tree
        finally:
            git(ROOT, environment, "worktree", "remove", "--force", str(tree))


def verify_result(report, suite, edit, red, commit, edited_digest, exit_code):
    require(report.get("working_tree_dirty") is True and report.get("commit") == commit, "receipt lost the edited revision")
    require(report["source_snapshot"]["files"][edit.path]["sha256"] == edited_digest, "receipt qualified different edited bytes")
    require((exit_code != 0) == red and report["passed"] is (not red) and "failure" not in report, "unexpected launcher verdict")
    runs = report["runs"]
    require(len(runs) == 2 and runs[0]["result"] == runs[1]["result"], "fresh-process results differ")
    require(all(run.get("failure") == ("test_failure" if red else None) for run in runs), "unexpected process failure")
    records = runs[0]["result"]["records"]
    for record in records:
        first, second = record["runs"]
        require(record["suite"] == suite and first == second and first["assertions"] > 0, "unexpected suite or incomplete repeat")
        failed = red and record["case"] == edit.case
        require(bool(first["failures"]) == failed, "unexpected assertion outcome")
        if failed:
            require(any(f.get("label") == edit.failure_label for f in first["failures"]), "expected assertion did not fail")
    require(sum(record["case"] == edit.case for record in records) == 1, "edited behavior did not run exactly once per process")
    expected_cases = {"golden", "truncation", "malformed", "limits", "types", "ownership", "semantics", "hostile_bytes"} if edit.changed else {edit.case}
    require(len(records) == len(expected_cases) and {r["case"] for r in records} == expected_cases, "edited suite inventory differs from the benchmark workload")
    return records


def sample(tree, environment, commit, index):
    cycle, offset = divmod(index, len(EDITS))
    edit = EDITS[offset]
    red = (cycle + offset) % 2 == 1
    cold = (cycle // 2 + offset) % 2 == 0
    suite = f"res://tests/unit/test_{edit.suite}.gd"
    command = ["make", "test-changed", "BASE=HEAD"] if edit.changed else ["make", "test-focus", f"SUITE={suite}", f"FILTER={edit.case}"]
    results = tree / ".cache/tests"
    results.mkdir(parents=True, exist_ok=True)
    history = results / "durations.json"
    if cold:
        history.unlink(missing_ok=True)
    else:
        history.write_text(json.dumps({suite: 0.5}), encoding="utf-8")
    receipt = results / "latest.json"
    receipt.unlink(missing_ok=True)
    path = tree / edit.path
    require(path.resolve(strict=True) == tree.resolve() / edit.path, f"edit path crosses a symlink: {edit.path}")
    original = path.read_bytes()
    require(original.count(edit.original.encode()) == 1, f"edit anchor changed in {edit.path}")
    edited = original.replace(edit.original.encode(), (edit.red if red else edit.green).encode()) + f"\n# Local iteration measurement {index}.\n".encode()
    edited_digest = hashlib.sha256(edited).hexdigest()
    path.write_bytes(edited)
    try:
        start = time.monotonic()
        exit_code, output = owned_process.run(command, environment, results / "measurement.log", timeout=1080, cwd=tree)
        seconds = time.monotonic() - start
        report = json.loads(receipt.read_text(encoding="utf-8"))
        records = verify_result(report, suite, edit, red, commit, edited_digest, exit_code)
        return {"index": index, "seconds": round(seconds, 6), "command": command, "red": red, "cold_durations": cold, "exit": exit_code,
                "commit": commit, "engine": report["engine"], "engine_sha256": report["engine_sha256"], "helpers": report["helper_sources"],
                "source_sha256": report["source_snapshot"]["sha256"], "edit": edit.path, "edit_sha256": edited_digest, "cases": len(records),
                "result_sha256": hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest(), "contended": "host_capacity_lease" in output}
    finally:
        path.write_bytes(original)


def summarize(seconds):
    ordered = sorted(seconds)
    return {"n": len(ordered), "p50": statistics.median(ordered), "p95": ordered[math.ceil(0.95 * len(ordered)) - 1], "max": ordered[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD", help="committed revision to measure")
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--output", type=Path, help="new JSONL output file (default: unique path under .cache/scratch)")
    comparison = parser.add_mutually_exclusive_group()
    comparison.add_argument("--compare-revision", help="run the same edit on a control revision, alternating order on each pair")
    comparison.add_argument("--control", type=Path, help="compare matching edited bytes and case results against the first five rows of a prior study")
    args = parser.parse_args()
    if args.count < 1 or ((args.control or args.compare_revision) and args.count < len(EDITS)):
        parser.error("count must be positive and cover all five edits for a paired comparison")
    control = []
    if args.control:
        with args.control.open(encoding="utf-8") as stream:
            control = [json.loads(next(stream, "null")) for _ in EDITS]
        require(all(isinstance(row, dict) for row in control), "control needs five completed samples")
    environment = fixture_environment()
    commit = git(ROOT, environment, "rev-parse", "--verify", "--end-of-options", args.revision + "^{commit}")
    SCRATCH.mkdir(parents=True, exist_ok=True)
    output = args.output or Path(tempfile.mkdtemp(dir=SCRATCH, prefix="iteration-study-")) / "samples.jsonl"
    output.parent.mkdir(parents=True, exist_ok=True)
    elapsed = []
    by_command = {}
    lease_waits = 0
    control_lease_waits = 0
    paired = []
    with output.open("x", encoding="utf-8") as rows, ExitStack() as trees:
        tree = trees.enter_context(worktree(commit, environment))
        if args.compare_revision:
            base = git(ROOT, environment, "rev-parse", "--verify", "--end-of-options", args.compare_revision + "^{commit}")
            base_tree = trees.enter_context(worktree(base, environment))
        for index in range(args.count):
            prior = control[index] if index < len(control) else None
            if args.compare_revision and index % 2 == 0:
                prior = sample(base_tree, environment, base, index)
            row = sample(tree, environment, commit, index)
            if args.compare_revision and index % 2 == 1:
                prior = sample(base_tree, environment, base, index)
            if prior is not None:
                fields = ("index", "command", "red", "cold_durations", "engine_sha256", "edit_sha256", "result_sha256")
                require(all(prior[key] == row[key] for key in fields), f"control sample {index} described a different workload or result")
                paired.append([prior["seconds"], row["seconds"]])
                control_lease_waits += prior["contended"]
            elapsed.append(row["seconds"])
            by_command.setdefault(row["command"][1], []).append(row["seconds"])
            lease_waits += row["contended"]
            if args.compare_revision:
                row["control"] = prior
            print(json.dumps(row, sort_keys=True), file=rows, flush=True)
    summary = {"revision": commit, "output": str(output), **summarize(elapsed), "lease_waits": lease_waits,
               "by_command": {name: summarize(values) for name, values in by_command.items()}}
    if paired:
        summary.update(control_lease_waits=control_lease_waits, pairs=paired, paired_median_delta=statistics.median(after - before for before, after in paired))
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Local iteration study failed: {error}")
