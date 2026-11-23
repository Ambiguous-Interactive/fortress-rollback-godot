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
    def test_native_recovery_checks_cumulative_relay_routes(self):
        # Value: protects=healthy links stay direct; fails_when=transient relay on a healthy link is overlooked; seam=recovery receipt
        script = r"""
const assert = require('node:assert/strict');
const { assertStableRoom } = require(process.argv[1]);

const direct = ['local', 'affected', 'healthy-a', 'healthy-b'].map(uuid => ({
  uuid, state: 'playing', started_on_full_mesh: true, plan_events: 1, sdk_roster: ['local', 'affected', 'healthy-a', 'healthy-b'],
}));
const peers = direct.map((peer, index) => {
  const counterpart = direct[1 - index]?.uuid.replaceAll('-', '');
  const relay = counterpart ? { [counterpart]: 1 } : {};
  return { ...peer, relay_peers: [], wire: { sockets: [1], relayRecipients: { ...relay }, relaySenders: { ...relay } } };
});
assert.doesNotThrow(() => assertStableRoom(direct, peers));
peers[0].wire.relayRecipients.healthya = 1;
assert.throws(() => assertStableRoom(direct, peers), /relay must stay within the recovering pair/);
delete peers[0].wire.relayRecipients.healthya;
peers[1].wire.relaySenders.healthyb = 1;
assert.throws(() => assertStableRoom(direct, peers), /relay must stay within the recovering pair/);
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_recovery.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_relay_warmup_preserves_stages_with_cutoff_and_eviction(self):
        # Value: protects=exact staged warmup attribution; fails_when=missing SDK or rolled-out packets appear complete; seam=raw socket and staged observers
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const local = '11'.repeat(16), remote = '22'.repeat(16), other = '33'.repeat(16);
const bytes = n => {
  const result = Buffer.alloc(46);
  result.set([0xf5, 0x52, 2, 0], 16);
  result[24] = 4;
  result[45] = n;
  return result;
};
const raw = (socket, payload, recipient = local, sender = remote) => {
  const frame = Buffer.alloc(57 + payload.length);
  frame.set([70, 83, 82, 49, 1]);
  frame.set(Buffer.from(sender + recipient, 'hex'), 21);
  frame.writeUInt32LE(payload.length, 53);
  frame.set(payload, 57);
  socket.message({data: frame});
};
class Socket {
  addEventListener(name, listener) { this[name] = listener; }
}
let time = 1;
const window = {}, checkpoints = [], tasks = [];
const realm = {
  window, performance: {now: () => time}, console: {debug: value => checkpoints.push(value)},
  setTimeout: callback => tasks.push(callback),
  Uint8Array, ArrayBuffer, DataView, WebSocket: Socket, RTCPeerConnection: class {},
};
runInNewContext(`(${instrumentNativeWire})(false, 'warmup ')`, realm);
const socket = new window.WebSocket();
const wire = window.fortressNativeWire;
wire.bind('00'.repeat(16), local, [local, remote]);
const sample = (stage, value, code = -1) => wire.recordWarmup(stage, remote, value.toString('hex'), code);
raw(socket, bytes(90), other);
raw(socket, bytes(91), local, other);
const excluded = bytes(92);
excluded[30] = 1;
raw(socket, excluded);
const quality = bytes(0);
raw(socket, quality);
time = 1.5;
raw(socket, quality);
const identicalToken = Buffer.from(quality);
identicalToken[28] = 1;
time = 2;
sample('sdk', identicalToken);
time = 3;
sample('native', quality, 6);
time = 4;
sample('native', quality, 0);
assert.equal(checkpoints.length, 0);
assert.equal(tasks.length, 1);
tasks.shift()();
assert.equal(checkpoints.length, 1);
let [link] = wire.warmupStatus().links;
assert.equal(link.sender, remote);
assert.deepEqual(link.packets.map(packet => packet.payload).join(), [quality, identicalToken].map(b => b.toString('hex')).join());
const [rawRecord, sdkRecord] = link.packets;
// Missing SDK evidence stays absent even if the native enqueue was observed with the same payload.
assert.equal(rawRecord.raw.first_ms, 1);
assert.equal(rawRecord.raw.last_ms, 1.5);
assert.equal(rawRecord.raw.count, 2);
assert.equal(rawRecord.sdk, null);
assert.equal(rawRecord.native.first_code, 6);
assert.equal(rawRecord.native.attempts, 2);
assert.equal(rawRecord.native.acceptances, 1);
assert.equal(rawRecord.native.accepted_ms, 4);
assert.equal(sdkRecord.raw, null);
assert.equal(sdkRecord.sdk.first_ms, 2);
assert.equal(sdkRecord.native, null);
for (let i = 1; i < 30; i++) {
  time = i + 10;
  raw(socket, bytes(i));
}
time = 50;
sample('sdk', bytes(8));
sample('native', bytes(8), 0);
sample('sdk', bytes(29));
sample('native', bytes(29), 0);
wire.recordWarmupTick(300, 44, 256, 1000, false);
[link] = wire.warmupStatus().links;
assert.equal(link.packets.length, 24);
assert.equal(link.evicted, 7);
assert.equal(link.unretained.sdk, 1);
assert.equal(link.unretained.native, 1);
assert.equal(link.packets.some(packet => packet.payload === bytes(8).toString('hex')), false);
assert.equal(link.packets[23].sdk.first_ms, 50);
assert.equal(link.packets[23].native.accepted_ms, 50);
time = 1051;
raw(socket, bytes(8));
sample('sdk', bytes(8));
sample('native', bytes(8), 0);
const resurfaced = wire.warmupStatus().links[0].packets.at(-1);
assert.equal(resurfaced.payload, bytes(8).toString('hex'));
assert.equal(resurfaced.after_eviction, true);
const wireBeforeCutoff = wire.status();
assert.equal(tasks.length, 1);
wire.finishWarmup('gate');
const cutoff = JSON.stringify(wire.warmupStatus());
assert.equal(JSON.stringify(JSON.parse(checkpoints.at(-1).slice('warmup '.length))), cutoff);
assert.equal(wire.warmupStatus().recipient, local);
assert.equal(wire.warmupStatus().started_ms, 1);
assert.equal(wire.warmupStatus().cutoff.at_ms, 1051);
assert.equal(wire.warmupStatus().ticks[0].budget, 256);
tasks.shift()();
assert.equal(checkpoints.length, 2);
time = 1052;
raw(socket, bytes(30));
sample('sdk', bytes(30));
sample('native', bytes(30), 0);
wire.recordWarmupTick(1200, 0, 256, 1000, true);
wire.finishWarmup('failed');
assert.equal(JSON.stringify(wire.warmupStatus()), cutoff);
const after = wire.status();
assert.equal(after.armed, false);
assert.equal(after.deferredClose, false);
assert.equal(after.held.relay, wireBeforeCutoff.held.relay);
assert.equal(after.relaySenders[remote], wireBeforeCutoff.relaySenders[remote] + 1);
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_input_and_terminal_holds_have_distinct_liveness(self):
        # Value: protects=physical input/control hold; fails_when=control blocked in recovery or leaks during expiry; seam=browser send and receive
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const packet = (kind, timestamp = 0, version = 2) => {
  const bytes = new Uint8Array(kind === 4 ? 46 : kind === 5 ? 44 : 28);
  bytes.set([0xf5, 0x52, version, 0, 1, 0, 0, 0, kind, 0, 0, 0], 16);
  bytes[bytes.length - 2] = timestamp >>> 8;
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
    bufferedAmount = 4096;
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
  const socket = new window.WebSocket();
  socket.send('authenticate');
  assert.deepEqual(socket.written.splice(0), ['authenticate']);
  wire.bind('00'.repeat(16), local);
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
    socket.message({data: relay(2, 1, packet(4, 4))});
    socket.send(relay(1, 2, packet(5, 4)));
  }
  assert.equal(wire.status().held.mesh, expiry ? 4 : 1);
  assert.equal(wire.status().held.relay, expiry ? 1 : 0);
  assert.deepEqual({...wire.status().control_round_trips}, {mesh: expiry ? 0 : 1, relay: expiry ? 0 : 1});
  assert.deepEqual(socket.written, expiry ? [] : [report, relay(1, 2, packet(5, 4))]);
  const relayTrace = wire.status().relay_trace;
  assert.equal(relayTrace.buffered_bytes_peak, expiry ? 0 : 4096);
  assert.equal(relayTrace.events.length, expiry ? 0 : 6);
  if (!expiry) {
    assert.deepEqual(JSON.parse(JSON.stringify(relayTrace.events)).map(({direction, kind, peer, token}) => [direction, kind, peer, token.slice(-2)]), [
      ['send', 4, '02'.repeat(16), '02'], ['receive', 5, '02'.repeat(16), '02'],
      ['receive', 5, '03'.repeat(16), '02'], ['receive', 5, '02'.repeat(16), '02'],
      ['receive', 4, '02'.repeat(16), '04'], ['send', 5, '02'.repeat(16), '04'],
    ]);
    assert.equal(relayTrace.events.every(event => Number.isFinite(event.at_ms)), true);
    for (let i = 0; i < 256; i++) socket.message({data: relay(2, 1, packet(4, i))});
    const wrapped = wire.status().relay_trace;
    assert.equal(wrapped.event_count, 262);
    assert.deepEqual({...wrapped.direction_counts}, {send: 2, receive: 260});
    assert.equal(wrapped.events.length, 258);
    assert.deepEqual(wrapped.events.slice(0, 2).map(event => event.direction).join(), 'send,send');
    assert.deepEqual(wrapped.events.slice(2).map(event => parseInt(event.token.slice(-2), 16)).join(), Array.from({length: 256}, (_, i) => i).join());

    for (let i = 0; i < 256; i++) socket.send(relay(1, 2, packet(4, i)));
    const wrappedBoth = wire.status().relay_trace;
    assert.equal(wrappedBoth.event_count, 518);
    assert.deepEqual({...wrappedBoth.direction_counts}, {send: 258, receive: 260});
    assert.equal(wrappedBoth.events.map(event => event.direction).join(','), [
      ...Array(256).fill('receive'), ...Array(256).fill('send'),
    ].join(','));
    assert.equal(wrappedBoth.events.slice(256).map(event => parseInt(event.token.slice(-2), 16)).join(), Array.from({length: 256}, (_, i) => i).join());

    // A slow eight-player relay can echo an earlier report after many more are sent.
    socket.send(relay(1, 3, packet(4, 200)));
    for (let i = 0; i < 80; i++) socket.send(relay(1, 3, packet(4, i)));
    socket.message({data: relay(3, 1, packet(5, 200))});
    socket.message({data: relay(3, 1, packet(5, 200))});
    assert.equal(wire.status().control_round_trips.relay, 2);
    socket.send(relay(1, 3, packet(4, 200)));
    socket.message({data: relay(3, 1, packet(5, 200))});
    assert.equal(wire.status().control_round_trips.relay, 2);

    for (let i = 0; i <= 256; i++) socket.send(relay(1, 4, packet(4, i)));
    socket.message({data: relay(4, 1, packet(5, 0))});
    assert.equal(wire.status().control_round_trips.relay, 2);
    socket.message({data: relay(4, 1, packet(5, 1))});
    assert.equal(wire.status().control_round_trips.relay, 3);
  }
  assert.throws(() => channel.send(packet(7, 0, 3)), /native gameplay wire header/);
  if (!expiry) {
    wire.release();
    assert.deepEqual(seen, [packet(4, 2), packet(4, 3), packet(255), packet(2)].map(bytes => Array.from(bytes)));
  } else assert.deepEqual(seen, []);
}
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_relay_release_drains_originals_in_order_while_control_passes(self):
        # Value: protects=bounded FIFO recovery on the real socket hook; fails_when=release bursts or overtakes; seam=browser send
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const released = [], turns = [];
class Socket {
  static OPEN = 1;
  readyState = Socket.OPEN;
  bufferedAmount = 0;
  addEventListener() {}
  send(bytes) { released.push(bytes.at(-1)); }
}
const realm = { window: {}, performance, Uint8Array, ArrayBuffer, DataView, WebSocket: Socket,
  RTCPeerConnection: class {}, requestAnimationFrame(callback) { turns.push(callback); } };
runInNewContext(`(${instrumentNativeWire})()`, realm);
const wire = realm.window.fortressNativeWire;
wire.bind('00'.repeat(16), '01'.repeat(16));
const socket = new realm.window.WebSocket();
const relay = (kind, value) => {
  const bytes = new Uint8Array(57 + (kind === 4 ? 46 : 29));
  bytes.set([70, 83, 82, 49, 1]);
  bytes.fill(1, 21, 37);
  bytes.fill(2, 37, 53);
  new DataView(bytes.buffer).setUint32(53, bytes.length - 57, true);
  bytes.set([0xf5, 0x52, 2, 0, 1, 0, 0, 0, kind, 0, 0, 0], 73);
  bytes[bytes.length - 1] = value;
  return bytes;
};
async function run() {
  wire.arm();
  for (let i = 0; i < 33; i++) socket.send(relay(2, i));
  const recovery = wire.release();
  assert.equal(released.length, 16);
  socket.send(relay(2, 33));
  socket.send(relay(4, 99));
  assert.deepEqual(released.slice(-2), [15, 99]);
  assert.equal(turns.length, 1);
  while (turns.length) {
    turns.shift()();
    await Promise.resolve();
  }
  await recovery;
  assert.deepEqual(released.filter(value => value !== 99), Array.from({length: 34}, (_, i) => i));
  assert.equal(wire.status().released, 34);
  assert.equal(wire.status().holding, false);
  assert.equal(wire.status().held.relay, 34);
  socket.send(relay(2, 34));
  assert.equal(released.at(-1), 34);
  const stopped = { ...realm, window: {}, WebSocket: class extends Socket {}, RTCPeerConnection: class {} };
  runInNewContext(`(${instrumentNativeWire})()`, stopped);
  const stoppedWire = stopped.window.fortressNativeWire;
  const stoppedSocket = new stopped.window.WebSocket();
  stoppedWire.bind('00'.repeat(16), '01'.repeat(16));
  stoppedWire.arm();
  stoppedSocket.send(relay(2, 55));
  stoppedSocket.readyState = 3;
  await assert.rejects(stoppedWire.release(), /closed before release send/);
  assert.equal(stoppedWire.status().released, 0);

  const full = { ...realm, window: {}, WebSocket: class extends Socket {}, RTCPeerConnection: class {} };
  runInNewContext(`(${instrumentNativeWire})()`, full);
  const fullWire = full.window.fortressNativeWire;
  const fullSocket = new full.window.WebSocket();
  fullWire.bind('00'.repeat(16), '01'.repeat(16));
  fullWire.arm();
  for (let i = 0; i < 1024; i++) fullSocket.send(relay(2, i));
  const overflow = assert.rejects(fullWire.release(), /native packet hold exceeded bounds/);
  assert.throws(() => fullSocket.send(relay(2, 33)), /native packet hold exceeded bounds/);
  while (turns.length) {
    turns.shift()();
    await Promise.resolve();
  }
  await overflow;
  assert.equal(fullWire.status().released, 16);
}
const timer = setTimeout(() => { throw new Error('release did not settle'); }, 1000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_history_capture_rejects_stale_rows_and_snapshot_mutations(self):
        # Value: protects=fresh confirmed history; fails_when=reusing a capture or skipping either comparison; why_new=per-render capture had no request boundary; seam=browser
        script = r"""
