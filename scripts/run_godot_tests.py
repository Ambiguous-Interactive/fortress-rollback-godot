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
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / 'reference'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine_path import resolve_engine  # noqa: E402
import host_capacity  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "FORTRESS_TEST_RESULT "
CASES_PREFIX = "FORTRESS_TEST_CASES "
PROGRESS_PREFIX = "FORTRESS_TEST_PROGRESS "
# A suite this slow in the last run is split into one process per case.
SPLIT_SECONDS = 4.0
DEFAULT_RESULTS = ROOT / ".cache/tests/latest.json"
# Seconds per suite from earlier runs. It only orders shards, so a stale or missing file is harmless.
DURATIONS = ROOT / ".cache/tests/durations.json"
# The engine reports a script error as a header line, followed by an "at:" line
# that names the aborting file and line.
ENGINE_ERROR_LINE = re.compile(r"^\s*(?:SCRIPT ERROR:|ERROR:|Parse Error:|Failed to load script)\s*(?P<message>.*)$")
# Only a script-level header belongs to the case that was executing. A generic
# engine error names a condition of the engine, not an aborted test case.
SCRIPT_ERROR_LINE = re.compile(r"^\s*(?:SCRIPT ERROR:|Parse Error:)\s*(?P<message>.*)$")
ENGINE_ERROR_AT = re.compile(r"^\s*at:\s[^(]*\((?P<file>[^()]+):(?P<line>\d+)\)")
# The lease names this runner as the owner of the development host's CPU capacity.
LEASE_NAME = "godot-tests"


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
            if (type(run["assertions"]) is not int or run["assertions"] < 0
                    or not isinstance(run["failures"], list)
                    or not isinstance(run["states"], list)):
                raise ValueError("incomplete run")
            # A run that recorded a failure is evidence even without an assertion:
            # a case that aborted before its first assertion has none.
            if run["assertions"] == 0 and not run["failures"]:
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


def last_progress(stdout: str) -> dict | None:
    """Return the last case the runner reported, so an interrupted run names it."""
    record: dict | None = None
    for line in stdout.splitlines():
        if not line.startswith(PROGRESS_PREFIX):
            continue
        try:
            value = json.loads(line[len(PROGRESS_PREFIX):])
        except ValueError:
            continue
        if isinstance(value, dict):
            record = value
    return record


def executing_case(line: str) -> tuple[str, str] | None:
    """Return the suite and case a progress record says is executing."""
    try:
        value = json.loads(line[len(PROGRESS_PREFIX):])
    except ValueError:
        return None
    if not isinstance(value, dict):
        return None
    executing = value.get("executing")
    if not isinstance(executing, dict):
        return None
    suite, case = executing.get("suite"), executing.get("case")
    if isinstance(suite, str) and isinstance(case, str) and suite and case:
        return suite, case
    return None


def engine_errors(output: str) -> list[dict]:
    """Return every engine error with the case that was executing when it was reported.

    A GDScript runtime error aborts the innermost function and the caller resumes,
    so the engine cannot report the abort itself. The runner publishes the case it
    is about to execute before every case, so the error is attributed to the case
    the last progress record named. Only a script-level header names an aborted
    case; a generic engine error belongs to the engine and stays unattributed.
    """
    entries: list[dict] = []
    executing: tuple[str, str] | None = None
    pending: dict | None = None
    for line in output.splitlines():
        if line.startswith(PROGRESS_PREFIX):
            executing = executing_case(line)
            pending = None
            continue
        header = ENGINE_ERROR_LINE.match(line)
        if header:
            attributable = SCRIPT_ERROR_LINE.match(line) is not None
            suite, case = (executing if attributable else (None, None)) if executing else (None, None)
            pending = {"suite": suite, "case": case, "file": None, "line": None,
                       "message": header.group("message").strip()}
            entries.append(pending)
            continue
        location = ENGINE_ERROR_AT.match(line)
        if pending is not None and location:
            pending["file"] = location.group("file")
            pending["line"] = int(location.group("line"))
            pending = None
            continue
        pending = None
    return entries


def engine_aborts(result: object, suite: str | None = None, case: str | None = None) -> bool:
    """True when the engine's own result already reports an aborted case.

    An engine that hands a script error to a custom logger fails the aborted
    case in its result. The launcher stays the gate on every engine, so it
    reads that verdict instead of reporting the same abort a second time. With
    no suite and case, every aborted case counts.
    """
    if not isinstance(result, dict):
        return False
    records = result.get("records")
    if not isinstance(records, list):
        return False
    for record in records:
        if not isinstance(record, dict):
            continue
        if suite is not None and (record.get("suite") != suite or record.get("case") != case):
            continue
        runs = record.get("runs")
        if not isinstance(runs, list):
            continue
        for run in runs:
            failures = run.get("failures") if isinstance(run, dict) else None
            if not isinstance(failures, list):
                continue
            for failure in failures:
                if isinstance(failure, dict) and failure.get("kind") == "case_aborted":
                    return True
    return False


