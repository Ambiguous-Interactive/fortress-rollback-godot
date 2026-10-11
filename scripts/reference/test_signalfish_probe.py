"""Value: SDK receipts reject failed processes, stale success and changed executed evidence."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import signalfish_probe as probe


class SignalFishProbeControls(unittest.TestCase):
    def test_process_and_evidence_controls(self):
        scripts = {
            'success': 'print(\'FORTRESS_SIGNALFISH_RELAY_RESULT {"broadcast_deliveries": 1, "records": '
                       '[{"players":2,"canonical_comparisons":76,"frames_submitted":40},'
                       '{"players":4,"canonical_comparisons":152,"frames_submitted":40},'
                       '{"players":8,"canonical_comparisons":304,"frames_submitted":40}]}\')\nprint("FORTRESS_SIGNALFISH_SDK_OK")\n',
            'nonzero': 'print("FORTRESS_SIGNALFISH_SDK_OK")\nraise SystemExit(2)\n',
            'invalid_utf8': 'import os\nos.write(1, b"FORTRESS_SIGNALFISH_SDK_OK\\xff")\n',
            'timeout': 'import time\nprint("FORTRESS_SIGNALFISH_SDK_OK", flush=True)\ntime.sleep(1)\n',
            'tool_changed': 'from pathlib import Path\np = Path(__file__)\np.write_text(p.read_text() + "# changed\\n")\nprint("FORTRESS_SIGNALFISH_SDK_OK")\n',
            'source_changed': 'from pathlib import Path\nimport sys\np = Path(sys.argv[sys.argv.index("--path") + 1]) / "probe.gd"\n'
                              'p.write_text("changed source\\n")\nprint("FORTRESS_SIGNALFISH_SDK_OK")\n',
        }
        for name, relative in [('helper_changed', 'scripts/reference/fetch.py'), ('pins_changed', 'docs/reference/pins.json')]:
            scripts[name] = ('from pathlib import Path\np = Path(__file__).parent / ' + repr(relative) + '\n'
                             'p.write_text(p.read_text() + "changed source\\n")\n' + scripts['success'])
        for name, script in scripts.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                addon = root / 'addons/fortress_rollback'
                addon.mkdir(parents=True)
                (addon / 'core.gd').write_text('extends RefCounted\n')
                source = root / 'scripts/reference/signalfish_probe.gd'
                source.parent.mkdir(parents=True)
                source.write_text('extends SceneTree\n')
                (source.parent / 'fetch.py').write_text('# pinned fetch helper\n')
                pin_manifest = root / 'docs/reference/pins.json'
                pin_manifest.parent.mkdir(parents=True)
                pin_manifest.write_text('{"schema_version": 1}\n')
                (source.parent / 'signalfish_probe_new_peer.gd').write_text('extends RefCounted\n')
                (source.parent / 'signalfish_probe_relay.gd').write_text('extends RefCounted\n')
                (source.parent / 'signalfish_probe_relay_controls.gd').write_text('extends RefCounted\n')
                (source.parent / 'signalfish_probe_lifetime.gd').write_text('extends RefCounted\n')
                sdk = root / 'sdk/addons/signal_fish'
                sdk.mkdir(parents=True)
                (sdk / 'client.gd').write_text('extends Node\n')
                archive = root / 'sdk.tar.gz'
                with tarfile.open(archive, 'w:gz') as package:
                    package.add(root / 'sdk', arcname='sdk')
                manifest = {'sources': {'sdk': {'root': 'sdk', 'revision': 'a' * 40,
                                              'archive': {'digest': hashlib.sha256(archive.read_bytes()).hexdigest()}}}}
                engine = root / 'fake-engine'
                engine.write_text('#!' + sys.executable + '\n' + script)
                engine.chmod(0o755)
                output = root / 'results'
                output.mkdir()
                receipt = output / 'signalfish-sdk.json'
                receipt.write_text('{"passed": true}\n')
                with patch.object(probe, 'ROOT', root), patch.object(probe, 'load_manifest', return_value=manifest), \
                        patch.object(probe, 'fetch', return_value=archive), patch.object(probe, 'TIMEOUT', 0.1 if name == 'timeout' else 30), \
                        patch('sys.argv', ['signalfish_probe.py', '--godot', str(engine), '--output', str(output)]):
                    if name == 'success':
                        probe.main()
                        result = json.loads(receipt.read_text())
                        self.assertTrue(result['passed'])
                        self.assertEqual(result['input_inventory']['addon/core.gd'], result['executed_inventory']['addon/core.gd'])
                        self.assertEqual(result['input_inventory']['probe'], result['executed_inventory']['probe'])
                        self.assertEqual(result['input_inventory']['engine'], result['engine_sha256'])
                        self.assertEqual(result['input_inventory']['fetch_helper'], hashlib.sha256((source.parent / 'fetch.py').read_bytes()).hexdigest())
                        self.assertEqual(result['input_inventory']['pin_manifest'], hashlib.sha256(pin_manifest.read_bytes()).hexdigest())
                    else:
                        diagnostic = {'nonzero': 'SDK integration failed', 'invalid_utf8': 'utf-8',
                                      'timeout': 'SDK integration timed out', 'tool_changed': 'inventory changed',
                                      'source_changed': 'inventory changed', 'helper_changed': 'inventory changed',
                                      'pins_changed': 'inventory changed'}[name]
                        with self.assertRaisesRegex((ValueError, UnicodeDecodeError), diagnostic):
                            probe.main()
                        self.assertIs(json.loads(receipt.read_text())['passed'], False)
                        self.assertTrue((output / 'signalfish-sdk.log').exists())


if __name__ == '__main__':
    unittest.main()
