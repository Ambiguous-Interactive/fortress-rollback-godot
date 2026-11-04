"""Value: retain bounded request-failure identity without weakening fatal browser errors."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('node'), 'Node is required for browser observer controls')
class SpectatorRequestTests(unittest.TestCase):
    def run_node(self, script):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        result = subprocess.run(['node', '-e', script, str(source.resolve())], capture_output=True, encoding='utf-8', timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_bounded_sanitized_request_metadata_and_malformed_requests(self):
        self.run_node(r"""
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {observeErrors}=require(process.argv[1]);
const page=new EventEmitter(), errors=[], requestFailures=[];
let phase='navigation', closing=false;
observeErrors(page,errors,()=>closing,{requestFailures,phase:()=>phase});
const request={url:()=> 'https://user:password@fixture.invalid/assets/game.wasm?token=secret#private',
  method:()=> 'GET',resourceType:()=> 'fetch',failure:()=>({errorText:'net::ERR_ABORTED'})};
page.emit('requestfailed',request);
assert.deepEqual(requestFailures[0],{origin:'https://fixture.invalid',path:'/assets/game.wasm',method:'GET',
  resourceType:'fetch',failure:'net::ERR_ABORTED',phase:'navigation'});
for(const malformed of [null,{}, {url:()=> {throw Error('secret');}}, {url:()=> 'data:secret'},
  {url:()=> 'not a URL secret',method:()=> 42,resourceType:()=>({}),failure:()=>({errorText:'secret=private'})},
  new Proxy({},{get(){throw Error('secret');}})]) page.emit('requestfailed',malformed);
assert.equal(errors.length,7,'malformed diagnostics cannot suppress fatal request failures');
assert.equal(requestFailures.length,7);
assert(!JSON.stringify(requestFailures).includes('secret'));
assert(!JSON.stringify(requestFailures).includes('password'));
phase='not-a-phase secret';
page.emit('requestfailed',{...request,url:()=> 'https://fixture.invalid/'+'x'.repeat(1000)});
assert.equal(requestFailures.at(-1).path.length,256);
assert.equal(requestFailures.at(-1).phase,'unknown');
page.emit('requestfailed',{...request,url:()=> 'https://fixture.invalid/'+'x'.repeat(10000)});
assert.equal(requestFailures.at(-1).origin,'unknown');
for(let i=0;i<100;i++) page.emit('requestfailed',request);
assert.equal(requestFailures.length,32,'request records remain bounded');
assert.equal(errors.length,109,'every failure remains fatal after diagnostic capacity');
closing=true;
page.emit('requestfailed',request);
assert.equal(errors.length,109,'teardown preserves existing ignore policy');
assert.equal(requestFailures.length,32);
const other=new EventEmitter(), fatal=[];
observeErrors(other,fatal,()=>false,{requestFailures:[],phase:()=>{throw Error('private');}});
other.emit('requestfailed',request);
assert.deepEqual(fatal,['browser request failed']);
for(const options of [null,{requestFailures:{}},new Proxy({},{get(){throw Error('private');}})]) {
  const malformedPage=new EventEmitter(), captured=[];
  observeErrors(malformedPage,captured,()=>false,options);
  malformedPage.emit('requestfailed',request);
  assert.deepEqual(captured,['browser request failed']);
}

""")

    def test_runner_reports_startup_late_and_final_request_failures(self):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        scratch = Path(__file__).resolve().parents[2] / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        stub = """
const {EventEmitter}=require('node:events');
const page=new EventEmitter();
const fail=()=>page.emit('requestfailed',{url:()=> 'http://user:password@fixture.invalid/game.wasm?token=private#fragment',
  method:()=> 'GET',resourceType:()=> 'fetch',failure:()=>({errorText:'net::ERR_ABORTED'})});
page.addInitScript=async()=>{if(process.env.FORTRESS_TEST_FAILURE_PHASE==='startup')fail();};
page.goto=async()=>{if(process.env.FORTRESS_TEST_FAILURE_PHASE==='navigation')fail();};
let waits=0,reads=0;
page.waitForFunction=async()=>{if(++waits===2 && process.env.FORTRESS_TEST_FAILURE_PHASE==='socket-drain')fail();};
page.evaluate=async()=>{if(++reads===2 && process.env.FORTRESS_TEST_FAILURE_PHASE==='state')fail();return reads===1?{passed:true}:undefined;};
const browser={newContext:async()=>({newPage:async()=>page}),version:()=>{if(process.env.FORTRESS_TEST_FAILURE_PHASE==='final')fail();return 'stub';},close:async()=>fail()};
module.exports={chromium:{launch:async()=>browser}};
"""
        with tempfile.TemporaryDirectory(prefix='request-diagnostics-', dir=scratch) as folder:
            directory = Path(folder)
            package = directory / 'playwright.cjs'
            package.write_text(stub, encoding='utf-8')
            runtime = directory / 'runtime.json'
            runtime.write_text('{}', encoding='utf-8')
            for phase in ['none', 'startup', 'navigation', 'state', 'socket-drain', 'final']:
                environment = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_TEST_FAILURE_PHASE': phase}
                result = subprocess.run(['node', str(source.resolve()), 'http://fixture.invalid', str(runtime)], env=environment,
                                        capture_output=True, encoding='utf-8', timeout=10)
                with self.subTest(phase=phase):
                    self.assertEqual(result.stderr, '')
                    self.assertEqual(result.returncode, 0 if phase == 'none' else 1)
                    report = json.loads(result.stdout)
                    self.assertIs(report['result']['passed'], True)
                    self.assertEqual(report['errors'], [] if phase == 'none' else ['browser request failed'])
                    self.assertEqual(len(report['requestFailures']), 0 if phase == 'none' else 1)
                    if phase != 'none':
                        self.assertEqual(report['requestFailures'][0]['phase'], phase)
                        self.assertEqual(report['requestFailures'][0]['path'], '/game.wasm')
                    self.assertNotIn('password', result.stdout)
                    self.assertNotIn('private', result.stdout)


if __name__ == '__main__':
    unittest.main()
