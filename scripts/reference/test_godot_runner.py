"""Runner negative controls at the engine boundary; stdlib only."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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

    def test_malformed_engine_stream_is_a_captured_failure(self) -> None:
        result = RUNNER.invoke([sys.executable, '-c', "import sys;sys.stdout.buffer.write(b'bad\\xff')"], 10)
        self.assertEqual(result.get('failure'), 'invalid_utf8_output', result)
        self.assertEqual(result['stdout'], 'bad\ufffd')


class EngineControls(unittest.TestCase):
    def setUp(self) -> None:
        if GODOT is None:
            self.skipTest("pass --godot to execute real engine controls")

    def command(self, script: str = "res://tests/runner/run_tests.gd", *args: str) -> list[str]:
        return [str(GODOT), "--headless", "--path", str(ROOT), "--script", script, "--", *args]

    # Value: guards false-green on real engine errors/partial completion and checks
    # failure reason, so watchdog/parse errors cannot masquerade as assertion red.
    def test_controls(self) -> None:
        cases = [
            ("pass", None), ("fail", "test_failure"),
            ("incomplete", "test_failure"), ("uncaught", "engine_error"),
            ("after_completion_error", "engine_error"),
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

    def test_fresh_process_repeat_and_categories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for category in ("unit", "determinism", "integration"):
                with self.subTest(category=category):
                    output = Path(directory) / (category + ".json")
                    process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"),
                        "--godot", str(GODOT), "--category", category, "--suite",
                        "res://tests/runner/self_suite.gd", "--seed", "9223372036854775807",
                        "--results", str(output)], cwd=ROOT, capture_output=True, text=True)
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
            for label, arguments, passed in cases:
                with self.subTest(case=label):
                    results = []
                    for jobs in ("1", "4"):
                        output = Path(directory) / f"{label}-{jobs}.json"
                        process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"), "--godot", str(GODOT),
                            *suites, *arguments, "--jobs", jobs, "--results", str(output)], cwd=ROOT, capture_output=True, text=True)
                        self.assertEqual(process.returncode, 0 if passed else 1, process.stdout + process.stderr)
                        results.append(json.loads(output.read_text())["runs"][0].get("result"))
                    self.assertEqual(results[0], results[1])
                    if passed:
                        self.assertEqual(len({record["suite"] for record in results[0]["records"]}), 1 if arguments else 2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--godot", type=Path)
    args, remaining = parser.parse_known_args()
    GODOT = args.godot.resolve() if args.godot else None
    unittest.main(argv=[sys.argv[0], *remaining])
