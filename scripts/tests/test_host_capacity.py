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

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
