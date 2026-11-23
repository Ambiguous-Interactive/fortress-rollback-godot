"""The compact template cache must restore exactly the Web bytes from the verified parent archive."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from fetch import digest
from web_templates import SUBSETS, web_template_archive, write_subset


class WebTemplateArchiveTests(unittest.TestCase):
    def test_reuse_rebuild_and_parent_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            parent = cache / "test.tpz"
            with zipfile.ZipFile(parent, "w") as archive:
                archive.writestr("templates/web_release.zip", b"web bytes")
                archive.writestr("templates/linux", b"other platform")
            fixture = cache / "expected.zip"
            write_subset(parent, fixture)
            pin = dict(algorithm="sha256", digest=digest(parent))
            fetch_archive = Mock(return_value=parent)
            with patch.dict(SUBSETS, {("sha256", pin["digest"]): digest(fixture)}):
                actual = web_template_archive(pin, parent.name, True, cache, fetch_archive)
                with zipfile.ZipFile(actual) as archive:
                    self.assertEqual(archive.namelist(), ["templates/web_release.zip"])
                    self.assertEqual(archive.read(archive.namelist()[0]), b"web bytes")
                self.assertEqual(web_template_archive(pin, parent.name, True, cache, fetch_archive), actual)
                fetch_archive.assert_called_once_with(pin, parent.name, True)
                actual.write_bytes(b"bad cache")
                self.assertEqual(web_template_archive(pin, parent.name, True, cache, fetch_archive).read_bytes(), fixture.read_bytes())
                self.assertEqual(fetch_archive.call_count, 2)
                actual.write_bytes(b"bad cache")
                with zipfile.ZipFile(parent, "w") as archive:
                    archive.writestr("templates/web_release.zip", b"wrong Web bytes")
                with self.assertRaisesRegex(ValueError, "differs from pinned members"):
                    web_template_archive(pin, parent.name, True, cache, fetch_archive)
            self.assertEqual(web_template_archive(pin, parent.name, True, cache, fetch_archive), parent)
