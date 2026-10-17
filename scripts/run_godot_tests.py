#!/usr/bin/env python3
"""Fail-closed development launcher for the dependency-free GDScript runner."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "FORTRESS_TEST_RESULT "
ENGINE_ERROR = re.compile(r"(?m)^\s*(?:SCRIPT ERROR:|ERROR:|Parse Error:|Failed to load script)")


def validate_result(value: object) -> dict:
    """Validate completion/counts before trusting even a zero process status."""
    if not isinstance(value, dict) or set(value) != {
        "format", "complete", "passed", "count", "errors", "records"
    }:
        raise ValueError("unknown or missing result fields")
    if type(value["format"]) is not int or value["format"] != 1:
        raise ValueError("unsupported result format")
    if value["complete"] is not True or type(value["passed"]) is not bool:
        raise ValueError("incomplete or invalid result")
    records, errors = value["records"], value["errors"]
    if not isinstance(records, list) or not isinstance(errors, list):
        raise ValueError("invalid records/errors")
    if type(value["count"]) is not int or value["count"] != len(records):
        raise ValueError("record count mismatch")
    failed = bool(errors) or not records
    seen = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "suite", "case", "category", "seed", "runs"
        }:
            raise ValueError("unknown or missing case fields")
        if any(not isinstance(record[key], str) or not record[key]
               for key in ("suite", "case", "category", "seed")):
            raise ValueError("invalid case identity")
        if record["category"] not in ("unit", "determinism", "integration"):
            raise ValueError("invalid category")
        if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)", record["seed"]):
            raise ValueError("invalid seed")
        identity = record["suite"], record["case"]
        if identity in seen:
            raise ValueError("duplicate case")
        seen.add(identity)
        runs = record["runs"]
        if not isinstance(runs, list) or len(runs) != 2:
            raise ValueError("missing repeated execution")
        for run in runs:
            if not isinstance(run, dict) or set(run) != {"assertions", "failures", "states"}:
                raise ValueError("unknown or missing run fields")
            if (type(run["assertions"]) is not int or run["assertions"] < 1
                    or not isinstance(run["failures"], list)
                    or not isinstance(run["states"], list)):
                raise ValueError("incomplete run")
            failed |= bool(run["failures"])
            for state in run["states"]:
                if (not isinstance(state, dict) or set(state) != {"frame", "bytes"}
                        or type(state["frame"]) is not int or state["frame"] < 0
                        or not isinstance(state["bytes"], str)
                        or not re.fullmatch(r"(?:[0-9a-f]{2})*", state["bytes"])):
                    raise ValueError("invalid canonical state record")
        failed |= runs[0] != runs[1]
    if value["passed"] == failed:
        raise ValueError("pass flag contradicts records")
    return value


def invoke(command: list[str], timeout: float) -> dict:
    try:
        process = subprocess.run(command, cwd=ROOT, capture_output=True,
                                 timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        return {"command": command, "exit": None, "failure": "watchdog",
                "stdout": _decode(exc.stdout), "stderr": _decode(exc.stderr)}
    report = {"command": command, "exit": process.returncode,
              "stdout": _decode(process.stdout), "stderr": _decode(process.stderr)}
    if _invalid_utf8(process.stdout, process.stderr):
        report["failure"] = "invalid_utf8_output"
        return report
    lines = [line[len(PREFIX):] for line in report["stdout"].splitlines()
             if line.startswith(PREFIX)]
    try:
        if ENGINE_ERROR.search(report["stdout"] + report["stderr"]):
            raise ValueError("engine_error")
        if len(lines) != 1:
            raise ValueError("missing_or_duplicate_completion")
        result = validate_result(json.loads(lines[0]))
        report["result"] = result
        if process.returncode != 0 or not result["passed"]:
            raise ValueError("test_failure")
    except (ValueError, TypeError) as exc:
        report["failure"] = str(exc)
    return report


def discover(category: str) -> list[str]:
    """Mirror run_tests.gd discovery: sorted test_*.gd under the category, plus the unit self-suite."""
    paths = ["res://" + path.relative_to(ROOT).as_posix()
             for path in (ROOT / "tests" / category).rglob("test_*.gd")]
    if category == "unit":
        paths.append("res://tests/runner/self_suite.gd")
    return sorted(paths)


def merge(reports: list[dict], filtered: bool) -> dict:
    """Combine per-suite shard reports into one process-equivalent run, in suite order."""
    if filtered:
        # A filter matches a subset of suites; only the merged selection must be nonempty.
        reports = [report for report in reports if report.get("result", {}).get("errors") != [{"kind": "zero_matching_cases"}]
                   or report["result"]["records"]] or reports[:1]
    run = {"shards": reports}
    failures = [report["failure"] for report in reports if "failure" in report]
    try:
        results = [report["result"] for report in reports]
    except KeyError:
        run["failure"] = failures[0]
        return run
    records = [record for result in results for record in result["records"]]
    errors = [error for result in results for error in result["errors"]]
    run["result"] = {"format": 1, "complete": True, "passed": all(result["passed"] for result in results),
                     "count": len(records), "errors": errors, "records": records}
    if failures:
        run["failure"] = failures[0]
        return run
    try:
        validate_result(run["result"])
    except ValueError as exc:
        run["failure"] = str(exc)
    return run


def first_divergence(expected: dict, actual: dict) -> dict:
    """Find the first ordered case/state difference without normalizing bytes."""
    for case_index, (left, right) in enumerate(zip(expected["records"], actual["records"])):
        if left == right:
            continue
        diagnostic = {"case_record": case_index, "suite": left["suite"], "case": left["case"]}
        for state_index, (first, second) in enumerate(zip(left["runs"][0]["states"], right["runs"][0]["states"])):
            if first == second:
                continue
            before, after = bytes.fromhex(first["bytes"]), bytes.fromhex(second["bytes"])
            difference = next((i for i, (a, b) in enumerate(zip(before, after)) if a != b),
                              min(len(before), len(after)))
            diagnostic.update(record=state_index, frame=first["frame"],
                              expected=first, actual=second)
            if before != after:
                diagnostic["byte"] = difference
            return diagnostic
        diagnostic.update(expected=left, actual=right)
        return diagnostic
    return {"expected_count": expected["count"], "actual_count": actual["count"],
            "expected_errors": expected["errors"], "actual_errors": actual["errors"]}


def _decode(value: bytes | str | None) -> str:
    return value.decode(errors="replace") if isinstance(value, bytes) else value or ""


def _invalid_utf8(*streams: bytes | str | None) -> bool:
    for stream in streams:
        if isinstance(stream, bytes):
            try:
                stream.decode('utf-8')
            except UnicodeDecodeError:
                return True
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--category", choices=("unit", "determinism", "integration"), default="unit")
    parser.add_argument("--suite", action="append", default=[])
    parser.add_argument("--filter", default="")
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--results", type=Path, default=ROOT / ".cache/tests/latest.json")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1,
                        help="parallel Godot processes; each suite runs in its own pair of fresh processes")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be finite and positive")
    if not -(2**63) <= args.seed < 2**63:
        parser.error("seed must fit a signed 64-bit integer")
    if args.jobs < 1:
        parser.error("jobs must be positive")
    # Supersede prior success before any external executable gets control.
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps({"format": 1, "passed": False,
                                       "failure": "in_progress"}) + "\n", encoding="utf-8")
    located = shutil.which(str(args.godot))
    executable = Path(located).resolve() if located else args.godot.resolve()
    command = [str(executable), "--headless", "--path", str(ROOT), "--script",
               "res://tests/runner/run_tests.gd", "--", "--category", args.category,
               "--seed", str(args.seed)]
    if args.filter:
        command += ["--filter", args.filter]
    # run_tests.gd sorts its suites, so shards follow the same order.
    suites = sorted(args.suite) or discover(args.category)
    shards = [command + ["--suite", suite] for suite in suites] if args.jobs > 1 else [
        command + [part for suite in args.suite for part in ("--suite", suite)]]
    version_probe = None
    try:
        version_process = subprocess.run([str(executable), "--version"], capture_output=True,
                                 timeout=args.timeout)
        version_probe = {"command": [str(executable), "--version"],
                         "exit": version_process.returncode,
                         "stdout": _decode(version_process.stdout), "stderr": _decode(version_process.stderr)}
        if _invalid_utf8(version_process.stdout, version_process.stderr):
            raise ValueError("invalid_utf8_version_output")
        if version_process.returncode != 0:
            raise ValueError("version_probe_failed")
        version = version_probe["stdout"].strip()
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            pending = [[pool.submit(invoke, shard, args.timeout) for shard in shards] for _ in range(2)]
            runs = [merge([future.result() for future in repetition], bool(args.filter)) for repetition in pending]
        failed = any("failure" in run for run in runs)
        if not failed and runs[0]["result"] != runs[1]["result"]:
            failed = True
            runs[1]["failure"] = "fresh_process_divergence"
            runs[1]["divergence"] = first_divergence(runs[0]["result"], runs[1]["result"])
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                capture_output=True, text=True, check=True).stdout.strip()
        manifest = ROOT / "docs/reference/pins.json"
        report = {"format": 1, "passed": not failed, "commit": commit,
                  "working_tree_dirty": bool(subprocess.run(
                      ["git", "status", "--porcelain"], cwd=ROOT, capture_output=True,
                      text=True, check=True).stdout),
                  "engine": version, "engine_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                  "pin_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest() if manifest.exists() else None,
                  "platform": platform.platform(), "machine": platform.machine(),
                  "cwd": str(ROOT), "seed": str(args.seed), "runs": runs}
    except (OSError, subprocess.SubprocessError, ValueError, UnicodeError) as exc:
        report = {"format": 1, "passed": False, "failure": str(exc)}
        if version_probe is not None:
            report["version_probe"] = version_probe
        if isinstance(exc, subprocess.TimeoutExpired):
            report.update(stdout=_decode(exc.stdout), stderr=_decode(exc.stderr))
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "results": str(args.results)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
