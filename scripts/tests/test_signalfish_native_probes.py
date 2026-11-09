"""Self-test: the online leg's native probe wave must fail closed.

The wave replaces the serial native probe chain in the Reference Baseline
workflow, so its aggregation is the gate. These tests pin:

* probes that all pass exit zero and run once each against their own output,
  with the wave-held lease flag in their environment;
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
assert os.environ.get('FORTRESS_HOST_LEASE_HELD') == 'online-native-probes', 'wave children must inherit the wave lease by name'
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

        def record_and_kill(pid):
            killed.append(pid)
            real_kill(pid)

        real_popen = probes.subprocess.Popen

        def popen_then_abort(command, **kwargs):
            # Abort lands in the spawn-to-registration window the fence owns.
            process = real_popen(command, **kwargs)
            probes._abort.set()
            return process

        log = self.results / 'native-probe-4.3-sleeper.log'
        try:
            with unittest.mock.patch.object(probes.subprocess, 'Popen', side_effect=popen_then_abort), \
                    unittest.mock.patch.object(probes, 'kill_group', side_effect=record_and_kill):
                began = time.monotonic()
                result = probes.run_probe('sleeper', ['sleep', '30'], log, {})
        finally:
            probes._abort.clear()
        self.assertLess(time.monotonic() - began, 15, 'the spawned probe must be killed, not waited out')
        self.assertEqual(result['returncode'], -9, 'SIGKILL to the probe group must end the probe')
        self.assertEqual(len(killed), 1, 'the spawn-window abort must kill its own group')

    def test_a_fenced_run_probe_refuses_to_launch(self):
        probes._abort.set()
        self.addCleanup(probes._abort.clear)
        log = self.results / 'native-probe-4.3-refused.log'
        result = probes.run_probe('refused', ['sleep', '30'], log, {})
        self.assertEqual(result['returncode'], 1, 'a fenced probe is a failed probe')
        self.assertFalse(log.exists(), 'a fenced probe must not start its command')

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