def apply_aborts(result: object, errors: list[dict]) -> tuple[object, bool]:
    """Fail every case the engine aborted, naming the aborting file, line and message.

    The aborted case keeps its record and the other cases keep theirs: a case that
    died before its last assertion is a failure of that case, not of the run.
    """
    if not isinstance(result, dict):
        return result, False
    grouped: dict[tuple[str, str], list[dict]] = {}
    for error in errors:
        suite, case = error["suite"], error["case"]
        if not suite or not case:
            continue
        grouped.setdefault((suite, case), []).append(error)
    aborted = False
    for (suite, case), reports in grouped.items():
        aborted = True
        first = reports[0]
        # One entry names the abort; the count says how many repetitions died.
        entry = {"kind": "case_aborted", "suite": suite, "case": case,
                 "file": first["file"], "line": first["line"],
                 "message": first["message"], "aborts": len(reports)}
        if engine_aborts(result, suite, case):
            # The engine reported the abort in its own result. The launcher keeps
            # the reason and does not report the same abort twice.
            if isinstance(result.get("errors"), list) and not any(
                    isinstance(item, dict) and item.get("kind") == "case_aborted"
                    and item.get("suite") == suite and item.get("case") == case
                    for item in result["errors"]):
                result["errors"].append(dict(entry))
            continue
        if isinstance(result.get("errors"), list):
            result["errors"].append(dict(entry))
        records = result.get("records")
        record = next((item for item in records if isinstance(item, dict)
                       and item.get("suite") == suite and item.get("case") == case), None) \
            if isinstance(records, list) else None
        if record is None:
            if result.get("passed") is True:
                result["passed"] = False
            continue
        runs = record.get("runs")
        runs = runs if isinstance(runs, list) else []
        counts = [run["assertions"] for run in runs if isinstance(run, dict) and type(run.get("assertions")) is int]
        top = max(counts) if counts else 0
        # A repetition that the abort truncated recorded fewer assertions, so it is
        # the one that died and the other repetition keeps its own verdict: a case
        # that dies in one repetition and not in the other stays a divergence. When
        # every repetition recorded the same count, the abort came after the last
        # assertion, so the launcher cannot name the repetition that died and every
        # repetition carries the entry. The report count says how many repetitions
        # the engine actually reported.
        truncated = [run for run in runs if isinstance(run, dict) and run.get("assertions", 0) < top]
        targets = truncated if truncated else runs
        for run in targets:
            if not isinstance(run, dict) or not isinstance(run.get("failures"), list):
                continue
            run["failures"].append(dict(entry))
        if result.get("passed") is True:
            result["passed"] = False
    # An engine that reported the abort in its own result failed the run even when
    # its output did not name the script error.
    aborted = aborted or engine_aborts(result)
    return result, aborted


def invoke(command: list[str], timeout: float) -> dict:
    # The engine runs in its own process group, so a timeout kills the engine and
    # every process it started. A child that outlives its parent would keep the
    # host busy and would own the result that the report names.
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        group = os.getpgid(process.pid) if hasattr(os, "getpgid") else None
        _kill_group(process)
        # A process that escaped the group can still hold the pipe open, so the report
        # uses the output read so far instead of waiting for the end of the stream.
        output = exc.output or b""
        if process.stdout is not None:
            try:
                process.stdout.close()
            except OSError:
                pass
        report = {"command": command, "exit": None, "failure": "watchdog",
                  "process_group": group, "stdout": _decode(output), "stderr": ""}
        progress = last_progress(report["stdout"])
        if progress is not None:
            report["progress"] = progress
        return report
    report = {"command": command, "exit": process.returncode,
              "stdout": _decode(output), "stderr": ""}
    progress = last_progress(report["stdout"])
    if progress is not None:
        report["progress"] = progress
    if _invalid_utf8(output):
        report["failure"] = "invalid_utf8_output"
        return report
    lines = [line[len(PREFIX):] for line in report["stdout"].splitlines()
             if line.startswith(PREFIX)]
    errors = engine_errors(report["stdout"])
    try:
        if len(lines) != 1:
            raise ValueError("engine_error" if errors else "missing_or_duplicate_completion")
        try:
            parsed = json.loads(lines[0])
        except ValueError as exc:
            # A truncated or corrupted completion record is a stable reason, not a
            # parser message: the merged stream can carry a stray fragment.
            raise ValueError("malformed_completion") from exc
        result, aborted = apply_aborts(parsed, errors)
        report["result"] = validate_result(result)
        if aborted:
            raise ValueError("case_aborted")
        if errors:
            raise ValueError("engine_error")
        if process.returncode != 0 or not report["result"]["passed"]:
            raise ValueError("test_failure")
    except (ValueError, TypeError) as exc:
        report["failure"] = str(exc)
    return report


