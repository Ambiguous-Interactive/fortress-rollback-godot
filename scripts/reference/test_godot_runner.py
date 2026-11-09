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
from unittest.mock import patch

from python_fixture import write_executable

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


def process_live(path: Path) -> bool:
    try:
        return path.read_bytes().rsplit(b')', 1)[1].split()[0] not in (b'Z', b'X')
    except (FileNotFoundError, ProcessLookupError):
        return False


class CompletionContract(unittest.TestCase):
    # Value: protects=filtered execution retains broken suites; fails_when=partial/error listings skip tests; why_new=shard parity covers valid inventory; seam=none
    def test_case_inventory_requires_complete_error_free_output(self) -> None:
        suites = ["res://one.gd", "res://two.gd"]
        valid = {suites[0]: ["match"], suites[1]: ["other"]}
        cases = [
            (valid, "", 0, valid),
            ({suites[0]: ["match"]}, "", 0, {}),
            ({suites[0]: ["match"], suites[1]: []}, "", 0, {}),
            ({suites[0]: ["match"], suites[1]: ["other", "other"]}, "", 0, {}),
            ([], "", 0, {}),
            (valid, "SCRIPT ERROR: invalid suite", 0, {}),
            (valid, "", 1, {}),
        ]
        for inventory, error, status, expected in cases:
            with self.subTest(inventory=inventory, error=error, status=status):
                text = RUNNER.CASES_PREFIX + json.dumps(inventory)
                program = f"import sys; print({text!r}); print({error!r}); sys.exit({status})"
                self.assertEqual(RUNNER.case_inventory([sys.executable, '-c', program], suites, 5), expected)

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
    # Value: protects=cleanup observations with arbitrary process names; fails_when=proc comm requires UTF-8; why_new=ordinary process fixtures use ASCII; seam=proc inventory
    def test_cleanup_proc_names_do_not_require_utf8(self) -> None:
        if not Path('/proc').is_dir():
            self.skipTest('requires Linux proc observations')
        with tempfile.TemporaryDirectory() as directory:
            entry = Path(directory) / '123'
            entry.mkdir()
            rows = [
                (b'ordinary', b'S', 77, True),
                (b'name\xff', b'S', 77, True),
                (b'name) )\xff', b'R', 77, True),
                (b'name\xff', b'Z', 77, False),
                (b'name\xff', b'X', 77, False),
                (b'name)\xff', b'S', 78, False),
            ]
            for name, state, group, expected in rows:
                with self.subTest(name=name, state=state, group=group):
                    (entry / 'stat').write_bytes(b'123 (' + name + b') ' + state + b' 1 ' + str(group).encode('ascii') + b' 0')
                    with patch.object(RUNNER, '_group_exists', return_value=True), patch.object(Path, 'iterdir', return_value=iter([entry])):
                        self.assertIs(RUNNER._group_active(77), expected)
            for error in (FileNotFoundError(2, 'No such file'), ProcessLookupError(3, 'No such process')):
                with self.subTest(error=type(error).__name__), patch.object(RUNNER, '_group_exists', return_value=True), \
                        patch.object(Path, 'iterdir', return_value=iter([entry])), patch.object(Path, 'read_bytes', side_effect=error):
                    self.assertFalse(RUNNER._group_active(77))
            with patch.object(RUNNER, '_group_exists', return_value=True), patch.object(Path, 'iterdir', return_value=iter([entry])), \
                    patch.object(Path, 'read_bytes', side_effect=PermissionError(13, 'Permission denied')):
                with self.assertRaises(PermissionError):
                    RUNNER._group_active(77)

    # Value: protects=group observation errors; fails_when=inventory falls back after failed supervision; why_new=ESRCH controls miss other OS errors; seam=killpg zero probe
    def test_group_observation_errors_cannot_start_unsupervised_inventory(self) -> None:
        if not Path('/proc').is_dir() or not hasattr(os, 'killpg'):
            self.skipTest('requires Linux process-group observations')
        for error in (PermissionError(1, 'Operation not permitted'), OSError(5, 'Input/output error')):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as directory:
                pid_file = Path(directory) / 'child.pid'
                command = ("import pathlib,subprocess,sys;"
                           "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                           "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);"
                           f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid));"
                           "print('FORTRESS_TEST_CASES {\"res://suite.gd\":[\"one\",\"two\"]}')")
                killpg = os.killpg
                observed = [False]

                def fail_probe(group, signal):
                    if signal == 0 and not observed[0]:
                        observed[0] = True
                        raise error
                    return killpg(group, signal)

                try:
                    with patch.object(os, 'killpg', fail_probe):
                        with self.assertRaisesRegex(ValueError, '^case_list_descendants_after_exit$') as failure:
                            RUNNER.split_cases([sys.executable, '-c', command], ['res://suite.gd'], 5)
                    self.assertTrue(observed[0], 'group-observation error was not injected')
                    self.assertIs(failure.exception.report['cleanup_complete'], True)
                    self.assertIsInstance(failure.exception.report['process_group'], int)
                    self.assertFalse(process_live(Path('/proc') / pid_file.read_text() / 'stat'))
                finally:
                    if pid_file.exists():
                        try:
                            os.kill(int(pid_file.read_text()), 9)
                        except ProcessLookupError:
                            pass

    # Value: protects=exiting process observations; fails_when=stat disappears during read; why_new=live child schedules rarely expose the race; seam=proc stat read
    def test_process_stat_disappearance_is_not_a_live_child(self) -> None:
        path = Path('/proc/fixture/stat')
        for state in ('S', 'R', 'T', 'Z', 'X'):
            with self.subTest(state=state), patch.object(Path, 'read_bytes', return_value=f'123 (fixture) {state} 1 2 3'.encode('ascii')):
                self.assertEqual(process_live(path), state not in ('Z', 'X'))
        for error in (FileNotFoundError(2, 'No such file'), ProcessLookupError(3, 'No such process')):
            with self.subTest(error=type(error).__name__), patch.object(Path, 'read_bytes', side_effect=error):
                self.assertFalse(process_live(path))
        with patch.object(Path, 'read_bytes', side_effect=PermissionError(13, 'Permission denied')):
            with self.assertRaises(PermissionError):
                process_live(path)

    # Value: protects=failed inventory cleanup; fails_when=a wait failure falls back to ordinary shards; why_new=successful kill controls miss cleanup errors; seam=cleanup wait
    def test_case_listing_cleanup_failure_cannot_fall_back(self) -> None:
        kill_group = RUNNER._kill_group

        def fail_wait(process):
            kill_group(process)
            raise subprocess.TimeoutExpired('cleanup_wait', 5)

        with patch.object(RUNNER, '_kill_group', fail_wait):
            with self.assertRaisesRegex(ValueError, '^case_list_process_cleanup_failed$') as observed:
                RUNNER.split_cases([sys.executable, '-c', 'import time;time.sleep(30)'], ['res://suite.gd'], 0.05)
        report = observed.exception.report
        self.assertEqual(report['failure'], 'process_cleanup_failed')
        self.assertIsInstance(report['process_group'], int)
        self.assertIs(report['cleanup_complete'], False)

    # Value: protects=descendant replacement; fails_when=a new child survives completion; why_new=stationary children cannot expose churn; seam=group check order
    def test_descendant_replacement_cannot_hide_from_completion(self) -> None:
        self._replacement_completion(inventory_control=False)

    # Value: protects=group-gate control; fails_when=fixture never creates the missed child; why_new=production gate avoids proc enumeration; seam=inventory gate mutation
    def test_inventory_observation_can_miss_replacement(self) -> None:
        self._replacement_completion(inventory_control=True)

    def _replacement_completion(self, inventory_control: bool) -> None:
        if not Path('/proc').is_dir() or not hasattr(os, 'killpg'):
            self.skipTest('requires Linux process-group observations')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trigger, ready, leaf_pid, child_pid = [root / name for name in ('trigger', 'ready', 'leaf', 'child')]
            child_code = ("import pathlib,subprocess,sys,time\n"
                          f"trigger=pathlib.Path({str(trigger)!r})\n"
                          f"pathlib.Path({str(ready)!r}).touch()\n"
                          "while not trigger.exists(): time.sleep(0.001)\n"
                          "leaf=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])\n"
                          f"pathlib.Path({str(leaf_pid)!r}).write_text(str(leaf.pid))\n")
            parent_code = ("import pathlib,subprocess,sys,time\n"
                           f"child=subprocess.Popen([sys.executable,'-c',{child_code!r}],"
                           "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
                           f"pathlib.Path({str(child_pid)!r}).write_text(str(child.pid))\n"
                           f"ready=pathlib.Path({str(ready)!r})\n"
                           "while not ready.exists(): time.sleep(0.001)\n"
                           f"print({(RUNNER.PREFIX + json.dumps(valid_result()))!r})\n")
            iterdir = Path.iterdir
            group_exists = RUNNER._group_exists
            ordered = [False]
            expected_group = [None]

            def replace_child():
                if ordered[0]:
                    return
                ordered[0] = True
                process_state = Path('/proc') / child_pid.read_text() / 'stat'
                self.assertTrue(process_live(process_state), 'replacement fixture parent exited too soon')
                trigger.touch()
                deadline = time.monotonic() + 5
                while (not leaf_pid.exists() or process_live(process_state)) and time.monotonic() < deadline:
                    time.sleep(0.001)
                self.assertTrue(leaf_pid.exists(), 'replacement fixture did not fork')
                self.assertFalse(process_live(process_state), 'replacement fixture parent did not exit')
                self.assertEqual(os.getpgid(int(leaf_pid.read_text())), expected_group[0], 'replacement escaped the owned group')

            def observe_inventory(path: Path):
                entries = list(iterdir(path))
                if path == Path('/proc'):
                    replace_child()
                return iter(entries)

            def observe_group(group: int):
                expected_group[0] = group
                if inventory_control:
                    with patch.object(RUNNER, '_group_exists', group_exists):
                        return RUNNER._group_active(group)
                replace_child()
                return group_exists(group)

            try:
                with patch.object(RUNNER, '_group_exists', observe_group):
                    if inventory_control:
                        with patch.object(Path, 'iterdir', observe_inventory):
                            result = RUNNER.invoke([sys.executable, '-c', parent_code], 5)
                    else:
                        result = RUNNER.invoke([sys.executable, '-c', parent_code], 5)
                self.assertTrue(ordered[0], 'replacement ordering hook did not execute')
                self.assertTrue(leaf_pid.exists(), 'replacement fixture did not fork')
                leaf_state = Path('/proc') / leaf_pid.read_text() / 'stat'
                if inventory_control:
                    self.assertNotIn('failure', result)
                    self.assertIs(result['result']['passed'], True)
                    self.assertTrue(process_live(leaf_state), 'inventory control did not expose a surviving replacement')
                else:
                    self.assertEqual(result.get('failure'), 'descendants_after_exit', result)
                    self.assertIs(result['cleanup_complete'], True)
                    self.assertFalse(process_live(leaf_state), 'owned replacement survived completion')
            finally:
                for identity in (child_pid, leaf_pid):
                    if identity.exists():
                        try:
                            os.kill(int(identity.read_text()), 9)
                        except ProcessLookupError:
                            pass

    # Value: protects=completed receipt child lifetime; fails_when=redirected child outlives a passing parent; why_new=watchdogs cover only live parents; seam=real Python child
    def test_completed_parent_cannot_leave_owned_children(self) -> None:
        if not Path('/proc').is_dir() or not hasattr(os, 'killpg'):
            self.skipTest('requires Linux process-group observations')
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / 'child.pid'
            script = ("import pathlib,subprocess,sys;"
                      "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                      "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);"
                      f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid));"
                      f"print({(RUNNER.PREFIX + json.dumps(valid_result()))!r})")
            try:
                result = RUNNER.invoke([sys.executable, '-c', script], 5)
                self.assertEqual(result.get('failure'), 'descendants_after_exit', result)
                child = int(pid_file.read_text())
                state = Path(f'/proc/{child}/stat')
                self.assertTrue(not process_live(state),
                                'owned child remains executable after receipt completion')
            finally:
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), 9)
                    except ProcessLookupError:
                        pass

    # Value: protects=inventory loading has its own budget; fails_when=combined discovery consumes a shard timeout; why_new=fast listings hide the regression; seam=scripted engine
    def test_filtered_inventory_has_independent_budget(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / 'engine'
            inventory = {'res://suite.gd': ['pass'], 'res://unmatched.gd': ['other']}
            slow_execution = Path(directory) / 'slow-execution'
            program = ("import json,pathlib,sys,time\n"
                       "if '--version' in sys.argv: print('test-engine');sys.exit(0)\n"
                       "if '--list-cases' in sys.argv:\n time.sleep(2)\n"
                       f" print('FORTRESS_TEST_CASES '+{json.dumps(json.dumps(inventory))})\n sys.exit(0)\n"
                       f"if pathlib.Path({str(slow_execution)!r}).exists(): time.sleep(2)\n"
                       f"print('FORTRESS_TEST_RESULT '+{json.dumps(json.dumps(valid_result()))})\n")
            write_executable(engine, program)
            receipt = Path(directory) / 'receipt.json'
            arguments = ['--godot', str(engine), '--results', str(receipt), '--jobs', '2', '--timeout', '1',
                         '--suite', 'res://suite.gd', '--suite', 'res://unmatched.gd', '--filter', 'pass']
            self.assertEqual(RUNNER.main(arguments), 0, json.loads(receipt.read_text()).get('failure'))
            self.assertTrue(json.loads(receipt.read_text())['passed'])
            self.assertEqual(RUNNER.main(arguments + ['--inventory-timeout', '1']), 1)
            report = json.loads(receipt.read_text())
            self.assertEqual(report['failure'], 'case_list_watchdog')
            self.assertIs(report['passed'], False)
            slow_execution.touch()
            self.assertEqual(RUNNER.main(arguments), 1)
            report = json.loads(receipt.read_text())
            self.assertIs(report['passed'], False)
            for run in report['runs']:
                self.assertEqual(run['failure'], 'watchdog')
                self.assertTrue(all(shard['cleanup_complete'] for shard in run['shards']))

    # Value: protects=fixture execution through spaced interpreter paths; fails_when=shebang splits paths or argv identity changes; why_new=ordinary Python paths hide it; seam=none
    def test_python_fixture_preserves_script_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            interpreter = root / "Python environment's interpreter"
            interpreter.symlink_to(sys.executable)
            engine = root / "engine fixture's script"
            program = "import json,sys;print(json.dumps([__file__,sys.argv]))"
            write_executable(engine, program, str(interpreter))
            arguments = ['argument with spaces', '$(literal)']
            alias = root / "alias's script"
            alias.symlink_to(engine)
            for invocation in [str(engine), "./" + engine.name, str(alias)]:
                with self.subTest(invocation=invocation):
                    process = subprocess.run([invocation, *arguments], cwd=root, capture_output=True, text=True, check=True, timeout=5)
                    filename = invocation if Path(invocation).is_absolute() else str(root) + "/" + invocation
                    self.assertEqual(json.loads(process.stdout), [filename, [invocation, *arguments]])

    # Value: protects=probe lifetime ownership; fails_when=version/list probes accept live children; why_new=execution supervision does not cover discovery; seam=real Python child
    def test_probe_children_are_rejected_and_stopped(self) -> None:
        if not Path('/proc').is_dir() or not hasattr(os, 'killpg'):
            self.skipTest('requires Linux process-group observations')
        for phase in ('version', 'case_list'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                pid_file = Path(directory) / 'child.pid'
                engine = Path(directory) / 'engine'
                write_executable(engine, 'import pathlib,subprocess,sys\n'
                                  + ("if '--version' in sys.argv: print('test-engine');sys.exit(0)\n" if phase == 'case_list' else '')
                                  +
                                  "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                                  "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
                                  f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid))\n"
                                  "print('test-engine' if '--version' in sys.argv else 'FORTRESS_TEST_CASES {}')\n")
                try:
                    if phase == 'version':
                        receipt = Path(directory) / 'receipt.json'
                        receipt.write_text('{"passed":true}')
                        self.assertEqual(RUNNER.main(['--godot', str(engine), '--results', str(receipt)]), 1)
                        report = json.loads(receipt.read_text())
                        self.assertIs(report['passed'], False)
                        self.assertEqual(report['failure'], 'descendants_after_exit')
                        self.assertIs(report['version_probe']['cleanup_complete'], True)
                    else:
                        with self.assertRaisesRegex(ValueError, '^case_list_descendants_after_exit$'):
                            RUNNER.split_cases([str(engine)], ['res://suite.gd'], 5)
                        receipt = Path(directory) / 'receipt.json'
                        durations = Path(directory) / 'durations.json'
                        durations.write_text(json.dumps({'res://suite.gd': 40}))
                        receipt.write_text('{"passed":true}')
                        self.assertEqual(RUNNER.main(['--godot', str(engine), '--results', str(receipt), '--suite', 'res://suite.gd',
                                                      '--jobs', '2', '--durations', str(durations)]), 1)
                        report = json.loads(receipt.read_text())
                        self.assertIs(report['passed'], False)
                        self.assertEqual(report['failure'], 'case_list_descendants_after_exit')
                        self.assertIsInstance(report['case_list_probe']['process_group'], int)
                        self.assertIs(report['case_list_probe']['cleanup_complete'], True)
                        self.assertNotIn('runs', report, 'failed inventory cleanup must not start ordinary runs')
                    child = int(pid_file.read_text())
                    state = Path(f'/proc/{child}/stat')
                    self.assertTrue(not process_live(state))
                finally:
                    if pid_file.exists():
                        try:
                            os.kill(int(pid_file.read_text()), 9)
                        except ProcessLookupError:
                            pass

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
                write_executable(engine, 'import json,pathlib,sys\n'
                                  + f'pathlib.Path({str(observed)!r}).write_text(json.dumps(json.loads(pathlib.Path({str(receipt)!r}).read_text())["passed"]))\n'
                                  + f'sys.stdout.buffer.write({output!r})\nsys.exit({exit_code})\n')
                self.assertEqual(RUNNER.main(['--godot', str(engine), '--results', str(receipt)]), 1)
                report = json.loads(receipt.read_text())
                self.assertIs(report['passed'], False)
                self.assertIs(json.loads(observed.read_text()), False, 'prior success visible during version probe')
                self.assertEqual(report['failure'], failure)
                self.assertEqual(report['version_probe']['stdout'], output.decode(errors='replace'))

    # Value: a rejected attempt must not leave an earlier pass at the results it names; help writes nothing.
    def test_rejected_arguments_invalidate_selected_results(self) -> None:
        for arguments, invalidated in [(['--category', 'bogus'], True), (['--timeout', '-1'], True), (['--inventory-timeout', '0'], True),
                                       (['--inventory-timeout', 'nan'], True), (['--inventory-timeout', 'inf'], True), (['--jobs', '0'], True),
                                       (['--host-wait', '-1'], True), (['--host-wait', 'nan'], True), (['--host-wait', 'inf'], True),
                                       (['--seed', str(2**63)], True), (['--bogus'], True), (['--help'], False),
                                       (['--shard', '3of2'], True), (['--shard', 'x/y'], True), (['--shard', '1of2', '--jobs', '1'], True),
                                       (['--shard', '1of2', '--filter', 'x'], True)]:
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
                  "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'],start_new_session=True);"
                  "print(child.pid,flush=True);time.sleep(120)")
        started = time.monotonic()
        result = RUNNER.invoke([sys.executable, '-c', escape], 1)
        try:
            elapsed = time.monotonic() - started
            self.assertEqual(result.get('failure'), 'watchdog', result)
            self.assertLess(elapsed, 20, f"the watchdog waited {elapsed:.1f}s for an escaped process")
        finally:
            # The fixture deliberately escapes ownership; its test still owns cleanup.
            if result['stdout'].strip():
                try:
                    os.kill(int(result['stdout'].strip()), 9)
                except ProcessLookupError:
                    pass


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
            (["--suite", "res://tests/runner-controls/control_suite.gd", "--filter", "no-such-case"], "test_failure"),
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
                        launches = Path(directory) / "launches.jsonl"
                        launches.write_text("")
                        engine = Path(directory) / "engine"
                        write_executable(engine, "import json,os,sys\n" +
                                          f"with open({str(launches)!r}, 'a') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')\n" +
                                          f"os.execv({str(GODOT)!r}, [{str(GODOT)!r}, *sys.argv[1:]])\n")
                        process = subprocess.run([sys.executable, str(ROOT / "scripts/run_godot_tests.py"), "--godot", str(engine),
                            *suites, *arguments, "--jobs", jobs, "--results", str(output), "--durations", str(timing)],
                            cwd=ROOT, capture_output=True, text=True)
                        self.assertEqual(process.returncode, 0 if passed else 1, process.stdout + process.stderr)
                        report = json.loads(output.read_text())
                        results.append(report["runs"][0].get("result"))
                        if label == "filtered" and jobs == "4":
                            executions = [json.loads(line) for line in launches.read_text().splitlines()]
                            executions = [command for command in executions if "--suite" in command and "--list-cases" not in command]
                            self.assertEqual(len(executions), 2, "filter launched a nonmatching suite")
                            self.assertTrue(all("res://tests/runner/self_suite.gd" in command for command in executions))
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
