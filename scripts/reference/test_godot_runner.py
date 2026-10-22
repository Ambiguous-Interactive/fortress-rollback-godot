"""Runner negative controls at the engine boundary; stdlib only."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("godot_runner", ROOT / "scripts/run_godot_tests.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
GODOT: Path | None = None


def valid_result() -> dict:
    run = {"assertions": 1, "failures": [], "states": [{"frame": 0, "bytes": "01"}]}
    return {"format": 1, "complete": True, "passed": True, "count": 1,
            "errors": [], "records": [{"suite": "res://suite.gd", "case": "pass",
            "category": "unit", "seed": "1701", "runs": [run, copy.deepcopy(run)]}]}


class CompletionContract(unittest.TestCase):
    # Value: prevents green on truncated/unknown/vacuous structured evidence.
    def test_invalid_evidence(self) -> None:
        mutations = {
            "unknown field": lambda x: x.update(unknown=True),
            "incomplete": lambda x: x.update(complete=False),
            "count": lambda x: x.update(count=2),
            "zero cases": lambda x: x.update(records=[], count=0),
            "missing repeat": lambda x: x["records"][0]["runs"].pop(),
            "zero assertions": lambda x: x["records"][0]["runs"][0].update(assertions=0),
            "negative assertions": lambda x: x["records"][0]["runs"][0].update(assertions=-1),
            "unknown run": lambda x: x["records"][0]["runs"][0].update(unknown=True),
            "invalid bytes": lambda x: x["records"][0]["runs"][0]["states"][0].update(bytes="x"),
            "run disagreement": lambda x: x["records"][0]["runs"][0]["states"][0].update(bytes="02"),
            "hidden failure": lambda x: x["records"][0]["runs"][0]["failures"].append({"kind": "failure"}),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                result = valid_result()
                mutate(result)
                with self.assertRaises(ValueError):
                    RUNNER.validate_result(result)
        self.assertEqual(RUNNER.validate_result(valid_result()), valid_result())

    # Value: a run that recorded a failure is evidence even without an assertion:
    # a case that aborted before its first assertion has none.
    def test_unasserted_failure_is_evidence(self) -> None:
        result = valid_result()
        for run in result["records"][0]["runs"]:
            run["assertions"] = 0
            run["failures"] = [{"kind": "case_aborted"}]
        result["passed"] = False
        self.assertEqual(RUNNER.validate_result(result), result)

    def test_first_divergence(self) -> None:
        expected = valid_result()
        actual = copy.deepcopy(expected)
        actual["records"][0]["runs"][0]["states"][0]["bytes"] = "09"
        diagnostic = RUNNER.first_divergence(expected, actual)
        self.assertEqual((diagnostic["frame"], diagnostic["byte"]), (0, 0))
        actual = copy.deepcopy(expected)
        actual["records"][0]["runs"][0]["states"][0]["frame"] = 1
        diagnostic = RUNNER.first_divergence(expected, actual)
        self.assertEqual(diagnostic["frame"], 0)
        self.assertNotIn("byte", diagnostic)

    # Value: one fresh process can finish without a result, and the divergence
    # report must name the missing result instead of raising.
    def test_first_divergence_without_a_result(self) -> None:
        for expected, actual in [(valid_result(), None), (None, valid_result()), (None, None)]:
            with self.subTest(expected=expected is not None, actual=actual is not None):
                diagnostic = RUNNER.first_divergence(expected, actual)
                self.assertEqual(diagnostic["expected_present"], expected is not None)
                self.assertEqual(diagnostic["actual_present"], actual is not None)


class AbortAttribution(unittest.TestCase):
    # Value: the launcher must fail the case the engine aborted, keep every other
    # case's record and keep the two repetitions comparable.
    def error(self) -> list[dict]:
        return [{"suite": "res://suite.gd", "case": "pass", "file": "res://suite.gd",
                 "line": 12, "message": "boom"}]

    def test_abort_fails_only_the_aborted_case(self) -> None:
        result = valid_result()
        result["records"].append(copy.deepcopy(result["records"][0]))
        result["records"][1]["case"] = "other"
        result["count"] = 2
        amended, aborted = RUNNER.apply_aborts(result, self.error())
        self.assertTrue(aborted)
        self.assertIs(amended["passed"], False)
        self.assertEqual(amended["records"][0]["runs"][0]["failures"][0]["kind"], "case_aborted")
        self.assertEqual(amended["records"][0]["runs"][0]["failures"][0]["case"], "pass")
        self.assertEqual(amended["records"][1]["runs"][0]["failures"], [])
        self.assertEqual(amended["errors"][0]["kind"], "case_aborted")
        self.assertEqual(amended["errors"][0]["case"], "pass")

    def test_abort_keeps_the_repetitions_comparable(self) -> None:
        # Both repetitions died at the same point: they stay equal, so the abort
        # does not manufacture a divergence.
        amended, aborted = RUNNER.apply_aborts(valid_result(), self.error())
        self.assertTrue(aborted)
        self.assertEqual(amended["records"][0]["runs"][0], amended["records"][0]["runs"][1])
        # One repetition died: the difference between the repetitions stays visible
        # and the repetition that reached the end keeps its own verdict.
        result = valid_result()
        result["records"][0]["runs"][0]["assertions"] = 5
        result["records"][0]["runs"][1]["assertions"] = 9
        amended, aborted = RUNNER.apply_aborts(result, self.error())
        self.assertTrue(aborted)
        self.assertEqual(amended["records"][0]["runs"][0]["failures"][0]["kind"], "case_aborted")
        self.assertEqual(amended["records"][0]["runs"][1]["failures"], [])
        self.assertNotEqual(amended["records"][0]["runs"][0], amended["records"][0]["runs"][1])

    # Value: an error the engine reported outside a case has no case to fail, so
    # the launcher keeps the reason and does not invent a case.
    def test_unattributed_error_names_no_case(self) -> None:
        amended, aborted = RUNNER.apply_aborts(valid_result(), [
            {"suite": None, "case": None, "file": "res://suite.gd", "line": 12, "message": "boom"}])
        self.assertFalse(aborted)
        self.assertEqual(amended["records"][0]["runs"][0]["failures"], [])
        self.assertEqual(amended["errors"], [])


class ReceiptControls(unittest.TestCase):
    # Value: a failed new engine probe must supersede prior success, including
    # before the external executable gets control and when its bytes are invalid.
    def test_failed_version_probe_cannot_preserve_success(self) -> None:
        for output, exit_code, failure in [(b'4.3.stable\xff', 0, 'invalid_utf8_version_output'),
                                           (b'probe failed', 7, 'version_probe_failed')]:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory) / 'receipt.json'
                observed = Path(directory) / 'observed.json'
                receipt.write_text('{"passed":true}')
                engine = Path(directory) / 'engine'
                engine.write_text('#!' + sys.executable + '\nimport json,pathlib,sys\n'
                                  + f'pathlib.Path({str(observed)!r}).write_text(json.dumps(json.loads(pathlib.Path({str(receipt)!r}).read_text())["passed"]))\n'
                                  + f'sys.stdout.buffer.write({output!r})\nsys.exit({exit_code})\n')
                engine.chmod(0o755)
                self.assertEqual(RUNNER.main(['--godot', str(engine), '--results', str(receipt)]), 1)
                report = json.loads(receipt.read_text())
                self.assertIs(report['passed'], False)
                self.assertIs(json.loads(observed.read_text()), False, 'prior success visible during version probe')
                self.assertEqual(report['failure'], failure)
                self.assertEqual(report['version_probe']['stdout'], output.decode(errors='replace'))

    # Value: a rejected attempt must not leave an earlier pass at the results it names; help writes nothing.
    def test_rejected_arguments_invalidate_selected_results(self) -> None:
        for arguments, invalidated in [(['--category', 'bogus'], True), (['--timeout', '-1'], True), (['--jobs', '0'], True),
                                       (['--seed', str(2**63)], True), (['--bogus'], True), (['--help'], False)]:
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory) / 'receipt.json'
                receipt.write_text('{"passed":true}')
                process = subprocess.run([sys.executable, str(ROOT / 'scripts/run_godot_tests.py'), '--godot', 'unused',
                                          f'--results={receipt}', *arguments], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(process.returncode, 2 if invalidated else 0, process.stderr)
                self.assertEqual(json.loads(receipt.read_text())['passed'], not invalidated)

    def test_malformed_engine_stream_is_a_captured_failure(self) -> None:
        result = RUNNER.invoke([sys.executable, '-c', "import sys;sys.stdout.buffer.write(b'bad\\xff')"], 10)
        self.assertEqual(result.get('failure'), 'invalid_utf8_output', result)
        self.assertEqual(result['stdout'], 'bad\ufffd')

    # Value: a timeout must leave no process behind. The engine runs in its own
    # process group, so the host kills the whole group and no child of the
    # engine can outlive the run that named it.
    def test_watchdog_kills_the_whole_process_group(self) -> None:
        if not hasattr(os, 'killpg'):
            self.skipTest("this platform has no process groups")
        result = RUNNER.invoke([sys.executable, '-c', "import time;time.sleep(30)"], 1)
        self.assertEqual(result.get('failure'), 'watchdog', result)
        group = result.get('process_group')
        self.assertIsInstance(group, int)
        with self.assertRaises(ProcessLookupError):
            os.killpg(group, 0)

    # Value: a process that escapes the group still holds the output pipe open.
    # The watchdog must report the failure instead of waiting for that pipe.
    def test_watchdog_reports_promptly_when_a_process_escapes_the_group(self) -> None:
        if not hasattr(os, 'killpg'):
            self.skipTest("this platform has no process groups")
        escape = ("import subprocess,sys,time;"
                  "subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'],start_new_session=True);"
                  "time.sleep(120)")
        started = time.monotonic()
        result = RUNNER.invoke([sys.executable, '-c', escape], 1)
        elapsed = time.monotonic() - started
        self.assertEqual(result.get('failure'), 'watchdog', result)
        self.assertLess(elapsed, 20, f"the watchdog waited {elapsed:.1f}s for an escaped process")


class EngineControls(unittest.TestCase):
    def setUp(self) -> None:
        if GODOT is None:
            self.skipTest("pass --godot to execute real engine controls")

    def command(self, script: str = "res://tests/runner/run_tests.gd", *args: str) -> list[str]:
        return [str(GODOT), "--headless", "--path", str(ROOT), "--script", script, "--", *args]

    def engine_result(self, script: str, *args: str) -> tuple[dict, dict]:
        """Run the engine directly and return its result record and its watch record."""
        process = subprocess.run(self.command(script, *args), cwd=ROOT, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=30)
        text = process.stdout.decode("utf-8", errors="replace")
        result: dict = {}
        watch: dict = {}
        for line in text.splitlines():
            if line.startswith("FORTRESS_TEST_RESULT "):
                result = json.loads(line[len("FORTRESS_TEST_RESULT "):])
            elif line.startswith("FORTRESS_TEST_ABORT_WATCH "):
                watch = json.loads(line[len("FORTRESS_TEST_ABORT_WATCH "):])
        self.assertTrue(result, text)
        return result, watch

    # Value: the engine result itself must report an aborted case as failed, so a
    # reader of the engine output never sees a green aborted case. Godot 4.3 has
    # no logger, so the runner supervises a child and reports the abort from the
    # child's merged output instead of leaving the verdict to the launcher.
    def test_engine_result_reports_the_aborted_case(self) -> None:
        result, watch = self.engine_result(
            "res://tests/runner/run_tests.gd", "--suite",
            "res://tests/runner-controls/control_suite.gd", "--filter", "nested_abort")
        self.assertEqual(result["count"], 1)
        self.assertTrue(watch.get("available"), watch)
        self.assertEqual(watch.get("errors"), 2, watch)
        self.assertIs(result["passed"], False)
        self.assertEqual(len(result["errors"]), 1, result)
        entry = result["errors"][0]
        self.assertEqual(entry["kind"], "case_aborted")
        self.assertEqual(entry["case"], "nested_abort")
        self.assertEqual(entry["suite"], "res://tests/runner-controls/control_suite.gd")
        self.assertEqual(entry["file"], "res://tests/runner-controls/control_suite.gd")
        self.assertIsInstance(entry["line"], int)
        self.assertIn("Out of bounds", entry["message"])
        self.assertEqual(entry["aborts"], 2)
        for run in result["records"][0]["runs"]:
            self.assertEqual(run["failures"][0]["kind"], "case_aborted")

    # Value: an aborted case must not erase the other cases' records: the engine
    # result keeps every case and names the one that died.
    def test_engine_result_keeps_the_other_cases(self) -> None:
        result, watch = self.engine_result(
            "res://tests/runner/run_tests.gd", "--suite", "res://tests/runner-controls/control_suite.gd",
            "--case", "nested_abort", "--case", "pass")
        records = {record["case"]: record for record in result["records"]}
        self.assertEqual(result["count"], 2)
        self.assertEqual(records["pass"]["runs"][0]["failures"], [])
        self.assertEqual(records["pass"]["runs"][1]["failures"], [])
        self.assertTrue(watch.get("available"), watch)
        self.assertEqual(records["nested_abort"]["runs"][0]["failures"][0]["kind"], "case_aborted")

    # Value: guards false-green on real engine errors/partial completion and checks
    # failure reason, so watchdog/parse errors cannot masquerade as assertion red.
    def test_controls(self) -> None:
        cases = [
            ("pass", None), ("fail", "test_failure"),
            ("incomplete", "test_failure"), ("uncaught", "case_aborted"),
            ("after_completion_error", "case_aborted"), ("nested_abort", "case_aborted"),
            ("static_leak", "test_failure"), ("watchdog", "watchdog"),
        ]
        for case, failure in cases:
            with self.subTest(case=case):
                result = RUNNER.invoke(self.command(
                    "res://tests/runner/run_tests.gd", "--suite",
                    "res://tests/runner-controls/control_suite.gd", "--filter", case),
                    2 if case == "watchdog" else 10)
                self.assertEqual(result.get("failure"), failure, result)
                if case == "watchdog":
                    self.assertIn("FORTRESS_WATCHDOG_ENTERED", result["stdout"])
                if case == "fail":
                    self.assertEqual(result["result"]["records"][0]["runs"][0]["failures"][0],
                                     {"kind": "bytes", "label": "known fail", "frame": 7,
                                      "byte": 1, "expected": "0102", "actual": "0109"})
                if case == "incomplete":
                    self.assertEqual(result["result"]["records"][0]["runs"][0]["failures"],
                                     [{"kind": "incomplete_case"}])
                if case in ("uncaught", "after_completion_error", "nested_abort"):
                    # The host fails the case and names the case, the suite, the
                    # aborting line and the message. The engine itself never
                    # reports the case as passed when the abort came before its
                    # last assertion, so the entry is the only failure of the case.
                    self.assertIs(result["result"]["passed"], False)
                    failure = result["result"]["records"][0]["runs"][0]["failures"][-1]
                    self.assertEqual(failure["kind"], "case_aborted")
                    self.assertEqual(failure["suite"], "res://tests/runner-controls/control_suite.gd")
                    self.assertEqual(failure["case"], case)
                    self.assertEqual(failure["file"], "res://tests/runner-controls/control_suite.gd")
                    self.assertIsInstance(failure["line"], int)
                    self.assertIn("Out of bounds", failure["message"])
                if case in ("after_completion_error", "nested_abort"):
                    # The engine reported this case as passed; the host's entry is
                    # the only failure of the case, so the case cannot pass quietly.
                    self.assertEqual(len(result["result"]["records"][0]["runs"][0]["failures"]), 1, result)
                    self.assertEqual(result["result"]["records"][0]["runs"][0]["failures"][0]["kind"], "case_aborted")
        cases = [
            (["--suite", "res://tests/runner-controls/parse_error.gd"], "engine_error"),
            (["--suite", "res://tests/runner-controls/absent.gd"], "test_failure"),
            (["--filter", "no-such-case"], "test_failure"),
        ]
        for arguments, failure in cases:
            with self.subTest(arguments=arguments):
                result = RUNNER.invoke(self.command("res://tests/runner/run_tests.gd", *arguments), 10)
                self.assertEqual(result.get("failure"), failure, result)
        result = RUNNER.invoke(self.command("res://tests/runner-controls/missing_completion.gd"), 10)
        self.assertEqual(result.get("failure"), "missing_or_duplicate_completion", result)

    # Value: an aborted case must not erase the other cases' records: the receipt
    # keeps every case and names the one that died.
    def test_aborted_case_keeps_the_other_records(self) -> None:
        result = RUNNER.invoke(self.command(
            "res://tests/runner/run_tests.gd", "--suite",
            "res://tests/runner-controls/control_suite.gd", "--case", "nested_abort", "--case", "pass"), 10)
        self.assertEqual(result.get("failure"), "case_aborted", result)
        self.assertIs(result["result"]["passed"], False)
        self.assertEqual(result["result"]["count"], 2)
        records = {record["case"]: record for record in result["result"]["records"]}
        self.assertEqual(records["pass"]["runs"][0]["failures"], [])
        self.assertEqual(records["pass"]["runs"][1]["failures"], [])
        self.assertEqual(records["nested_abort"]["runs"][0]["failures"][0]["kind"], "case_aborted")
        self.assertEqual(records["nested_abort"]["runs"][1]["failures"][0]["kind"], "case_aborted")

    # Value: the receipt of a run with an aborted case must fail with a reason a
    # reader can act on, and must name the case, the suite and the aborting line.
    def test_receipt_fails_with_the_aborted_case(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "aborted.json"
            process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"), "--godot", str(GODOT),
                "--suite", "res://tests/runner-controls/control_suite.gd", "--filter", "nested_abort",
                "--results", str(output), "--durations", str(Path(directory) / "durations.json")],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
            report = json.loads(output.read_text())
            self.assertIs(report["passed"], False)
            for run in report["runs"]:
                self.assertEqual(run["failure"], "case_aborted")
                self.assertIs(run["result"]["passed"], False)
                entry = run["result"]["errors"][0]
                self.assertEqual(entry["kind"], "case_aborted")
                self.assertEqual(entry["case"], "nested_abort")
                self.assertEqual(entry["suite"], "res://tests/runner-controls/control_suite.gd")
                self.assertIsInstance(entry["line"], int)
                # The case aborts in both in-process repetitions, so the engine
                # printed two reports for it.
                self.assertEqual(entry["aborts"], 2, entry)
            # The two fresh processes must agree on the failed run.
            self.assertEqual(report["runs"][0]["result"], report["runs"][1]["result"])

    def test_fresh_process_repeat_and_categories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for category in ("unit", "determinism", "integration"):
                with self.subTest(category=category):
                    output = Path(directory) / (category + ".json")
                    process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"),
                        "--godot", str(GODOT), "--category", category, "--suite",
                        "res://tests/runner/self_suite.gd", "--seed", "9223372036854775807",
                        "--results", str(output), "--durations", str(Path(directory) / "durations.json")], cwd=ROOT, capture_output=True, text=True)
                    self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                    report = json.loads(output.read_text())
                    self.assertTrue(report["passed"])
                    self.assertEqual(report["runs"][0]["result"], report["runs"][1]["result"])
                    self.assertEqual(report["runs"][0]["result"]["count"], 1)

    # Value: sharded runs must record exactly what one process records, so parallelism cannot
    # reorder, drop or duplicate cases. A filter must still fail when no suite matches.
    def test_sharded_runs_match_one_process(self) -> None:
        suites = ["--suite", "res://tests/unit/test_snapshot_history.gd", "--suite", "res://tests/runner/self_suite.gd"]
        cases = [("all", [], True), ("filtered", ["--filter", "fixture_reset"], True), ("unmatched", ["--filter", "no-such-case"], False)]
        with tempfile.TemporaryDirectory() as directory:
            # A recorded slow suite runs one process per case; its merged records must still match one process.
            slow = Path(directory) / "slow.json"
            slow.write_text(json.dumps({"res://tests/unit/test_snapshot_history.gd": 60}))
            for label, arguments, passed in cases:
                with self.subTest(case=label):
                    results = []
                    for jobs, durations in (("1", None), ("4", None), ("4", slow)):
                        output = Path(directory) / f"{label}-{jobs}-{durations is None}.json"
                        timing = Path(directory) / f"{label}-{jobs}-timing.json"
                        timing.write_bytes(slow.read_bytes() if durations else b"{}")
                        process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"), "--godot", str(GODOT),
                            *suites, *arguments, "--jobs", jobs, "--results", str(output), "--durations", str(timing)],
                            cwd=ROOT, capture_output=True, text=True)
                        self.assertEqual(process.returncode, 0 if passed else 1, process.stdout + process.stderr)
                        report = json.loads(output.read_text())
                        results.append(report["runs"][0].get("result"))
                        if durations and not arguments:
                            self.assertGreater(len(report["runs"][0]["shards"]), 2, "slow suite was not split by case")
                    self.assertEqual(results[0], results[1])
                    self.assertEqual(results[0], results[2])
                    if passed:
                        self.assertEqual(len({record["suite"] for record in results[0]["records"]}), 1 if arguments else 2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--godot", type=Path)
    args, remaining = parser.parse_known_args()
    GODOT = args.godot.resolve() if args.godot else None
    unittest.main(argv=[sys.argv[0], *remaining])