def _kill_group(process: subprocess.Popen) -> None:
    """Kill the engine's whole process group, so no child outlives the timeout."""
    if hasattr(os, "killpg") and hasattr(os, "getpgid"):
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
    else:
        # A platform without process groups only has the engine itself to stop.
        process.kill()
    try:
        # Waiting for the killed process does not wait for the pipe, so a process that
        # escaped the group cannot keep this call open.
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def timed(command: list[str], timeout: float) -> tuple[dict, float]:
    started = time.monotonic()
    return invoke(command, timeout), time.monotonic() - started


def load_durations(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {key: seconds for key, seconds in value.items() if isinstance(seconds, (int, float))} if isinstance(value, dict) else {}


def split_cases(command: list[str], suites: list[str], timeout: float) -> dict:
    """List case names for slow suites. Any listing problem leaves them whole; the run itself reports it."""
    try:
        process = subprocess.run(command + [part for suite in suites for part in ("--suite", suite)] + ["--list-cases"],
                                 cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        lines = [line[len(CASES_PREFIX):] for line in process.stdout.splitlines() if line.startswith(CASES_PREFIX)]
        inventory = json.loads(lines[0]) if process.returncode == 0 and len(lines) == 1 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    return {suite: names for suite, names in inventory.items() if suite in suites and isinstance(names, list) and len(names) > 1
            and all(isinstance(name, str) and name for name in names) and len(set(names)) == len(names)}


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


def first_divergence(expected: dict | None, actual: dict | None) -> dict:
    """Find the first ordered case/state difference without normalizing bytes."""
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        # One of the runs produced no result at all, so there is no record to
        # compare: the missing result is the divergence.
        return {"expected_present": isinstance(expected, dict), "actual_present": isinstance(actual, dict),
                "expected": expected if isinstance(expected, dict) else None,
                "actual": actual if isinstance(actual, dict) else None}
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


class _Parser(argparse.ArgumentParser):
    """Replace a stale passing receipt at the selected --results when arguments are rejected."""

    def error(self, message: str) -> None:
        preview = argparse.ArgumentParser(add_help=False, allow_abbrev=False, exit_on_error=False)
        preview.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
        try:
            results = preview.parse_known_args(self.arguments)[0].results
            results.parent.mkdir(parents=True, exist_ok=True)
            results.write_text(json.dumps({"format": 1, "passed": False, "failure": "invalid_arguments"}) + "\n", encoding="utf-8")
        except (argparse.ArgumentError, OSError):
            message += "; unable to invalidate the selected results"
        super().error(message)


def main(argv: list[str] | None = None) -> int:
    parser = _Parser(description=__doc__, allow_abbrev=False)
    parser.arguments = sys.argv[1:] if argv is None else argv
    parser.add_argument("--godot", required=True, help="engine name on PATH or a path to it")
    parser.add_argument("--category", choices=("unit", "determinism", "integration"), default="unit")
    parser.add_argument("--suite", action="append", default=[])
    parser.add_argument("--filter", default="")
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument("--changed", metavar="BASE", help="run only suites that load files changed since BASE (e.g. origin/main)")
    parser.add_argument("--durations", type=Path, default=DURATIONS, help="per-suite times that order and split shards")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1,
                        help="parallel Godot processes; each suite runs in its own pair of fresh processes")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be finite and positive")
    if not -(2**63) <= args.seed < 2**63:
        parser.error("seed must fit a signed 64-bit integer")
    if args.jobs < 1:
        parser.error("jobs must be positive")
    if args.changed and args.suite:
        parser.error("--changed selects suites itself")
    # Supersede prior success before any external executable gets control.
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps({"format": 1, "passed": False,
                                       "failure": "in_progress"}) + "\n", encoding="utf-8")
    executable = resolve_engine(args.godot)
    command = [str(executable), "--headless", "--path", str(ROOT), "--script",
               "res://tests/runner/run_tests.gd", "--", "--category", args.category,
               "--seed", str(args.seed)]
    if args.filter:
        command += ["--filter", args.filter]
    # run_tests.gd sorts its suites, so shards follow the same order.
    if args.changed:
        from changed_suites import changed_files, previous_class_names, select
        changed = changed_files(args.changed)
        args.suite = select(discover(args.category), changed, old_names=previous_class_names(args.changed, changed))
        print(json.dumps({"changed_since": args.changed, "suites": args.suite}), file=sys.stderr)
        if not args.suite:
            args.results.write_text(json.dumps({"format": 1, "passed": False, "failure": "no_affected_suites"}) + "\n", encoding="utf-8")
            print(json.dumps({"passed": None, "results": str(args.results), "note": "no suite loads a changed file"}))
            return 0
    suites = sorted(args.suite) or discover(args.category)
    durations = load_durations(args.durations)
    # Take the development host for this run. Another owner means a browser witness needs a
    # responsive host, so this run stays serial: it does not split slow suites into one
    # process per case, and it runs one process at a time.
    host_capacity.acquire(LEASE_NAME)
    lease_holder = host_capacity.holder()
    shared_host = lease_holder != LEASE_NAME
    if shared_host:
        print(json.dumps({"host_capacity_lease": lease_holder, "jobs": 1}), file=sys.stderr)
        args.jobs = 1
    if shared_host:
        # One process per suite, one suite at a time. Every suite keeps its own watchdog, so a
        # slow suite cannot time out the whole run, and no suite is split into one process per case.
        keys = [(suite, None) for suite in suites]
        shards = [command + ["--suite", suite] for suite in suites]
    elif args.jobs > 1:
        slow = [] if args.filter else [suite for suite in suites if durations.get(suite, 0) >= SPLIT_SECONDS]
        cases = split_cases(command, slow, args.timeout) if slow else {}
        # Shards stay in suite order, then inventory order, so merged records match one process.
        keys = [(suite, case) for suite in suites for case in cases.get(suite, [None])]
        shards = [command + ["--suite", suite] + (["--case", case] if case else []) for suite, case in keys]
    else:
        keys = [("|".join(args.suite), None)]
        shards = [command + [part for suite in args.suite for part in ("--suite", suite)]]
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
        # Start the slowest shards first, and both repetitions of each together, so no long shard starts last.
        # Shards with no recorded time count as slowest. Results are still merged in suite order.
        def estimate(key: tuple) -> float:
            suite, case = key
            return durations.get(suite + "::" + case, durations.get(suite, math.inf)) if case else durations.get(suite, math.inf)
        order = sorted(range(len(shards)), key=lambda index: -estimate(keys[index]))
        pending = [[None] * len(shards), [None] * len(shards)]
        # The wave keeps the development host, so a witness that starts later waits for it.
        try:
            with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                for index in order:
                    for repetition in pending:
                        repetition[index] = pool.submit(timed, shards[index], args.timeout)
                completed = [[future.result() for future in repetition] for repetition in pending]
        finally:
            host_capacity.release()
        runs = [merge([report for report, _ in repetition], bool(args.filter)) for repetition in completed]
        if not args.filter and args.jobs > 1:
            times = [max(completed[0][index][1], completed[1][index][1]) for index in range(len(keys))]
            measured, fastest = {}, {}
            for (suite, case), seconds in zip(keys, times):
                if case:
                    durations[suite + "::" + case] = round(seconds, 2)
                    fastest[suite] = min(fastest.get(suite, seconds), seconds)
                measured[suite] = measured.get(suite, 0) + seconds
            # A split suite pays engine startup once per case. Estimate its one-process time by removing the
            # extra startups, bounded by its fastest case, so a suite that is no longer slow becomes whole again.
            for suite, seconds in measured.items():
                durations[suite] = round(seconds - (len(cases[suite]) - 1) * fastest[suite] if suite in fastest else seconds, 2)
            try:
                args.durations.parent.mkdir(parents=True, exist_ok=True)
                args.durations.write_text(json.dumps(durations, indent=1, sort_keys=True) + "\n", encoding="utf-8")
            except OSError:
                pass
        failed = any("failure" in run for run in runs)
        # The fresh-process divergence is reported whenever the two runs differ, even
        # when a run already failed: a case that aborts in one process and not in the
        # other is a divergence, and the failed run alone does not explain it.
        if runs[0].get("result") != runs[1].get("result"):
            failed = True
            runs[1]["failure"] = "fresh_process_divergence"
            runs[1]["divergence"] = first_divergence(runs[0].get("result"), runs[1].get("result"))
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
