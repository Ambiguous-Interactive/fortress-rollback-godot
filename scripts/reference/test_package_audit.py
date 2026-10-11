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

GODOT: Path | None = None


class PackageAuditControls(unittest.TestCase):
    def test_invalid_candidate_supersedes_success_before_running_engine(self):
        for defect in ('rust', 'extensionless_tool', 'missing_notice', 'symlink', 'root_symlink', 'fifo', 'empty_notice', 'wrong_license'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                addon = root / package_audit.ADDON
                (addon / 'licenses').mkdir(parents=True)
                for name in ('LICENSE', 'NOTICE.md', 'licenses/fortress-LICENSE-MIT'):
                    (addon / name).write_text('required notice\n')
                (root / 'LICENSE').write_text('required notice\n')
                canonical = root / 'docs/reference/licenses/fortress-LICENSE-MIT'
                canonical.parent.mkdir(parents=True)
                canonical.write_text('required notice\n')
                (addon / 'core.gd').write_text('extends RefCounted\n')
                if defect == 'missing_notice':
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
                            'missing runtime attribution|unsupported addon file|symlink|nonregular entry|empty runtime attribution|differs from canonical'):
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
            optional = root / package_audit.ADDON / 'transport/optional_dependency.gd'
            optional.parent.mkdir(exist_ok=True)
            optional.write_text('extends RefCounted\nconst SDK = preload("res://addons/signal_fish/missing.gd")\n')
            output = root / 'results'
            arguments = ['package_audit.py', '--godot', str(GODOT), '--output', str(output)]
            with patch.object(package_audit, 'ROOT', root), patch('sys.argv', arguments):
                with self.assertRaisesRegex(ValueError, 'clean addon failed'):
                    package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], False)
                self.assertIn('missing.gd', (output / 'clean-addon.log').read_text())
                optional.write_text('extends RefCounted\n')
                package_audit.main()
                self.assertIs(json.loads((output / 'package-audit.json').read_text())['passed'], True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', type=Path)
    args, remaining = parser.parse_known_args()
    GODOT = args.godot.resolve() if args.godot else None
    unittest.main(argv=[__file__, *remaining])
