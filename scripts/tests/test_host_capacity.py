"""Self-test: the development host has one owner at a time.

The local test runner starts one process per suite and saturates the machine
on a many core host. A browser witness that runs at the same time then stops
delivering packets inside the two second production deadline, and its session
ends with `PROTOCOL_FAILED`. The host lock makes that ownership explicit:

* exactly one process holds the host, and the runner's wave runs serially
  while another owner holds it;
* a second owner cannot take the host while the first one holds it;
* the lock ends with its owner, so the host of a process that is gone never
  blocks the next probe;
* a process that holds the host does not wait for itself.
"""

import ast
import copy
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import host_capacity
import run_godot_tests

SCRIPTS = Path(__file__).resolve().parents[1]


class HostCapacityTest(unittest.TestCase):
    """The host lock, against a temporary lease directory."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = (host_capacity.LEASE_DIR, host_capacity.LEASE_FILE)
        host_capacity.LEASE_DIR = Path(self.directory.name)
        host_capacity.LEASE_FILE = host_capacity.LEASE_DIR / "host.lock"

    def tearDown(self):
        host_capacity.release()
        host_capacity.LEASE_DIR, host_capacity.LEASE_FILE = self.previous
        self.directory.cleanup()

    def hold_in_subprocess(self):
        """Start a process that takes the host and keeps it."""
        ready = Path(self.directory.name) / "ready"
        script = (
            "import sys, time, pathlib\n"
            f"sys.path.insert(0, {str(SCRIPTS)!r})\n"
            "import host_capacity\n"
            f"host_capacity.LEASE_DIR = pathlib.Path({str(self.directory.name)!r})\n"
            "host_capacity.LEASE_FILE = host_capacity.LEASE_DIR / 'host.lock'\n"
            "assert host_capacity.acquire('other')\n"
            f"pathlib.Path({str(ready)!r}).write_text('held')\n"
            "time.sleep(30)\n"
        )
        process = subprocess.Popen([sys.executable, "-c", script])
        deadline = time.time() + 10
        while not ready.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(ready.exists(), "the other owner did not take the host")
        return process

    # Value: a shared host serializes execution without merging known slow cases into one watchdog.
    def test_shared_host_keeps_slow_cases_isolated_with_one_worker(self):
        suite = "res://tests/unit/slow.gd"
        names = ["first", "second"]
        directory = Path(self.directory.name)
        durations, results = directory / "durations.json", directory / "results.json"
        durations.write_text(json.dumps({suite: 40}), encoding="utf-8")
        run_command = subprocess.run
        executor = run_godot_tests.ThreadPoolExecutor
        observed = []

        def command(command, **options):
            if "--list-cases" in command:
                self.assertIn(suite, command)
                return SimpleNamespace(returncode=0, stdout=run_godot_tests.CASES_PREFIX + json.dumps({suite: names}))
            if "--version" in command:
                return SimpleNamespace(returncode=0, stdout=b"test-engine", stderr=b"")
            return run_command(command, **options)

        def timed(command, timeout):
            observed.append((command, timeout))
            if "--case" not in command:
                return {"failure": "watchdog_expired"}, 40
            case = command[command.index("--case") + 1]
            state = {"assertions": 1, "failures": [], "states": [{"frame": 0, "bytes": "01"}]}
            record = {"suite": suite, "case": case, "category": "unit", "seed": "1701", "runs": [state, copy.deepcopy(state)]}
            return {"result": {"format": 1, "complete": True, "passed": True, "count": 1, "errors": [], "records": [record]}}, 20

        for owner_name in ("browser-witness", run_godot_tests.LEASE_NAME):
            observed.clear()
            host_capacity.LEASE_FILE.write_text(json.dumps({"name": owner_name}), encoding="utf-8")
            with host_capacity.LEASE_FILE.open("a+") as owner:
                fcntl.flock(owner.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(run_godot_tests, "resolve_engine", return_value=Path(sys.executable)), \
                        patch.object(run_godot_tests.subprocess, "run", side_effect=command), \
                        patch.object(run_godot_tests, "timed", side_effect=timed), \
                        patch.object(run_godot_tests, "ThreadPoolExecutor", wraps=executor) as pool:
                    status = run_godot_tests.main(["--godot", sys.executable, "--suite", suite, "--jobs", "8", "--timeout", "30",
                                                  "--durations", str(durations), "--results", str(results)])
                pool.assert_called_once_with(max_workers=1)
                self.assertEqual(host_capacity.holder(), owner_name)
            self.assertEqual(status, 0)
            self.assertEqual(len(observed), 4)
            self.assertTrue(all(timeout == 30 for command, timeout in observed))
            report = json.loads(results.read_text(encoding="utf-8"))
            self.assertTrue(report["passed"])
            for repetition in report["runs"]:
                self.assertEqual([record["case"] for record in repetition["result"]["records"]], names)

    def test_free_host_keeps_the_requested_worker_count(self):
        self.assertIsNone(host_capacity.holder())
        self.assertEqual(host_capacity.worker_count(16), 16)
        self.assertEqual(host_capacity.worker_count(1), 1)

    def test_owner_names_itself_and_gives_the_host_back(self):
        self.assertTrue(host_capacity.acquire("godot-tests"))
        self.assertEqual(host_capacity.holder(), "godot-tests")
        self.assertEqual(host_capacity.worker_count(16), 16)
        host_capacity.release()
        self.assertIsNone(host_capacity.holder())
        self.assertEqual(host_capacity.worker_count(16), 16)

    def test_another_owner_cannot_take_the_host(self):
        owner = self.hold_in_subprocess()
        try:
            self.assertEqual(host_capacity.holder(), "other")
            self.assertFalse(host_capacity.acquire("godot-tests"))
            self.assertEqual(host_capacity.worker_count(16), 1)
            self.assertFalse(host_capacity.wait_for_free(0.0))
            self.assertFalse(host_capacity.acquire_when_free("godot-tests", 0.0))
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_the_lock_ends_with_its_owner(self):
        owner = self.hold_in_subprocess()
        owner.terminate()
        owner.wait(timeout=10)
        # The operating system released the lock, so the host is free again.
        self.assertIsNone(host_capacity.holder())
        self.assertTrue(host_capacity.acquire("godot-tests"))

    def test_own_host_does_not_make_the_process_wait(self):
        self.assertTrue(host_capacity.acquire("online-witness"))
        self.assertTrue(host_capacity.wait_for_free(0.0))
        self.assertTrue(host_capacity.acquire("online-witness"))
        self.assertTrue(host_capacity.acquire_when_free("online-witness", 0.0))

    def test_wait_for_free_returns_when_the_host_is_free(self):
        self.assertTrue(host_capacity.wait_for_free(0.0))
        self.assertTrue(host_capacity.acquire_when_free("online-witness", 0.0))
        self.assertEqual(host_capacity.holder(), "online-witness")

    def test_worker_count_rejects_a_non_positive_request(self):
        with self.assertRaises(ValueError):
            host_capacity.worker_count(0)

    def test_the_lock_lives_in_the_machine_local_cache(self):
        default = self.previous[0]
        self.assertEqual(default.parent.name, ".cache")
        self.assertTrue(default.is_relative_to(SCRIPTS.parent / ".cache"))


class HostSensitiveLauncherTest(unittest.TestCase):
    """Every probe that needs a responsive host takes the host lease.

    A launcher that runs a browser witness or a parallel engine wave can be
    starved by a concurrent local test wave, so it waits for a free host and
    then holds it. The wiring is otherwise invisible: a later refactor could
    drop the lease and the probe would only fail as a flaky timeout, so this
    locks the call, the bounded wait and the lease name into the source.
    """

    LEASED = ('scripts/reference/signalfish_live_probe.py', 'scripts/reference/signalfish_webrtc_probe.py',
              'scripts/reference/ownership_probes.py', 'scripts/reference/online_example_probe.py')

    @staticmethod
    def _calls(source, attribute):
        """Every named host_capacity call in a module's source, in order."""
        tree = ast.parse(source)
        return [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute) and node.func.attr == attribute]

    def test_each_host_sensitive_launcher_waits_for_the_host(self):
        for relative in self.LEASED:
            with self.subTest(launcher=relative):
                source = (SCRIPTS.parent / relative).read_text(encoding='utf-8')
                self.assertTrue(self._calls(source, 'acquire_when_free'), f'{relative} no longer takes the host lease')

    def test_each_lease_names_its_owner_and_bounds_the_wait(self):
        # The wait must be bounded: an unbounded probe would hang the build
        # forever instead of failing with a diagnosis.
        for relative in self.LEASED:
            with self.subTest(launcher=relative):
                source = (SCRIPTS.parent / relative).read_text(encoding='utf-8')
                for call in self._calls(source, 'acquire_when_free'):
                    self.assertEqual(len(call.args), 2, f'{relative} passes a name and a wait budget')
                    name, timeout = call.args
                    self.assertIsInstance(name, (ast.Constant, ast.Name), f'{relative} names its owner')
                    if isinstance(name, ast.Constant):
                        self.assertTrue(name.value, f'{relative} names its owner')
                    self.assertIsInstance(timeout, (ast.Constant, ast.Name), f'{relative} bounds its wait')
                    if isinstance(timeout, ast.Constant):
                        self.assertGreater(timeout.value, 0, f'{relative} waits a positive time')
                    self.assertFalse(call.keywords, f'{relative} passes the name and budget positionally')

    def test_the_local_runner_takes_the_host_without_waiting(self):
        # The runner must never block on the host: it takes it when free and
        # runs serially otherwise, so it takes it with the non-waiting call.
        source = (SCRIPTS.parent / 'scripts/run_godot_tests.py').read_text(encoding='utf-8')
        self.assertTrue(self._calls(source, 'acquire'), 'the local runner no longer takes the host')
        self.assertFalse(self._calls(source, 'acquire_when_free'), 'the local runner must not wait for the host')

    def test_the_transport_witness_leases_after_cheap_argument_checks(self):
        # A rejected invocation (an unknown pin, a bad --version) must fail
        # fast, not wait for a busy host, so the lease call comes after the
        # version validation in the transport witness.
        source = (SCRIPTS.parent / 'scripts/reference/signalfish_webrtc_probe.py').read_text(encoding='utf-8')
        tree = ast.parse(source)
        acquire = self._calls(source, 'acquire_when_free')[0]
        rejections = [node for node in ast.walk(tree) if isinstance(node, ast.Raise)
                      and isinstance(node.exc, ast.Call) and isinstance(node.exc.func, ast.Name) and node.exc.func.id == 'ValueError'
                      and any(isinstance(arg, ast.Constant) and 'pinned engine versions' in str(arg.value) for arg in node.exc.args)]
        self.assertEqual(len(rejections), 1, 'the version rejection stays in the transport witness')
        self.assertLess(rejections[0].lineno, acquire.lineno, 'the version check must run before the host wait')




if __name__ == "__main__":
    unittest.main()
