"""Provenance and publication controls for the instrumented relay server."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
import os
from pathlib import Path
import sys
import tempfile
from threading import Event
import unittest
from unittest.mock import patch

from fetch import MANIFEST, digest, load_manifest
import native_online_probe as native
import signalfish_build_trace_server as builder


class TraceServerBuildTest(unittest.TestCase):
    def setUp(self):
        stack = self.enterContext(ExitStack())
        self.root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        self.cache = self.root / 'cache'
        self.output = self.root / 'output'
        self.receipt = self.output / 'build-receipt.json'
        self.binary = self.output / 'signal-fish-server'
        self.log = self.output / 'build.log'
        self.manifest = self.root / 'pins.json'
        self.manifest.write_bytes(MANIFEST.read_bytes())
        self.archive = self.root / 'server.tar.gz'
        self.archive.touch()
        self.cargo, rustc, patch_tool = (self.root / tool for tool in ('cargo', 'rustc', 'patch'))
        for tool in (self.cargo, rustc, patch_tool):
            tool.touch()
        stack.enter_context(patch.object(builder, 'MANIFEST', self.manifest))
        stack.enter_context(patch.object(builder.shutil, 'which', return_value=str(patch_tool)))
        stack.enter_context(patch.object(builder, 'extract', side_effect=self.extract))
        stack.enter_context(patch.object(builder, 'fetch', return_value=self.archive))
        stack.enter_context(patch.object(builder.subprocess, 'run', side_effect=self.run_command))

    @staticmethod
    def extract(_archive, _pin, temporary):
        (temporary / 'src').mkdir()
        return temporary

    @staticmethod
    def run_command(command, *, stdout, env=None, **_kwargs):
        if command[1] == 'build':
            built = Path(env['CARGO_TARGET_DIR']) / 'debug/signal-fish-server'
            built.parent.mkdir(exist_ok=True)
            built.write_bytes(env['CARGO_TARGET_DIR'].encode())
            stdout.write(b'build completed\n')

    def build(self, cache=None):
        return builder.build(self.cargo, cache or self.cache, self.output, True)

    def change_manifest(self):
        self.manifest.write_bytes(self.manifest.read_bytes() + b'\n')

    # Value: protects=the build binds the pin used for fetch; fails_when=fetch or copy accepts a changed pin; why_new=existing controls cover the normal builder; seam=none
    def test_rejects_manifest_drift_through_publication(self):
        stable = self.build()
        self.assertEqual(stable['input_inventory']['pins'], digest(self.manifest))
        self.assertEqual(json.loads(self.receipt.read_text()), stable)
        self.assertEqual(stable['binary_sha256'], digest(self.binary))
        self.assertEqual(stable['log_sha256'], digest(self.log))
        original_manifest = self.manifest.read_bytes()
        copy = builder.shutil.copy2

        def changed_fetch(*_args):
            self.assertEqual(self.manifest.read_bytes(), original_manifest)
            self.change_manifest()
            return self.archive

        def changed_copy(*args):
            self.assertEqual(self.manifest.read_bytes(), original_manifest)
            self.change_manifest()
            return copy(*args)

        for operation, function in (('fetch', changed_fetch), ('copy2', changed_copy)):
            with self.subTest(operation=operation), ExitStack() as stack:
                self.manifest.write_bytes(original_manifest)
                owner = builder if operation == 'fetch' else builder.shutil
                injection = stack.enter_context(patch.object(owner, operation, side_effect=function))
                with self.assertRaisesRegex(ValueError, 'trace server build inputs changed'):
                    self.build()
                injection.assert_called_once()
                self.assertFalse(json.loads(self.receipt.read_text())['passed'])
                self.assertFalse(self.binary.exists())

    def test_build_consumes_the_bytes_whose_hashes_it_records(self):
        patch_path, module_path = (self.root / name for name in ('hooks.patch', 'relay_packet_trace.rs'))
        patch_path.write_bytes(b'original patch')
        module_path.write_bytes(b'original module')

        def transient_edit(command, *, cwd, input=None, **kwargs):
            if '--batch' in command:
                patch_path.write_bytes(b'transient patch')
                module_path.write_bytes(b'transient module')
                self.assertEqual(input, b'original patch')
            elif command[1] == 'build':
                self.assertEqual((cwd / 'src/relay_packet_trace.rs').read_bytes(), b'original module')
                patch_path.write_bytes(b'original patch')
                module_path.write_bytes(b'original module')
            return self.run_command(command, **kwargs)

        with patch.object(builder, 'TRACE_SOURCE', self.root), patch.object(builder.subprocess, 'run', side_effect=transient_edit):
            report = self.build()
        self.assertEqual(report['input_inventory']['patch'], digest(patch_path))
        self.assertEqual(report['input_inventory']['module'], digest(module_path))

    # Value: protects=builders serialize shared output; fails_when=a second build removes a live log; why_new=target lock tests use the same cache; seam=none
    def test_serializes_builds_into_the_same_output(self):
        publishing, contender, release = Event(), Event(), Event()
        second_cache = self.root / 'different-cache'
        hash_file, lock = builder.digest, builder.locked

        def paused_digest(path):
            if path == self.log and not publishing.is_set():
                publishing.set()
                if not release.wait(10):
                    raise RuntimeError('timed out waiting to publish the first build')
            return hash_file(path)

        def observe_lock(target, **kwargs):
            if target == self.output and publishing.is_set():
                contender.set()
            return lock(target, **kwargs)

        def observe_fetch(_pin, _name, _offline, cache):
            if cache == second_cache:
                contender.set()
                if not release.wait(10):
                    raise RuntimeError('timed out waiting to fetch the second build')
            return self.archive

        with patch.object(builder, 'digest', side_effect=paused_digest), patch.object(builder, 'locked', side_effect=observe_lock), \
                patch.object(builder, 'fetch', side_effect=observe_fetch), ThreadPoolExecutor(2) as executor:
            first = executor.submit(self.build)
            try:
                self.assertTrue(publishing.wait(10), 'first build never reached publication')
                second = executor.submit(self.build, second_cache)
                self.assertTrue(contender.wait(10), 'second build never attempted to use the output')
                self.assertTrue(self.log.is_file(), 'second build removed the first build log')
            finally:
                release.set()
            first.result(timeout=10)
            latest = second.result(timeout=10)
        self.assertEqual(json.loads(self.receipt.read_text()), latest)
        self.assertEqual(latest['binary_sha256'], digest(self.binary))
        self.assertEqual(latest['log_sha256'], digest(self.log))
        self.assertIn(str(second_cache).encode(), self.binary.read_bytes())


class TraceServerWitnessTest(unittest.TestCase):
    # Value: protects=the witness binds both trace sources; fails_when=stale receipts or mid-run edits pass; why_new=launcher tests cover option rejection; seam=none
    def test_native_witness_rejects_stale_and_changed_trace_sources(self):
        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            root = Path(folder)
            output, cache, server = (root / name for name in ('output', 'cache', 'trace-server'))
            server.mkdir()
            build, binary = (server / name for name in ('build-receipt.json', 'signal-fish-server'))
            binary.touch()
            manifest = load_manifest()
            version = manifest['godot']['current_stable']
            sdk_pin, server_pin = (manifest['sources'][name] for name in ('sdk', 'server'))
            sdk = cache / sdk_pin['root'] / 'addons/signal_fish'
            sdk.mkdir(parents=True)
            config = cache / server_pin['root'] / 'config.example.json'
            config.parent.mkdir(parents=True)
            config.touch()
            templates = cache / f'downloads/Godot_v{version}-stable_export_templates.tpz'
            templates.parent.mkdir()
            templates.touch()
            manifest['artifacts'][templates.name] = {'algorithm': 'sha256', 'digest': digest(templates)}
            editor, browser, addon, export = (root / name for name in ('godot', 'chromium', 'addon.zip', 'export.zip'))
            for path in (editor, browser, addon, export):
                path.touch()
            trace_sources = {key: root / name for key, name in (('patch', 'hooks.patch'), ('module', 'relay_packet_trace.rs'))}
            for path in trace_sources.values():
                path.write_bytes(b'original')
            trace_inputs = dict(trace_sources, pins=MANIFEST)
            recorded = {'format': 1, 'passed': True, 'source_revision': server_pin['revision'], 'binary_sha256': digest(binary),
                        'input_inventory': {key: digest(path) for key, path in trace_inputs.items()}}
            build.write_text(json.dumps(recorded))
            argv = ['runner', '--addon', str(addon), '--output', str(output), '--cache', str(cache), '--cell', 'relay:2', '--relay-trace-server', str(build)]
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(patch.dict(os.environ, {'FORTRESS_PLAYWRIGHT_PACKAGE': str(root), 'FORTRESS_CHROMIUM_EXECUTABLE': str(browser)}))
            stack.enter_context(patch.object(native, 'TRACE_SOURCE', root, create=True))
            stack.enter_context(patch.object(native, 'parse_manifest', return_value=manifest))
            stack.enter_context(patch.object(native, 'prepare_editor', return_value=editor))
            stack.enter_context(patch.object(native, 'run', return_value=version + '.stable.test'))
            stage = stack.enter_context(patch.object(native, 'stage_export', return_value=(export, {})))
            play = stack.enter_context(patch.object(native, 'play_cells', return_value={}))
            stack.enter_context(patch.object(native.host_capacity, 'acquire_when_free', return_value=True))
            stack.enter_context(patch.object(native.host_capacity, 'release'))
            report = output / native.REPORT
            native.main()
            self.assertTrue(json.loads(report.read_text())['passed'])

            for key in trace_inputs:
                with self.subTest(source=key, phase='missing receipt digest'):
                    stage.reset_mock()
                    build.write_text(json.dumps(dict(recorded, input_inventory={name: hash_value for name, hash_value
                                                                                in recorded['input_inventory'].items() if name != key})))
                    try:
                        with self.assertRaisesRegex(ValueError, 'relay trace server build receipt does not match'):
                            native.main()
                        stage.assert_not_called()
                        self.assertFalse(report.exists())
                    finally:
                        build.write_text(json.dumps(recorded))
            for key, path in trace_sources.items():
                with self.subTest(source=key, phase='before launch'):
                    stage.reset_mock()
                    path.write_bytes(b'changed')
                    try:
                        with self.assertRaisesRegex(ValueError, 'relay trace server build receipt does not match'):
                            native.main()
                        stage.assert_not_called()
                        self.assertFalse(report.exists())
                    finally:
                        path.write_bytes(b'original')
                with self.subTest(source=key, phase='during execution'):
                    def changed_play(*_args):
                        path.write_bytes(b'changed')
                        return {}

                    play.reset_mock(side_effect=True)
                    play.side_effect = changed_play
                    try:
                        with self.assertRaisesRegex(ValueError, 'native browser witness inputs changed during execution'):
                            native.main()
                        play.assert_called_once()
                        self.assertFalse(report.exists())
                    finally:
                        path.write_bytes(b'original')

            play.reset_mock(side_effect=True)
            native.main()
            inputs = json.loads(report.read_text())['inputs']
            self.assertEqual(inputs['relay_trace_patch'], digest(trace_sources['patch']))
            self.assertEqual(inputs['relay_trace_module'], digest(trace_sources['module']))


if __name__ == '__main__':
    unittest.main()