const assert = require('node:assert/strict');
const { compareHistory, readConfirmedHistory } = require(process.argv[1]);

async function run() {
  const fresh = { frames: 2, rows: { 0: [1, 2], 1: [1, 2] }, snapshots: { 1: '01', 2: '02' } };
  global.window = { fortressNativeHistory: { ...fresh, snapshots: { 1: 'ff', 2: 'ff' } } };
  const page = { async evaluate(operation, value) { return operation(value); } };
  const captured = await readConfirmedHistory(page, 2, async (owner, complete, frames) => {
    assert.equal(owner, page);
    assert.equal(window.fortressNativeCapture, 2);
    assert.equal(complete(frames), false, 'an old capture for the same frame count must be invalidated');
    window.fortressNativeHistory = fresh;
    assert.equal(complete(frames), true);
  });
  assert.deepEqual(captured, fresh);
  await assert.rejects(readConfirmedHistory(page, 2, async (_, complete, frames) => {
    window.fortressNativeHistory = fresh;
    assert.equal(complete(frames), true);
    window.fortressNativeHistory = { ...fresh, frames: 3 };
  }), /native history receipt changed/);

  const peers = [0, 1].map(slot => ({ ...fresh, index: slot, slot, uuid: String(slot), session_id: '00'.repeat(16), room_id: 'room' }));
  compareHistory(peers, 2);
  for (const [field, mutation, error] of [
    ['rows', { 1: [2, 1] }, /input row at frame 1/],
    ['snapshots', { 2: 'ff' }, /canonical state at frame 2/],
  ]) {
    const changed = { ...peers[1], [field]: { ...peers[1][field], ...mutation } };
    assert.throws(() => compareHistory([peers[0], changed], 2), error);
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_webkit_abort_must_belong_to_the_reported_closed_link(self):
        # Value: protects=departure attribution; fails_when=another link excuses the warning; seam=browser receipt validator
        script = r"""
const assert = require('node:assert/strict');
const { closeEvidence, reportedChannel } = require(process.argv[1]);
const receivedClose = (index, channel, before, closed, closer, {sentAt, clocks} = {}) =>
  Boolean(closeEvidence({index, channel, sentAt}, before, closed, closer, clocks).proof);
const frame = '    at fortressNativeSend_5 (:5:27)';
assert.deepEqual(reportedChannel('Error sending binary data\n' + frame), {channel:5, sentAt:null});
assert.deepEqual(reportedChannel(frame + '\n' + frame), {channel:null, sentAt:null});
assert.deepEqual(reportedChannel('at unrelated (:5:27)'), {channel:null, sentAt:null});
assert.deepEqual(reportedChannel('    at fortressNativeSend_5_1795419840003000 (:5:27)'),
  {channel:5, sentAt:1795419840003000});
const counterpart = {local:'closing', remote:'survivor', closed:true, connectionClosed:true};
const link = {index:5, local:'survivor', remote:'closing', closeAborts:1, closed:false};
const other = {index:8, local:'same-page', remote:'another-peer', closeAborts:0};
const newAbort = {...link, closeAborts:2, closed:true};
const closed = [[counterpart], [newAbort, other]];
assert.ok(receivedClose(1, 5, [link, other], closed));
const streamClosed = [[{...counterpart, connectionClosed:false}], [{...link, closed:true}, other]];
assert.ok(receivedClose(1, 5, [link, other], streamClosed, 0));
assert.ok(!receivedClose(1, 5, [link, other], streamClosed));
const timed = [[{...counterpart, closedAt:30000}], [{...link, closed:true}, other]];
const clocks = [{offsetMin:9900, offsetMax:10100}, {offsetMin:-5100, offsetMax:-4900}];
assert.ok(receivedClose(1, 5, [link, other], timed, null, {sentAt:47300, clocks}));
assert.ok(!receivedClose(1, 5, [link, other], timed, null, {sentAt:44000, clocks}));
assert.ok(!receivedClose(1, 5, [link, other], timed, null, {sentAt:47199, clocks}));
assert.ok(!receivedClose(1, 5, [link, other], timed, null, {sentAt:64000}));
assert.ok(!receivedClose(1, 5, [link, other], [[counterpart], [link, other]], 0));
assert.ok(!receivedClose(1, 5, [link, other], [[], closed[1], [counterpart]], 0));
assert.ok(!receivedClose(1, null, [link, other], closed));
assert.ok(!receivedClose(1, 8, [link, other], closed));
assert.ok(!receivedClose(1, 5, [link, other], [[{...counterpart, connectionClosed:false}], closed[1]]));
assert.ok(!receivedClose(1, 5, [link, other], [[counterpart, counterpart], closed[1]]));
assert.ok(!receivedClose(1, 5, [link, other], [[counterpart], [link, {...other, closeAborts:1}]]));
const same = {...link, remote:link.local};
assert.ok(!receivedClose(1, 5, [same], [[], [{...same, closeAborts:2, closed:true}]]));
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_close_receipt_names_the_ambiguous_link(self):
        # Value: protects=failed causal attribution; fails_when=actual reciprocal channel or clock gap is lost; seam=browser receipt validator
        script = r"""
const assert = require('node:assert/strict');
const { closeEvidence } = require(process.argv[1]);
const before = {index:17, local:'survivor', remote:'leaver', closeAborts:1, closed:false};
const sender = {...before, closed:true, connectionClosed:true, closedAt:50000};
const closer = {index:18, local:'leaver', remote:'survivor', closeAborts:0, closed:true, connectionClosed:true, closedAt:30000};
const clocks = [{offsetMin:9900, offsetMax:10100}, {offsetMin:-5100, offsetMax:-4900}];
const tagged = {index:1, channel:17, sentAt:47199};
const fail = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks);
assert.deepEqual(JSON.parse(JSON.stringify(fail)), {
  ...tagged, closer:null, before, sender, counterparts:[{...closer, owner:0}], minimumGapUs:1999, proof:null,
});
const timed = closeEvidence({...tagged, sentAt:47200}, [before], [[closer], [sender]], null, clocks);
assert.equal(timed.minimumGapUs, 2000);
assert.equal(timed.proof, 'clock-order');
const aborted = closeEvidence(tagged, [before], [[closer], [{...sender, closeAborts:2}]], null, clocks);
assert.equal(aborted.minimumGapUs, 1999);
assert.equal(aborted.proof, 'sctp-abort');
const missing = closeEvidence(tagged, [before], [[], [sender]], null, clocks);
assert.deepEqual(missing.counterparts, []);
assert.equal(missing.minimumGapUs, null);
assert.equal(missing.proof, null);
const duplicate = closeEvidence(tagged, [before], [[closer], [sender], [closer]], null, clocks);
assert.deepEqual(duplicate.counterparts, [{...closer, owner:0}, {...closer, owner:2}]);
assert.equal(duplicate.proof, null);
const stream = closeEvidence(tagged, [before], [[{...closer, connectionClosed:false, closedAt:null}], [sender]], 0, undefined);
assert.equal(stream.closer, 0);
assert.equal(stream.minimumGapUs, null);
assert.equal(stream.proof, 'stream-close');
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_close_rechecks_the_remote_page_without_an_abort(self):
        # Value: protects=late reciprocal close; fails_when=only sender abort is retried or missing snapshots excuse an error; seam=room verifier
        script = r"""
const assert = require('node:assert/strict');
const { waitForCloseProofs } = require(process.argv[1]);
const before = {index:17, local:'survivor', remote:'leaver', closeAborts:0, closed:false};
const reciprocal = {index:18, local:'leaver', remote:'survivor', closeAborts:0, closed:true, connectionClosed:true, closedAt:30000};
const clocks = [{offsetMin:9900, offsetMax:10100}, {offsetMin:-5100, offsetMax:-4900}];
const sample = (links, offset) => ({
  evaluate: async () => {
    const start = now;
    const snapshot = links();
    await Promise.resolve();
    now = Math.max(now, start + 1);
    return {links:snapshot, sampledAt:start * 1000 - offset + 500};
  },
});
const initial = [{wire:{sctp:[reciprocal]}}, {wire:{sctp:[before]}}];
const warning = [{index:1, channel:17, sentAt:47200}];
const sender = sample(() => [before], -5000);
let now = 25;

(async () => {
  let rounds = 0;
  const clock = () => now;
  const pause = async ms => { now += ms; };
  const report = {};
  const late = sample(() => ++rounds === 1 ? [{...reciprocal, connectionClosed:false, closedAt:null}] : [reciprocal], 10000);
  assert.deepEqual(await waitForCloseProofs([late, sender], initial, warning, report, { clocks, clock, delay: pause }), [[reciprocal], [before]]);
  assert.equal(rounds, 2);
  assert.equal(report.proofs[0].proof, 'clock-order');

  now = 25;
  let attempts = 0;
  const ambiguous = sample(() => { attempts++; return [{...reciprocal, closedAt:30001}]; }, 10000);
  const expire = async () => { now = 5025; };
  await assert.rejects(waitForCloseProofs([ambiguous, sender], initial, warning, report, { clocks, clock, delay: expire }),
    /WebKit close evidence deadline .*peer 1 channel 17/);
  assert.equal(attempts, 1);
  assert.equal(report.proofs[0].minimumGapUs, 1999);
  assert.equal(report.proofs[0].proof, null);

  now = 25;
  const crashed = { evaluate: async () => { throw Error('Page crashed'); } };
  await assert.rejects(waitForCloseProofs([late, crashed], initial, warning, report, { clocks, clock, delay: pause }),
    error => error instanceof AggregateError && error.errors[0].message.includes('peer 1') && error.errors[0].cause.message === 'Page crashed');
  assert.deepEqual(report.snapshotErrors, [{index:1, reason:'Error: Page crashed'}]);
  assert.deepEqual(report.proofs, []);

  const lateReply = sample(() => { now = 5025; return [reciprocal]; }, 10000);
  now = 25;
  await assert.rejects(waitForCloseProofs([lateReply, sender], initial, warning, report, { clocks, clock, delay: pause }),
    /WebKit close evidence deadline/);
  assert.deepEqual(report.proofs, []);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_close_intersects_only_bounded_clock_samples(self):
        # Value: protects=exact close-time margin and bounded calibration; fails_when=proof ignores compatible samples or accepts bad clocks; seam=room verifier
        script = r"""
const assert = require('node:assert/strict');
const { waitForCloseProofs } = require(process.argv[1]);
const before = {index:17, local:'survivor', remote:'leaver', closeAborts:0, closed:false};
const reciprocal = {index:18, local:'leaver', remote:'survivor', connectionClosed:true, closedAt:30000};
const initial = [{wire:{sctp:[reciprocal]}}, {wire:{sctp:[before]}}];
const clocks = [{offsetMin:9500, offsetMax:10500}, {offsetMin:-5500, offsetMax:-4500}];

async function collect(sentAt, sender, contradictory = false) {
  let now = 25;
  const report = {};
  const sampled = [[], []];
  const pages = [reciprocal, sender].map((link, index) => ({
    evaluate: async (_read, sampleClock) => {
      sampled[index].push(sampleClock);
      const offsets = [10000, contradictory && sampled[index].length === 1 ? 0 : -5000];
      return {links:[link], sampledAt:now * 1000 - offsets[index]};
    },
  }));
  const proof = waitForCloseProofs(pages, initial, [{index:1, channel:17, sentAt}], report, {
    clocks, clock: () => now, delay: async ms => { now = sampled[0].length === 5 ? 5025 : now + ms; },
  });
  return { report, proof, sampled };
}

(async () => {
  const enough = await collect(47082, before);
  await enough.proof;
  assert.equal(enough.report.proofs[0].minimumGapUs, 2000);
  assert.equal(enough.report.proofs[0].proof, 'clock-order');
  assert.deepEqual(enough.report.clocks, [{offsetMin:9959, offsetMax:10041}, {offsetMin:-5041, offsetMax:-4959}]);

  const short = await collect(47081, before);
  await assert.rejects(short.proof, /WebKit close evidence deadline .*peer 1 channel 17/);
  assert.equal(short.report.proofs[0].minimumGapUs, 1999);
  assert.deepEqual(short.sampled, [[true,true,true,true,false], [true,true,true,true,false]]);

  const conflict = await collect(52000, before, true);
  await assert.rejects(conflict.proof, /WebKit close evidence deadline .*peer 1 channel 17/);
  assert.equal(conflict.report.clocks[1], null);
  assert.equal(conflict.report.proofs[0].minimumGapUs, null);

  const exactAbort = await collect(47081, {...before, closeAborts:1}, true);
  await exactAbort.proof;
  assert.equal(exactAbort.report.clocks[1], null);
  assert.equal(exactAbort.report.proofs[0].proof, 'sctp-abort');
})().catch(error => { console.error(error); process.exitCode = 1; });
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
