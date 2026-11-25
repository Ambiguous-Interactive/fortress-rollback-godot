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
    def test_native_leave_requires_a_correlated_publication(self):
        # Value: protects=departure receipt; fails_when=stale or incomplete evidence passes; seam=Playwright console event
        script = r"""
const assert = require('node:assert/strict');
const { leaveWithReceipt } = require(process.argv[1]);
const message = (id, stage, data = {}) => ({ text: () => 'fortress native departure ' + JSON.stringify({ id, stage, page_ms: 4, ...data }) });
function fixture(published, dispatchError = false) {
  let predicate, resolve, reject;
  return {
    waitForEvent(event, options) {
      assert.equal(event, 'console');
      predicate = options.predicate;
      return new Promise((yes, no) => { resolve = yes; reject = no; });
    },
    async evaluate(_publish, command) {
      assert.deepEqual(command, { id: 18, kind: 'leave' });
      assert.equal(typeof predicate, 'function');
      assert.equal(predicate(message(17, 'published', { code: 0, state: 'offline' })), false);
      assert.equal(predicate(message(18, 'published', { code: 0, state: 'offline' })), false);
      assert.equal(predicate(message(18, 'entered')), false);
      setImmediate(() => {
        if (published && predicate(message(18, 'published', published))) {
          resolve();
          predicate(message(18, 'published', { code: 0, state: 'offline' }));
        } else {
          reject(Error('departure timed out'));
        }
      });
      if (dispatchError) throw Error('dispatch response lost');
    }
  };
}
let completed = false;
process.on('beforeExit', () => {
  if (!completed) process.exitCode = 1;
});
(async () => {
  const trace = { id: 18 };
  await leaveWithReceipt(fixture({ code: 0, state: 'offline' }), trace);
  assert.ok(trace.controller_dispatch_ms <= trace.published.controller_ms);
  assert.equal(trace.entered.page_ms, 4);
  assert.equal(trace.published.code, 0);
  for (const [published, pattern, error] of [[null, /departure timed out/], [{ code: 0, state: 'offline' }, /dispatch response lost/, true],
    [{ code: 1, state: 'offline' }, /leave failed/], [{ code: 0, state: 'playing' }, /leave failed/]]) {
    const partial = { id: 18 };
    await assert.rejects(leaveWithReceipt(fixture(published, error), partial), pattern);
    assert.equal(partial.entered.page_ms, 4);
    if (published) assert.deepEqual({ code: partial.published.code, state: partial.published.state }, published);
    else assert.equal(partial.published, undefined);
  }
  completed = true;
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_recovery_holds_only_offerers_signaling(self):
        # Value: protects=unmodified responder signaling; fails_when=answerer ICE stays queued; seam=browser socket
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const candidate = JSON.stringify({ type: 'Signal', data: { generation: 'gen', to: 'peer',
  signal: { MeshRecovery: { v: 1, room: 'room', from_epoch: 1, to_epoch: 2, attempt: 1, kind: 'IceCandidate', body: 'candidate' } } } });
for (const holdsOffer of [true, false]) {
  const sent = [], window = {};
  class Socket {
    send(data) { sent.push(data); }
    addEventListener() {}
  }
  runInNewContext(`(${instrumentNativeWire})(false, '')`, {
    window, WebSocket: Socket, RTCPeerConnection: class {}, performance: { now: () => 1 },
  });
  const wire = window.fortressNativeWire;
  wire.observeRecovery({ room: 'room', generation: 'gen', peer: 'peer', localEpoch: 1, peerEpoch: 2, holdsOffer });
  const socket = new window.WebSocket();
  socket.send(candidate);
  assert.deepEqual(sent, holdsOffer ? [] : [candidate], 'answerer ICE must pass through unchanged');
  assert.equal(wire.status().recovery.pending, Number(holdsOffer));
}
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_recovery_drops_only_selected_first_offer(self):
        # Value: protects=exact Offer-only loss; fails_when=the fault drops ICE, a later offer or unrelated traffic; seam=SDK socket
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const sent = [], window = {};
class Socket {
  static OPEN = 1;
  readyState = 1;
  send(data) { sent.push(data); }
  addEventListener() {}
}
runInNewContext(`(${instrumentNativeWire})(false, '')`, {
  window, WebSocket: Socket, RTCPeerConnection: class {}, performance: { now: () => 1 },
});
const wire = window.fortressNativeWire;
wire.observeRecovery({ room: 'room', generation: 'gen', peer: 'peer', localEpoch: 1, peerEpoch: 2, holdsOffer: true });
function signal(kind, attempt = 1, room = 'room') {
  return JSON.stringify({ type: 'Signal', data: { generation: 'gen', to: 'peer',
    signal: { MeshRecovery: { v: 1, room, from_epoch: 1, to_epoch: 2, attempt, kind, body: 'body' } } } });
}
const socket = new window.WebSocket();
const ice = signal('IceCandidate'), other = signal('Offer', 1, 'other'), retry = signal('Offer', 2);
for (const data of [signal('Offer'), ice, other]) socket.send(data);
assert.deepEqual(sent, [other]);
assert.equal(wire.releaseRecovery('drop-first-offer'), 1);
socket.send(retry);
assert.deepEqual(sent, [other, ice, retry], 'only the scoped first Offer must be lost');
assert.equal(wire.status().recovery.droppedOffers, 1);
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

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

    def test_native_recovery_requires_direct_progress_through_final_capture(self):
        # Value: protects=direct gameplay through final capture; fails_when=open channels can stop carrying inputs; seam=recovery receipt
        script = r"""
