"""Value: addon packaging rejects development files, missing notices and symlinks before engine startup."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import package_audit
from test_package_builder import fixture

GODOT: Path | None = None


class PackageAuditControls(unittest.TestCase):
    def test_invalid_candidate_supersedes_success_before_running_engine(self):
        for defect in ('rust', 'extensionless_tool', 'missing_notice', 'symlink', 'root_symlink', 'fifo', 'empty_notice', 'wrong_license', 'orphan_uid', 'development_directory',
                       'missing_transport', 'notices_only', 'unknown_script'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                addon = fixture(root)
                if defect == 'missing_transport':
                    shutil.rmtree(addon / 'transport')
                elif defect == 'notices_only':
                    for family in ('core', 'protocol', 'transport'):
                        shutil.rmtree(addon / family)
                elif defect == 'unknown_script':
                    (addon / 'core/test_dev.gd').write_text('extends RefCounted\n')
                elif defect == 'missing_notice':
                    (addon / 'NOTICE.md').unlink()
                elif defect == 'symlink':
                    (addon / 'linked-directory').symlink_to(root, target_is_directory=True)
                elif defect == 'root_symlink':
                    original = root / 'original-addon'
                    addon.rename(original)
                    addon.symlink_to(original, target_is_directory=True)
                elif defect == 'fifo':
                    os.mkfifo(addon / 'ignored-pipe')
                elif defect == 'empty_notice':
                    (addon / 'NOTICE.md').write_text(' \n')
                elif defect == 'orphan_uid':
                    (addon / 'core/missing.gd.uid').write_text('uid://orphan\n')
                elif defect == 'development_directory':
                    (addon / 'tools').mkdir()
                elif defect == 'wrong_license':
                    (addon / 'LICENSE').write_text('invented notice\n')
                else:
                    (addon / ('tool.rs' if defect == 'rust' else 'tool')).write_text('development tool\n')
                output = root / 'results'
                output.mkdir()
                receipt = output / 'package-audit.json'
                receipt.write_text('{"passed": true}\n')
                with patch.object(package_audit, 'ROOT', root), patch('sys.argv',
                        ['package_audit.py', '--godot', '/nonexistent-engine', '--output', str(output)]), \
                        patch.object(package_audit.subprocess, 'run') as run:
                    with self.assertRaisesRegex(ValueError,
                            'missing runtime attribution|unsupported addon file|symlink|nonregular entry|empty runtime attribution'
                            '|differs from canonical|unsupported addon directory|missing required runtime scripts'):
                        package_audit.main()
                    run.assert_not_called()
                self.assertIs(json.loads(receipt.read_text())['passed'], False)


class RuntimeScriptControls(unittest.TestCase):
    # Value: an unused optional adapter with a missing dependency must fail the clean install.
    def test_every_runtime_script_loads_without_sdk(self):
        if GODOT is None:
            self.skipTest('pass --godot to execute real addon controls')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(package_audit.ROOT / package_audit.ADDON, root / package_audit.ADDON)
            shutil.copyfile(package_audit.ROOT / 'LICENSE', root / 'LICENSE')
            canonical = root / 'docs/reference/licenses/fortress-LICENSE-MIT'
            canonical.parent.mkdir(parents=True)
            shutil.copyfile(package_audit.ROOT / 'docs/reference/licenses/fortress-LICENSE-MIT', canonical)
            optional = root / package_audit.ADDON / 'transport/signalfish_adapter.gd'
            optional.parent.mkdir(exist_ok=True)
            original = optional.read_bytes()
            optional.write_bytes(original + b'\nconst MissingSDK = preload("res://addons/signal_fish/missing.gd")\n')
            output = root / 'results'
            arguments = ['package_audit.py', '--godot', str(GODOT), '--output', str(output)]
            with patch.object(package_audit, 'ROOT', root), patch('sys.argv', arguments):
                with self.assertRaisesRegex(ValueError, 'clean addon failed'):
                    package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], False)
                self.assertIn('missing.gd', (output / 'clean-addon.log').read_text())
                optional.write_bytes(original)
                package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], True)


class SpectatorReplayInstallControls(unittest.TestCase):
    # Value: installed capture must preserve final status and reject failed final validation.
    def test_installed_spectator_replay_is_actually_validated(self):
        if GODOT is None:
            self.skipTest('pass --godot to execute real addon controls')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(package_audit.ROOT / package_audit.ADDON, root / package_audit.ADDON)
            shutil.copyfile(package_audit.ROOT / 'LICENSE', root / 'LICENSE')
            canonical = root / 'docs/reference/licenses/fortress-LICENSE-MIT'
            canonical.parent.mkdir(parents=True)
            shutil.copyfile(package_audit.ROOT / 'docs/reference/licenses/fortress-LICENSE-MIT', canonical)
            output = root / 'results'
            arguments = ['package_audit.py', '--godot', str(GODOT), '--output', str(output)]
            with patch.object(package_audit, 'ROOT', root), patch('sys.argv', arguments):
                package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], True)
                player = root / package_audit.ADDON / 'core/replay_player.gd'
                original = player.read_text()
                anchor = 'if not expected.is_empty() and checkpoint.checksum != expected:'
                self.assertEqual(original.count(anchor), 1)
                replacement = 'if _frame != _replay.frame_count() and not expected.is_empty() and checkpoint.checksum != expected:'
                player.write_text(original.replace(anchor, replacement))
                with self.assertRaisesRegex(ValueError, 'clean addon failed'):
                    package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], False)
                log = (output / 'clean-addon.log').read_text()
                self.assertIn('installed_spectator_replay', log)
                self.assertNotIn(package_audit.MARKER, log)
                self.assertNotIn('ERROR:', log)
                player.write_text(original)
                package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', type=Path)
    args, remaining = parser.parse_known_args()
    GODOT = args.godot.resolve() if args.godot else None
    unittest.main(argv=[__file__, *remaining])
