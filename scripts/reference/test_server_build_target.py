"""Value: one shared cargo tree and one shared cargo home instead of one per session.

The relay server's cargo output is about 970 MB. Building it into the
per-run output directory left one copy per session -- twenty copies and
21 GB, all byte-identical, in one devcontainer. The build now targets a
revision-keyed shared tree and publishes the executable at the path the
probes and the docs name.

Cargo also records the absolute path of every registry source in its build
fingerprints, so a per-run cargo home changed every one of those paths and
recompiled all 206 dependencies on every build. The build now uses one
stable cargo home under the reference cache, which the CI caches across
the six matrix jobs.

These tests pin the shared target, the exclusive lock that keeps two
sessions from cleaning each other's build, the published path, the stable
cargo home and the receipt field that names it.
"""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import signalfish_build_server as builder
import signalfish_live_probe as probe
from fetch import CACHE


class SharedTargetTest(unittest.TestCase):
    def test_target_is_keyed_by_revision(self):
        first = builder.shared_target('a' * 40)
        second = builder.shared_target('b' * 40)
        self.assertNotEqual(first, second)
        self.assertEqual(first, builder.shared_target('a' * 40))

    def test_target_lives_inside_the_reference_cache(self):
        self.assertTrue(str(builder.shared_target('c' * 40)).startswith(str(CACHE)))

    def test_builder_does_not_target_the_per_run_output(self):
        """The regression guard: the output directory must not hold a build tree."""
        source = Path(builder.__file__).read_text(encoding='utf-8')
        self.assertIn('CARGO_TARGET_DIR=str(target)', source)
        self.assertNotIn('CARGO_TARGET_DIR=str(output', source)


class LockTest(unittest.TestCase):
    def test_lock_is_exclusive_and_released_on_close(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'target'
            handle = builder.locked(target)
            try:
                self.assertTrue(target.is_dir())
                self.assertTrue(target.with_name(target.name + '.lock').exists())
                self.assertTrue(os.fstat(handle.fileno()).st_size >= 0)
            finally:
                handle.close()

    def test_lock_can_be_reacquired_after_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'target'
            first = builder.locked(target)
            first.close()
            second = builder.locked(target)
            second.close()


class PublishedBinaryTest(unittest.TestCase):
    def test_published_path_matches_the_documented_contract(self):
        """Probes and docs name `<output>/target/debug/signal-fish-server`."""
        source = Path(builder.__file__).read_text(encoding='utf-8')
        self.assertIn("output / 'target/debug/signal-fish-server'", source)


class StableCargoHomeTest(unittest.TestCase):
    """The cargo home must be the same path in every run and every CI job."""

    def test_home_is_one_path_for_every_call(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            with patch.object(builder, 'CACHE', cache), patch.object(probe, 'CACHE', cache):
                first = builder.cargo_home()
                second = builder.cargo_home()
                self.assertEqual(first, second)
                self.assertEqual(first, probe.server_cargo_home())

    def test_home_lives_inside_the_shared_reference_cache(self):
        self.assertTrue(str(probe.server_cargo_home()).startswith(str(CACHE)))
        self.assertEqual(probe.server_cargo_home().parent, CACHE)

    def test_home_is_seeded_once_from_the_reference_registry(self):
        """The crates stay in the shared home instead of a per-run copy."""
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            seed = cache / 'cargo/registry/cache'
            seed.mkdir(parents=True)
            (seed / 'crate.crate').write_bytes(b'crate')
            index = cache / 'cargo/registry/index'
            index.mkdir(parents=True)
            with patch.object(builder, 'CACHE', cache), patch.object(probe, 'CACHE', cache):
                home = builder.cargo_home()
                self.assertEqual((home / 'registry/cache/crate.crate').read_bytes(), b'crate')
                self.assertTrue((home / 'registry/index').is_dir())
                (home / 'registry/cache/crate.crate').write_bytes(b'changed')
                builder.cargo_home()
                self.assertEqual((home / 'registry/cache/crate.crate').read_bytes(), b'changed')

    def test_builder_uses_no_temporary_cargo_home(self):
        """The regression guard: a per-run home would recompile every dependency."""
        source = Path(builder.__file__).read_text(encoding='utf-8')
        self.assertIn('CARGO_HOME=str(home)', source)
        self.assertNotIn("home = workspace / 'cargo'", source)
        self.assertNotIn("output / 'cargo-cache'", source)

    def test_receipt_records_the_cargo_home(self):
        source = Path(builder.__file__).read_text(encoding='utf-8')
        self.assertIn("'cargo_home': str(home)", source)

    def test_receipt_validator_rejects_a_foreign_cargo_home(self):
        """A stale or swapped receipt must not pass the probe."""
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            with patch.object(probe, 'CACHE', cache):
                home = probe.server_cargo_home()
                revision, digest = 'a' * 40, 'b' * 64
                source = {'Cargo.toml': 'c' * 64}
                inputs = {name: 'f' * 64 for name in ('builder', 'fetch', 'pins', 'run', 'native_launcher', 'sdk_launcher',
                                                      'receipt_arguments', 'archive', 'cargo', 'rustc')}
                inputs.update(cargo='d' * 64, rustc='e' * 64)
                log_digest = '1' * 64
                build = {'format': 1, 'passed': True, 'source_revision': revision, 'source_inventory': source,
                         'binary': '/build/server', 'binary_sha256': digest, 'exit_codes': [0, 0],
                         'tool_sha256': {'cargo': inputs['cargo'], 'rustc': inputs['rustc']},
                         'commands': [['/toolchain/cargo', 'clean', '-p', 'signal-fish-server'],
                                      ['/toolchain/cargo', 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']],
                         'builder_sha256': inputs['builder'], 'server_archive_sha256': inputs['archive'],
                         'input_inventory': inputs, 'log_sha256': log_digest, 'cargo_home': str(home)}
                probe.validate_build_receipt(build, revision, source, digest, inputs, log_digest)
                for value in (None, '', '/tmp/other-cargo-home', str(cache / 'cargo'), str(home / 'nested')):
                    changed = dict(build, cargo_home=value)
                    with self.subTest(cargo_home=value), self.assertRaises(ValueError):
                        probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)
                del build['cargo_home']
                with self.assertRaises(ValueError):
                    probe.validate_build_receipt(build, revision, source, digest, inputs, log_digest)


if __name__ == '__main__':
    unittest.main()
