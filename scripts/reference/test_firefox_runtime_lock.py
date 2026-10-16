"""Value: preseed only Firefox's empty runtime lock while retaining complete installation integrity checks."""
import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest import mock

from browser import webrtc_matrix as matrix
from signalfish_probe import inventory


class FirefoxRuntimeLockTests(unittest.TestCase):
    def test_fresh_archive_preseeds_empty_regular_lock_before_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            archive = cache / 'firefox.zip'
            with zipfile.ZipFile(archive, 'w') as package:
                package.writestr('firefox/firefox', b'pinned executable')
            pins = {'browser': {'firefox_revision': '1495'}, 'artifacts': {'firefox-1495-ubuntu24.04-arm64.zip': {}}}
            sources, environment = {}, {}
            original = Path.read_text

            def read_text(path, *args, **kwargs):
                return 'ID=ubuntu\nVERSION_ID="24.04"\n' if str(path) == '/etc/os-release' else original(path, *args, **kwargs)

            with (mock.patch.object(matrix, 'CACHE', cache), mock.patch.object(matrix, 'fetch', return_value=archive),
                  mock.patch.object(matrix.shutil, 'which', return_value='/usr/bin/xdotool'),
                  mock.patch.object(Path, 'read_text', read_text), mock.patch.dict(matrix.os.environ, {'DISPLAY': ':99'})):
                matrix.prepare_firefox(pins, 'arm64', True, sources, environment)
            lock = sources['firefox_installation'] / 'firefox/.parentlock'
            self.assertFalse(lock.is_symlink())
            self.assertTrue(lock.is_file())
            self.assertEqual(lock.read_bytes(), b'')
            self.assertEqual(inventory({'installation': sources['firefox_installation']})['installation/firefox/.parentlock'], hashlib.sha256(b'').hexdigest())

    def test_reserved_lock_never_overwrites_existing_archive_entry_or_symlink(self):
        for kind in ('empty', 'payload', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                installation = Path(temporary)
                (installation / 'firefox').mkdir()
                lock = installation / 'firefox/.parentlock'
                if kind == 'symlink':
                    lock.symlink_to(installation / 'missing')
                else:
                    lock.write_bytes(b'archive payload' if kind == 'payload' else b'')
                with self.assertRaisesRegex(ValueError, 'runtime lock'):
                    matrix.seed_firefox_runtime_lock(installation)
                if kind == 'symlink':
                    self.assertTrue(lock.is_symlink())
                else:
                    self.assertEqual(lock.read_bytes(), b'archive payload' if kind == 'payload' else b'')

    def test_complete_inventory_still_rejects_runtime_payloads_and_symlinks(self):
        for mutation in ('lock_payload', 'update_payload', 'lock_symlink', 'executable'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                installation = Path(temporary)
                (installation / 'firefox').mkdir()
                executable = installation / 'firefox/firefox'
                executable.write_bytes(b'pinned executable')
                matrix.seed_firefox_runtime_lock(installation)
                sources = {'installation': installation}
                frozen = inventory(sources)
                lock = installation / 'firefox/.parentlock'
                if mutation == 'lock_payload':
                    lock.write_bytes(b'unexpected runtime payload')
                elif mutation == 'update_payload':
                    (installation / 'firefox/update.bin').write_bytes(b'unexpected update')
                elif mutation == 'lock_symlink':
                    lock.unlink()
                    lock.symlink_to(executable)
                else:
                    executable.write_bytes(b'changed executable')
                if mutation == 'lock_symlink':
                    with self.assertRaisesRegex(ValueError, 'symlinked'):
                        inventory(sources)
                else:
                    self.assertNotEqual(inventory(sources), frozen)


if __name__ == '__main__':
    unittest.main()
