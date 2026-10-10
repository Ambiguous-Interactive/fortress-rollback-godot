"""Value: corrupt/missing/hostile pins must not become trusted oracle sources."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import os
import sys
import unittest
from unittest.mock import patch
import subprocess
import zipfile
import run as rust_runner
import godot_smoke as godot_runner

from fetch import MANIFEST, fetch, load_manifest
from run import semantic
from godot_smoke import run as engine_command


class ReferenceContracts(unittest.TestCase):
    def test_manifest_rejects_missing_sha_and_digest(self):
        original = json.loads(MANIFEST.read_text())
        for field, value in [('revision', ''), ('revision', 'main'), ('digest', 'bad')]:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as folder:
                data = copy.deepcopy(original)
                target = data['sources']['fortress']
                if field == 'digest':
                    target = target['archive']
                target[field] = value
                path = Path(folder) / 'pins.json'
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    load_manifest(path)

    def test_offline_missing_corrupt_and_valid_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder)
            pin = {'algorithm': 'sha256', 'digest': hashlib.sha256(b'valid').hexdigest(),
                   'url': 'https://invalid.example/never-contacted'}
            with self.assertRaises(FileNotFoundError):
                fetch(pin, 'artifact', offline=True, cache=cache)
            path = cache / 'downloads/artifact'
            path.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                fetch(pin, 'artifact', offline=True, cache=cache)
            path.write_bytes(b'valid')
            self.assertEqual(fetch(pin, 'artifact', offline=True, cache=cache), path)

    def test_runner_rejects_empty_failed_or_ignored_selection(self):
        for output in ('running 0 tests', 'test regression ... FAILED', 'test regression ... ignored', 'test partial ... ok',
                       'running 2 tests\ntest partial ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                semantic(output)
        self.assertEqual(semantic('running 1 test\ntest real_contract ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n'), [('real_contract', 'ok')])

    def test_expected_panic_is_a_completed_passing_test(self):
        output = 'running 1 test\ntest panic_contract - should panic ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;\n'
        self.assertEqual(semantic(output), [('panic_contract', 'ok')])

    def test_engine_rejects_zero_exit_script_error_and_nonzero_tool(self):
        # Godot can print a script/export failure while exiting zero.
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'engine.log'
            for script in ["print('SCRIPT ERROR: invalid script')", "print('ERROR: failed export'); raise SystemExit(0)", "raise SystemExit(7)"]:
                with self.subTest(script=script), self.assertRaises(RuntimeError):
                    engine_command([sys.executable, '-c', script], os.environ.copy(), log)
            output = engine_command([sys.executable, '-c', "print('FORTRESS_BASELINE_SMOKE_OK:78563412')"], os.environ.copy(), log)
            self.assertIn('FORTRESS_BASELINE_SMOKE_OK:78563412', output)

    def test_failed_rerun_invalidates_prior_report_and_only_owned_logs(self):
        for module, report_name, owned_log, other_log in [
            (rust_runner, 'rust-baseline.json', 'queue-2.log', 'godot-4.3-browser.log'),
            (godot_runner, 'godot-baseline.json', 'godot-4.3-browser.log', 'queue-2.log'),
        ]:
            for stage in ('manifest', 'tool', 'later'):
                with self.subTest(runner=module.__name__, stage=stage), tempfile.TemporaryDirectory() as folder:
                    cache = Path(folder)
                    results = cache / 'results'
                    results.mkdir()
                    (results / report_name).write_text('{"status":"passed"}')
                    (results / owned_log).write_text('OLD_SUCCESS')
                    (results / other_log).write_text('OTHER_RUNNER')
                    argv = ['runner', '--offline']
                    if module is rust_runner:
                        argv += ['--output', str(results)]
                    with patch.object(module, 'CACHE', cache), patch.object(sys, 'argv', argv):
                        if stage == 'manifest':
                            with patch.object(module, 'load_manifest', side_effect=ValueError('invalid manifest')):
                                with self.assertRaises(ValueError):
                                    module.main()
                        elif module is rust_runner:
                            cargo = cache / 'cargo/bin/cargo'
                            if stage == 'later':
                                cargo.parent.mkdir(parents=True)
                                cargo.write_text('#!/bin/sh\ncase "$*" in *--version*) echo "cargo 1.94.0";; *) echo "INJECTED_TOOL_FAILURE"; exit 7;; esac\n')
                                cargo.chmod(0o755)
                            with patch.object(module, 'sources', return_value={'fortress': cache}):
                                with self.assertRaises(RuntimeError if stage == 'later' else FileNotFoundError):
                                    module.main()
                            if stage == 'later':
                                self.assertIn('INJECTED_TOOL_FAILURE', (results / 'queue-1.log').read_text())
                        elif stage == 'tool':
                            with patch.object(module, 'fetch', side_effect=FileNotFoundError('tool unavailable')):
                                with self.assertRaises(FileNotFoundError):
                                    module.main()
                        else:
                            # A real process passes --version/import, then fails its first probe.
                            archive = cache / 'editor.zip'
                            arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}[godot_runner.platform.machine()]
                            with zipfile.ZipFile(archive, 'w') as package:
                                package.writestr(f'Godot_v4.3-stable_linux.{arch}', '#!/bin/sh\ncase "$*" in *--version*) echo "4.3.stable.fake";; *) echo "INJECTED_MISSING_MARKER";; esac\n')
                            with patch.object(module, 'fetch', return_value=archive):
                                with self.assertRaises(ValueError):
                                    module.main()
                            self.assertIn('INJECTED_MISSING_MARKER', (results / 'godot-4.3-headless-1.log').read_text())
                    self.assertFalse((results / report_name).exists(), 'prior success survived failed rerun')
                    self.assertFalse((results / owned_log).exists(), 'prior runner log survived failed rerun')
                    self.assertEqual((results / other_log).read_text(), 'OTHER_RUNNER')

    def test_timeout_replaces_old_log_with_partial_diagnostics(self):
        for command in (rust_runner.command, godot_runner.run):
            with self.subTest(command=command.__module__), tempfile.TemporaryDirectory() as folder:
                log = Path(folder) / 'command.log'
                log.write_text('OLD_SUCCESS')
                expired = subprocess.TimeoutExpired(['tool'], 180, output=b'partial stdout', stderr=b'partial stderr')
                with patch('subprocess.run', side_effect=expired), self.assertRaises(subprocess.TimeoutExpired):
                    if command is rust_runner.command:
                        command(['tool'], Path(folder), os.environ.copy(), log)
                    else:
                        command(['tool'], os.environ.copy(), log)
                output = log.read_text()
                self.assertIn('partial stdout', output)
                self.assertIn('partial stderr', output)
                self.assertIn('TIMEOUT', output)
                self.assertNotIn('OLD_SUCCESS', output)


if __name__ == '__main__':
    unittest.main()
