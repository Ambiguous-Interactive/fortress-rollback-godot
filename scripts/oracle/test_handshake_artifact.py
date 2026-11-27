"""Value: preserve reviewed TLC bytes; fail closed before caches can hide missing or altered fixtures."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tlc_artifact import ensure_jar


class HandshakeArtifactTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.fixture = Path(self.directory.name) / 'reviewed.jar'
        self.cache = Path(self.directory.name) / 'cache.jar'
        self.fixture.write_bytes(b'reviewed TLC bytes')
        self.expected = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        self.network = self.enterContext(patch('urllib.request.urlopen'))

    def test_fresh_offline_cache_uses_reviewed_repository_bytes(self):
        ensure_jar(self.cache, self.fixture, self.expected)
        self.assertEqual(self.cache.read_bytes(), self.fixture.read_bytes())
        self.network.assert_not_called()

    def test_missing_or_corrupt_repository_fixture_cannot_hide_behind_valid_cache(self):
        self.cache.write_bytes(self.fixture.read_bytes())
        for missing in (False, True):
            if missing:
                self.fixture.unlink()
            else:
                self.fixture.write_bytes(b'changed upstream bytes')
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'repository TLC artifact'):
                ensure_jar(self.cache, self.fixture, self.expected)
        self.network.assert_not_called()

    def test_corrupt_cache_is_rejected_without_repair_or_network(self):
        self.cache.write_bytes(b'corrupt cache')
        with self.assertRaisesRegex(ValueError, 'cached TLC artifact hash mismatch'):
            ensure_jar(self.cache, self.fixture, self.expected)
        self.assertEqual(self.cache.read_bytes(), b'corrupt cache')
        self.network.assert_not_called()

    def test_using_repository_fixture_directly_preserves_it(self):
        ensure_jar(self.fixture, self.fixture, self.expected)
        self.assertEqual(hashlib.sha256(self.fixture.read_bytes()).hexdigest(), self.expected)

    # Value: protects=one manifest selects the artifact; fails_when=valid old cache wins over new pin; why_new=both jars individually valid; seam=none
    def test_selected_digest_rejects_a_previously_valid_cache(self):
        ensure_jar(self.cache, self.fixture, self.expected)
        self.fixture.write_bytes(b'replacement fixture')
        replacement = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'cached TLC artifact'):
            ensure_jar(self.cache, self.fixture, replacement)


if __name__ == '__main__':
    unittest.main()