const assert = require('node:assert/strict');
const { assertRecoveredRoom } = require(process.argv[1]);
const targets = [1, 0, 3, 2];
const direct = ['first', 'second', 'third', 'fourth'].map((uuid, index, roster) => ({
  uuid, state: 'playing', started_on_full_mesh: true, plan_events: 1, sdk_roster: roster,
  wire: { sctp: [0, 1, 2].map(channel => ({ index: channel, open: true, closeEvents: 0, local: 'local', remote: 'remote',
    inputsSent: 0, inputsReceived: 0 })) },
}));
const restored = direct.map((peer, index) => {
  const sctp = peer.wire.sctp.map(link => ({ ...link, index: link.index === 0 ? 3 : link.index, inputsSent: 1, inputsReceived: 1 }));
  const relay = { [direct[targets[index]].uuid]: 1 };
  return { ...peer, wire: { sctp, sockets: [1], relayRecipients: relay, relaySenders: relay } };
});
const evidence = {
  pairs: [[0, 1], [2, 3]].map(pair => ({
    old: pair.map(index => direct[index].wire.sctp[0]),
    replacement: pair.map(index => restored[index].wire.sctp[0]),
  })),
  targets,
};
const final = restored.map(peer => ({
  ...peer, wire: { ...peer.wire, sctp: peer.wire.sctp.map(link => ({ ...link, inputsSent: 2, inputsReceived: 2 })) },
}));
assert.doesNotThrow(() => assertRecoveredRoom(direct, restored, final, evidence));
for (const link of final.flatMap(peer => peer.wire.sctp)) {
  for (const counter of ['inputsSent', 'inputsReceived']) {
    link[counter] = 1;
    assert.throws(() => assertRecoveredRoom(direct, restored, final, evidence), /direct gameplay must advance through final history capture/);
    link[counter] = 2;
  }
}
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_recovery.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_relay_warmup_counts_only_timely_playing_gate_receipts(self):
        # Value: protects=warmup without a page RPC; fails_when=invalid, duplicate or late receipts open the hold; seam=console delivery
        script = r"""
const assert = require('node:assert/strict');
const { createWarmupBarrier, WARMUP_CHECKPOINT } = require(process.argv[1]);
const checkpoint = (cutoff, extra = {}) => WARMUP_CHECKPOINT + JSON.stringify({
  cutoff, started_ms: 2, through_ms: cutoff?.at_ms ?? 8, recipient: '01'.repeat(16),
  links: [{ sender: '02'.repeat(16) }], ticks: [], tick_count: 0, ...extra,
});
const gate = { reason: 'gate', state: 'playing', frame: 16, confirmed: 12, at_ms: 8 };

async function run() {
  let now = 9;
  const barrier = createWarmupBarrier(2, () => now);
  barrier.record(1, checkpoint(gate));
  assert.deepEqual(barrier.received, [null, null], 'a receipt must follow start dispatch');
  assert.deepEqual(barrier.frontier().peers[1], { outcome: 'gate_unaccepted', observation: gate, received_ms: 9 });
  let acknowledgeStart;
  const wait = barrier.wait(() => new Promise(resolve => { acknowledgeStart = resolve; }), 1000);
  let passed = false;
  void wait.then(() => { passed = true; }, () => {});
  now = 10;
  barrier.record(0, checkpoint(gate));
  now = 11;
  acknowledgeStart();
  barrier.record(0, checkpoint(gate));
  now = 12;
  barrier.record(1, checkpoint(null));
  barrier.record(1, WARMUP_CHECKPOINT + 'null');
  barrier.record(1, WARMUP_CHECKPOINT + '{');
  barrier.record(1, checkpoint({ ...gate, state: 'failed' }));
  barrier.record(1, checkpoint({ ...gate, confirmed: 11 }));
  barrier.record(1, checkpoint({ ...gate, at_ms: 1 }));
  barrier.record(1, checkpoint(gate, { recipient: null }));
  barrier.record(1, checkpoint(gate, { links: [null] }));
  barrier.record(1, checkpoint(gate, { ticks: [null], tick_count: 1 }));
  await new Promise(setImmediate);
  assert.equal(passed, false);
  assert.equal(barrier.received[1], null);
  assert.ok(barrier.errors[1]);
  assert.deepEqual(barrier.checkpoints[1].cutoff, gate);
  now = 13;
  barrier.record(1, checkpoint(gate));
  await wait;
  assert.deepEqual(barrier.received, [10, 13]);

  const late = createWarmupBarrier(2, () => now);
  const pending = late.wait(() => {}, 5);
  void pending.catch(() => {});
  await Promise.resolve(); // The acknowledged start fixes the deadline at 18.
  const tick = { state: 'playing', frame: 16, confirmed: 8, at_ms: 7, before: 5, after: 0, budget: 256, elapsed_us: 500 };
  now = 16;
  late.record(0, checkpoint(null, { ticks: [tick], tick_count: 1 }));
  now = 17;
  late.record(0, checkpoint(null, { ticks: [{ ...tick, at_ms: 8, confirmed: 12 }, tick], tick_count: 2 }));
  late.record(0, checkpoint(null, { ticks: [{ ...tick, confirmed: '8' }], tick_count: 1 }));
  assert.deepEqual(late.frontier().peers, [
    { outcome: 'observed_below_gate', observation: tick, received_ms: 16 },
    { outcome: 'unobserved', observation: null, received_ms: null },
  ]);
  now = 18;
  late.record(1, checkpoint(gate));
  await assert.rejects(pending, /absolute native warmup deadline/);
  assert.deepEqual(late.received, [null, null]);
  assert.deepEqual(late.checkpoints[1].cutoff, gate);
  assert.deepEqual(late.frontier(), { deadline_ms: 18, peers: [
    { outcome: 'observed_below_gate', observation: tick, received_ms: 16 },
    { outcome: 'gate_received_late', observation: gate, received_ms: 18 },
  ] });
  now = 22;
  const failureTick = { ...tick, state: 'failed', at_ms: 8 };
  late.record(0, checkpoint(null, { ticks: [failureTick], tick_count: 2 }));
  assert.deepEqual(late.frontier().peers[0], { outcome: 'terminal', observation: failureTick, received_ms: 22 });
  now = 23;
  const failure = { ...gate, reason: 'failed', state: 'failed' };
  late.record(0, checkpoint(failure));
  now = 24;
  late.record(0, checkpoint(null, { ticks: [tick], tick_count: 1 }));
  late.record(1, checkpoint(null, { ticks: [tick], tick_count: 1 }));
  assert.deepEqual(late.frontier().peers[0], { outcome: 'terminal', observation: failure, received_ms: 23 });
  assert.deepEqual(late.frontier().peers[1], { outcome: 'gate_received_late', observation: gate, received_ms: 18 });
}
const timer = setTimeout(() => { throw new Error('warmup barrier test did not settle'); }, 2000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_warmup_reports_expired_peer_in_failure_checkpoint(self):
        # Value: protects=expiry attribution without a page RPC; fails_when=the frozen endpoint is lost or misattributed; seam=warmup console checkpoint
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { createWarmupBarrier, instrumentNativeWire, WARMUP_CHECKPOINT } = require(process.argv[1]);
const roster = ['11', '22', '33'].map(pair => pair.repeat(16));
for (const [endpoint, sender] of [[3, roster[2]], [0, undefined], [2, undefined], [4, undefined]]) {
  const barrier = createWarmupBarrier(3, () => 2);
  const window = {};
  runInNewContext(`(${instrumentNativeWire})(false, "${WARMUP_CHECKPOINT}")`, {
    window, performance: { now: () => 1 }, console: { debug: text => barrier.record(0, text) },
    WebSocket: class {}, RTCPeerConnection: class {},
  });
  const wire = window.fortressNativeWire;
  wire.bind('00'.repeat(16), roster[1], roster);
  wire.finishWarmup('failed', 13, 5, endpoint);
  wire.finishWarmup('failed', 14, 6, 1);
  assert.deepEqual(barrier.errors, [null, null, null]);
  const receipt = barrier.checkpoints[0];
  assert.equal(receipt.cutoff.confirmed, 5, 'only the first cutoff is published');
  assert.equal(receipt.cutoff.terminal_endpoint, sender === undefined ? undefined : endpoint);
  assert.equal(receipt.cutoff.terminal_uuid, sender);
  if (sender) {
    assert.ok(receipt.links.some(link => link.sender === sender));
    const wrong = { ...receipt, cutoff: { ...receipt.cutoff, terminal_uuid: roster[0] } };
    barrier.record(1, WARMUP_CHECKPOINT + JSON.stringify(wrong));
    assert.match(barrier.errors[1], /invalid warmup expiry endpoint/);
    assert.equal(barrier.checkpoints[1], null);
    const duplicate = { ...receipt, links: [receipt.links[1], receipt.links[1]] };
    barrier.record(2, WARMUP_CHECKPOINT + JSON.stringify(duplicate));
    assert.match(barrier.errors[2], /invalid warmup roster/);
    assert.equal(barrier.checkpoints[2], null);
  }
  assert.deepEqual(barrier.received, [null, null, null], 'failure cannot open the warmup gate');
}
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_warmup_preserves_stages_with_cutoff_and_eviction(self):
        # Value: protects=exact staged warmup attribution; fails_when=an unmatched reply implies processing; seam=raw socket and staged observers
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
const relayFrame = (payload, recipient, sender) => {
  const frame = Buffer.alloc(57 + payload.length);
  frame.set([70, 83, 82, 49, 1]);
  frame.set(Buffer.from(sender + recipient, 'hex'), 21);
  frame.writeUInt32LE(payload.length, 53);
  frame.set(payload, 57);
  return frame;
};
const raw = (socket, payload, recipient = local, sender = remote) => socket.message({data: relayFrame(payload, recipient, sender)});
class Socket {
  addEventListener(name, listener) { this[name] = listener; }
  send() {}
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
wire.bind('00'.repeat(16), local, [local, remote, other]);
const sample = (stage, value, code = -1, sender = remote) => wire.recordWarmup(stage, sender, value.toString('hex'), code);
const reply = (report, recipient = remote) => {
  const payload = Buffer.alloc(44);
  payload.set(report.subarray(0, 28));
  payload[24] = 5;
  payload.set(report.subarray(30), 28);
  socket.send(relayFrame(payload, recipient, local));
};
const lastReply = () => wire.warmupStatus().links[0].last_replied_report;
raw(socket, bytes(90), other);
raw(socket, bytes(91), local, '44'.repeat(16));
const excluded = bytes(92);
excluded[30] = 1;
raw(socket, excluded);
const quality = bytes(0);
raw(socket, quality);
time = 1.5;
raw(socket, quality);
const sdkOnly = bytes(94);
time = 2;
sample('sdk', sdkOnly);
time = 3;
sample('native', quality, 6);
reply(quality);
assert.equal(lastReply()?.reply_observed_ms, undefined);
time = 4;
sample('native', quality, 0);
reply(quality, other);
reply(bytes(93));
assert.equal(lastReply()?.reply_observed_ms, undefined);
assert.equal(wire.warmupStatus().links[1].last_replied_report?.reply_observed_ms, undefined);
time = 5;
reply(quality);
assert.deepEqual(JSON.parse(JSON.stringify(lastReply() ?? null)), {
  payload: quality.toString('hex'), raw_observed_ms: 1, native_enqueued_ms: 4, reply_observed_ms: 5,
});
time = 6;
reply(quality);
assert.equal(lastReply().reply_observed_ms, 5);
assert.equal(checkpoints.length, 0);
assert.equal(tasks.length, 1);
tasks.shift()();
assert.equal(checkpoints.length, 1);
let [link] = wire.warmupStatus().links;
assert.equal(link.sender, remote);
assert.deepEqual(link.packets.map(packet => packet.payload).join(), [quality, sdkOnly].map(b => b.toString('hex')).join());
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
const collision = bytes(1);
const incomplete = Buffer.from(collision);
incomplete[28] = 1;
sample('native', incomplete, 0, other);
raw(socket, collision, local, other);
sample('native', collision, 0, other);
reply(collision, other);
assert.equal(wire.warmupStatus().links[1].last_replied_report?.reply_observed_ms, undefined, 'an incomplete competing report can explain the reply');
for (let i = 1; i < 30; i++) {
  time = i + 10;
  raw(socket, bytes(i));
}
time = 50;
sample('sdk', bytes(8));
sample('native', bytes(8), 0);
sample('sdk', bytes(29));
sample('native', bytes(29), 0);
wire.recordWarmupTick(300, 44, 256, 1000, 'starting', 0, -1);
[link] = wire.warmupStatus().links;
assert.equal(link.packets.length, 24);
assert.equal(link.evicted, 7);
assert.equal(link.unretained.sdk, 1);
assert.equal(link.unretained.native, 1);
assert.equal(link.packets.some(packet => packet.payload === bytes(8).toString('hex')), false);
assert.equal(link.packets[23].sdk.first_ms, 50);
assert.equal(link.packets[23].native.accepted_ms, 50);
reply(bytes(29));
assert.equal(lastReply().reply_observed_ms, 50);
for (let i = 31; i < 48; i++) {
  time = i + 20;
  raw(socket, bytes(i));
}
assert.equal(wire.warmupStatus().links[0].packets.length, 24);
assert.equal(wire.warmupStatus().links[0].packets.some(packet => packet.payload === bytes(29).toString('hex')), false);
assert.equal(lastReply().payload, bytes(29).toString('hex'));
time = 1051;
raw(socket, bytes(8));
sample('sdk', bytes(8));
sample('native', bytes(8), 0);
const resurfaced = wire.warmupStatus().links[0].packets.at(-1);
assert.equal(resurfaced.payload, bytes(8).toString('hex'));
assert.equal(resurfaced.after_eviction, true);
reply(bytes(8));
assert.equal(lastReply().payload, bytes(29).toString('hex'), 'a dropped report with the same token can explain the reply');
const ambiguous = Buffer.from(bytes(8));
ambiguous[28] = 1;
raw(socket, ambiguous);
sample('native', ambiguous, 0);
reply(bytes(8));
assert.equal(lastReply().payload, bytes(29).toString('hex'));
const wireBeforeCutoff = wire.status();
assert.equal(tasks.length, 1);
for (let i = 0; i < 24; i++) {
  wire.recordWarmupTick(300, 44, 256, 1000, 'playing', 16, 11);
}
wire.finishWarmup('playing', 16, 12);
const cutoff = JSON.stringify(wire.warmupStatus());
assert.equal(JSON.stringify(JSON.parse(checkpoints.at(-1).slice('warmup '.length))), cutoff);
assert.equal(wire.warmupStatus().recipient, local);
assert.equal(wire.warmupStatus().started_ms, 1);
assert.equal(wire.warmupStatus().cutoff.at_ms, 1051);
assert.equal(wire.warmupStatus().cutoff.reason, 'gate');
assert.equal(wire.warmupStatus().cutoff.state, 'playing');
assert.equal(wire.warmupStatus().cutoff.confirmed, 12);
assert.equal(wire.warmupStatus().tick_count, 25);
assert.equal(wire.warmupStatus().ticks.length, 24);
assert.equal(JSON.stringify(wire.warmupStatus().ticks[0]), JSON.stringify({
  at_ms: 1051, before: 300, after: 44, budget: 256, elapsed_us: 1000, state: 'playing', frame: 16, confirmed: 11,
}));
assert.equal(wire.warmupStatus().ticks[0].budget, 256);
tasks.shift()();
assert.equal(checkpoints.length, 2);
time = 1052;
raw(socket, bytes(30));
sample('sdk', bytes(30));
sample('native', bytes(30), 0);
reply(bytes(30));
wire.recordWarmupTick(1200, 0, 256, 1000, 'failed', 16, 12);
wire.finishWarmup('failed', 16, 12);
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
  const milestones = [];
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
  const window = {
    fortressNativePostRelease: { mark(kind, frames, { at_ms, queued, released }) { milestones.push([kind, at_ms, queued, released]); } },
  };
  let now = 10;
  const realm = {
    window, performance: { now: () => now }, Uint8Array, ArrayBuffer, DataView, WebSocket: Socket,
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
  const roster = [1, 2, 3, 4].map(value => ('0' + value).repeat(16));
  wire.bind('00'.repeat(16), local, roster);
  const otherSocket = new window.WebSocket();
  channel.send(packet(4, 1));
  seen.length = 0;
  if (expiry) wire.holdTerminal();
  else wire.arm();
  assert.equal(wire.recordHoldReadiness('mesh'), null);
  assert.equal(wire.recordHoldReadiness('constructor'), null);
  channel.send(packet(2));
  assert.deepEqual(milestones, expiry ? [] : [['hold_first_input', 10, 1, 0]]);
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
    assert.equal(wire.recordHoldReadiness('mesh'), null);
    channel.message({data: packet(5, 2)});
    channel.message({data: packet(5, 2)});
    now = 15;
    assert.equal(wire.recordHoldReadiness('mesh').at_ms, 15);
    otherSocket.message({data: reply});
    socket.message({data: relay(3, 1, packet(5, 2))});
    socket.message({data: relay(2, 3, packet(5, 2))});
    assert.equal(wire.status().control_round_trips.relay, 0);
    assert.deepEqual(milestones, [['hold_first_input', 10, 1, 0], ['hold_first_control', 10, 1, 0]]);
    socket.message({data: reply});
    assert.equal(wire.recordHoldReadiness('relay'), null);
    socket.message({data: relay(2, 1, packet(4, 4))});
    socket.send(relay(1, 2, packet(5, 4)));
  }
  assert.equal(wire.status().held.mesh, expiry ? 4 : 1);
  assert.equal(wire.status().held.relay, expiry ? 1 : 0);
  assert.deepEqual({...wire.status().control_round_trips}, {mesh: expiry ? 0 : 1, relay: expiry ? 0 : 1});
  assert.deepEqual(milestones, expiry ? [] : [['hold_first_input', 10, 1, 0], ['hold_first_control', 10, 1, 0]]);
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
    const observed = wire.holdObservation().traffic;
    const quietLink = observed.find(event => event.peer === roster[2] && event.direction === 'receive' && event.kind === 5);
    assert.equal(quietLink?.token.slice(-2), '02', 'a busy link must not erase the last quiet-link packet');
    assert.equal(observed.length, 5);
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
    now = 25;
    assert.equal(wire.recordHoldReadiness('mesh').at_ms, 15);
    wire.release();
    assert.equal(wire.recordHoldReadiness('mesh'), null);
    assert.deepEqual(JSON.parse(JSON.stringify(wire.status().hold_boundaries)), {
      armed: { at_ms: 10, held: { mesh: 0, relay: 0 }, bytes: 0, queued: 0, released: 0 },
      ready: { at_ms: 15, held: { mesh: 1, relay: 0 }, bytes: 28, queued: 1, released: 0 },
      release: { at_ms: 25, held: { mesh: 1, relay: 0 }, bytes: 28, queued: 1, released: 0 },
    });
    assert.deepEqual(seen, [packet(4, 2), packet(4, 3), packet(255), packet(2)].map(bytes => Array.from(bytes)));
  } else assert.deepEqual(seen, []);
}
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_stalled_snapshot_starts_release_before_returning_to_controller(self):
        # Value: protects=release start in the stalled snapshot turn; fails_when=capture and release need separate calls; seam=page evaluation
        script = r"""
