"""Value: protects=latest native CLI installation; fails_when=publication races abort or downgrade;
why_new=tool probes run after installation; seam=fake npm and CLI processes on PATH.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


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
    def invoke(self, package='@opencode/cli', arch='amd64', **scenario):
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
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'], FAKE_ROOT=directory)
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
