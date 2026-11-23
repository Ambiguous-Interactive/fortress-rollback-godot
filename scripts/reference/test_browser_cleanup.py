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
    def test_native_input_and_terminal_holds_have_distinct_liveness(self):
        # Value: protects=physical input/control hold; fails_when=control blocked in recovery or leaks during expiry; seam=browser send and receive
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const packet = (kind, timestamp = 0, version = 2) => {
  const bytes = new Uint8Array(kind === 4 ? 46 : kind === 5 ? 44 : 28);
  bytes.set([0xf5, 0x52, version, 0, 1, 0, 0, 0, kind, 0, 0, 0], 16);
  bytes[bytes.length - 1] = timestamp;
  return bytes;
};

for (const expiry of [false, true]) {
  const seen = [];
  class Channel {
    id = 3;
    addEventListener(name, listener) { this[name] = listener; }
    send(bytes) { seen.push(Array.from(bytes)); }
  }
  class Socket {
    written = [];
    addEventListener(name, listener) { this[name] = listener; }
    send(bytes) { this.written.push(bytes); }
  }
  const channels = [new Channel(), new Channel()];
  const [channel, other] = channels;
  const window = {};
  const realm = {
    window, performance, Uint8Array, ArrayBuffer, DataView, WebSocket: Socket,
    RTCPeerConnection: class { addEventListener() {} createDataChannel() { return channels.shift(); } },
  };
  runInNewContext(`(${instrumentNativeWire})()`, realm);
  new realm.RTCPeerConnection().createDataChannel();
  new realm.RTCPeerConnection().createDataChannel();
  const wire = window.fortressNativeWire;
  const local = '01'.repeat(16);
  const relay = (sender, recipient, data) => {
    const envelope = new Uint8Array(57 + data.length + 3);
    envelope.set([70, 83, 82, 49, 1]);
    envelope.fill(sender, 21, 37);
    envelope.fill(recipient, 37, 53);
    new DataView(envelope.buffer).setUint32(53, data.length, true);
    envelope.set(data, 57);
    envelope.set([0xa1, 0x73, 0x01], 57 + data.length);
    return envelope;
  };
  wire.bind('00'.repeat(16), local);
  const socket = new window.WebSocket();
  const otherSocket = new window.WebSocket();
  channel.send(packet(4, 1));
  seen.length = 0;
  if (expiry) wire.holdTerminal();
  else wire.arm();
  channel.send(packet(2));
  channel.send(packet(4, 2));
  channel.send(packet(4, 3));
  channel.send(packet(255));
  const report = relay(1, 2, packet(4, 2));
  const reply = relay(2, 1, packet(5, 2));
  socket.send(report);
  if (!expiry) {
    channel.message({data: packet(5, 1)});
    channel.message({data: packet(255)});
    channel.message({data: packet(5, 2).subarray(0, 43)});
    other.message({data: packet(5, 2)});
    assert.deepEqual({...wire.status().control_round_trips}, {mesh: 0, relay: 0});
    channel.message({data: packet(5, 2)});
    channel.message({data: packet(5, 2)});
    otherSocket.message({data: reply});
    socket.message({data: relay(3, 1, packet(5, 2))});
    socket.message({data: relay(2, 3, packet(5, 2))});
    assert.equal(wire.status().control_round_trips.relay, 0);
    socket.message({data: reply});
  }
  assert.equal(wire.status().held.mesh, expiry ? 4 : 1);
  assert.equal(wire.status().held.relay, expiry ? 1 : 0);
  assert.deepEqual({...wire.status().control_round_trips}, {mesh: expiry ? 0 : 1, relay: expiry ? 0 : 1});
  assert.deepEqual(socket.written, expiry ? [] : [report]);
  assert.throws(() => channel.send(packet(7, 0, 3)), /native gameplay wire header/);
  if (!expiry) {
    wire.release();
    assert.deepEqual(seen, [packet(4, 2), packet(4, 3), packet(255), packet(2)].map(bytes => Array.from(bytes)));
  } else assert.deepEqual(seen, []);
}
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_abort_must_belong_to_the_departing_connection(self):
        # Value: protects=departure attribution; fails_when=another link excuses the warning; seam=browser receipt validator
        script = r"""
const assert = require('node:assert/strict');
const { receivedDepartureAbort } = require(process.argv[1]);
const leaving = {local:'departing', remote:'survivor', closeAborts:0};
const expected = {local:'survivor', remote:'departing', closeAborts:0};
const other = {local:'same-page', remote:'another-peer', closeAborts:0};
assert.ok(receivedDepartureAbort([expected, other], [{...expected, closeAborts:1}, other], [leaving]));
assert.ok(!receivedDepartureAbort([expected, other], [expected, {...other, closeAborts:1}], [leaving]));
assert.ok(!receivedDepartureAbort([expected, expected], [{...expected, closeAborts:1}], [leaving]));
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

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
if(process.env.FAIL_NATIVE_HANG==='1'){
  const timeout=global.setTimeout;
  global.setTimeout=(callback,delay,...args)=>timeout(callback,Math.min(delay,20),...args);
}
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
  if(process.env.FAIL_NATIVE_HANG==='1'){
    const pending=()=>new Promise(()=>{});
    const page={on(){},addInitScript:async()=>{},goto:async()=>{throw Error('PRIMARY_FAILURE');},evaluate:pending};
    const browser={browserType:()=>({name:()=> 'chromium'}),version:()=> 'fixture',
      close:async()=>cleanupLog('browser closed 0'),newContext:async()=>context};
    const context={browser:()=>browser,newPage:async()=>page,close:pending};
    return browser;
  }
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
                     ('ownership-diagnostic', False, False, False), ('ownership-diagnostic', False, True, True),
                     ('native_online', True, False, False)]
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
                               'FAIL_NATIVE_HANG': str(int(name == 'native_online')),
                               'FAIL_BROWSER': str(int(browser_failure)), 'FAIL_CONTEXT': str(int(context_failure)),
                               'FORTRESS_OWNERSHIP_BROWSER': 'chromium', 'FORTRESS_BROWSER_PAIR': '["chromium","chromium"]'}
                command = ['node', '--require', str(preload), str(ROOT / 'scripts/reference/browser' / (name + '.cjs')), str(directory)]
                command += [json.dumps(['res://tests/unit/test_alpha.gd'])] if name == 'ownership' else ['ws://127.0.0.1:12345/v3/ws']
                if name == 'native_online':
                    command += ['mesh', '2']
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
                    if name == 'native_online':
                        self.assertIn('native peer 0 diagnostics deadline', child.stderr)
                        self.assertIn('native context 0 close deadline', child.stderr)
                        self.assertIn('browser closed 0', log.read_text())
                    if not (primary or browser_failure or context_failure or diagnostic):
                        json.loads(child.stdout)


if __name__ == '__main__':
    unittest.main()
