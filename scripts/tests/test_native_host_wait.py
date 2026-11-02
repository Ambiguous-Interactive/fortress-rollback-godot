"""Cross-checkout launcher ownership, capacity recovery and bounded waiting."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_capacity

SCRIPTS = Path(__file__).resolve().parents[1]


class NativeHostWaitTest(unittest.TestCase):
    # Value: a waiting native launcher must regain parallel capacity without competing with browser owners.
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.previous = host_capacity.LEASE_DIR, host_capacity.LEASE_FILE
        host_capacity.LEASE_DIR = self.root / 'leases'
        host_capacity.LEASE_FILE = host_capacity.LEASE_DIR / 'host.lock'
        self.checkout = self.root / 'checkout'
        (self.checkout / 'scripts/reference').mkdir(parents=True)
        for name in ('run_godot_tests.py', 'host_capacity.py', 'native_source_snapshot.py'):
            shutil.copyfile(SCRIPTS / name, self.checkout / 'scripts' / name)
        shutil.copyfile(SCRIPTS / 'reference/engine_path.py', self.checkout / 'scripts/reference/engine_path.py')
        (self.checkout / 'project.godot').write_text('[application]\nconfig/name="capacity control"\n')
        subprocess.run(['git', 'init', '-q', str(self.checkout)], check=True)
        subprocess.run(['git', '-C', str(self.checkout), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.checkout), '-c', 'user.name=Control', '-c', 'user.email=control@local',
                        'commit', '-qm', 'source control'], check=True)
        self.engine = self.root / 'engine'
        self.engine.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys, time
root = pathlib.Path({str(self.root)!r})
if '--version' in sys.argv:
    print('control-engine')
    raise SystemExit(0)
if '--list-cases' in sys.argv:
    suites = [sys.argv[i+1] for i, arg in enumerate(sys.argv) if arg == '--suite']
    print('FORTRESS_TEST_CASES ' + json.dumps(dict.fromkeys(suites, ['first', 'second'])))
    raise SystemExit(0)
(root / ('started-' + str(os.getpid()))).write_text('started')
while not (root / 'finish').exists():
    time.sleep(.01)
suite = sys.argv[sys.argv.index('--suite') + 1]
run = dict(assertions=1, failures=[], states=[])
record = dict(suite=suite, case=sys.argv[sys.argv.index('--case') + 1], category='unit', seed='1701', runs=[run,run])
print('FORTRESS_TEST_RESULT ' + json.dumps(dict(format=1, complete=True, passed=True, count=1, errors=[], records=[record])))
''')
        self.engine.chmod(0o755)
        (self.root / 'durations.json').write_text(json.dumps({'res://first.gd': 40, 'res://second.gd': 40}))
        self.children = []
        self.streams = []

    def tearDown(self):
        (self.root / 'finish').touch()
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)
        groups = [int(started.name.split('-')[1]) for started in self.root.glob('started-*')]
        if (self.root / 'spawned-pid').exists():
            groups.append(int((self.root / 'spawned-pid').read_text()))
        for group in groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for stream in self.streams:
            stream.close()
        host_capacity.release()
        host_capacity.LEASE_DIR, host_capacity.LEASE_FILE = self.previous
        self.temp.cleanup()

    def start(self, budget=None, timeout='5', jobs='4'):
        env = dict(os.environ, FORTRESS_HOST_CAPACITY_DIR=str(host_capacity.LEASE_DIR))
        log = (self.root / 'launcher.log').open('w')
        self.streams.append(log)
        process = subprocess.Popen([sys.executable, str(self.checkout / 'scripts/run_godot_tests.py'),
                                    '--godot', str(self.engine), '--suite', 'res://first.gd', '--suite', 'res://second.gd',
                                    '--jobs', jobs, *(['--host-wait', budget] if budget is not None else []), '--timeout', timeout,
                                    '--results', str(self.root / 'result.json'), '--durations', str(self.root / 'durations.json')],
                                   env=env, stdout=subprocess.PIPE, stderr=log, text=True)
        self.children.append(process)
        return process

    def wait_for(self, predicate, process):
        deadline = time.monotonic() + 5
        while not predicate() and time.monotonic() < deadline and process.poll() is None:
            time.sleep(.01)
        self.assertTrue(predicate(), process.communicate(timeout=5) if process.poll() is not None else 'condition timed out')

    def test_owner_release_restores_parallel_capacity_and_blocks_later_browser(self):
        owner_script = (f'import sys; sys.path.insert(0, {str(SCRIPTS)!r}); import host_capacity; '
                        f"host_capacity.LEASE_DIR=__import__('pathlib').Path({str(host_capacity.LEASE_DIR)!r}); "
                        "host_capacity.LEASE_FILE=host_capacity.LEASE_DIR/'host.lock'; "
                        "assert host_capacity.acquire('browser-before'); "
                        f"__import__('pathlib').Path({str(self.root / 'owner-ready')!r}).write_text('held'); sys.stdin.read()")
        owner = subprocess.Popen([sys.executable, '-c', owner_script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.children.append(owner)
        self.wait_for(lambda: (self.root / 'owner-ready').exists(), owner)
        inode = host_capacity.LEASE_FILE.stat().st_ino
        process = self.start()
        self.wait_for(lambda: 'requested_jobs' in (self.root / 'launcher.log').read_text(), process)
        self.assertIsNone(process.poll())
        self.assertEqual(list(self.root.glob('started-*')), [])
        owner.communicate(timeout=5)
        self.assertEqual(owner.returncode, 0)
        self.wait_for(lambda: len(list(self.root.glob('started-*'))) == 4, process)
        self.assertEqual(host_capacity.holder(), 'godot-tests')
        self.assertFalse(host_capacity.acquire('browser-after'))
        self.assertEqual(host_capacity.LEASE_FILE.stat().st_ino, inode)
        (self.root / 'finish').touch()
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (output, error))
        result = json.loads((self.root / 'result.json').read_text())
        self.assertTrue(result['passed'])
        for run in result['runs']:
            self.assertEqual([(r['suite'], r['case']) for r in run['result']['records']],
                             [('res://first.gd', 'first'), ('res://first.gd', 'second'),
                              ('res://second.gd', 'first'), ('res://second.gd', 'second')])
            self.assertEqual(len(run['shards']), 4)
            self.assertTrue(all(shard['result']['count'] == 1 for shard in run['shards']))
            self.assertTrue(all(shard['command'][-2] == '--case' for shard in run['shards']))
        self.assertTrue(host_capacity.acquire('browser-after'))

    def test_free_host_starts_requested_capacity(self):
        process = self.start()
        self.wait_for(lambda: len(list(self.root.glob('started-*'))) == 4, process)
        (self.root / 'finish').touch()
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (output, error))

    def test_wait_timeout_fails_receipt_without_starting_engine(self):
        self.assertTrue(host_capacity.acquire('browser-before'))
        process = self.start('.1')
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 1, (output, error))
        self.assertEqual(list(self.root.glob('started-*')), [])
        result = json.loads((self.root / 'result.json').read_text())
        self.assertEqual(result.get('failure'), 'host_capacity_timeout')
        self.assertFalse(result['passed'])
        self.assertEqual(host_capacity.holder(), 'browser-before')

    def test_contended_single_worker_preserves_slow_case_watchdogs(self):
        self.assertTrue(host_capacity.acquire('browser-before'))
        process = self.start(jobs='1')
        self.wait_for(lambda: 'requested_jobs' in (self.root / 'launcher.log').read_text(), process)
        host_capacity.release()
        self.wait_for(lambda: len(list(self.root.glob('started-*'))) == 1, process)
        (self.root / 'finish').touch()
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (output, error))
        result = json.loads((self.root / 'result.json').read_text())
        for run in result['runs']:
            self.assertEqual(len(run['shards']), 4)
            self.assertTrue(all(shard['command'][-2] == '--case' for shard in run['shards']))

    def test_cancelled_active_wave_reaps_children_and_fences_queued_launches(self):
        self.engine.write_text(self.engine.read_text().replace("(root / ('started-' + str(os.getpid()))).write_text('started')",
            "import subprocess\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])\n"
            "(root / ('descendant-' + str(child.pid))).write_text('running')\n"
            "(root / ('started-' + str(os.getpid()))).write_text('started')"))
        process = self.start()
        self.wait_for(lambda: len(list(self.root.glob('started-*'))) == 4, process)
        descendants = [int(path.name.split('-')[1]) for path in self.root.glob('descendant-*')]
        self.assertEqual(len(descendants), 4)
        self.assertTrue(all(self.active(pid) for pid in descendants))
        process.terminate()
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130)
        result = json.loads((self.root / 'result.json').read_text())
        self.assertEqual(result.get('failure'), 'cancelled')
        self.assertFalse(result['passed'])
        self.assertEqual(len(list(self.root.glob('started-*'))), 4)
        for started in self.root.glob('started-*'):
            with self.assertRaises(ProcessLookupError):
                os.kill(int(started.name.split('-')[1]), 0)
        self.assertTrue(host_capacity.acquire('browser-after'))
        self.assertFalse(any(self.active(pid) for pid in descendants), 'active descendants outlived the host lease')

    @staticmethod
    def active(pid: int) -> bool:
        # Reparented zombies retain PIDs but cannot consume host capacity.
        try:
            return Path(f'/proc/{pid}/stat').read_bytes().rsplit(b')', 1)[1].split()[0] not in (b'Z', b'X')
        except FileNotFoundError:
            return False

    def test_signal_between_spawn_and_registration_reaps_the_new_group(self):
        self.engine.write_text(self.engine.read_text().replace("    print('control-engine')",
            "    (root / ('started-' + str(os.getpid()))).write_text('version')\n"
            "    while not (root / 'finish').exists(): time.sleep(.01)\n    print('control-engine')"))
        script = (f"import sys, os, signal; sys.path.insert(0, {str(self.checkout / 'scripts')!r}); "
                  "import run_godot_tests as runner\n"
                  "original = runner.subprocess.Popen\n"
                  "def spawn(command, *args, **kwargs):\n"
                  "    process = original(command, *args, **kwargs)\n"
                  "    if '--version' in command:\n"
                  f"        open({str(self.root / 'spawned-pid')!r}, 'w').write(str(process.pid))\n"
                  "        os.kill(os.getpid(), signal.SIGTERM)\n"
                  "    return process\n"
                  "runner.subprocess.Popen = spawn\n"
                  f"raise SystemExit(runner.main(['--godot', {str(self.engine)!r}, '--results', {str(self.root / 'result.json')!r}]))")
        process = subprocess.Popen([sys.executable, '-c', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=dict(os.environ, FORTRESS_HOST_CAPACITY_DIR=str(host_capacity.LEASE_DIR)), text=True)
        self.children.append(process)
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, (output, error))
        self.assertEqual(json.loads((self.root / 'result.json').read_text()).get('failure'), 'cancelled')
        self.assertTrue(host_capacity.acquire('browser-after'))
        with self.assertRaises(ProcessLookupError):
            os.kill(int((self.root / 'spawned-pid').read_text()), 0)

    def test_signal_after_registration_reaps_before_returning_capacity(self):
        self.registration_signal()

    def test_unretired_group_fails_cancelled_receipt(self):
        self.registration_signal(stuck=True)

    def registration_signal(self, stuck=False):
        script = (f"import sys, os, signal, json; sys.path.insert(0, {str(self.checkout / 'scripts')!r}); "
                  "import run_godot_tests as runner\n"
                  "original = runner.subprocess.Popen\n"
                  "spawned = []\n"
                  "def spawn(*args, **kwargs):\n"
                  "    process = original(*args, **kwargs)\n"
                  "    spawned.append(process)\n"
                  "    return process\n"
                  "runner.subprocess.Popen = spawn\n"
                  "group_active = runner._group_active\n"
                  "observations = []\n"
                  f"stuck = {stuck!r}\n"
                  "clock = runner.time.monotonic\n"
                  "clock_shift = [0]\n"
                  "runner.time.monotonic = lambda: clock() + clock_shift[0]\n"
                  "def delayed_retirement(group):\n"
                  "    if runner._cancelled.is_set() and (stuck or len(observations) < 3):\n"
                  "        if stuck: clock_shift[0] += 6\n"
                  "        observations.append(group)\n"
                  "        os.kill(os.getpid(), signal.SIGTERM)\n"
                  "        return True\n"
                  "    return group_active(group)\n"
                  "runner._group_active = delayed_retirement\n"
                  "def trace(frame, event, arg):\n"
                  "    if (frame.f_code is runner.owned_process.__wrapped__.__code__ and event == 'line'\n"
                  "            and frame.f_locals.get('process') is not None and not runner._launching\n"
                  "            and not runner._cancelled.is_set()):\n"
                  "        os.kill(os.getpid(), signal.SIGTERM)\n"
                  "    return trace\n"
                  "sys.settrace(trace)\n"
                  f"status = runner.main(['--godot', {str(self.engine)!r}, '--results', {str(self.root / 'result.json')!r}])\n"
                  "sys.settrace(None)\n"
                  "print(json.dumps(dict(registered=len(runner._processes), unreaped=sum(p.returncode is None for p in spawned), observations=len(observations))))\n"
                  "raise SystemExit(status)")
        process = subprocess.Popen([sys.executable, '-c', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=dict(os.environ, FORTRESS_HOST_CAPACITY_DIR=str(host_capacity.LEASE_DIR)), text=True)
        self.children.append(process)
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1 if stuck else 130, (output, error))
        state = json.loads(output.splitlines()[-1])
        if stuck:
            self.assertGreater(state['observations'], 0, 'cleanup must inspect group retirement before reporting failure')
        else:
            self.assertEqual(state, dict(registered=0, unreaped=0, observations=3))
        self.assertEqual(json.loads((self.root / 'result.json').read_text()).get('failure'), 'process_cleanup_failed' if stuck else 'cancelled')
        self.assertTrue(host_capacity.acquire('browser-after'))

    def test_execution_watchdog_reaps_owned_engine_children(self):
        process = self.start(timeout='.2')
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, (output, error))
        result = json.loads((self.root / 'result.json').read_text())
        self.assertFalse(result['passed'])
        for run in result['runs']:
            for shard in run['shards']:
                self.assertEqual(shard['failure'], 'watchdog')
                self.assertTrue(shard['cleanup_complete'])
        for started in self.root.glob('started-*'):
            with self.assertRaises(ProcessLookupError):
                os.kill(int(started.name.split('-')[1]), 0)
        self.assertTrue(host_capacity.acquire('browser-after'))

    def test_cancelled_wait_starts_no_children_and_preserves_owner(self):
        self.assertTrue(host_capacity.acquire('browser-before'))
        process = self.start()
        self.wait_for(lambda: 'requested_jobs' in (self.root / 'launcher.log').read_text(), process)
        self.assertIsNone(process.poll())
        process.terminate()
        process.communicate(timeout=5)
        self.assertEqual(list(self.root.glob('started-*')), [])
        self.assertEqual(host_capacity.holder(), 'browser-before')
        self.assertFalse(json.loads((self.root / 'result.json').read_text())['passed'])


if __name__ == '__main__':
    unittest.main()
