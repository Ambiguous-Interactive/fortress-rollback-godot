"""Value: protects=latest native CLI installation; fails_when=publication races abort or downgrade;
why_new=tool probes run after installation; seam=fake npm and CLI processes on PATH.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / '.devcontainer/install-native-cli.py'
FAKE_NPM = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FAKE_ROOT'])
scenario = json.loads((root / 'scenario.json').read_text())
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
package = scenario['package']
version = scenario.get('version', '2.0.30' if package == '@opencode/cli' else '0.163.0')
if args[:1] == ['view']:
    if args[1] == package + '@latest':
        prefix = '@opencode/cli-linux-' if package == '@opencode/cli' else '@openai/codex-linux-'
        dependencies = {prefix + arch: version if package == '@opencode/cli' else 'npm:@openai/codex@' + version + '-linux-' + arch
                        for arch in ('x64', 'arm64')}
        if package == '@opencode/cli':
            dependencies[prefix + 'x64-baseline'] = version
        print(json.dumps({'version': version, 'optionalDependencies': dependencies} if not scenario.get('bad_metadata') else {}))
    else:
        counter = root / 'attempts'
        attempt = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(attempt))
        if scenario.get('hang'):
            time.sleep(10)
        if attempt <= scenario.get('failures', 0):
            print('npm error code ' + scenario.get('code', 'ETARGET'), file=sys.stderr)
            print('first publication failure ' + args[1], file=sys.stderr)
            sys.exit(1)
        print(json.dumps({'version': args[1].rsplit('@', 1)[1]}))
elif args[:1] == ['install']:
    if '--foreground-scripts' in args and '--loglevel=http' in args:
        print('npm http fetch GET https://registry.example/' + package, flush=True)
        print('npm http fetch GET 200 https://registry.example/' + package + '/-/' + package.split('/')[1] + '-' + version + '.tgz?t=SIGNED-QUERY-CREDENTIAL', flush=True)
        print('npm sill runScript postinstall ' + package + '@' + version, flush=True)
    if scenario.get('install_hang'):
        (root / 'npm.pid').write_text(str(os.getpid()))
        time.sleep(60)
    if scenario.get('install_delay'):
        counter = root / 'installs'
        attempt = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(attempt))
        if attempt <= scenario.get('install_failures', 1):
            print('npm error code ETARGET', file=sys.stderr)
            print('first install publication failure ' + scenario.get('missing_spec', '@opencode/cli-linux-x64@' + version), file=sys.stderr)
            sys.exit(1)
    if scenario.get('install_error'):
        print('npm error code EACCES', file=sys.stderr)
        sys.exit(1)
    installed = root / 'global' / package
    installed.mkdir(parents=True, exist_ok=True)
    (installed / 'package.json').write_text(json.dumps({'version': scenario.get('installed_version', version)}))
elif args[:2] == ['root', '-g']:
    print(root / 'global')
else:
    sys.exit(9)
'''


class NativeCliInstallTests(unittest.TestCase):
    @staticmethod
    def load_helper():
        spec = importlib.util.spec_from_file_location('native_cli_installer', HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        return helper

    def test_command_failures_identify_phase_and_preserve_partial_output(self):
        # Value: distinguishes hung commands without registry timing or leaking caller environment;
        # the install phase merges its streams so diagnostics keep npm's original interleaving.
        helper = self.load_helper()
        outer = self
        for phase in ('wrapper metadata', 'native metadata', 'global installation', 'global root lookup', 'runtime version'):
            for timeout in (True, False):
                with self.subTest(phase=phase, timeout=timeout):
                    calls = []

                    def phase_of(command):
                        if command[0] == 'opencode':
                            return 'runtime version'
                        if command[1] == 'view':
                            return 'wrapper metadata' if command[2].endswith('@latest') else 'native metadata'
                        return {'install': 'global installation', 'root': 'global root lookup'}[command[1]]

                    def metadata(command):
                        if phase_of(command) == 'wrapper metadata':
                            return json.dumps({'version': '2.0.30', 'optionalDependencies': {
                                '@opencode/cli-linux-arm64': '2.0.30'}})
                        return json.dumps({'version': '2.0.30'})

                    class FakePopen:
                        pid = 4321

                        def __init__(self, command, **options):
                            self.command = command
                            self.current = phase_of(command)
                            self.returncode = 42 if self.current == phase and not timeout else 0
                            self.communicate_calls = 0
                            self.stdout = io.StringIO()
                            self.stderr = io.StringIO()
                            calls.append(options)

                        def kill(self):
                            pass

                        def communicate(self, **options):
                            bounded = options.get('timeout')
                            if self.current != phase:
                                if self.current == 'runtime version':
                                    return 'runtime', ''
                                return metadata(self.command), ''
                            self.communicate_calls += 1
                            if self.current == phase and bounded and self.communicate_calls == 1 and timeout:
                                raise subprocess.TimeoutExpired(
                                    self.command, bounded,
                                    output=b'npm http fetch GET 200 https://registry.example/x.tgz?t=TOK\n',
                                    stderr=b'partial stderr\n')
                            # The post-kill collect returns the retained partial evidence.
                            return 'npm http fetch GET 200 https://registry.example/x.tgz?t=TOK\n', 'partial stderr\n'

                    args = SimpleNamespace(timeout=600, package='@opencode/cli', arch='arm64', attempts=3, interval=0)
                    stdout, stderr = io.StringIO(), io.StringIO()
                    # The pid doubles as the group id (start_new_session); the real
                    # process group behavior is covered by the live child test below.
                    with patch.object(helper.time, 'monotonic', return_value=10), \
                            patch.object(helper.subprocess, 'Popen', FakePopen), \
                            patch.object(helper.os, 'killpg') as killpg, \
                            patch.object(helper.Path, 'read_text', return_value='{"version":"2.0.30"}'), \
                            contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        with self.assertRaisesRegex(ValueError, phase):
                            helper.Installer(args).install()
                    self.assertTrue(calls, 'the failing phase must have been reached')
                    for options in calls:
                        self.assertTrue(options['start_new_session'], 'every command must own its process group')
                    self.assertEqual(killpg.call_count, 1 if timeout else 0)
                    if timeout:
                        self.assertEqual(killpg.call_args.args, (4321, signal.SIGKILL))
                        self.assertIn('https://registry.example/x.tgz?<redacted>', stderr.getvalue(),
                                      'the timeout path keeps the host and path')
                        self.assertNotIn('TOK', stderr.getvalue(), 'the timeout path never prints query credentials')
                    else:
                        self.assertIn('partial stderr', stderr.getvalue())
                    self.assertNotIn('installed @', stdout.getvalue())
                    self.assertNotIn('retry 2/3', stderr.getvalue())

    def test_timeout_ends_the_process_group_and_preserves_partial_output(self):
        # Value: a hung wrapper postinstall must not hide the partial npm evidence or
        # hang the launcher: the whole group dies — the printed grandchild's exit
        # proves the kill reached the descendants, not just the direct child — and
        # the pipes reach EOF immediately.
        # fails_when=the timeout kills only the direct child; a surviving grandchild
        # holds the pipe until its own exit, which delays this test far past its bound.
        helper = self.load_helper()
        with tempfile.TemporaryDirectory() as directory:
            # The journal lands inside this test's temporary directory, so no other
            # suite or concurrent installer shares or cleans the file.
            with patch.object(helper.tempfile, 'tempdir', directory):
                evidence = helper.journal_path('@opencode/cli')
                pid_file = Path(directory) / 'grandchild.pid'
                script = ("printf 'npm http fetch GET 200 https://registry.example/x.tgz?t=TOK\\n';"
                          f"sh -c 'echo $$ > {pid_file}; exec sleep 60' & sleep 60")
                args = SimpleNamespace(timeout=3, package='@opencode/cli', arch='arm64', attempts=1, interval=0)
                stderr = io.StringIO()
                started = time.monotonic()
                with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(ValueError, 'timed out during global installation'):
                        helper.Installer(args).command(['sh', '-c', script], phase='global installation', merged=True)
                self.assertLess(time.monotonic() - started, 30, 'the process group must end at the deadline, not at grandchild exit')
                self.assertIn('https://registry.example/x.tgz?<redacted>', stderr.getvalue())
                self.assertNotIn('TOK', stderr.getvalue(), 'the timeout path never prints query credentials')
                # The streamed journal holds the same redacted evidence on disk, so an
                # outer deadline that kills this process before it prints keeps it.
                text = evidence.read_text(encoding='utf-8')
                self.assertIn('https://registry.example/x.tgz?<redacted>', text)
                self.assertNotIn('TOK', text, 'the journal never holds query credentials')
                # A killed process can stay a zombie briefly; poll for its removal.
                for _ in range(50):
                    try:
                        os.kill(int(pid_file.read_text()), 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.1)
                else:
                    self.fail('the grandchild pipe holder survived the group kill')

    def test_outer_deadline_kill_mid_install_retains_the_streamed_evidence(self):
        # Value: the recurring #249 failure mode is an outer build deadline that
        # kills the installer while npm hangs, and the failed Docker layer retained
        # no partial output; the journal must already hold the redacted acquisition
        # evidence when the installer dies without running its own timeout path.
        helper = self.load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scenario.json').write_text(json.dumps({'package': '@opencode/cli', 'install_hang': True}))
            npm = root / 'npm'
            npm.write_text(FAKE_NPM)
            npm.chmod(0o755)
            for name in ('opencode', 'codex'):
                cli = root / name
                cli.write_text('#!/bin/sh\nexit 0\n')
                cli.chmod(0o755)
            # The isolated temporary directory holds the journal, so suites and
            # concurrent installs neither share nor clean each other's evidence.
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       FAKE_ROOT=str(root), TMPDIR=str(root))
            command = [sys.executable, str(HELPER), '@opencode/cli', 'arm64',
                       '--attempts', '1', '--interval', '0', '--timeout', '60']
            evidence = root / 'install-native-cli-opencode-cli.log'
            process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                # The journal appears as soon as the install command starts streaming;
                # the generous budget only absorbs a loaded runner's process start.
                for _ in range(400):
                    if evidence.exists() and evidence.stat().st_size > 0:
                        break
                    time.sleep(0.05)
                self.assertTrue(evidence.exists() and evidence.stat().st_size > 0,
                                'the streaming install must journal its first evidence line')
                process.kill()
                process.wait(timeout=15)
                text = evidence.read_text(encoding='utf-8')
                self.assertIn('npm http fetch GET https://registry.example/@opencode/cli', text,
                              'the registry acquisition evidence reached the journal before the kill')
                self.assertNotIn('SIGNED-QUERY-CREDENTIAL', text, 'the journal never holds query credentials')
            finally:
                process.kill()
                process.wait(timeout=15)
                # The hung fake npm survives its killed parent; end it by the pid it
                # recorded, so the test leaves no sleeping process behind.
                pid_file = root / 'npm.pid'
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGKILL)
                    except (ProcessLookupError, ValueError):
                        pass

    def test_hostile_journal_path_disables_journaling_without_failing_the_install(self):
        # Value: the journal is a diagnostic, never a new install failure: a
        # foreign-owned or planted file at the fixed path must neither stop the
        # install nor be adopted as this run's evidence.
        helper = self.load_helper()
        for package, arch in (('@opencode/cli', 'amd64'), ('@openai/codex', 'arm64')):
            with self.subTest(package=package, arch=arch):
                with tempfile.TemporaryDirectory() as directory:
                    with patch.object(helper.tempfile, 'tempdir', directory):
                        evidence = helper.journal_path(package)
                        evidence.write_text('planted evidence that must not be adopted\n', encoding='utf-8')
                        evidence.chmod(0o000)
                        try:
                            result, calls = self.invoke(package, arch, tmpdir=directory, failures=0)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertIn('install evidence journal disabled', result.stderr)
                            self.assertTrue(any(call[0] == 'install' for call in calls),
                                            'the install must proceed without its journal')
                            self.assertIn('installed ' + package + '@', result.stdout)
                        finally:
                            evidence.chmod(0o600)
                        self.assertIn('planted evidence', evidence.read_text(encoding='utf-8'),
                                      'the hostile file must not be truncated into this run\u2019s journal')

    def test_install_failure_retains_its_journal_for_the_next_reader(self):
        # Value: the retention path for a plain non-timeout install failure: the
        # journal with the ordered acquisition and lifecycle evidence survives the
        # failed run, without query credentials.
        helper = self.load_helper()
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(helper.tempfile, 'tempdir', directory):
                evidence = helper.journal_path('@opencode/cli')
                result, _ = self.invoke(install_error=True, tmpdir=directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(evidence.exists(), 'a failed install keeps its evidence journal')
                text = evidence.read_text(encoding='utf-8')
                self.assertIn('npm http fetch GET https://registry.example/@opencode/cli', text)
                self.assertIn('npm sill runScript postinstall @opencode/cli@', text)
                self.assertNotIn('SIGNED-QUERY-CREDENTIAL', text, 'the journal never holds query credentials')

    def test_healthy_install_leaves_no_evidence_journal(self):
        # Value: the journal is failure evidence, not build residue; a green
        # install on any architecture removes it.
        helper = self.load_helper()
        for package, arch in (('@opencode/cli', 'amd64'), ('@openai/codex', 'arm64')):
            with self.subTest(package=package, arch=arch):
                with tempfile.TemporaryDirectory() as directory:
                    with patch.object(helper.tempfile, 'tempdir', directory):
                        evidence = helper.journal_path(package)
                        result, _ = self.invoke(package, arch, tmpdir=directory, failures=1, code='ETARGET')
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertFalse(evidence.exists(), 'a healthy install removes its evidence journal')

    def invoke(self, package='@opencode/cli', arch='amd64', tmpdir=None, **scenario):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scenario.json').write_text(json.dumps(dict(package=package, **scenario)))
            npm = root / 'npm'
            npm.write_text(FAKE_NPM)
            npm.chmod(0o755)
            for name in ('opencode', 'codex'):
                cli = root / name
                cli.write_text('#!/bin/sh\necho "' + name + ' final runtime version"\nexit ' + str(scenario.get('runtime_exit', 0)) + '\n')
                cli.chmod(0o755)
            # The journal follows TMPDIR, so each invocation owns its evidence file
            # and suites and concurrent installs never share or clean each other's.
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'], FAKE_ROOT=directory,
                       TMPDIR=str(tmpdir or directory))
            command = [sys.executable, str(HELPER), package, arch, '--attempts', '3', '--interval', '0',
                       '--timeout', '0.3' if scenario.get('hang') else '10']
            result = subprocess.run(command, capture_output=True, encoding='utf-8', env=env, timeout=15)
            calls = root / 'calls.jsonl'
            return result, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def test_native_publication_delay_recovers_exact_latest_on_both_architectures(self):
        for package in ('@opencode/cli', '@openai/codex'):
            for arch, native_arch in (('amd64', 'x64'), ('arm64', 'arm64')):
                for code in ('ETARGET', 'E404'):
                    with self.subTest(package=package, arch=arch, code=code):
                        result, calls = self.invoke(package, arch, failures=1, code=code)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn('first publication failure', result.stderr)
                        self.assertIn('retry 2/3', result.stderr)
                        self.assertIn('installed ' + package + '@', result.stdout)
                        self.assertIn('final runtime version', result.stdout)
                        installs = [call for call in calls if call[0] == 'install']
                        self.assertEqual(len(installs), 1)
                        self.assertNotIn('@latest', installs[0][-1])
                        natives = [call[1] for call in calls if call[0] == 'view' and not call[1].endswith('@latest')]
                        self.assertTrue(all('linux-' + native_arch in spec for spec in natives), natives)

    def test_terminal_registry_install_and_metadata_errors_do_not_retry(self):
        for scenario in ({'failures': 10, 'code': 'E401'}, {'failures': 10, 'code': 'EACCES'},
                         {'install_error': True}, {'bad_metadata': True}, {'version': '3.0.0'}):
            with self.subTest(scenario=scenario):
                result, calls = self.invoke(**scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('retry 2/3', result.stderr)
                self.assertNotIn('installed @', result.stdout)

    def test_attempt_budget_expires_with_first_failure_and_no_install(self):
        result, calls = self.invoke(failures=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publication retry budget exhausted', result.stderr)
        self.assertIn('first publication failure', result.stderr)
        self.assertEqual(len([call for call in calls if call[0] == 'view']), 4)
        self.assertFalse(any(call[0] == 'install' for call in calls))

    def test_install_failure_streams_lifecycle_and_registry_phase_evidence(self):
        # Value: a hung global install localizes to wrapper lifecycle execution versus
        # registry acquisition, on the next failure, without waiting for upstream logs;
        # the merged stream preserves the order npm produced the evidence in.
        result, calls = self.invoke(install_error=True)
        self.assertNotEqual(result.returncode, 0)
        installs = [call for call in calls if call[0] == 'install']
        self.assertEqual(len(installs), 1)
        self.assertIn('--foreground-scripts', installs[0])
        self.assertIn('--loglevel=http', installs[0])
        self.assertIn('npm http fetch GET https://registry.example/@opencode/cli', result.stderr)
        self.assertIn('npm sill runScript postinstall @opencode/cli@', result.stderr)
        self.assertIn('https://registry.example/@opencode/cli/-/cli-2.0.30.tgz?<redacted>', result.stderr,
                      'the host and path survive redaction')
        self.assertNotIn('SIGNED-QUERY-CREDENTIAL', result.stderr, 'query credentials never reach the diagnostics')
        self.assertLess(result.stderr.index('npm http fetch GET https://registry.example/@opencode/cli'),
                        result.stderr.index('npm sill runScript postinstall @opencode/cli@'),
                        'registry and lifecycle evidence keep their original order')
        views = [call for call in calls if call[0] == 'view']
        self.assertTrue(views)
        for view in views:
            self.assertNotIn('--foreground-scripts', view)
            self.assertNotIn('--loglevel=http', view)

    def test_install_publication_delay_retries_only_the_expected_native_release(self):
        result, calls = self.invoke(install_delay=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('first install publication failure', result.stderr)
        self.assertEqual(len([call for call in calls if call[0] == 'install']), 2)
        result, calls = self.invoke(install_delay=True, install_failures=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publication retry budget exhausted', result.stderr)
        self.assertEqual(len([call for call in calls if call[0] == 'install']), 3)
        result, _ = self.invoke(install_delay=True, missing_spec='@opencode/cli-linux-arm64@2.0.30')
        self.assertEqual(result.returncode, 0, result.stderr)
        for spec in ('@opencode/cli@2.0.30', '@unrelated/dependency@2.0.30', '@opencode/cli-linux-x64@2.0.29'):
            with self.subTest(spec=spec):
                result, calls = self.invoke(install_delay=True, missing_spec=spec)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('retry 2/3', result.stderr)
                self.assertEqual(len([call for call in calls if call[0] == 'install']), 1)

    def test_hung_registry_is_bounded_and_runtime_or_installed_version_failure_is_fatal(self):
        for scenario in ({'hang': True}, {'runtime_exit': 42}, {'installed_version': '2.0.29'}):
            with self.subTest(scenario=scenario):
                result, _ = self.invoke(**scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('installed @', result.stdout)

    def test_install_error_requires_a_complete_matching_package_version_token(self):
        cases = [('@opencode/cli', '@opencode/cli-linux-x64@2.0.30'),
                 ('@openai/codex', '@openai/codex@0.163.0-linux-x64')]
        for package, expected in cases:
            for suffix in ('0', '.1', '-extra', '+metadata', '_other', '/other', '@other'):
                with self.subTest(package=package, suffix=suffix):
                    result, calls = self.invoke(package, install_delay=True, missing_spec=expected + suffix)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('retry 2/3', result.stderr)
                    self.assertEqual(len([call for call in calls if call[0] == 'install']), 1)
            for diagnostic in (expected, "'" + expected + "'", expected + '.', '(' + expected + ')', 'npm:' + expected):
                with self.subTest(package=package, diagnostic=diagnostic):
                    result, calls = self.invoke(package, install_delay=True, missing_spec=diagnostic)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len([call for call in calls if call[0] == 'install']), 2)

    def test_unsupported_architecture_is_rejected_before_registry_access(self):
        result, calls = self.invoke(arch='riscv64')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
