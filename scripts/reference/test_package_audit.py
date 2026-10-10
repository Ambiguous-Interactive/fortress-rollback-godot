"""Value: addon packaging rejects development files, missing notices and symlinks before engine startup."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import package_audit


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


if __name__ == '__main__':
    unittest.main()
