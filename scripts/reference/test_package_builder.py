"""Value: installable candidate bytes survive host metadata changes and reject non-runtime inputs; seam=none."""
import os
import shutil
from pathlib import Path
import tarfile
import tempfile
import unittest

from package_audit import ADDON, build_archive


def fixture(root: Path) -> Path:
    addon = root / ADDON
    repository = Path(__file__).resolve().parents[2]
    shutil.copytree(repository / ADDON, addon)
    shutil.copyfile(repository / 'LICENSE', root / 'LICENSE')
    canonical = root / 'docs/reference/licenses/fortress-LICENSE-MIT'
    canonical.parent.mkdir(parents=True)
    shutil.copyfile(repository / 'docs/reference/licenses/fortress-LICENSE-MIT', canonical)
    return addon


class PackageBuilderTests(unittest.TestCase):
    def test_archive_is_reproducible_across_metadata_and_install_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            addon = fixture(root)
            first, second = root / 'first.tar', root / 'second.tar'
            frozen = build_archive(root, first)
            for path in addon.rglob('*'):
                if path.is_file():
                    os.utime(path, (123456789, 123456789))
                    path.chmod(0o755)
            build_archive(root, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            relocated = root / 'other-checkout'
            shutil.copytree(root / 'addons', relocated / 'addons')
            shutil.copytree(root / 'docs', relocated / 'docs')
            shutil.copyfile(root / 'LICENSE', relocated / 'LICENSE')
            build_archive(relocated, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first) as archive:
                self.assertEqual(archive.getnames(), sorted(frozen))
                for member in archive.getmembers():
                    self.assertTrue(member.isfile())
                    self.assertEqual((member.mode, member.mtime, member.uid, member.gid, member.uname, member.gname), (0o644, 0, 0, 0, '', ''))
                    self.assertEqual(archive.extractfile(member).read(), frozen[member.name])
                installed = root / 'clean-install'
                archive.extractall(installed, filter='data')
            self.assertEqual(sorted(str(path.relative_to(installed)) for path in installed.rglob('*') if path.is_file()), sorted(frozen))
            script = addon / 'core/config.gd'
            script.write_text('extends RefCounted\nvar changed: int = 1\n', encoding='utf-8')
            build_archive(root, second)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())

    def test_complete_runtime_inventory_is_required_and_development_scripts_are_rejected(self):
        for defect in ('missing_script', 'missing_transport', 'notices_only', 'development_script'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                addon = fixture(root)
                build_archive(root, root / 'control.tar')
                if defect == 'missing_script':
                    (addon / 'core/config.gd').unlink()
                    (addon / 'core/config.gd.uid').unlink()
                elif defect == 'missing_transport':
                    shutil.rmtree(addon / 'transport')
                elif defect == 'notices_only':
                    for family in ('core', 'protocol', 'transport'):
                        shutil.rmtree(addon / family)
                else:
                    (addon / 'core/test_dev.gd').write_text('extends RefCounted\n', encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'missing required runtime script|unsupported addon file'):
                    build_archive(root, root / 'rejected.tar')
                self.assertFalse((root / 'rejected.tar').exists())

    def test_rejected_input_preserves_previous_candidate_without_partial_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            addon = fixture(root)
            destination = root / 'candidate.tar'
            build_archive(root, destination)
            original = destination.read_bytes()
            for defect in ('orphan.gd.uid', 'tool.gd', 'core/native.so', 'core/notes.md'):
                with self.subTest(defect=defect):
                    path = addon / defect
                    path.write_text('unexpected content\n', encoding='utf-8')
                    with self.assertRaisesRegex(ValueError, 'unsupported addon file'):
                        build_archive(root, destination)
                    self.assertEqual(destination.read_bytes(), original)
                    path.unlink()
            self.assertEqual(list(root.glob('.candidate.tar.*')), [])
            with self.assertRaisesRegex(ValueError, 'outside the addon'):
                build_archive(root, addon / 'candidate.tar')
            self.assertFalse((addon / 'candidate.tar').exists())


if __name__ == '__main__':
    unittest.main()
