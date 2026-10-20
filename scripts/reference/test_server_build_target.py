"""Value: one shared cargo tree instead of one per session.

The relay server's cargo output is about 970 MB. Building it into the
per-run output directory left one copy per session -- twenty copies and
21 GB, all byte-identical, in one devcontainer. The build now targets a
revision-keyed shared tree and publishes the executable at the path the
probes and the docs name.

These tests pin the shared target, the exclusive lock that keeps two
sessions from cleaning each other's build, and the published path.
"""

import os
from pathlib import Path
import tempfile
import unittest

import signalfish_build_server as builder
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


if __name__ == '__main__':
    unittest.main()
