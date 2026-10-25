"""Value: independent checkouts must share actual host locks and safe cleanup."""

import json
import selectors
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'scripts' / 'host_capacity.py'
sys.path.insert(0, str(ROOT / 'scripts'))
import host_capacity
import prune_caches
import scratch_workspace


class HostCapacityRootsTest(unittest.TestCase):
    def setUp(self):
        # Lock controls need the local filesystem; checkout mounts may not implement flock.
        self.directory = tempfile.TemporaryDirectory(prefix='host-capacity-test-')
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.roots = [self.base / name for name in ('a', 'b')]
        for root in self.roots:
            (root / 'scripts').mkdir(parents=True)
            shutil.copyfile(SOURCE, root / 'scripts' / 'host_capacity.py')
        self.uid = 1000000000000 + os.getpid()
        self.shared = Path('/tmp') / f'fortress-rollback-host-capacity-{self.uid}'
        self.addCleanup(lambda: shutil.rmtree(self.shared, ignore_errors=True))
        self.environment = dict(os.environ)
        self.environment.pop('FORTRESS_HOST_CAPACITY_DIR', None)

    def command(self, root, body):
        return [sys.executable, '-c',
                f'import sys, os, json; os.getuid = lambda: {self.uid}; '
                f'sys.path.insert(0, {str(root / "scripts")!r}); import host_capacity as h; ' + body]

    def run_child(self, root, body, env=None):
        return subprocess.run(self.command(root, body), env=env or self.environment,
                              capture_output=True, encoding='utf-8', timeout=10)

    def hold(self, root):
        process = subprocess.Popen(self.command(root,
            "assert h.acquire('native-wave'); print('held', flush=True); sys.stdin.readline()"),
            env=self.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8')
        self.addCleanup(lambda: self.stop(process))
        self.readiness(process, 'held\n')
        return process

    def readiness(self, process, expected, timeout=5.0):
        deadline = time.monotonic() + timeout
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while b"\n" not in output:
                remaining = max(0.0, deadline - time.monotonic())
                if not selector.select(remaining):
                    self.fail("child startup watchdog expired")
                chunk = os.read(process.stdout.fileno(), 1024)
                if not chunk:
                    self.fail("child exited before startup readiness")
                output.extend(chunk)
                if len(output) > 1024:
                    self.fail("child startup output exceeded its bound")
        self.assertEqual(output.decode('utf-8'), expected)

    @staticmethod
    def stop(process):
        if process.poll() is None and process.stdin is None:
            process.kill()
        try:
            pending_input = '\n' if process.poll() is None and process.stdin is not None and not process.stdin.closed else None
            process.communicate(pending_input, timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=10)

    def test_startup_watchdog_bounds_silent_and_partial_output(self):
        for body in ("import time; time.sleep(30)", "import time; print('partial', end='', flush=True); time.sleep(30)"):
            with self.subTest(body=body):
                child = subprocess.Popen([sys.executable, '-c', body], stdout=subprocess.PIPE, encoding='utf-8')
                try:
                    with self.assertRaisesRegex(AssertionError, 'startup watchdog expired'):
                        self.readiness(child, 'held\n', timeout=0.05)
                finally:
                    self.stop(child)

    def test_unsafe_existing_directory_is_refused_without_chmod_or_fallback(self):
        self.shared.mkdir(mode=0o777)
        self.shared.chmod(0o777)
        for operation in ("h.holder()", "h.worker_count(4)", "h.acquire('unsafe')"):
            result = self.run_child(self.roots[0], f"print({operation})")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('host capacity directory', result.stderr)
        self.assertEqual(self.shared.stat().st_mode & 0o777, 0o777)
        self.assertFalse((self.shared / 'host.lock').exists())

    def test_foreign_directory_owner_is_refused(self):
        self.shared.mkdir(mode=0o700)
        result = self.run_child(self.roots[0], f"os.geteuid = lambda: {os.geteuid() + 1}; print(h.holder())")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('owned by this user', result.stderr)
        self.assertFalse((self.shared / 'host.lock').exists())

    def test_two_roots_exclude_and_owner_exit_releases_stale_metadata(self):
        owner = self.hold(self.roots[0])
        for root in self.roots:
            with self.subTest(root=root.name):
                result = self.run_child(root, "print(json.dumps([h.worker_count(4), h.acquire('challenger'), "
                                        "h.acquire_when_free('browser', 0.0), h.holder()]))")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [1, False, False, 'native-wave'])
        self.stop(owner)
        result = self.run_child(self.roots[1], "print(json.dumps([h.holder(), h.acquire('browser'), h.worker_count(4)]))")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [None, True, 4])

    def test_browser_waits_for_native_owner_then_acquires(self):
        owner = self.hold(self.roots[0])
        browser = subprocess.Popen(self.command(self.roots[1],
            "print('waiting', flush=True); print(h.acquire_when_free('browser', 5.0), flush=True)"),
            env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8')
        self.addCleanup(lambda: self.stop(browser))
        self.readiness(browser, 'waiting\n')
        self.assertIsNone(browser.poll())
        self.stop(owner)
        output, errors = browser.communicate(timeout=10)
        self.assertEqual(browser.returncode, 0, errors)
        self.assertEqual(output.strip(), 'True')

    def test_cleanup_preserves_active_and_idle_lock_inodes(self):
        lease = self.base / '.cache' / 'scratch' / 'owner' / 'lease'
        self.environment['FORTRESS_HOST_CAPACITY_DIR'] = str(lease)
        owner = self.hold(self.roots[0])
        lock = lease / 'host.lock'
        inode = lock.stat().st_ino
        with patch.object(host_capacity, 'LEASE_DIR', lease), patch.object(host_capacity, 'LEASE_FILE', lock), \
                patch.object(scratch_workspace, 'SCRATCH', lease.parent.parent):
            self.assertEqual(prune_caches.plan_workspace(self.base, -1, set()), [])
            self.assertEqual(prune_caches.apply_plans([prune_caches.Plan(lease.parent, 'workspace', 'stale plan')]), 1)
            with self.assertRaises(ValueError):
                scratch_workspace.remove('owner')
            with self.assertRaises(ValueError):
                scratch_workspace.copy_workspace(lease.parent, source=self.roots[0])
            self.assertEqual(lock.stat().st_ino, inode)
            result = self.run_child(self.roots[1], "print(h.acquire('challenger'))")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'False')
            self.stop(owner)
            self.assertEqual(prune_caches.plan_workspace(self.base, -1, set()), [])
            self.assertEqual(prune_caches.apply_plans([prune_caches.Plan(lock, 'scratch', 'idle lock')]), 1)
            self.assertEqual(lock.stat().st_ino, inode)
            lock.write_text('{invalid metadata', encoding='utf-8')
            result = self.run_child(self.roots[1], "print(json.dumps([h.holder(), h.acquire('reacquired')]))")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), [None, True])

    def test_explicit_isolation_and_invalid_paths_do_not_fall_back(self):
        for value in ('', ' ', 'relative/lease'):
            with self.subTest(value=value):
                result = self.run_child(self.roots[0], "print(h.acquire('invalid'))",
                                        dict(self.environment, FORTRESS_HOST_CAPACITY_DIR=value))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FORTRESS_HOST_CAPACITY_DIR', result.stderr)
        lease = self.base / 'isolated'
        result = self.run_child(self.roots[0], "print(h.acquire('isolated'))",
                                dict(self.environment, FORTRESS_HOST_CAPACITY_DIR=str(lease)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'True')
        self.assertTrue((lease / 'host.lock').is_file())
        blocked = self.base / 'file'
        blocked.write_text('not a directory', encoding='utf-8')
        result = self.run_child(self.roots[1], "print(h.acquire('invalid'))",
                                dict(self.environment, FORTRESS_HOST_CAPACITY_DIR=str(blocked)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.shared.exists())


if __name__ == '__main__':
    unittest.main()
