"""Self-test: the development host has one owner at a time.

The local test runner starts one process per suite and saturates the machine
on a many core host. A browser witness that runs at the same time then stops
delivering packets inside the two second production deadline, and its session
ends with `PROTOCOL_FAILED`. The lease makes that ownership explicit:

* a live lease holds the host and forces the runner's wave to run serially;
* a lease of a process that is gone does not hold the host;
* an expired lease does not hold the host;
* an unreadable lease file does not hold the host;
* the runner releases its own lease when its wave ends.
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import host_capacity


class HostCapacityTest(unittest.TestCase):
    """The lease semantics, against a temporary lease directory."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = host_capacity.LEASE_DIR
        host_capacity.LEASE_DIR = Path(self.directory.name)

    def tearDown(self):
        host_capacity.LEASE_DIR = self.previous
        self.directory.cleanup()

    def write_lease(self, name, pid, expires_at):
        """Write one lease file the way another process would write it."""
        host_capacity.LEASE_DIR.mkdir(parents=True, exist_ok=True)
        path = host_capacity.LEASE_DIR / f"{name}.{pid}.lease"
        path.write_text(json.dumps({"name": name, "pid": pid, "expires_at": expires_at}), encoding="utf-8")
        return path

    def test_free_host_keeps_the_requested_worker_count(self):
        self.assertIsNone(host_capacity.holder())
        self.assertEqual(host_capacity.worker_count(16), 16)
        self.assertEqual(host_capacity.worker_count(1), 1)

    def test_live_lease_holds_the_host(self):
        host_capacity.acquire("online-witness")
        self.assertEqual(host_capacity.holder(), "online-witness")
        self.assertEqual(host_capacity.worker_count(16), 1)
        host_capacity.release("online-witness")
        self.assertIsNone(host_capacity.holder())
        self.assertEqual(host_capacity.worker_count(16), 16)

    def test_lease_of_a_dead_process_does_not_hold_the_host(self):
        self.write_lease("gone", 999999, host_capacity.time.time() + 600)
        self.assertIsNone(host_capacity.holder())
        self.assertEqual(host_capacity.worker_count(16), 16)

    def test_expired_lease_does_not_hold_the_host(self):
        self.write_lease("old", os.getpid(), host_capacity.time.time() - 1)
        self.assertIsNone(host_capacity.holder())

    def test_unreadable_lease_file_does_not_hold_the_host(self):
        host_capacity.LEASE_DIR.mkdir(parents=True, exist_ok=True)
        (host_capacity.LEASE_DIR / "broken.1.lease").write_text("not json", encoding="utf-8")
        self.assertIsNone(host_capacity.holder())

    def test_each_process_holds_its_own_lease(self):
        host_capacity.acquire("godot-tests")
        path = host_capacity.lease_path("godot-tests")
        self.assertTrue(path.exists())
        self.assertIn(str(os.getpid()), path.name)
        host_capacity.release("godot-tests")
        self.assertFalse(path.exists())

    def test_wait_for_free_returns_when_the_host_is_free(self):
        self.assertTrue(host_capacity.wait_for_free(0.0))

    def test_worker_count_rejects_a_non_positive_request(self):
        with self.assertRaises(ValueError):
            host_capacity.worker_count(0)


if __name__ == "__main__":
    unittest.main()
