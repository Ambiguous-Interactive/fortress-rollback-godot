"""Self-test: the online leg's native probe wave must fail closed.

The wave replaces the serial native probe chain in the Reference Baseline
workflow, so its aggregation is the gate. These tests pin:

* probes that all pass exit zero and run once each against their own output,
  with the wave-held lease flag naming the wave owner's identity in their
  environment;
* a failing probe fails the whole run, surfaces its own output, and every
  sibling still joins with its own result — two failures are both named;
* interruption fences queued probes and terminates active process groups;
* the wave takes the host lease once and releases it after the last probe.

Each case exercises the real script end to end through temporary trees.
"""

import io
import shutil
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))

import host_capacity
import signalfish_native_probes as probes

PASS_SCRIPT = """\
import os, sys
from pathlib import Path
value = os.environ.get('FORTRESS_HOST_LEASE_HELD', '')
name, _, pid = value.rpartition(':')
assert name == 'online-native-probes' and pid.isdigit(), (
    f'wave children must inherit the wave owner identity, saw {value!r}')
args = sys.argv[1:]
for required in ('--godot', '--server', '--server-source', '--build-receipt', '--output'):
    assert required in args, args
output = Path(args[args.index('--output') + 1])
output.mkdir(parents=True, exist_ok=True)
(output / 'argv.txt').write_text('\\n'.join(args) + '\\n')
(output / 'spectator-live.json').write_text('{"passed": true}\\n')
"""

FAIL_SCRIPT = """\
import sys
print('probe controlled failure')
sys.exit(3)
"""


def write_script(directory, name, text):
    path = directory / name
    path.write_text(text)
    path.chmod(0o755)
    return path


class NativeProbeWaveTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='native-probe-wave-'))
        self.results = self.root / 'results'
        self.addCleanup(shutil.rmtree, self.root, True)
        # The wave's host-lease preflight must never touch the real machine
        # lock from a test: stub it for every case; a case can override.
        acquire = unittest.mock.patch.object(host_capacity, 'acquire_when_free', return_value=True)
        acquire.start()
        self.addCleanup(acquire.stop)
        release = unittest.mock.patch.object(host_capacity, 'release', return_value=None)
        release.start()
        self.addCleanup(release.stop)

    def table(self, scripts):
        return {name: (str(path), (), f'spectator-live-{{version}}-{name}') for name, path in scripts.items()}

    def run_main(self, table, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with unittest.mock.patch.dict(probes.PROBES, table, clear=True), \
                unittest.mock.patch('sys.argv', ['signalfish_native_probes.py'] + arguments), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = probes.main()
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def arguments(self, extra=()):
        return ['--godot', str(self.root / 'engine'),
                '--server', str(self.root / 'server'),
                '--server-source', str(self.root / 'server-source'),
                '--build-receipt', str(self.root / 'receipt.json'),
                '--version', '4.3', '--results', str(self.results)] + list(extra)

    def test_passing_probes_run_once_each_with_their_own_outputs_and_lease_flag(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', PASS_SCRIPT),
                            'beta': write_script(self.root, 'beta.py', PASS_SCRIPT)})
        exit_code, stdout, _ = self.run_main(table, self.arguments())
        self.assertEqual(exit_code, 0, stdout)
        for name in ('alpha', 'beta'):
            output = self.results / f'spectator-live-4.3-{name}'
            self.assertEqual(sorted(path.name for path in output.iterdir()), ['argv.txt', 'spectator-live.json'])
            argv = (output / 'argv.txt').read_text()
            self.assertIn('--godot', argv)
            self.assertIn('--server-source', argv)
            self.assertTrue((self.results / f'native-probe-4.3-{name}.log').exists(), name)
        self.assertIn('2 probes, 0 failed', stdout)
        self.assertIn('[2/2] pass', stdout)
        self.assertIn('pass beta', stdout)
        self.assertNotIn('FAIL', stdout)

    def test_every_failure_is_named_and_siblings_still_join(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', FAIL_SCRIPT),
                            'beta': write_script(self.root, 'beta.py', FAIL_SCRIPT),
                            'gamma': write_script(self.root, 'gamma.py', PASS_SCRIPT)})
        exit_code, stdout, _ = self.run_main(table, self.arguments())
        self.assertEqual(exit_code, 1)
        self.assertIn('--- alpha exited 3 ---', stdout)
        self.assertIn('--- beta exited 3 ---', stdout)
        self.assertIn('probe controlled failure', stdout)
        self.assertIn('3 probes, 2 failed', stdout)
        for name in ('alpha', 'beta', 'gamma'):
            self.assertTrue((self.results / f'native-probe-4.3-{name}.log').exists(), name)
        self.assertTrue((self.results / 'spectator-live-4.3-gamma').is_dir(),
                        'a sibling probe must still run to completion beside a rejection')

    def test_interruption_fences_queued_probes_and_kills_active_groups(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', PASS_SCRIPT),
                            'beta': write_script(self.root, 'beta.py', PASS_SCRIPT),
                            'gamma': write_script(self.root, 'gamma.py', PASS_SCRIPT)})
        killed = []
        registered = threading.Event()
        release = threading.Event()

        def fake(name, command, log_path, environment):
            if name == 'alpha':
                # Deterministic ordering: alpha interrupts only after beta has
                # registered its group, so the fence always has a live target.
                registered.wait(10)
                raise KeyboardInterrupt('simulated interruption')
            if name == 'beta':
                # A still-running probe whose group interruption must terminate.
                with probes._active_lock:
                    probes._active_handles.append({'pid': 4242})
                registered.set()
                try:
                    release.wait(10)
                finally:
                    with probes._active_lock:
                        probes._active_handles.remove({'pid': 4242})
            return {'name': name, 'seconds': 0.0, 'returncode': 0}

        def record_kill(pid):
            killed.append(pid)
            release.set()

        try:
            with unittest.mock.patch.dict(probes.PROBES, table, clear=True), \
                    unittest.mock.patch.object(probes, 'run_probe', side_effect=fake), \
                    unittest.mock.patch.object(probes, 'kill_group', side_effect=record_kill), \
                    unittest.mock.patch('sys.argv', ['signalfish_native_probes.py'] + self.arguments()), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    probes.main()
        finally:
            registered.set()
            release.set()
            probes._abort.clear()
        self.assertEqual(killed, [4242], 'interruption did not terminate the active probe group')

    def test_a_probe_spawned_into_an_abort_kills_its_own_group(self):
        real_kill = probes.kill_group
        killed = []
        descendant = self.root / 'descendant-pid'

        def record_and_kill(pid):
            killed.append(pid)
            real_kill(pid)

        real_popen = probes.subprocess.Popen

        def popen_then_abort(command, **kwargs):
            # Abort lands in the spawn-to-registration window the fence owns,
            # after the leader has forked its engine stand-in and recorded it.
            # The kill can interrupt a half-written pid file, so wait for the
            # recorded content, not the file's existence.
            process = real_popen(command, **kwargs)
            deadline = time.time() + 5
            while time.time() < deadline:
                recorded = (self.root / 'engine-descendant-pid')
                if recorded.exists() and recorded.read_text().strip().isdigit():
                    break
                time.sleep(0.01)
            probes._abort.set()
            return process

        leader_script = (
            "import os, sys, time, pathlib\n"
            f"pathlib.Path({str(descendant)!r}).write_text(str(os.getpid()))\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    time.sleep(30)\n"
            "    os._exit(0)\n"
            f"pathlib.Path({str(self.root / 'engine-descendant-pid')!r}).write_text(str(child))\n"
            "time.sleep(30)\n"
        )
        script_path = write_script(self.root, 'leader.py', leader_script)
        log = self.results / 'native-probe-4.3-sleeper.log'
        try:
            with unittest.mock.patch.object(probes.subprocess, 'Popen', side_effect=popen_then_abort), \
                    unittest.mock.patch.object(probes, 'kill_group', side_effect=record_and_kill):
                began = time.monotonic()
                result = probes.run_probe('sleeper', [sys.executable, str(script_path)], log, {})
        finally:
            probes._abort.clear()
        self.assertLess(time.monotonic() - began, 15, 'the spawned probe must be killed, not waited out')
        self.assertEqual(result['returncode'], -9, 'SIGKILL to the probe group must end the probe')
        self.assertEqual(len(killed), 1, 'the spawn-window abort must kill its own group')
        # The group kill is what protects engine children: the leader's forked
        # descendant must die with the group, not only the leader itself. A
        # freshly killed process can linger as a zombie until reaping, so a
        # zombie counts as dead. /proc is the evidence source; without it the
        # depth of the kill cannot be observed here.
        if not Path('/proc/self').exists():
            self.skipTest('process state requires /proc')
        child_pid = int((self.root / 'engine-descendant-pid').read_text())
        deadline = time.time() + 5

        def dead(pid):
            try:
                fields = Path(f'/proc/{pid}/stat').read_text()
                return fields.rsplit(')', 1)[1].split()[0] == 'Z'
            except (OSError, IndexError):
                return True

        while time.time() < deadline and not dead(child_pid):
            time.sleep(0.05)
        self.assertTrue(dead(child_pid), 'a forked engine descendant survived the group kill')

    def test_an_aborted_fence_refuses_later_launches(self):
        probes._abort.set()
        self.addCleanup(probes._abort.clear)
        with unittest.mock.patch.object(probes, 'kill_group', side_effect=lambda pid: None):
            probes.abort_active_groups()
        refused = probes.run_probe('next', ['sleep', '30'], self.results / 'next.log', {})
        self.assertEqual(refused['returncode'], 1,
                         'the fence must refuse launches after the abort, not only kill running groups')

    def test_a_fenced_run_probe_refuses_to_launch(self):
        probes._abort.set()
        self.addCleanup(probes._abort.clear)
        log = self.results / 'native-probe-4.3-refused.log'
        result = probes.run_probe('refused', ['sleep', '30'], log, {})
        self.assertEqual(result['returncode'], 1, 'a fenced probe is a failed probe')
        self.assertFalse(log.exists(), 'a fenced probe must not start its command')

    def test_sigterm_fences_and_exits_like_an_interrupt(self):
        real_kill = probes.kill_group
        killed = []

        def record_and_kill(pid):
            killed.append(pid)
            real_kill(pid)

        script_path = write_script(self.root, 'sleeper.py', 'import time\ntime.sleep(30)\n')
        log = self.results / 'native-probe-4.3-sigterm.log'
        began = time.monotonic()
        worker = threading.Thread(target=probes.run_probe,
                                  args=('sleeper', [sys.executable, str(script_path)], log, {}))
        try:
            worker.start()
            deadline = time.time() + 10
            while time.time() < deadline:
                with probes._active_lock:
                    if any(handle['pid'] is not None for handle in probes._active_handles):
                        break
                time.sleep(0.02)
            with probes._active_lock:
                self.assertTrue(any(handle['pid'] is not None for handle in probes._active_handles),
                                'the probe must register its group before the fence runs')
            with unittest.mock.patch.object(probes, 'kill_group', side_effect=record_and_kill):
                with self.assertRaises(SystemExit) as raised:
                    probes._on_terminate(15, None)
            worker.join(10)
        finally:
            probes._abort.clear()
        self.assertFalse(worker.is_alive(), 'the fenced probe must end promptly after SIGTERM')
        self.assertEqual(raised.exception.code, 143, 'SIGTERM must exit like a terminated shell command')
        self.assertLess(time.monotonic() - began, 15, 'the SIGTERM fence must not wait out the engine')
        self.assertEqual(len(killed), 1, 'the SIGTERM fence must kill the registered group')

    def test_the_pool_never_exceeds_its_worker_bound(self):
        script = write_script(self.root, 'hold.py', PASS_SCRIPT)
        table = self.table({name: script for name in ('alpha', 'beta', 'gamma', 'delta')})
        lock = threading.Lock()
        state = {'running': 0, 'peak': 0}

        def tracked(name, command, log_path, environment):
            with lock:
                state['running'] += 1
                state['peak'] = max(state['peak'], state['running'])
            time.sleep(0.2)
            with lock:
                state['running'] -= 1
            return {'name': name, 'seconds': 0.2, 'returncode': 0}

        for jobs, expected_peak in (('2', 2), ('1', 1), ('0', 1)):
            with self.subTest(jobs=jobs):
                state.update(running=0, peak=0)
                with unittest.mock.patch.dict(probes.PROBES, table, clear=True), \
                        unittest.mock.patch.object(probes, 'run_probe', side_effect=tracked), \
                        unittest.mock.patch('sys.argv', ['signalfish_native_probes.py'] + self.arguments(['--jobs', jobs])), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    exit_code = probes.main()
                self.assertEqual(exit_code, 0)
                self.assertEqual(state['peak'], expected_peak,
                                 f'--jobs {jobs} must bound the wave at {expected_peak} overlapping probes')

    def test_sigterm_handler_is_installed_for_the_wave(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', PASS_SCRIPT)})
        installed = []
        real_signal = probes.signal.signal

        def record_signal(signum, handler):
            installed.append((signum, handler))
            if signum == probes.signal.SIGTERM:
                return probes.signal.SIG_DFL
            return real_signal(signum, handler)

        with unittest.mock.patch.dict(probes.PROBES, table, clear=True), \
                unittest.mock.patch.object(probes.signal, 'signal', side_effect=record_signal), \
                unittest.mock.patch('sys.argv', ['signalfish_native_probes.py'] + self.arguments()), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            probes.main()
        signums = [signum for signum, _ in installed]
        self.assertIn(probes.signal.SIGTERM, signums, 'the wave must install its SIGTERM fence')
        self.assertIn(probes._on_terminate, [handler for _, handler in installed])

    def test_abort_active_groups_kills_every_registered_group(self):
        killed = []
        self.addCleanup(probes._abort.clear)
        with unittest.mock.patch.object(probes, 'kill_group', side_effect=killed.append):
            with probes._active_lock:
                handles = [{'pid': 11}, {'pid': None}, {'pid': 22}]
                probes._active_handles.extend(handles)
            try:
                probes.abort_active_groups()
            finally:
                with probes._active_lock:
                    for handle in handles:
                        probes._active_handles.remove(handle)
        self.assertEqual(sorted(killed), [11, 22], 'a spawn still without a pid must be skipped, not killed')

    def test_the_wave_takes_the_host_once_and_releases_after_the_join(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', PASS_SCRIPT)})
        calls = []
        release = unittest.mock.patch.object(host_capacity, 'release',
                                             side_effect=lambda: calls.append('release'))
        release.start()
        self.addCleanup(release.stop)
        wait = unittest.mock.patch.object(host_capacity, 'acquire_when_free',
                                          side_effect=lambda *args: calls.append('acquire') or True)
        wait.start()
        self.addCleanup(wait.stop)
        exit_code, stdout, _ = self.run_main(table, self.arguments())
        self.assertEqual(exit_code, 0, stdout)
        self.assertEqual(calls, ['acquire', 'release'],
                         'the wave must take the host once before the pool and release after the join')

    def test_a_busy_host_refuses_the_wave(self):
        table = self.table({'alpha': write_script(self.root, 'alpha.py', PASS_SCRIPT)})
        busy = unittest.mock.patch.object(host_capacity, 'acquire_when_free', return_value=False)
        busy.start()
        self.addCleanup(busy.stop)
        with unittest.mock.patch.dict(probes.PROBES, table, clear=True), \
                unittest.mock.patch('sys.argv', ['signalfish_native_probes.py'] + self.arguments()), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaises(ValueError) as caught:
                probes.main()
        self.assertIn('stayed busy', str(caught.exception))
        self.assertIn('responsive host', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
