"""Value: browser cleanup preserves causes and releases every owned server and browser."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('node'), 'Node is required for actual browser entrypoint controls')
class BrowserCleanupTests(unittest.TestCase):
    def test_real_entrypoints_finish_cleanup_and_keep_original_and_cleanup_errors(self):
        scratch = ROOT / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='cleanup-entrypoint-', dir=scratch) as folder:
            directory = Path(folder)
            log = directory / 'cleanup.log'
            preload = directory / 'preload.cjs'
            preload.write_text(r"""
const fs=require('node:fs'),http=require('node:http'),https=require('node:https');
global.cleanupLog=value=>fs.appendFileSync(process.env.CLEANUP_LOG,value+'\n');
const originalError=console.error;
console.error=(...values)=>{
  if(process.env.FAIL_CUSTOM_INSPECT==='1'&&process.exitCode!==1)throw Error('CLI_EXIT_CODE_NOT_SET');
  originalError(...values);
};
const create=http.createServer;
http.createServer=function(...args){const server=create.apply(this,args);
  server.on('close',()=>cleanupLog('server closed'));return server;};
https.createServer=(_options,listener)=>http.createServer(listener);
""", encoding='utf-8')
            package = directory / 'playwright.cjs'
            package.write_text(r"""
if(process.env.FAIL_OPAQUE==='1')throw Object.create(null);
const inspectionFailure={original:'ORIGINAL_CLI_FAILURE',get hidden(){throw Error('CLI_GETTER_FAILURE');},
  [require('node:util').inspect.custom](){throw Error('CLI_FORMAT_FAILURE');}};