const assert = require('node:assert/strict');
const { armAndWaitForInput, captureAndReleaseInput, waitForCorrectedHistory } = require(process.argv[1]);
let evaluations = 0, holding = true, started = 0;
const releaseMark = { at_ms: 80, held: { mesh: 0, relay: 9 }, bytes: 1440 };
const turns = [];
global.requestAnimationFrame = callback => turns.push(callback);
global.window = {
  fortressNative: { state: 'playing', frame: 13, confirmed: 12, stalls: 2, prediction: -1, restores: 1, nested: { count: 0 } },
  fortressNativeWire: {
    arm: () => 'arm mark',
    recordHoldReadiness(route) {
      assert.equal(route, 'relay');
      assert.equal(window.fortressNative.stalls, 3);
      return { at_ms: 30, held: { mesh: 0, relay: 3 }, bytes: 480 };
    },
    status: () => ({ holding }),
    async release() {
      assert.equal(evaluations, 2);
      holding = false;
      started++;
      window.fortressNative.restores++;
      window.fortressNative.nested.count++;
      return releaseMark;
    },
  },
};
const page = { async evaluate(callback, argument) { evaluations++; return callback(argument); } };
async function run() {
  const ready = armAndWaitForInput(page, 'relay');
  assert.equal(turns.length, 1);
  window.fortressNative.frame = 21;
  window.fortressNative.prediction = 12;
  window.fortressNative.stalls++;
  turns.shift()();
  const receipt = await ready;
  assert.deepEqual(receipt, { armed: { frame: 13, confirmed: 12, stalls: 2, hold: 'arm mark' },
    ready: { at_ms: 30, held: { mesh: 0, relay: 3 }, bytes: 480, frame: 21, confirmed: 12, restores: 1 } });

  // Another page can release before this page's stalled snapshot runs.
  window.fortressNative.restores = 2;
  const before = await captureAndReleaseInput(page, 3);
  assert.deepEqual(before, { index: 3, state: 'playing', frame: 21, confirmed: 12, stalls: 3, prediction: 12,
    restores: 2, nested: { count: 0 }, wire: { holding: true }, release: releaseMark });
  assert.equal(evaluations, 2);
  assert.equal(started, 1);
  const confirm = (owner, predicate, target, timeout) => {
    assert.equal(owner, page);
    assert.equal(timeout, 200);
    window.fortressNative = { state: 'playing', confirmed: 40, restores: before.restores };
    assert.equal(predicate(target), true, 'a restore before local release still counts');
    window.fortressNative.restores = receipt.ready.restores;
    assert.equal(predicate(target), false, 'a restore must follow readiness');
  };
  await waitForCorrectedHistory([page], 40, [{ page: receipt.ready }], confirm, 200);

  window.fortressNative = { state: 'failed', message: 'left before release' };
  await assert.rejects(captureAndReleaseInput(page, 4), /left before release/);
  assert.equal(started, 1);
  window.fortressNative = { state: 'playing' };
  window.fortressNativeWire.release = async () => { throw new Error('send failed'); };
  await assert.rejects(captureAndReleaseInput(page, 5), /send failed/);
  assert.equal(window.fortressNativeStalled.index, 5);
  assert.equal(window.fortressNativeStalled.state, 'playing');
}
const timer = setTimeout(() => { throw new Error('input hold test did not settle'); }, 1000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

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
  const started = await recovery;
  assert.equal(started.held.relay, 33);
  assert.deepEqual(released.filter(value => value !== 99), Array.from({length: 34}, (_, i) => i));
  assert.equal(wire.status().released, 34);
  assert.equal(wire.status().holding, false);
  assert.equal(wire.status().held.relay, 34);
  socket.send(relay(2, 34));
  assert.equal(released.at(-1), 34);
  const stopped = { ...realm, window: {}, WebSocket: class extends Socket {}, RTCPeerConnection: class {} };
  runInNewContext(`(${instrumentNativeWire})()`, stopped);
  const closed = [];
  stopped.window.fortressNativePostRelease = { mark(kind, frames, hold) { closed.push({ kind, ...hold }); } };
  const stoppedWire = stopped.window.fortressNativeWire;
  const stoppedSocket = new stopped.window.WebSocket();
  stoppedWire.bind('00'.repeat(16), '01'.repeat(16));
  stoppedWire.arm();
  for (let i = 0; i < 33; i++) stoppedSocket.send(relay(2, i));
  const blocked = assert.rejects(stoppedWire.release(), /closed before release send/);
  stoppedSocket.readyState = 3;
  turns.shift()();
  await blocked;
  assert.equal(stoppedWire.status().released, 16);
  const close = closed.find(sample => sample.kind === 'release_socket_closed');
  assert.deepEqual([close?.released, close?.queued, close?.socket_state, close?.socket_stage, close?.held_send], [16, 17, 3, 'before_send', true]);
  assert.throws(() => stoppedSocket.send(relay(4, 99)), /closed before release send/);
  const laterControl = closed.find(sample => sample.kind === 'release_control_socket_closed');
  assert.deepEqual([laterControl?.released, laterControl?.queued, laterControl?.held_send], [16, 17, false]);

  const closing = { ...realm, window: {}, WebSocket: class extends Socket {
    send(bytes) {
      if (bytes.at(-1) === 99) this.readyState = 2;
      super.send(bytes);
    }
  }, RTCPeerConnection: class {} };
  const closedDuring = [];
  closing.window.fortressNativePostRelease = { mark(kind, frames, hold) { closedDuring.push({ kind, ...hold }); } };
  runInNewContext(`(${instrumentNativeWire})()`, closing);
  const closingWire = closing.window.fortressNativeWire;
  const closingSocket = new closing.window.WebSocket();
  closingWire.bind('00'.repeat(16), '01'.repeat(16));
  closingWire.arm();
  for (let i = 0; i < 33; i++) closingSocket.send(relay(2, i));
  const interrupted = assert.rejects(closingWire.release(), /closed before release send/);
  assert.throws(() => closingSocket.send(relay(4, 99)), /closed during release send/);
  const closingControl = closedDuring.find(sample => sample.kind === 'release_control_socket_closed');
  assert.deepEqual([closingControl?.released, closingControl?.queued, closingControl?.socket_state, closingControl?.socket_stage, closingControl?.held_send],
    [16, 17, 2, 'during_send', false]);
  turns.shift()();
  await interrupted;
  const closingOriginals = closedDuring.filter(sample => sample.kind === 'release_socket_closed');
  assert.equal(closingOriginals.length, 1);
  assert.equal(closingOriginals[0].held_send, true);
  assert.equal(closingOriginals[0].socket_stage, 'before_send');

  const full = { ...realm, window: {}, WebSocket: class extends Socket {}, RTCPeerConnection: class {} };
  runInNewContext(`(${instrumentNativeWire})()`, full);
  const cap = [];
  full.window.fortressNativePostRelease = { mark(kind, frames, hold) { cap.push({ kind, ...hold }); } };
  const fullWire = full.window.fortressNativeWire;
  const fullSocket = new full.window.WebSocket();
  fullWire.bind('00'.repeat(16), '01'.repeat(16));
  fullWire.arm();
  for (let i = 0; i < 1024; i++) fullSocket.send(relay(2, i));
  const overflow = assert.rejects(fullWire.release(), /native packet hold exceeded bounds/);
  assert.throws(() => fullSocket.send(relay(2, 33)), /native packet hold exceeded bounds/);
  assert.throws(() => fullSocket.send(relay(2, 34)), /native packet hold exceeded bounds/);
  while (turns.length) {
    turns.shift()();
    await Promise.resolve();
  }
  await overflow;
  assert.equal(fullWire.status().released, 16);
  assert.deepEqual(cap.map(function (sample) {
    return [sample.kind, sample.held.relay, sample.bytes, sample.queued, sample.released];
  }), [['hold_first_input', 1, 86, 1, 0], ['release_progress', 1024, 88064, 1008, 16], ['hold_cap', 1024, 88064, 1008, 16]]);
}
const timer = setTimeout(() => { throw new Error('release did not settle'); }, 1000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_expiry_matches_release_and_received_traffic_without_page_reads(self):
        # Value: protects=release-time expiry attribution from console receipts; fails_when=reporter or sender evidence is lost; seam=page and controller
        script = r"""
const assert = require('node:assert/strict');
const { bindDepartureCheckpoints, instrumentPostRelease, missedCorrectionDeadline, postReleaseCheckpoint, relayReleaseEvidence } = require(process.argv[1]);
const roster = Array.from({length: 8}, (_, i) => '00000000-0000-0000-0000-00000000000' + (i + 1));
const uuids = [roster[4], roster[0], roster[5], roster[2], roster[6], roster[1], roster[7], roster[3]];
const peers = uuids.map(() => ({}));
const prefix = 'fortress native post-release ';
let receiptOrder = 0;
const incoming = controller_ms => ({ controller_ms, controller_order: ++receiptOrder });
const record = (index, fields, receivedAt, rosterKnown = true) =>
  postReleaseCheckpoint(peers[index], prefix + JSON.stringify(fields), incoming(receivedAt), rosterKnown ? roster : undefined, uuids[index]);
let now = 100, controller = 120;
global.performance = {now: () => now};
global.window = {};
console.debug = text => postReleaseCheckpoint(peers[2], text, incoming(controller), roster, uuids[2]);
instrumentPostRelease(prefix, 40);
window.fortressNativePostRelease.bindDeparture(uuids[2], roster);
const evidence = (depth, accepted) => ({observed_us: 6000, sdk_queued: depth, sdk_peak: 710,
  last_accepted: accepted === null ? null : {accepted_us: accepted, kind: 4, bytes: 46}});
const hold = (kind, released) => ({kind, page_ms: 500 + released, state: 'playing', turns: 28, frame: 30, confirmed: 12, restores: 0,
  held: {mesh: 0, relay: 33}, bytes: 2838, queued: 33 - released, released});
record(6, hold('release_started', 0), 115);
record(6, hold('release_progress', 16), 115);
window.fortressNativePostRelease.recordDeparture('native_expiry', 8, JSON.stringify(evidence(702, 3000)));
record(6, hold('release_completed', 33), 120);
record(0, {kind: 'native_expiry', endpoint: 8, uuid: uuids[6], page_ms: 5, expiry: evidence(674, null)}, 130, false);
bindDepartureCheckpoints(peers[0], roster, uuids[0]);
record(2, {...hold('release_socket_closed', 16), socket_state: 3, socket_stage: 'before_send', held_send: true}, 135);
record(1, hold('hold_cap', 16), 140);
record(3, {kind: 'native_expiry', endpoint: 8, uuid: uuids[6], page_ms: 6, expiry: evidence(0, 6001)}, 145);
const report = relayReleaseEvidence(peers, uuids, false);
assert.equal(report.correction_deadline_reached, false);
const timeout = Object.assign(new Error('timed out'), {name: 'TimeoutError'});
assert.equal(missedCorrectionDeadline('corrected history', timeout, 120, 119), false);
assert.equal(missedCorrectionDeadline('corrected history', timeout, 120, 120), true);
assert.equal(missedCorrectionDeadline('post-confirmation engine turn', timeout, 120, 121), false);
for (const message of ['native relay socket closed before release send', 'native packet hold exceeded bounds']) {
  assert.equal(missedCorrectionDeadline('input release', new Error(message), 120, 131), false);
}
for (const message of ['absolute native peer 2 input release deadline', 'absolute native corrected history deadline',
  'native input release exhausted the correction deadline', 'native corrected history exceeded the correction deadline']) {
  assert.equal(missedCorrectionDeadline('input release', new Error(message), 120, 120), true);
}
const timedOut = missedCorrectionDeadline('corrected history', timeout, 120, 120);
assert.equal(relayReleaseEvidence(peers, uuids, timedOut).correction_deadline_reached, true);
assert.deepEqual(report.socket_closed_pages, [2]);
assert.deepEqual(report.hold_cap_pages, [1]);
assert.deepEqual(report.expiries.map(({reporter_page, expired_page, last_release_checkpoint, expiry}) =>
  [reporter_page, expired_page, last_release_checkpoint.kind, last_release_checkpoint.released, expiry.sdk_queued, expiry.last_accepted?.accepted_us]),
  [[0, 6, 'release_completed', 33, 674, undefined], [2, 6, 'release_progress', 16, 702, 3000]]);
assert.match(peers[3].checkpoint_error, /invalid native expiry evidence/);
assert.equal(peers[2].native_expiry.expiry.last_accepted.kind, 4);
assert.equal(peers[2].native_expiry.expiry.last_accepted.bytes, 46);
assert.equal(peers[2].release_socket_closed.socket_state, 3);
assert.equal(peers[2].release_socket_closed.socket_stage, 'before_send');
assert.equal(peers[2].release_socket_closed.held_send, true);
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_post_release_checkpoints_survive_a_missing_history_response(self):
        # Value: protects=phase attribution; fails_when=final page reads are required; seam=page and controller checkpoints
        script = r"""
const assert = require('node:assert/strict');
const { armAndWaitForInput, bindDepartureCheckpoints, captureAndReleaseInput, instrumentPostRelease,
  postReleaseCheckpoint, readConfirmedHistory } = require(process.argv[1]);
const checkpoints = {};
const roster = ['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003'];
const [local, expired, departing] = roster;
let now = 10, heartbeat, comparedTarget = 40;
global.window = {
  fortressNative: { state: 'playing', turns: 20, frame: 24, confirmed: 16, restores: 2, stalls: 0, prediction: 12, history_limit: 128 },
  fortressNativeWire: {
    arm: () => ({ at_ms: now, held: { mesh: 0, relay: 0 }, bytes: 0, queued: 0, released: 0 }),
    holdProgress: () => ({ at_ms: now, held: { mesh: 0, relay: 10 }, bytes: 880, queued: 10, released: 0 }),
    holdConditions: () => [true, false],
    holdObservation: () => ({ ...window.fortressNativeWire.holdProgress(), control_round_trips: 0, buffered_bytes: 0, traffic: [] }),
    recordHoldReadiness: () => window.fortressNative.stalls >= 3 ? window.fortressNativeWire.holdProgress() : null,
    status: () => { now += 2; return {}; },
    release: async () => { now++; window.fortressNativeWire.holdProgress = () => ({
      at_ms: now, held: { mesh: 0, relay: 10 }, bytes: 880, queued: 0, released: 10,
    }); },
  },
};
global.performance = { now: () => now };
global.setInterval = callback => { heartbeat = callback; };
global.requestAnimationFrame = callback => { now++; window.fortressNative.stalls++; callback(); };
console.debug = text => postReleaseCheckpoint(checkpoints, text, { controller_ms: now + 100 }, roster, local, comparedTarget);
instrumentPostRelease('fortress native post-release ', 40);
const trace = window.fortressNativePostRelease;
function observe() {
  const { state, turns, frame, confirmed, restores, history_limit } = window.fortressNative;
  trace.observe(state, turns, frame, confirmed, restores, history_limit);
}
const page = {
  async evaluate(operation, value) {
    const result = await operation(value);
    if (value?.frames === 40) {
      assert.deepEqual(window.fortressNativeCapture, { id: 4, frames: 40 });
      now++;
      trace.mark('history_published', value.frames);
      throw new Error('controller receipt unavailable');
    }
    return result;
  },
  waitForEvent(event) {
    assert.equal(event, 'console');
    return new Promise((_, reject) => setImmediate(() => reject(new Error('history receipt timed out'))));
  },
};
async function run() {
  assert.equal((await armAndWaitForInput(page, 'relay')).ready.restores, 2);
  assert.deepEqual([checkpoints.hold_armed?.page_ms, checkpoints.hold_armed?.controller_ms, checkpoints.hold_armed?.held.relay], [10, 110, 0]);
  assert.equal(checkpoints.hold_first_prediction?.page_ms, 11);
  assert.deepEqual([checkpoints.hold_ready?.page_ms, checkpoints.hold_ready?.controller_ms, checkpoints.hold_ready?.held.relay], [13, 113, 10]);
  const rejected = { hold_ready: checkpoints.hold_ready };
  for (const patch of [{ frames: 41 }, { restores: 2 }, { page_ms: 12 }, { turns: 20 }]) {
    postReleaseCheckpoint(rejected, 'fortress native post-release ' + JSON.stringify({
      kind: 'corrected_frontier', frames: 40, page_ms: 14, emitted_ms: 14, state: 'playing', turns: 21, frame: 44, confirmed: 42, restores: 3, ...patch,
    }), { controller_ms: 114 });
    assert.equal(rejected.frontiers, undefined);
    assert.match(rejected.checkpoint_error, /invalid corrected frontier sample/);
  }
  window.fortressNative.confirmed = 40;
  observe();
  assert.equal(checkpoints.correction, undefined, 'old restores do not prove correction');
  assert.equal(checkpoints.frontiers, undefined, 'confirmation before the restore baseline does not qualify');
  window.fortressNative.confirmed = 16;
  postReleaseCheckpoint(checkpoints, 'fortress native post-release {"kind":"correction"}', { controller_ms: now });
  Object.assign(window.fortressNative, { turns: 21, restores: 3 });
  observe();
  now++;
  await captureAndReleaseInput(page, 0, checkpoints);
  now++;
  Object.assign(window.fortressNative, { turns: 22, confirmed: 40 });
  observe();
  await assert.rejects(readConfirmedHistory(page, 40, 4, 2), /controller receipt unavailable/);
  for (let i = 0; i < 5; i++) {
    now++;
    heartbeat();
  }
  postReleaseCheckpoint(checkpoints, 'fortress native post-release {"kind":"heartbeat"}', { controller_ms: now });
  assert.equal(checkpoints.release_dispatched_ms, 14);
  assert.equal(checkpoints.release_entered.page_ms, 14);
  assert.equal(checkpoints.release_entered.controller_ms, 114);
  assert.deepEqual([checkpoints.release_started.page_ms, checkpoints.release_started.queued, checkpoints.release_started.released], [16, 10, 0]);
  const malformed = {};
  const cap = { ...checkpoints.release_started, kind: 'hold_cap', released: 1 };
  postReleaseCheckpoint(malformed, 'fortress native post-release ' + JSON.stringify(cap), { controller_ms: 116 });
  assert.match(malformed.checkpoint_error, /invalid hold sample/);
  assert.equal(malformed.hold_cap, undefined);
  assert.equal(checkpoints.release_completed.page_ms, 17);
  assert.equal(checkpoints.correction.page_ms, 13, 'correction can precede local release');
  assert.equal(checkpoints.correction.turns, 21, 'retain the first observed correction');
  assert.equal(checkpoints.frontiers[40].corrected_frontier.page_ms, 18);
  assert.equal(checkpoints.frontiers[40].corrected_advance, undefined, 'a stationary frame does not prove an engine advance');
  assert.equal(checkpoints.history_requested.frames, 40);
  assert.equal(checkpoints.history_published.frames, 40);
  assert.equal(checkpoints.history_published.controller_ms, 119);
  assert.equal(checkpoints.history_received, undefined, 'publication does not prove receipt delivery');
  assert.deepEqual(checkpoints.heartbeats.map(sample => [sample.page_ms, sample.turns, sample.confirmed]), [[23, 22, 40], [24, 22, 40]]);
  assert.match(checkpoints.checkpoint_error, /invalid post-release sample/);
  const failed = {};
  const unavailable = { async evaluate() { throw new Error('release evaluation unavailable'); } };
  await assert.rejects(captureAndReleaseInput(unavailable, 0, failed), /release evaluation unavailable/);
  assert.deepEqual(failed, { release_dispatched_ms: 24 });
  Object.assign(window.fortressNative, { state: 'failed', turns: 23, frame: 25, confirmed: 44 });
  observe();
  Object.assign(window.fortressNative, { state: 'playing', turns: 24, frame: 25 });
  now++;
  observe();
  assert.equal(checkpoints.frontiers[40].corrected_advance.frame, 25);
  now++;
  Object.assign(window.fortressNative, { turns: 25, frame: 26, confirmed: 45 });
  observe();
  now++;
  comparedTarget = 44;
  trace.setTarget(44);
  assert.deepEqual([checkpoints.frontiers[44].corrected_frontier.page_ms, checkpoints.frontiers[44].corrected_frontier.controller_ms,
    checkpoints.frontiers[44].corrected_advance.page_ms], [25, 127, 26]);
  assert.equal(checkpoints.frontiers[44].corrected_frontier.emitted_ms, 27);
  trace.setTarget(45);
  assert.deepEqual(Object.keys(checkpoints.frontiers), ['40', '44'], 'only the default and compared targets are published');
  trace.bindDeparture(local, roster);
  const expiry = {observed_us: 6000, sdk_queued: -1, sdk_peak: 0, last_accepted: null};
  trace.recordDeparture('native_expiry', 2, JSON.stringify(expiry));
  now++;
  trace.recordDeparture('sdk_departure', departing);
  trace.recordDeparture('sdk_departure', local);
  trace.recordDeparture('sdk_departure', 'unknown');
  trace.recordDeparture('native_expiry', 3);
  now++;
  trace.recordDeparture('sdk_departure', departing);
  trace.recordDeparture('sdk_departure', expired);
  assert.deepEqual(checkpoints.native_expiry, { endpoint: 2, uuid: expired, page_ms: 27, controller_ms: 127, expiry });
  assert.deepEqual(checkpoints.sdk_departures, {
    [departing]: { endpoint: 3, uuid: departing, page_ms: 28, controller_ms: 128 },
    [expired]: { endpoint: 2, uuid: expired, page_ms: 29, controller_ms: 129 },
  });
  postReleaseCheckpoint(checkpoints, 'fortress native post-release ' + JSON.stringify({
    kind: 'sdk_departure', endpoint: 3, uuid: expired, page_ms: 30
  }), { controller_ms: 130 }, roster, local);
  assert.equal(checkpoints.sdk_departures[expired].endpoint, 2);
  const early = {};
  for (let repeat = 0; repeat < 10; repeat++) {
    postReleaseCheckpoint(early, 'fortress native post-release ' + JSON.stringify({
      kind: 'sdk_departure', endpoint: 3, uuid: departing, page_ms: 30 + repeat
    }), { controller_ms: 130 + repeat });
  }
  postReleaseCheckpoint(early, 'fortress native post-release ' + JSON.stringify({
    kind: 'sdk_departure', endpoint: 2, uuid: expired, page_ms: 40
  }), { controller_ms: 140 });
  assert.equal(early.sdk_departures, undefined);
  bindDepartureCheckpoints(early, roster, local);
  assert.deepEqual(early, { sdk_departures: {
    [departing]: { endpoint: 3, uuid: departing, page_ms: 30, controller_ms: 130 },
    [expired]: { endpoint: 2, uuid: expired, page_ms: 40, controller_ms: 140 },
  } });
}
const timer = setTimeout(() => { throw new Error('post-release checkpoint control did not settle'); }, 1000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_history_capture_rejects_stale_rows_and_snapshot_mutations(self):
        # Value: protects=correlated confirmed history; fails_when=RPC completion governs receipt or stale rows pass; why_new=the publisher can outlive the RPC; seam=console
        script = r"""
const assert = require('node:assert/strict');
const { compareHistory, readConfirmedHistory } = require(process.argv[1]);

async function run() {
  const fresh = { frames: 2, rows: { 0: [1, 2], 1: [1, 2] }, snapshots: { 1: '01', 2: '02' } };
  const message = value => ({ text: () => 'fortress native history ' + JSON.stringify(value) });
  let now = 100;
  global.performance = { now: () => now };
  global.window = {};
  function fixture(id, outcome) {
    let predicate, complete, reject;
    return {
      waitForEvent(event, options) {
        assert.equal(event, 'console');
        predicate = options.predicate;
        return new Promise((resolve, fail) => { complete = resolve; reject = fail; });
      },
      evaluate(operation, request) {
        assert.equal(typeof predicate, 'function', 'register the listener before dispatch');
        operation(request);
        setImmediate(() => {
          assert.deepEqual(window.fortressNativeCapture, { id, frames: 2 });
          assert.equal(predicate(message({ ...fresh, id: id - 1 })), false, 'same-frame receipt from an earlier request');
          assert.equal(predicate(message({ ...fresh, id, frames: 3 })), false, 'wrong frame count');
          assert.equal(predicate(message({ ...fresh, id, rows: null })), false, 'incomplete receipt');
          assert.equal(predicate(message({ ...fresh, id, rows: { 0: [], 1: [] } })), false, 'empty rows cannot consume the receipt');
          assert.equal(predicate(message({ ...fresh, id, snapshots: { 1: '', 2: 'gg' } })), false, 'invalid snapshot encoding cannot consume the receipt');
          if (outcome === 'late') {
            now += 30000;
            assert.equal(predicate(message({ ...fresh, id })), false, 'receipt at the deadline');
            reject(new Error('history receipt timed out'));
            return;
          }
          assert.equal(predicate(message({ ...fresh, id })), true);
          assert.equal(predicate(message({ ...fresh, id })), false, 'repeat publication');
          complete();
        });
        if (outcome === 'rejected') return Promise.reject(new Error('dispatch response lost'));
        return new Promise(() => {});
      },
    };
  }
  assert.deepEqual(await readConfirmedHistory(fixture(18, 'pending'), 2, 18, 2), fresh);
  assert.deepEqual(await readConfirmedHistory(fixture(19, 'rejected'), 2, 19, 2), fresh);
  await assert.rejects(readConfirmedHistory(fixture(20, 'late'), 2, 20, 2), /history receipt timed out/);

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
const timer = setTimeout(() => { throw new Error('matching history publication did not settle the request'); }, 500);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(timer));
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_engine_turn_reports_the_actual_baseline_and_later_frame(self):
        # Value: protects=engine turn evidence; fails_when=earlier progress replaces the baseline or final reads own the trace; seam=browser entrypoint
        script = r"""
const { AsyncLocalStorage } = require('node:async_hooks');
const { runMain, _load: load } = require('node:module');
const entrypoint = process.argv[1];
const control = process.argv[2];
const rejecting = control.startsWith('rejection');
const stuck = control === 'same frame' || control === 'rejection and timeout';
const realm = new AsyncLocalStorage();
const windows = [];
const roster = [1, 2].map(value => '00000000-0000-0000-0000-00000000000' + value);
const unavailable = () => new Promise(() => {});
let now = 0;
global.performance = { now: () => ++now };
Object.defineProperty(global, 'window', { get: () => realm.getStore() });
const timeout = global.setTimeout;
global.setTimeout = (callback, ms, ...args) => timeout(callback, [5000, 30000].includes(ms) ? 20 : ms, ...args);
global.requestAnimationFrame = callback => {
  if (window.index === 1 && stuck) return;
  window.fortressNative.frame++;
  callback();
};
function makePage() {
  const index = windows.length;
  const state = { state: 'lobby', room: 'test', command_code: 0, ready_enabled: true, start_enabled: true,
    frame: 18, confirmed: 0, turns: 20, stalls: 0, prediction: 12, restores: 2, history_limit: 128, uuid: roster[index], frozen_roster: roster };
  const events = {};
  let lateBaseline;
  const hold = () => ({ at_ms: performance.now(), held: { mesh: 0, relay: 1 }, bytes: 1, queued: 1, released: 0 });
  function mark(kind, fields = {}) {
    const { state: status, frame, confirmed, turns, restores } = state;
    const sample = { kind, page_ms: performance.now(), state: status, frame, confirmed, turns, restores, ...fields };
    events.console({ text: () => 'fortress native post-release ' + JSON.stringify(sample) });
  }
  const pageWindow = { index, fortressNative: state, fortressNativeReady: true,
    fortressNativePostRelease: { mark(kind, frames, progress) { mark(kind, { frames, ...progress }); }, arm() {}, setTarget() {} },
    fortressNativeWire: {
      arm() { state.stalls++; return hold(); },
      holdProgress: hold, recordHoldReadiness: hold, status: () => ({}),
      holdConditions: () => [true, true],
      holdObservation: () => ({ ...hold(), control_round_trips: 1, buffered_bytes: 0, traffic: [] }),
      async release() {
        Object.assign(state, { frame: 40, confirmed: 40, turns: 21, restores: 3 });
        mark('corrected_frontier', { frames: 40, emitted_ms: now + 1 });
        Object.assign(state, { frame: 41, turns: 22 });
        mark('corrected_advance', { frames: 40, emitted_ms: now + 1 });
        Object.assign(state, { frame: 42, turns: 23 });
      },
    },
    set fortressNativeCommand(command) {
      state.command_id = command.id;
      if (command.kind === 'start') {
        for (const peer of windows) Object.assign(peer.fortressNative, { state: 'playing', confirmed: 12 });
      }
    },
  };
  windows.push(pageWindow);
  return {
    on(event, handler) { events[event] = handler; },
    async addInitScript() {}, async goto() {}, keyboard: { async down() {} },
    async evaluate(operation, argument) {
      if (operation.toString().includes('warmupStatus()')) {
        lateBaseline?.(state.frame);
        return unavailable();
      }
      if (operation.toString().includes('() => window.fortressNative.frame')) {
        if (index === 1 && control === 'baseline timeout') return new Promise(resolve => { lateBaseline = resolve; });
        if (index === 0 && rejecting) throw new Error('fixture baseline RPC failed');
        if (index === 1 && rejecting) await new Promise(setImmediate);
      }
      return realm.run(pageWindow, () => operation(argument));
    },
    async waitForFunction(condition, argument) {
      const ready = realm.run(pageWindow, () => condition(argument));
      if (!ready) return unavailable();
      return { async dispose() {} };
    },
    async waitForEvent() { throw Error('fixture stops after the engine turn'); },
  };
}
require('node:module')._load = function (name, ...args) {
  if (name === './online_host.cjs') {
    return { createHost: async () => ({ proxyPairs: [], server: { address: () => ({ port: 1 }), close: callback => callback() } }) };
  }
  if (name === 'fixture-playwright') {
    const browser = { browserType: () => ({ name: () => 'chromium' }), version: () => 'fixture', async close() {},
      async newContext() { return { newPage: makePage, async close() {} }; } };
    return { chromium: { async launch() { return browser; } } };
  }
  return load.call(this, name, ...args);
};
process.env.FORTRESS_PLAYWRIGHT_PACKAGE = 'fixture-playwright';
process.env.FORTRESS_CHROMIUM_EXECUTABLE = '/fixture';
process.argv = [process.execPath, entrypoint, '.', 'ws://127.0.0.1/v3/ws', 'relay', '2', 'chromium'];
runMain();
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        for control in ('baseline timeout', 'same frame', 'higher frame', 'rejection', 'rejection and timeout'):
            with self.subTest(control=control):
                run = subprocess.run([*command, control], capture_output=True, encoding='utf-8', timeout=10)
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertEqual(run.stdout, '')
                report_line, _, failure = run.stderr.partition('\n')
                report = json.loads(report_line)
                expected_phase = 'confirmed history capture' if control == 'higher frame' else 'post-confirmation engine turn'
                self.assertEqual(report['phase'], expected_phase)
                if control in ('baseline timeout', 'same frame', 'rejection and timeout'):
                    self.assertIn('absolute native post-confirmation engine turn deadline', failure)
                if control.startswith('rejection'):
                    self.assertIn('fixture baseline RPC failed', failure)
                self.assertEqual(report['compared_frames'], 40)
                self.assertEqual([state['status'] for state in report['states']], ['rejected', 'rejected'])
                self.assertIn('native peer 0 diagnostics deadline', run.stderr)
                self.assertIn('native peer 1 diagnostics deadline', run.stderr)
                engine_turns = report.get('engineTurns')
                self.assertIsNotNone(engine_turns, 'engine turn evidence must survive unavailable final reads')
                self.assertEqual(len(engine_turns), 2)
                for index, attempt in enumerate(engine_turns):
                    early = report['postRelease'][index]['frontiers']['40']['corrected_advance']
                    self.assertEqual(early['frame'], 41)
                    baseline = attempt['baseline']
                    self.assertGreater(baseline['dispatched_ms'], early['controller_ms'])
                    if (index == 1 and control == 'baseline timeout') or (index == 0 and control.startswith('rejection')):
                        self.assertNotIn('receipt', baseline)
                        self.assertNotIn('advance', attempt)
                        continue
                    self.assertIn('receipt', baseline, 'a timely reply must survive a sibling rejection')
                    self.assertEqual(baseline['receipt']['frame'], 42)
                    self.assertGreater(baseline['receipt']['controller_ms'], baseline['dispatched_ms'])
                    advance = attempt['advance']
                    self.assertGreater(advance['dispatched_ms'], baseline['receipt']['controller_ms'])
                    if index == 1 and control in ('same frame', 'rejection and timeout'):
                        self.assertNotIn('receipt', advance)
                    else:
                        self.assertEqual(advance['receipt']['frame'], 43)
                        self.assertGreater(advance['receipt']['controller_ms'], advance['dispatched_ms'])

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

    # Value: protects=last known readiness conditions; fails_when=the terminal page read replaces pre-expiry evidence; seam=page and controller checkpoints
    def test_native_relay_hold_retains_pending_conditions_before_terminal_read(self):
        script = r"""
const assert = require('node:assert/strict');
const { armAndWaitForInput, instrumentPostRelease, postReleaseCheckpoint } = require(process.argv[1]);
const roster = ['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002'];
const peer = {};
const turns = [];
let now = 0, held = 0;
const state = { state: 'playing', turns: 4, frame: 24, confirmed: 16, stalls: 0, prediction: 0, restores: 0 };
const traffic = [{ direction: 'send', peer: roster[1].replaceAll('-', ''), kind: 4, token: '01'.repeat(16), at_ms: 999 }];
function queue() { return { at_ms: now, held: { mesh: 0, relay: held }, bytes: 86 * held, queued: held, released: 0 }; }
global.performance = { now: () => now };
global.requestAnimationFrame = callback => turns.push(callback);
global.window = {
  fortressNative: state,
  fortressNativeWire: {
    arm: queue,
    holdProgress: queue,
    holdConditions: () => [held > 0, false],
    holdObservation: () => ({ ...queue(), control_round_trips: 0, buffered_bytes: 420, traffic: now >= 999 ? traffic : [] }),
    recordHoldReadiness: () => null,
  },
};
console.debug = text => postReleaseCheckpoint(peer, text, { controller_ms: now + 100 }, roster, roster[0]);
instrumentPostRelease('fortress native post-release ', 40);
const page = { async evaluate(callback, argument) { return callback(argument); } };
async function tick(at) {
  now = at;
  turns.shift()();
  await Promise.resolve();
}
(async () => {
  const result = assert.rejects(armAndWaitForInput(page, 'relay'), /native disconnected/);
  assert.deepEqual(peer.hold_waiting?.pending, ['stall', 'prediction', 'held_input', 'quality_reply']);
  for (let n = 1; n < 1000; n += 101) await tick(n);
  assert.equal(peer.hold_waiting?.page_ms, 0);
  held = 13;
  Object.assign(state, { stalls: 1, prediction: 12 });
  await tick(999);
  assert.equal(peer.hold_waiting?.controller_ms, 1099);
  assert.deepEqual(peer.hold_waiting?.pending, ['quality_reply']);
  assert.deepEqual(peer.hold_waiting?.traffic, traffic);
  const prefix = 'fortress native post-release ';
  const waiting = { ...peer.hold_waiting, kind: 'hold_waiting', traffic: [{ ...traffic[0], extra: 'discard this' }] };
  const normalized = {};
  postReleaseCheckpoint(normalized, prefix + JSON.stringify(waiting), { controller_ms: 1099 }, roster, roster[0]);
  assert.deepEqual(normalized.hold_waiting?.traffic, traffic);
  for (const patch of [{ pending: [] }, { traffic: [traffic[0], traffic[0]] }, { traffic: [{ ...traffic[0], at_ms: 1000 }] }]) {
    const invalid = {};
    postReleaseCheckpoint(invalid, prefix + JSON.stringify({ ...waiting, ...patch }), { controller_ms: 1099 }, roster, roster[0]);
    assert.match(invalid.checkpoint_error, /invalid relay hold readiness sample/);
    assert.equal(invalid.hold_waiting, undefined);
  }
  Object.assign(state, { state: 'failed', message: 'native disconnected' });
  await tick(1000);
  await result;
  assert.equal(peer.hold_waiting?.page_ms, 999);
  assert.equal(peer.hold_terminal?.page_ms, 1000);
  assert.equal(peer.hold_terminal?.held.relay, 13);
  assert.equal(peer.hold_terminal?.buffered_bytes, 420);
  assert.equal(turns.length, 0);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

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
  const crashReport = {};
  const crashed = { evaluate: async () => { throw Error('Page crashed'); } };
  await assert.rejects(waitForCloseProofs([late, crashed], initial, warning, crashReport, { clocks, clock, delay: pause }),
    error => error instanceof AggregateError && error.errors[0].message.includes('peer 1') && error.errors[0].cause.message === 'Page crashed');
  assert.deepEqual(crashReport.snapshotErrors, [{index:1, reason:'Error: Page crashed'}]);
  assert.deepEqual(crashReport.partialSnapshots, [[reciprocal], null]);
  assert.deepEqual(crashReport.clockSamples, [{before:[], after:[{offsetMin:9459, offsetMax:10541}]}, {before:[], after:[]}]);
  assert.deepEqual(crashReport.proofs, []);

  const lateReply = sample(() => { now = 5025; return [reciprocal]; }, 10000);
  now = 25;
  const lateReport = {};
  await assert.rejects(waitForCloseProofs([sender, lateReply], initial, warning, lateReport, { clocks, clock, delay: pause }),
    /WebKit close evidence deadline/);
  assert.deepEqual(lateReport.partialSnapshots, [null, null]);
  assert.deepEqual(lateReport.clockSamples.map(page => page.after), [[], []]);
  assert.deepEqual(lateReport.proofs, []);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_departure_retains_the_individual_calibration_brackets(self):
        # Value: protects=per-page clock provenance; fails_when=contradictory pre-close samples disappear; seam=controller calibration
        script = r"""
const assert = require('node:assert/strict');
const { calibrateDepartureClocks } = require(process.argv[1]);
const report = {};
function page(samples) {
  let reads = 0;
  return { evaluate: async () => {
    assert.ok(reads < samples.length);
    return samples[reads++];
  }};
}
(async () => {
  await calibrateDepartureClocks([page([10, 20, 30]), page([100, 200, null])], report, () => 1);
  assert.deepEqual(report.clocks, [{offsetMin:949, offsetMax:1011}, null]);
  assert.deepEqual(report.clockSamples, [
    {before:[{offsetMin:949, offsetMax:1031}, {offsetMin:939, offsetMax:1021}, {offsetMin:929, offsetMax:1011}], after:[]},
    {before:[{offsetMin:859, offsetMax:941}, {offsetMin:759, offsetMax:841}, null], after:[]},
  ]);
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
  assert.deepEqual(short.report.clockSamples, [
    {before:[], after:Array(4).fill({offsetMin:9959, offsetMax:10041})},
    {before:[], after:Array(4).fill({offsetMin:-5041, offsetMax:-4959})},
  ]);

  const conflict = await collect(52000, before, true);
  await assert.rejects(conflict.proof, /WebKit close evidence deadline .*peer 1 channel 17/);
  assert.equal(conflict.report.clocks[1], null);
  assert.deepEqual(conflict.report.clockSamples[1].after[0], {offsetMin:-41, offsetMax:41});
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
