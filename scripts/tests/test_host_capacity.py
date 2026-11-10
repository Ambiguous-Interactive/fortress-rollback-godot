"""Self-test: the development host has one owner at a time.

The local test runner starts one process per suite and saturates the machine
on a many core host. A browser witness that runs at the same time then stops
delivering packets inside the two second production deadline, and its session
ends with `PROTOCOL_FAILED`. The host lock makes that ownership explicit:

* exactly one process holds the host, and the runner waits before engine
  execution while another owner holds it;
* a second owner cannot take the host while the first one holds it;
* the lock ends with its owner, so the host of a process that is gone never
  blocks the next probe;
* a process that holds the host does not wait for itself;
* a probe wave's children inherit their wave owner's lease only while that
  exact owner — name and pid — still holds it.
"""

import ast
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import host_capacity

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

    # Value: a probe wave takes the host once; its children must inherit that
    # ownership without contending with their own wave or releasing it early.
    def test_wave_child_acquires_at_once_while_the_named_owner_holds(self):
        owner = self.hold_in_subprocess()
        try:
            self.assertEqual(host_capacity.holder(), "other")
            started = time.time()
            with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: f"other:{owner.pid}"}):
                self.assertTrue(host_capacity.acquire("wave-child"))
                self.assertTrue(host_capacity.wait_for_free(0.0))
                self.assertTrue(host_capacity.acquire_when_free("wave-child", 0.0))
            self.assertLess(time.time() - started, 5, "a wave child waited for its own wave's lease")
            # The child never held the lock itself, so the wave owner keeps the host.
            self.assertEqual(host_capacity.holder(), "other")
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_a_stray_wave_value_with_another_owner_held_does_not_inherit(self):
        owner = self.hold_in_subprocess()
        try:
            # A value naming nobody cannot silently disable contention protection.
            for stray in ("1", "not-the-owner", "other", "other:junk", "other:"):
                with self.subTest(stray=stray):
                    with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: stray}):
                        self.assertFalse(host_capacity.acquire("stray"))
                        self.assertFalse(host_capacity.acquire_when_free("stray", 0.0))
                        self.assertEqual(host_capacity.worker_count(16), 1)
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_a_stray_wave_value_with_a_free_host_takes_the_real_lock(self):
        with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: "1"}):
            self.assertTrue(host_capacity.acquire("wave-child"))
            self.assertEqual(host_capacity.holder(), "wave-child")
            host_capacity.release()
        self.assertIsNone(host_capacity.holder(), "the release must give the real lock back")

    def test_wave_child_release_keeps_the_wave_owner_in_place(self):
        owner = self.hold_in_subprocess()
        try:
            with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: f"other:{owner.pid}"}):
                self.assertTrue(host_capacity.acquire("wave-child"))
                host_capacity.release()
            self.assertEqual(host_capacity.holder(), "other",
                             "a wave child released the lease its wave owner still holds")
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_wave_child_sees_the_wave_owner_by_name_not_the_string_none(self):
        owner = self.hold_in_subprocess()
        try:
            with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: f"other:{owner.pid}"}):
                self.assertTrue(host_capacity.acquire("wave-child"))
                self.assertEqual(host_capacity.holder(), "other",
                                 "an inheriting member must read the live owner's name")
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    # Value: inheritance is ownership-scoped, not name-scoped, so a member can
    # never ride a lease whose recorded owner is not exactly the wave owner
    # the environment names (issue #345's identity-based inheritance).
    def test_wave_inheritance_requires_the_live_owner_identity(self):
        owner = self.hold_in_subprocess()
        try:
            self.assertEqual(host_capacity.holder(), "other")
            cases = [
                (f"other:{owner.pid}", True, "the live wave owner's exact identity"),
                (f"other:{owner.pid + 1}", False, "a stale pid under the same lease name"),
                (f"someone-else:{owner.pid}", False, "the live pid under another lease name"),
                ("other", False, "a name-only value without an owner pid"),
                ("other:not-a-pid", False, "a non-numeric pid"),
                ("other:", False, "an empty pid"),
                (f":{owner.pid}", False, "an empty lease name"),
                ("other:-1", False, "a negative pid"),
                ("other:²", False, "a superscript digit that isdigit() accepts but int() rejects"),
                ("other:" + "9" * 5000, False, "a digit string beyond int()'s conversion limit"),
                (f"other:+{owner.pid}", False, "a signed spelling of the live pid"),
                (f"other:0{owner.pid}", False, "a zero-padded spelling of the live pid"),
                (f"other:{owner.pid} ", False, "a space-padded spelling of the live pid"),
            ]
            for value, inherits, why in cases:
                with self.subTest(value=value, why=why):
                    with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: value}):
                        self.assertEqual(host_capacity.acquire("wave-child"), inherits,
                                         f"{why}: must {'inherit' if inherits else 'contend'}")
                        self.assertEqual(host_capacity.worker_count(16), 16 if inherits else 1)
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_wave_owner_value_names_this_process_exactly(self):
        self.assertEqual(host_capacity.wave_owner_value("online-native-probes"),
                         f"online-native-probes:{os.getpid()}")
        self.assertEqual(host_capacity.wave_owner_value("x"), f"x:{os.getpid()}")

    # Value: only the canonical decimal spelling the wave owner publishes
    # counts; every other spelling of a live pid stays a stray value.
    def test_wave_owner_rejects_noncanonical_pid_spellings(self):
        live = os.getpid()
        cases = [f"x:+{live}", f"x:0{live}", f"x:{live} ", f"x: {live}", f"x:{live}\t",
                 "x:1_0", "x:٥", "x:½"]
        for value in cases:
            with self.subTest(value=value):
                with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: value}):
                    self.assertIsNone(host_capacity._wave_owner(),
                                      "a noncanonical pid spelling must stay a stray value")
        with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: f"x:{live}"}):
            self.assertEqual(host_capacity._wave_owner(), ("x", live),
                             "the canonical spelling keeps parsing")
        # A negative number is already canonical, so it parses — but its pid
        # can never equal a record's, so it can never inherit.
        with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: "x:-7"}):
            self.assertEqual(host_capacity._wave_owner(), ("x", -7))

    # Value: the reused-name hazard — a second wave takes the constant lease
    # name after the first wave ended, and the first wave's leftover member
    # must not inherit the second wave's lease (issue #345's case).
    def test_a_second_wave_reusing_the_name_does_not_inherit_a_stale_child(self):
        first = self.hold_in_subprocess()
        stale = f"other:{first.pid}"
        first.terminate()
        first.wait(timeout=10)
        (Path(self.directory.name) / "ready").unlink(missing_ok=True)
        owner = self.hold_in_subprocess()
        try:
            self.assertEqual(host_capacity.holder(), "other", "the second wave took the reused name")
            with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: stale}):
                self.assertFalse(host_capacity.acquire("stale-child"),
                                 "a stale child must not inherit a later wave's reused lease")
                self.assertEqual(host_capacity.worker_count(16), 1)
            with patch.dict(os.environ, {host_capacity.WAVE_HELD_ENV: f"other:{owner.pid}"}):
                self.assertTrue(host_capacity.acquire("live-child"),
                                "the live wave's own child still inherits")
        finally:
            owner.terminate()
            owner.wait(timeout=10)

    def test_wait_for_free_returns_when_the_host_is_free(self):
        self.assertTrue(host_capacity.wait_for_free(0.0))
        self.assertTrue(host_capacity.acquire_when_free("online-witness", 0.0))
        self.assertEqual(host_capacity.holder(), "online-witness")

    # Value: ownership waits must not claim capacity after their budget, even when polling oversleeps.
    def test_wait_budgets_preserve_immediate_attempt_and_expiration(self):
        cases = [(0, 0, 0, True), (0, 1, 0, False), (.1, .2, 0, False),
                 (.5, .6, .2, False), (1, .2, 0, True), (.5, .5, 0, False)]
        for operation in ('wait_for_free', 'acquire_when_free'):
            for budget, release, oversleep, expected in cases:
                with self.subTest(operation=operation, budget=budget, release=release, oversleep=oversleep):
                    clock, sleeps, attempts = [0.0], [], []

                    def sleep(seconds):
                        sleeps.append((clock[0], seconds))
                        clock[0] += seconds + oversleep

                    def acquire(_name):
                        attempts.append(clock[0])
                        return clock[0] >= release

                    with patch.object(host_capacity, 'time', SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep)), \
                            patch.object(host_capacity, '_ours', return_value=False), \
                            patch.object(host_capacity, 'holder', side_effect=lambda: None if clock[0] >= release else 'other'), \
                            patch.object(host_capacity, 'acquire', side_effect=acquire):
                        result = (host_capacity.wait_for_free(budget) if operation == 'wait_for_free'
                                  else host_capacity.acquire_when_free('next', budget))
                    self.assertEqual(result, expected)
                    for started, duration in sleeps:
                        self.assertLessEqual(duration, min(.5, budget - started), 'polling sleep must fit remaining budget')
                    self.assertTrue(all(attempt == 0 or attempt < budget for attempt in attempts), 'expired waits cannot acquire capacity')

    # Value: a real owner leaving after expiration must not convert a timed-out wait into successful ownership.
    def test_owner_exit_after_budget_cannot_grant_capacity(self):
        for operation in ('wait_for_free', 'acquire_when_free'):
            with self.subTest(operation=operation):
                owner = self.hold_in_subprocess()
                clock, sleeps = [0.0], []

                def sleep(seconds):
                    sleeps.append(seconds)
                    clock[0] += seconds + .2
                    owner.terminate()
                    owner.wait(timeout=5)

                try:
                    with patch.object(host_capacity, 'time', SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep)):
                        result = (host_capacity.wait_for_free(.1) if operation == 'wait_for_free'
                                  else host_capacity.acquire_when_free('next', .1))
                    self.assertFalse(result, 'capacity released after expiration cannot satisfy the old wait')
                    self.assertEqual(sleeps, [.1])
                    self.assertTrue(host_capacity.acquire_when_free('fresh-attempt', 0), 'a fresh immediate attempt can acquire the released host')
                    host_capacity.release()
                finally:
                    if owner.poll() is None:
                        owner.terminate()
                    owner.wait(timeout=5)
                    (Path(self.directory.name) / 'ready').unlink(missing_ok=True)

    def test_worker_count_rejects_a_non_positive_request(self):
        with self.assertRaises(ValueError):
            host_capacity.worker_count(0)

    def test_the_lock_lives_outside_checkouts(self):
        default = self.previous[0]
        self.assertTrue(default.is_absolute())
        self.assertFalse(default.is_relative_to(SCRIPTS.parent))


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

    def test_the_local_runner_takes_the_host_with_a_bounded_wait(self):
        # A competing owner must not permanently lower the requested native capacity.
        source = (SCRIPTS.parent / 'scripts/run_godot_tests.py').read_text(encoding='utf-8')
        self.assertTrue(self._calls(source, 'acquire'), 'the local runner no longer takes the host')
        self.assertTrue(self._calls(source, 'acquire_when_free'), 'the local runner must acquire before starting children')

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