if(process.env.FAIL_CUSTOM_INSPECT==='1'&&process.env.CUSTOM_INSPECT_ON_GOTO!=='1')throw inspectionFailure;
let launched=0;
module.exports.chromium={launch:async()=>{
  const index=launched++;
  const page={on(){},addInitScript:async()=>{},goto:async()=>{},evaluate:async()=>({})};
  const context={newPage:async()=>{if(index===1)throw Error('PRIMARY_FAILURE');return page;},close:async()=>{
    await new Promise(resolve=>setTimeout(resolve,index===1?60:1));cleanupLog('context closed '+index);
    if(process.env.FAIL_CONTEXT==='1')throw Error('CONTEXT_FAILURE_'+index);}};
  return {version:()=> 'fixture',contexts:()=>[context],close:async()=>{
    await new Promise(resolve=>setTimeout(resolve,index===1?60:1));cleanupLog('browser closed '+index);
    if(process.env.FAIL_BROWSER==='1')throw Error('BROWSER_FAILURE_'+index);},
    newContext:async()=>{if(process.env.FAIL_CONTEXT==='1')return context;throw Error('PRIMARY_FAILURE');},
    newPage:async()=>({on(){},goto:async()=>{
      if(process.env.CUSTOM_INSPECT_ON_GOTO==='1')throw inspectionFailure;
      if(process.env.FAIL_PRIMARY==='1')throw Error('PRIMARY_FAILURE');},
      waitForFunction:async()=>{if(process.env.FAIL_OWNERSHIP_DIAGNOSTIC==='1')throw Error('OWNERSHIP_WAIT_FAILURE');},
      evaluate:async()=>{if(process.env.FAIL_OWNERSHIP_DIAGNOSTIC==='1')throw Object.create(null);return{passed:true};}})};
}};
""", encoding='utf-8')
            certificate = directory / 'tls'
            certificate.write_text('', encoding='utf-8')
            cases = [('smoke', False, False, False), ('smoke', True, False, False), ('smoke', False, True, False),
                     ('smoke', True, True, False), ('ownership', False, False, False), ('ownership', True, True, True),
                     ('ownership', True, False, True), ('ownership', False, True, True),
                     ('online', True, False, False), ('online', True, True, False),
                     ('webrtc', True, False, False), ('webrtc', True, True, False),
                     ('webrtc', True, False, True), ('webrtc', True, True, True),
                     ('online-opaque', True, False, False), ('webrtc-opaque', True, False, False),
                     *[(name+'-inspect', True, False, False) for name in ['smoke', 'ownership', 'online', 'webrtc', 'spectator']],
                     ('ownership-diagnostic', False, False, False), ('ownership-diagnostic', False, True, True)]
            for name, primary, browser_failure, context_failure in cases:
                opaque = name.endswith('-opaque')
                custom_inspect = name.endswith('-inspect')
                diagnostic = name.endswith('-diagnostic')
                name = name.removesuffix('-opaque').removesuffix('-inspect').removesuffix('-diagnostic')
                log.unlink(missing_ok=True)
                environment = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_CHROMIUM_EXECUTABLE': '/fixture',
                               'FORTRESS_TLS_CERT': str(certificate), 'FORTRESS_TLS_KEY': str(certificate), 'CLEANUP_LOG': str(log),
                               'FAIL_PRIMARY': str(int(primary)), 'FAIL_OPAQUE': str(int(opaque)),
                               'FAIL_CUSTOM_INSPECT': str(int(custom_inspect)), 'CUSTOM_INSPECT_ON_GOTO': str(int(custom_inspect and name == 'smoke')),
                               'FAIL_OWNERSHIP_DIAGNOSTIC': str(int(diagnostic)),
                               'FAIL_BROWSER': str(int(browser_failure)), 'FAIL_CONTEXT': str(int(context_failure)),
                               'FORTRESS_OWNERSHIP_BROWSER': 'chromium', 'FORTRESS_BROWSER_PAIR': '["chromium","chromium"]'}
                command = ['node', '--require', str(preload), str(ROOT / 'scripts/reference/browser' / (name + '.cjs')), str(directory)]
                command += [json.dumps(['res://tests/unit/test_alpha.gd'])] if name == 'ownership' else ['ws://127.0.0.1:12345/v3/ws']
                with self.subTest(name=name, primary=primary, browser_failure=browser_failure, context_failure=context_failure):
                    # Match sibling Node controls: allow hosted startup scheduling while still bounding hangs.
                    child = subprocess.run(command, env=environment, capture_output=True, encoding='utf-8', timeout=10)
                    self.assertEqual(child.returncode, int(primary or browser_failure or context_failure or diagnostic), child.stderr)
                    if custom_inspect:
                        if name == 'smoke':
                            self.assertEqual(log.read_text().splitlines()[-1], 'server closed')
                        else:
                            self.assertFalse(log.exists(), 'early module rejection owns no server')
                        self.assertIn('ORIGINAL_CLI_FAILURE', child.stderr)
                        self.assertNotIn('Error: CLI_FORMAT_FAILURE', child.stderr)
                        self.assertNotIn('Error: CLI_GETTER_FAILURE', child.stderr)
                        self.assertEqual(child.stdout, '')
                        continue
                    if diagnostic:
                        self.assertIn('OWNERSHIP_WAIT_FAILURE', child.stderr)
                    if opaque:
                        self.assertFalse(log.exists(), 'early module rejection owns no server')
                        self.assertIn('null prototype', child.stderr, 'CLI retains the original opaque rejection')
                        self.assertNotIn('TypeError', child.stderr, 'CLI must not replace the opaque rejection during conversion')
                        self.assertEqual(child.stdout, '')
                        continue
                    self.assertEqual(log.read_text(encoding='utf-8').splitlines()[-1], 'server closed')
                    if primary:
                        self.assertIn('PRIMARY_FAILURE', child.stderr)
                    if browser_failure:
                        self.assertIn('BROWSER_FAILURE_0', child.stderr)
                    if context_failure:
                        self.assertIn('CONTEXT_FAILURE', child.stderr)
                    if name == 'ownership' or (name == 'webrtc' and context_failure):
                        self.assertLess(log.read_text().index('context closed'), log.read_text().index('browser closed'))
                    if name == 'webrtc':
                        if context_failure:
                            self.assertIn('CONTEXT_FAILURE_0', child.stderr)
                            self.assertIn('CONTEXT_FAILURE_1', child.stderr)
                            self.assertLess(log.read_text().index('context closed 1'), log.read_text().index('browser closed'))
                        self.assertIn('browser closed 1', log.read_text())
                        if browser_failure:
                            self.assertIn('BROWSER_FAILURE_1', child.stderr)
                    if not (primary or browser_failure or context_failure or diagnostic):
                        json.loads(child.stdout)


if __name__ == '__main__':
    unittest.main()
