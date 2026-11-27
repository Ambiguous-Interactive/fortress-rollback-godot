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
    def test_native_webkit_https_departure_clock_requires_exact_ordered_exchange(self):
        subprocess.run(['node', '--test', str(ROOT / 'scripts/reference/browser/native_departure_clock.test.cjs')], check=True, timeout=10)

    def test_native_relay_proxy_preserves_carriers_and_distinguishes_observation_gaps(self):
        subprocess.run(['node', '--test', str(ROOT / 'scripts/reference/browser/native_relay_proxy.test.cjs')], check=True, timeout=20)

    def test_native_relay_hold_keeps_exact_receipt_when_final_read_times_out(self):
        subprocess.run(['node', '--test', str(ROOT / 'scripts/reference/browser/native_relay_hold.test.cjs')], check=True, timeout=10)

    def test_relay_wire_receipt_crosses_page_boundary_as_json_text(self):
        script = r"""
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { readRelayWireReceipt } = require(process.argv[1]);
const envelope = Buffer.alloc(103, 0x5b);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const metadata = { seq: '18446744073709551615', kind: 4, code: 0 };
const receipt = event => ({ sockets: 1, streams: { native: { quality: { count: 130, omitted: 2, events: [{ ...metadata, ...event }] } } } });
const links = ['11'.repeat(16) + '/' + '22'.repeat(16)];
const page = { async evaluate(read, selected) {
  const transferred = await read(selected);
  assert.ok(transferred === undefined || typeof transferred === 'string');
  return transferred;
} };
(async () => {
  globalThis.window = { fortressNativeWire: { relayWireTrace(selected) {
    assert.deepEqual(selected, links);
    return receipt({ bytes: envelope.toString('base64') });
  } } };
  assert.deepEqual(await readRelayWireReceipt(page, links),
    receipt({ envelope_bytes: envelope.length, envelope_sha256: digest(envelope), payload_sha256: digest(envelope.subarray(57)) }));
  delete window.fortressNativeWire;
  assert.equal(await readRelayWireReceipt(page), undefined);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_control.cjs')], check=True, timeout=10)

    def test_relay_server_reader_requires_a_current_snapshot(self):
        # Value: protects=capture freshness; fails_when=an earlier server reply satisfies a new request; seam=trace request and receipt files
        script = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { setTimeout: pause } = require('node:timers/promises');
const { createRelayServerReader } = require(process.argv[1]);
const path = process.argv[2];
const read = createRelayServerReader(path);
async function publish(request, links = []) {
  await fs.writeFile(path + '.new', JSON.stringify({ version: 2, request, links }));
  await fs.rename(path + '.new', path);
}
async function respond() {
  for (const expected of [1, 2]) {
    while (true) {
      const request = await fs.readFile(path + '.request', 'utf8').catch(error => {
        if (error.code !== 'ENOENT') throw error;
        return '';
      });
      if (request === String(expected)) break;
      await pause(5);
    }
    await publish(expected);
  }
}
(async () => {
  await publish(99);
  const served = respond();
  const considered = [];
  const receipt = await read(candidate => {
    considered.push(candidate.request);
    return candidate.request === 2 ? candidate : null;
  });
  assert.equal(receipt.request, 2);
  assert.deepEqual(considered, [1, 2]);
  await served;
  await assert.rejects(read(undefined, 50), /relay server receipt deadline/);
  assert.equal(await fs.readFile(path + '.request', 'utf8'), '3');
  const link = '11'.repeat(16) + '/' + '22'.repeat(16);
  for (const malformed of [new Array(1), null, new Set([link])]) {
    await assert.rejects(read(undefined, 3000, malformed), /invalid relay server link selection/);
  }
  const retry = read(undefined, 3000, [link]);
  await assert.rejects(read(), /already has a caller/);
  await publish(3);
  while (await fs.readFile(path + '.request', 'utf8') !== '4\n' + link) {
    await pause(5);
  }
  await publish(4, [link]);
  assert.equal((await retry).request, 4);
  await Promise.all([
    assert.rejects(read(undefined, 3000, [link]), /receipt selected different links/),
    (async () => {
      while (await fs.readFile(path + '.request', 'utf8') !== '5\n' + link) await pause(5);
      await publish(5, [link.split('/').reverse().join('/')]);
    })(),
  ]);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_control.cjs'),
                            str(Path(directory) / 'trace.json')], check=True, timeout=10)

    def test_relay_server_reader_times_current_generation_across_deadline(self):
        # Value: protects=server publication evidence during receipt timeouts; fails_when=late reads and missing publications look the same; seam=atomic receipt files
        script = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { createRelayServerReader } = require(process.argv[1]);
const file = process.argv[2];
const { open, rename } = fs;
const read = createRelayServerReader(file);
const publish = async request => {
  await fs.writeFile(file + '.new', JSON.stringify({ version: 2, request, links: [] }));
  await fs.rename(file + '.new', file);
};
let now = 10;
Object.defineProperty(globalThis, 'performance', { value: { now: () => now } });

(async () => {
  fs.rename = async (from, to) => {
    await rename(from, to);
    if (to === file + '.request') await publish(1);
  };
  fs.open = async (...args) => {
    const reader = await open(...args);
    now = 99;
    return { close: () => reader.close(), readFile: async (...args) => {
      const text = await reader.readFile(...args);
      now = 100;
      return text;
    } };
  };
  await assert.rejects(read(undefined, 90), error => {
    assert.match(error.message, /relay server receipt deadline/);
    assert.deepEqual(error.receiptTiming, {
      clock: 'controller.performance', deadline_ms: 100, generation: 1, links: [],
      request_started_ms: 10, request_published_ms: 10, open_started_ms: 10,
      opened_ms: 99, read_ms: 100, parse_started_ms: 100, parsed_ms: 100, observed_generation: 1, outcome: 'late_read',
    });
    return true;
  });

  // A recovery read can consume the same pending request, with its original request stamps.
  Object.assign(fs, { open, rename });
  const receipt = await read();
  assert.equal(receipt.request, 1);
  assert.equal(receipt.controller_timing.request_published_ms, 10);
  assert.equal(receipt.controller_timing.outcome, 'selected');

  fs.open = async (...args) => {
    const reader = await open(...args);
    now = 150;
    return reader;
  };
  await assert.rejects(read(undefined, 50), error => {
    assert.match(error.message, /relay server receipt deadline/);
    assert.equal(error.receiptTiming.generation, 2);
    assert.equal(error.receiptTiming.observed_generation, 1);
    assert.equal(error.receiptTiming.outcome, 'generation_not_observed');
    return true;
  });
  fs.open = open;
  await publish(2);
  const failure = new Error('selection rejected');
  await assert.rejects(read(() => { throw failure; }), error => {
    assert.equal(error, failure);
    assert.equal(error.receiptTiming.outcome, 'predicate_error');
    assert.equal(error.receiptTiming.selection_finished_ms, 150);
    return true;
  });
  await read(() => { throw null; }).then(
    () => assert.fail('selection should reject'), error => assert.equal(error, null));
  await assert.rejects(read(candidate => {
    now = 151;
    return candidate;
  }, 1), error => {
    assert.match(error.message, /relay server receipt deadline/);
    assert.equal(error.receiptTiming.parsed_ms, 150);
    assert.equal(error.receiptTiming.selection_finished_ms, 151);
    assert.equal(error.receiptTiming.outcome, 'late_selection');
    return true;
  });
  assert.equal((await read()).request, 2);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_control.cjs'),
                            str(Path(directory) / 'trace.json')], check=True, timeout=10)

    def test_relay_control_releases_only_after_both_addressed_stamps_arrive(self):
        # Value: protects=the FIFO barrier; fails_when=unrelated or duplicate arrivals can release it; seam=browser socket observer
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
class Socket {
  static OPEN = 1;
  readyState = 1;
  listeners = [];
  addEventListener(_name, listener) { this.listeners.push(listener); }
  dispatchEvent(event) {
    let stopped = false;
    event.stopImmediatePropagation = () => { stopped = true; };
    for (const listener of this.listeners) {
      listener(event);
      if (stopped) break;
    }
  }
}
const window = {};
let alarm;
const local = '22'.repeat(16);
const source = '33'.repeat(16);
const other = '44'.repeat(16);
const packets = [];
const carrierEntries = [];
let beforeDecode;
const trace = {
  bind() {},
  recordCarrier(data) { carrierEntries.push(data[0]); },
  record(_stage, data) {
    if (!data) return;
    const packet = { sender: data[1] === 1 ? other : source, recipient: local, epoch: 1, seq: String(data[0]), kind: data[2] ?? 4 };
    packets.push(packet);
    return packet;
  },
  retentionSample: () => ({ frontier: ['input', 'quality'], counts: { raw: { input: 1, quality: 2 } } }),
  expiryFrontier: sender => {
    const captured_ms = clock;
    if (slowFreeze) clock += 2;
    return { sender, captured_ms };
  },
  hasBlockedRelayStamps(sender, gate, stamps) {
    return stamps.every(stamp => packets.some(packet => packet.delivery_gate === gate && packet.sender === sender
      && packet.kind === stamp.kind && packet.epoch === stamp.epoch && packet.seq === stamp.seq));
  },
};
let clock = 10;
let slowFreeze = false;
const realm = { window, trace, holdBeforeDecode(socket, event) {
  if (event.data[0] !== 99) return false;
  beforeDecode = () => socket.dispatchEvent(event);
  return true;
}, WebSocket: Socket, RTCPeerConnection: class {}, Uint8Array, ArrayBuffer, DataView, performance: { now: () => clock },
  setTimeout: run => { alarm = run; }, clearTimeout: () => {} };
runInNewContext(`(${instrumentNativeWire})(false, '', trace, '', holdBeforeDecode)`, realm);
const socket = new window.WebSocket();
const wire = window.fortressNativeWire;
const seen = [];
socket.addEventListener('message', event => seen.push(event.data[0]));
const deliver = (seq, target = socket, peer = 0, kind = 4) => target.dispatchEvent({ data: Uint8Array.of(seq, peer, kind) });
const stamps = [10, 11].map(seq => ({ sender: source, recipient: local, epoch: 1, seq: String(seq) }));
wire.bind('00'.repeat(16), local, [local, source, other]);
assert.equal(wire.blockRelayLink(source).started_ms, 10);
deliver(1, socket, 0, 2);
deliver(2);
deliver(3, socket, 1);
deliver(4, socket, 0, 1);
assert.deepEqual(seen.splice(0), [3, 4]);
assert.deepEqual(packets.map(packet => packet.delivery_blocked), [true, true, undefined, undefined]);
clock = 1260;
deliver(5);
assert.equal(wire.resumeBlockedRelay().reports, 1);
assert.deepEqual(seen.splice(0), [5]);
wire.blockRelayLink(source);
const pressureStamps = ['12', '13'].map(seq => ({ kind: 4, epoch: 1, seq }));
deliver(12);
deliver(12);
deliver(13, socket, 1);
assert.equal(wire.resumeBlockedRelay(pressureStamps), null, 'duplicates and another sender cannot release the gate');
assert.deepEqual(seen.splice(0), [13]);
deliver(13);
const resumed = wire.resumeBlockedRelay(pressureStamps);
assert.equal(resumed.reports, 3);
assert.deepEqual({ ...resumed.frontier }, { sender: source, captured_ms: clock });
wire.blockRelayLink(source);
assert.equal(wire.resumeBlockedRelay(pressureStamps), null, 'an earlier gate must not qualify at the same page clock tick');
wire.resumeBlockedRelay();
deliver(14);
assert.deepEqual(seen.splice(0), [14]);
const finalGate = wire.blockRelayLink(source);
deliver(12);
deliver(13);
clock = finalGate.started_ms + 1249;
slowFreeze = true;
const late = wire.resumeBlockedRelay(pressureStamps);
assert.ok(late.resumed_ms >= late.deadline_ms, 'freeze completion must precede the resume deadline');
assert.equal(late.frontier, undefined);
wire.holdRelayControl();
deliver(8);
alarm();
assert.equal(wire.releaseRelayControl(stamps).reason, 'deadline');
assert.deepEqual(seen.splice(0), [8]);
wire.holdRelayControl();
deliver(9);
deliver(10);
deliver(10);
assert.equal(wire.releaseRelayControl(stamps), null);
assert.deepEqual(seen, []);
assert.equal(wire.releaseRelayControl([stamps[0], stamps[0]]), null);
assert.equal(wire.releaseRelayControl([]), null);
assert.equal(wire.releaseRelayControl([{ ...stamps[0], epoch: 2 }, stamps[1]]), null);
deliver(11, new window.WebSocket());
assert.equal(wire.releaseRelayControl(stamps), null);
deliver(11);
assert.equal(wire.releaseRelayControl(stamps).reason, 'controller');
assert.deepEqual(seen, [9, 10, 10, 11]);
deliver(99);
assert.equal(carrierEntries.filter(value => value === 99).length, 1);
assert.equal(packets.some(packet => packet.seq === '99'), false);
assert.equal(seen.includes(99), false);
beforeDecode();
assert.equal(carrierEntries.filter(value => value === 99).length, 1);
assert.equal(packets.some(packet => packet.seq === '99'), true);
assert.equal(seen.at(-1), 99);
beforeDecode();
assert.equal(packets.filter(packet => packet.seq === '99').length, 1);
assert.equal(seen.filter(value => value === 99).length, 1);
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_join_keeps_missing_stages_and_rejects_conflicting_digests(self):
        # Value: protects=exact stage joins; fails_when=equal bytes fill observation gaps or an ordinal hides mismatched bytes; seam=browser arrival and server receipts
        script = r"""
const assert = require('node:assert/strict');
const { assertJoinedRelayControl, joinRelayReceipts } = require(process.argv[1]);
const sender = 'a', recipient = 'b', room = 'match';
const packet = { sender, recipient, epoch: 1, seq: '9', kind: 2, envelope_bytes: 109, envelope_sha256: 'sha', ordinal: 1, socket_ordinal: 5 };
const stage = (events = []) => ({ sync: { events: [] }, input: { events }, quality: { events: [] } });
const another = { ...packet, seq: '10', socket_ordinal: 6, ordinal: 2 };
const writes = [packet, another].map(event => ({ ...event, actual_recipient: recipient }));
const server = { room, roster: [sender, recipient], streams: { ingress: stage([packet, another]), write: stage(writes) } };
const pageA = { room, local: sender, sockets: 1,
  streams: { send: stage([packet, another]), raw: stage(), sdk: stage(), native: stage() } };
const pageB = { room, local: recipient, sockets: 1,
  streams: { send: stage(), raw: stage([another]), sdk: stage([another]), native: stage([{...another, code: 0}, {...another, ordinal: 3, code: 1}]) } };
const result = joinRelayReceipts(server, [pageA, pageB]);
const byStamp = new Map(result.rows.map(row => [row.seq, row]));
assert.equal(byStamp.get('9').send, 1);
assert.deepEqual(byStamp.get('9').raw, []);
assert.deepEqual(byStamp.get('9').native, []);
assert.deepEqual(byStamp.get('10').raw, [2]);
assert.deepEqual(byStamp.get('10').native, [2, 3]);
assert.deepEqual(byStamp.get('10').native_accepted, [2]);
assert.deepEqual(result.unjoined_sends, []);
assert.throws(() => assertJoinedRelayControl(result), /40 complete packet joins/);
const complete = Array.from({ length: 40 }, (_, i) => ({ ...byStamp.get('10'), seq: String(i), family: ['sync', 'input', 'quality'][i % 3] }));
assertJoinedRelayControl({ rows: complete });
assert.throws(() => assertJoinedRelayControl({ rows: complete.slice(1) }), /40 complete packet joins/);
assert.throws(() => assertJoinedRelayControl({ rows: complete.map(row => ({ ...row, native_accepted: [] })) }), /40 complete packet joins/);
assert.throws(() => assertJoinedRelayControl({ rows: complete.map(row => ({ ...row, family: 'sync' })) }), /complete sync, input, and quality/);
writes[0].actual_recipient = sender;
assert.throws(() => joinRelayReceipts(server, [pageA, pageB]), /addressed socket/);
writes[0].actual_recipient = recipient;
const privatePacket = { ...packet, lane: 'addressed', socket_ordinal: 7, ordinal: 3 };
server.streams.ingress.input.events.push(privatePacket);
writes.push({ ...privatePacket, actual_recipient: recipient, ordinal: 13 });
const senderStages = pageA.streams.send.input.events;
senderStages.push({ ...privatePacket, ordinal: 17 });
for (const [index, stage] of ['raw', 'sdk', 'native'].entries()) {
  const arrivals = pageB.streams[stage].input.events;
  arrivals.push({ ...packet, ordinal: 20 + index, code: 0 }, { ...privatePacket, ordinal: 30 + index, code: 0 });
}
pageB.streams.native.input.events.push({ ...privatePacket, ordinal: 33, code: 1 });
const privateJoin = joinRelayReceipts(server, [pageA, pageB]);
const privateRows = privateJoin.rows.filter(row => row.seq === packet.seq).sort((a, b) => a.send - b.send);
assert.deepEqual(privateRows.map(row => [row.lane, row.send, row.ingress, row.write, row.raw, row.sdk, row.native, row.native_accepted]), [
  [undefined, 1, [1], [1], [20], [21], [22], [22]],
  ['addressed', 17, [3], [13], [30], [31], [32, 33], [32]],
]);
assert.deepEqual(privateJoin.unjoined_sends, []);
senderStages[2] = { ...privatePacket, lane: undefined };
assert.throws(() => joinRelayReceipts(server, [pageA, pageB]), /relay socket ordinal disagrees/);
senderStages.pop();
pageB.streams.raw.input.events.splice(-2);
pageB.streams.sdk.input.events.splice(-2);
pageB.streams.native.input.events.splice(-3);
server.streams.ingress.input.events.pop();
writes.pop();
pageA.sockets = 2;
const ambiguous = joinRelayReceipts(server, [pageA, pageB]);
assert.ok(ambiguous.rows.every(row => row.send === null));
assert.equal(ambiguous.unjoined_sends.length, 2);
pageB.streams.raw.input.events[0] = { ...another, envelope_sha256: 'conflicting' };
assert.throws(() => joinRelayReceipts(server, [pageA, pageB]), /receipt disagrees/);
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_control.cjs')], check=True, timeout=10)

    def test_native_relay_wire_preserves_duplicate_stamps_and_addresses(self):
        # Value: protects=relay identity and shared digests; fails_when=bytes collapse, hashes repeat, or foreign routes survive; seam=browser wire receipt
        script = r"""
const assert = require('node:assert/strict');
const { createHash, webcrypto } = require('node:crypto');
const { createRelayWireTrace } = require(process.argv[1]);
let digestCalls = 0;
Object.defineProperty(globalThis, 'crypto', { value: { subtle: { digest(...args) {
  digestCalls++;
  return webcrypto.subtle.digest(...args);
} } } });
const bytes = value => Buffer.from(value, 'hex');
const [room, source, local, other] = ['11', '22', '33', '44'].map(value => value.repeat(16));
const trace = createRelayWireTrace();
trace.bind(room, local, [source, local, other]);
function envelope(sender, recipient, kind = 2) {
  const body = Buffer.alloc({2: 24, 4: 18, 5: 16}[kind]);
  const payload = Buffer.concat([bytes(room), bytes('f552020001000000'), Buffer.from([kind, 0, 0, 0]), body]);
  return Buffer.concat([bytes('4653523101'), bytes(room), bytes(sender), bytes(recipient), Buffer.from([payload.length, 0, 0, 0]), payload]);
}
const name = text => Buffer.concat([Buffer.from([0xa0 + text.length]), Buffer.from(text)]);
function delivered(packet, seq, outerSender = source, encodingKey = 'encoding') {
  const stamp = Buffer.alloc(9);
  stamp[0] = 0xcf;
  stamp.writeBigUInt64BE(seq, 1);
  return Buffer.concat([bytes('85'), name('from_player'), bytes('c410'), bytes(outerSender), name(encodingKey), name('message_pack'),
    name('payload'), Buffer.from([0xc4, packet.length]), packet, name('seq'), stamp, name('epoch'), bytes('01')]);
}
const packet = envelope(source, local);
const first = 9007199254740992n;
trace.record('raw', delivered(packet, first));
trace.record('raw', delivered(packet, first + 1n));
trace.record('raw', delivered(envelope(source, other), first + 2n));
trace.record('raw', delivered(packet, 0n));
trace.record('raw', delivered(packet, first + 3n, other));
trace.record('raw', Buffer.concat([delivered(packet, first + 4n), bytes('00')]));
trace.record('raw', delivered(packet, first + 5n).subarray(0, -1));
trace.record('raw', delivered(Buffer.concat([packet, bytes('00')]), first + 6n));
const badQuality = envelope(source, local, 4).subarray(0, 85);
badQuality.writeUInt32LE(28, 53);
trace.record('raw', delivered(badQuality, first + 7n));
const bomPacket = delivered(packet, first + 8n);
const key = bomPacket.indexOf(name('encoding'));
trace.record('raw', Buffer.concat([bomPacket.subarray(0, key), bytes('abefbbbf'), bomPacket.subarray(key + 1)]));
assert.throws(() => trace.bind(other, local, [source, local, other]), /already bound/);
const signedSeq = '-1';
trace.recordEngine('sdk', source, packet.toString('hex'), 1, signedSeq, null);
trace.recordEngine('native', source, packet.subarray(57).toString('hex'), 1, signedSeq, 0);
trace.recordEngine('native', source, envelope(source, local, 4).subarray(57).toString('hex'), 1, '5', 0);
trace.recordEngine('native', source, envelope(source, local, 4).subarray(57).toString('hex'), 1, '6', 0);
const expected = { sender: source, recipient: local, epoch: 1, seq: '5' };
assert.equal(trace.freezeEnqueued([{ ...expected, seq: '7' }]), null);
assert.equal(trace.freezeEnqueued([{ ...expected, recipient: other }]), null);
const frozenAtEnqueue = trace.freezeEnqueued([expected]);
trace.record('send', envelope(local, source, 5));
trace.record('send', envelope(local, source));
const owned = envelope(local, other);
const ownedDigest = createHash('sha256').update(owned).digest('hex');
trace.record('send', owned);
owned.fill(0);
for (let i = 0; i < 140; i++) trace.record('raw', delivered(envelope(source, local, 4), BigInt(i + 1)));
(async () => {
  const receipt = await trace.freeze();
  assert.equal(receipt.room, room);
  assert.equal(receipt.local, local);
  const input = receipt.streams.raw.input;
  assert.equal(input.count, 2);
  assert.deepEqual(input.events.map(event => [event.epoch, event.seq, event.sender, event.recipient]),
    [[1, String(first), source, local], [1, String(first + 1n), source, local]]);
  assert.ok(input.events.every(event => event.envelope_bytes === packet.length &&
    event.envelope_sha256 === createHash('sha256').update(packet).digest('hex')));
  const sent = receipt.streams.send.input.events;
  assert.equal(sent[1].envelope_sha256, ownedDigest);
  assert.equal(sent[0].payload_sha256, sent[1].payload_sha256);
  assert.notEqual(sent[0].envelope_sha256, sent[1].envelope_sha256);
  const [sdk, native] = ['sdk', 'native'].map(stage => receipt.streams[stage].input.events[0]);
  assert.equal(sdk.seq, '18446744073709551615');
  assert.equal(native.seq, sdk.seq);
  assert.equal(native.envelope_sha256, sdk.envelope_sha256);
  assert.equal(native.code, 0);
  assert.deepEqual(receipt.streams.send.quality.events[0].protocol_reply,
    { token: '00'.repeat(16), candidates: [{ epoch: 1, seq: '5' }, { epoch: 1, seq: '6' }] });
  for (let i = 7; i < 140; i++) trace.recordEngine('native', source, envelope(source, local, 4).subarray(57).toString('hex'), 1, String(i), 0);
  assert.equal(trace.freezeEnqueued([expected]), null);
  assert.equal((await frozenAtEnqueue).streams.native.quality.events[0].seq, '5');
  const quality = receipt.streams.raw.quality;
  assert.equal(quality.count, 140);
  assert.equal(quality.omitted, 12);
  assert.equal(quality.events.length, 128);
  assert.equal(quality.events[0].seq, '13');
  assert.equal(quality.events.at(-1).seq, '140');
  const expanded = await trace.freeze([`${source}/${local}`]);
  assert.equal(expanded.streams.raw.quality.omitted, 0);
  assert.deepEqual(expanded.streams.raw.quality.events.map(event => event.seq),
    Array.from({ length: 140 }, (_, index) => String(index + 1)));
  assert.deepEqual((await trace.freeze([`${local}/${source}`])).streams.raw.quality, { count: 140, omitted: 140, events: [] });
  assert.equal(expanded.streams.send.input.events.length, 0, 'unselected directions must not enter the focused receipt');
  const scopedLink = `${source}/${local}`;
  for (const malformed of [[scopedLink, scopedLink], [`${source}/${source}`], [`${source}/ff`], [scopedLink + '/'], [null],
    new Array(1), null, new Set([scopedLink])]) {
    await assert.rejects(trace.freeze(malformed), /invalid relay wire link selection/);
  }
  for (let seq = 141; seq <= 520; seq++) trace.record('raw', delivered(envelope(source, local, 4), BigInt(seq)));
  const crowded = (await trace.freeze([scopedLink])).streams.raw.quality;
  assert.equal(crowded.omitted, 0);
  assert.deepEqual(crowded.events.map(event => Number(event.seq)), Array.from({ length: 520 }, (_, index) => index + 1));
  for (let seq = 521; seq <= 1025; seq++) trace.record('raw', delivered(envelope(source, local, 4), BigInt(seq)));
  const wrapped = (await trace.freeze([`${source}/${local}`])).streams.raw.quality;
  assert.equal(wrapped.omitted, 1);
  assert.deepEqual(wrapped.events.map(event => Number(event.seq)), Array.from({ length: 1024 }, (_, index) => index + 2));
  for (let ordinal = 1; ordinal <= 521; ordinal++) trace.record('send', envelope(local, source, 4), ordinal);
  const sentArchive = (await trace.freeze([`${local}/${source}`])).streams.send.quality;
  assert.equal(sentArchive.events.length, 522);
  assert.equal(sentArchive.events[1].socket_ordinal, 1);
  assert.equal((await trace.freeze()).streams.send.quality.events.length, 128);
  const gateTrace = createRelayWireTrace();
  gateTrace.bind(room, local, [source, local, other]);
  gateTrace.record('raw', delivered(packet, 1n)).delivery_gate = 1;
  gateTrace.record('raw', delivered(envelope(other, local, 4), 2n, other)).delivery_gate = 1;
  const report = gateTrace.record('raw', delivered(envelope(source, local, 4), 2n));
  const blocked = [{ kind: 2, epoch: 1, seq: '1' }, { kind: 4, epoch: 1, seq: '2' }];
  assert.equal(gateTrace.hasBlockedRelayStamps(source, 1, blocked), false);
  report.delivery_gate = 1;
  assert.equal(gateTrace.hasBlockedRelayStamps(source, 1, blocked), true);
  assert.equal(gateTrace.hasBlockedRelayStamps(source, 2, blocked), false);
  assert.equal(gateTrace.hasBlockedRelayStamps(source, 1, [{ kind: 2, epoch: 1, seq: '2' }]), false);
  assert.equal(gateTrace.hasBlockedRelayStamps(source, 1, [{ kind: 4, epoch: 2, seq: '2' }]), false);
  const digestFixture = createRelayWireTrace();
  digestFixture.bind(room, local, [source, local, other]);
  const original = envelope(source, local, 4);
  const changed = Buffer.from(original);
  changed[changed.length - 1] = 1;
  const outgoing = envelope(local, source, 4);
  digestFixture.record('raw', delivered(original, 5n));
  digestFixture.record('raw', delivered(original, 5n));
  digestFixture.record('raw', delivered(original, 6n));
  digestFixture.recordEngine('sdk', source, changed.toString('hex'), 1, '5', null);
  digestFixture.recordEngine('native', source, changed.subarray(57).toString('hex'), 1, '5', 0);
  digestFixture.recordEngine('native', source, original.subarray(57).toString('hex'), 1, '5', 1);
  digestFixture.record('send', outgoing, 7);
  digestFixture.record('send', outgoing, 8);
  function checkDigests(events, packets) {
    const digest = packet => createHash('sha256').update(packet).digest('hex');
    assert.deepEqual(events.map(({ envelope_sha256, payload_sha256 }) => [envelope_sha256, payload_sha256]),
      packets.map(packet => [digest(packet), digest(packet.subarray(57))]));
  }
  const firstFreezeCalls = digestCalls;
  const digestReceipt = await digestFixture.freeze();
  const { raw, sdk: sdkStage, native: nativeStage, send } = digestReceipt.streams;
  assert.deepEqual(raw.quality.events.map(({ ordinal, seq }) => [ordinal, seq]), [[1, '5'], [2, '5'], [3, '6']]);
  checkDigests(raw.quality.events, [original, original, original]);
  checkDigests(sdkStage.quality.events, [changed]);
  checkDigests(nativeStage.quality.events, [changed, original]);
  assert.deepEqual(nativeStage.quality.events.map(({ seq, code }) => [seq, code]), [['5', 0], ['5', 1]]);
  checkDigests(send.quality.events, [outgoing, outgoing]);
  assert.deepEqual(send.quality.events.map(event => event.socket_ordinal), [7, 8]);
  assert.equal(digestCalls - firstFreezeCalls, 10, 'hash each exact stamped packet once per receipt');
  const secondFreezeCalls = digestCalls;
  assert.deepEqual(await digestFixture.freeze(), digestReceipt);
  assert.equal(digestCalls - secondFreezeCalls, 10, 'digest reuse must stay inside one freeze');

  const lanes = createRelayWireTrace();
  lanes.bind(room, local, [source, local, other]);
  const ordinary = delivered(original, 5n);
  assert.equal(lanes.record('raw', Buffer.concat([bytes('00'), ordinary])), undefined);
  assert.equal(lanes.record('raw', Buffer.concat([bytes('01'), ordinary.subarray(0, -1)])), undefined);
  assert.equal(lanes.record('raw', ordinary).ordinal, 1);
  lanes.recordEngine('sdk', source, original.toString('hex'), 1, '5', null);
  const addressedRaw = lanes.record('raw', Buffer.concat([bytes('01'), ordinary]));
  assert.equal(addressedRaw.lane, 'addressed');
  addressedRaw.delivery_gate = 1;
  const expectedStamp = { kind: 4, epoch: 1, seq: '5' };
  assert.equal(lanes.hasBlockedRelayStamps(source, 1, [expectedStamp]), false);
  assert.equal(lanes.hasBlockedRelayStamps(source, 1, [{ ...expectedStamp, lane: 'addressed' }]), true);
  lanes.recordEngine('native', source, original.subarray(57).toString('hex'), 1, '5', 0);
  const broadcastPin = lanes.expiryFrontier(source).packets[0];
  assert.equal(broadcastPin.lane, undefined);
  assert.equal(broadcastPin.stages.raw.ordinal, 1);
  lanes.recordEngine('sdk', source, original.toString('hex'), 1, '5', null, true);
  lanes.recordEngine('native', source, original.subarray(57).toString('hex'), 1, '5', 0, true);
  const privatePin = lanes.expiryFrontier(source).packets[0];
  assert.equal(privatePin.lane, 'addressed');
  assert.equal(privatePin.stages.sdk.ordinal, 2);
  assert.equal(privatePin.stages.raw.ordinal, 2);
  assert.equal(lanes.record('send', Buffer.concat([bytes('01' + other), outgoing]), 10), undefined);
  assert.equal(lanes.record('send', Buffer.concat([bytes('00'), outgoing]), 11).lane, undefined);
  lanes.record('send', Buffer.concat([bytes('01' + source), outgoing]), 12);
  const repeated = [];
  lanes.repeatQuality(source, other, wire => repeated.push(Buffer.from(wire)));
  assert.deepEqual(repeated.map(wire => [wire[0], wire.subarray(1, 17).toString('hex'), wire.subarray(54, 70).toString('hex')]),
    [[1, source, source], [1, source, source], [1, other, other]]);
  const laneReceipt = await lanes.freeze();
  assert.deepEqual(laneReceipt.streams.send.quality.events.map(event => [event.socket_ordinal, event.lane, event.carrierOpcode]),
    [[11, undefined, undefined], [12, 'addressed', undefined]]);
  for (const stage of ['raw', 'sdk', 'native']) {
    const events = laneReceipt.streams[stage].quality.events;
    assert.deepEqual(events.map(event => [event.epoch, event.seq, event.lane]), [[1, '5', undefined], [1, '5', 'addressed']]);
    checkDigests(events, [original, original]);
  }

  const members = [source, local, other, ...['55', '66', '77', '88', '99'].map(value => value.repeat(16))];
  const pressured = createRelayWireTrace();
  pressured.bind(room, local, members);
  for (const [kind, family] of [[2, 'input'], [4, 'quality']]) {
    pressured.record('send', envelope(local, source, kind), kind);
    function receive(peer, seq) {
      const packet = envelope(peer, local, kind);
      pressured.record('raw', delivered(packet, BigInt(seq), peer));
      pressured.recordEngine('sdk', peer, packet.toString('hex'), 1, String(seq), null);
      pressured.recordEngine('native', peer, packet.subarray(57).toString('hex'), 1, String(seq), 0);
    }
    receive(source, kind);
    for (let seq = 1; seq <= 129; seq++) {
      for (const peer of members.slice(2)) {
        pressured.record('send', envelope(local, peer, kind), seq);
        receive(peer, seq);
      }
    }
    const pressureDigestCalls = digestCalls;
    const { streams } = await pressured.freeze();
    const retainedPerFamily = 1 + 128 * 6;
    assert.equal(digestCalls - pressureDigestCalls, 4 * retainedPerFamily * (family === 'input' ? 1 : 2),
      'reuse raw, SDK and native digests at the per-link cap');
    for (const [stage, groups] of Object.entries(streams)) {
      const { count, omitted, events } = groups[family];
      assert.equal(count, 1 + 129 * 6);
      const first = events[0];
      assert.equal(stage === 'send' ? first.recipient : first.sender, source, `${stage} ${family} tail evicted by healthy links`);
      assert.equal(first.socket_ordinal ?? first.seq, stage === 'send' ? kind : String(kind));
      assert.equal(omitted, 6);
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_trace.cjs')], check=True, timeout=10)

    def test_native_expiry_keeps_the_last_accepted_stamps_beyond_ring_pressure(self):
        # Value: protects=expiry-time packet evidence; fails_when=newer raw or refused packets evict the native acceptance; seam=browser trace and departure receipt
        script = r"""
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { createRelayWireTrace } = require(process.argv[1]);
const { instrumentPostRelease, postReleaseCheckpoint } = require(process.argv[2]);
const { joinRelayReceipts, relayExpiryRows } = require(process.argv[3]);
const [room, source, local, other] = ['11', '22', '33', '44'].map(value => value.repeat(16));
const roster = [source, local, other];
const hex = value => Buffer.from(value, 'hex');
const trace = createRelayWireTrace();
trace.bind(room, local, roster);
const bytes = (sender, kind, mutation = 0) => {
  const body = Buffer.alloc({2: 31, 4: 18, 5: 16}[kind]);
  if (kind === 2) {
    body.writeBigUInt64LE(1n, 0);
    body.writeInt32LE(420, 9);
  }
  body[body.length - 1] = mutation;
  const payload = Buffer.concat([hex(room), hex('f552020001000000'), Buffer.from([kind, 0, 0, 0]), body]);
  return Buffer.concat([hex('4653523101'), hex(room), hex(sender), hex(local), Buffer.from([payload.length, 0, 0, 0]), payload]);
};
const name = value => Buffer.concat([Buffer.from([0xa0 + value.length]), Buffer.from(value)]);
function arrive(sender, buffer, seq) {
  const stamp = Buffer.alloc(9);
  stamp[0] = 0xcf;
  stamp.writeBigUInt64BE(BigInt(seq), 1);
  return trace.record('raw', Buffer.concat([hex('85'), name('from_player'), hex('c410'), hex(sender),
    name('encoding'), name('message_pack'), name('payload'), Buffer.from([0xc4, buffer.length]), buffer,
    name('seq'), stamp, name('epoch'), hex('01')]));
}
const inBytes = bytes(source, 2);
const report = bytes(source, 4);
for (const [packet, seq] of [[inBytes, '3'], [report, '4']]) {
  arrive(source, packet, seq);
  trace.recordEngine('sdk', source, packet.toString('hex'), 1, seq, null);
  trace.recordEngine('native', source, packet.subarray(57).toString('hex'), 1, seq, 0);
}
for (let i = 5; i <= 528; i++) {
  for (const [sender, kind] of [[source, 2], [source, 4], [other, 4]]) {
    const packet = bytes(sender, kind);
    arrive(sender, packet, i);
    trace.recordEngine('sdk', sender, packet.toString('hex'), 1, String(i), null);
    trace.recordEngine('native', sender, packet.subarray(57).toString('hex'), 1, String(i), sender === source ? 1 : 0);
  }
}
const reply = bytes(source, 5);
arrive(source, reply, 529);
trace.recordEngine('sdk', source, reply.toString('hex'), 1, '529', null);
trace.recordEngine('native', source, reply.subarray(57).toString('hex'), 1, '529', 0);
const consoleLines = [];
const savedDebug = console.debug;
console.debug = line => consoleLines.push(line);
const format = uuid => uuid.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
const frozen = roster.map(format);
const prefix = 'fortress native post-release ';
globalThis.window = { fortressNativeWire: { relayExpiryFrontier: sender => trace.expiryFrontier(sender) } };
instrumentPostRelease(prefix, 40);
window.fortressNativePostRelease.bindDeparture(format(local), frozen);
window.fortressNativePostRelease.recordDeparture('native_expiry', 1, JSON.stringify({
  observed_us: 4000, sdk_queued: 0, sdk_peak: 1, sdk_before_poll: 1,
  service_started_us: 3900, service_gap_us: 800, service_gap_peak_us: 900, last_accepted: null,
}));
window.fortressNativePostRelease.recordDeparture('native_expiry', 3);
console.debug = savedDebug;
assert.equal(consoleLines.length, 1);
const latched = {};
postReleaseCheckpoint(latched, consoleLines[0], {controller_ms: 100, controller_order: 1}, frozen, format(local));
assert.ok(latched.native_expiry?.frontier);
assert.deepEqual(latched.native_expiry.frontier.packets.map(packet => packet.seq), ['3', '4']);
assert.deepEqual(latched.native_expiry.frontier.packets.map(packet => Object.keys(packet.stages)), [
  ['raw', 'sdk', 'native'], ['raw', 'sdk', 'native'],
]);
const altered = JSON.parse(consoleLines[0].slice(prefix.length));
altered.frontier.packets[1].envelope = bytes(other, 4).toString('hex');
const rejected = {};
postReleaseCheckpoint(rejected, prefix + JSON.stringify(altered), {controller_ms: 100, controller_order: 2}, frozen, format(local));
assert.ok(rejected.native_expiry, 'retain the expiry independently of diagnostic validation');
assert.equal(rejected.native_expiry.frontier, undefined);
assert.match(rejected.checkpoint_error, /invalid native expiry frontier/);
const expiry = [latched.native_expiry];
const stage = (input = [], quality = []) => ({ sync: { events: [] }, input: { events: input }, quality: { events: quality } });
const digest = value => createHash('sha256').update(value).digest('hex');
const ingress = { sender: source, recipient: local, epoch: 1, seq: '3', kind: 2, envelope_bytes: inBytes.length,
  envelope_sha256: digest(inBytes), ordinal: 10, socket_ordinal: 20 };
const server = { room, roster, streams: { ingress: stage([ingress]), write: stage([{ ...ingress, actual_recipient: local }]) } };
const sourcePage = { room, local: source, sockets: 1, streams: { raw: stage(), sdk: stage(), native: stage(),
  send: stage([{ ...ingress, ordinal: 30 }]) } };
const joined = joinRelayReceipts(server, [sourcePage, { error: 'final read timed out' }], expiry);
const [inputRow, reportRow] = relayExpiryRows(expiry, joined, [source + '/' + local]);
assert.deepEqual(inputRow.missing, []);
assert.equal(inputRow.upstream_scope, 'focused');
assert.deepEqual(reportRow.missing, ['send', 'ingress', 'write']);
const withoutServer = relayExpiryRows(expiry, null, []);
assert.deepEqual(withoutServer.map(row => row.missing), [['send', 'ingress', 'write'], ['send', 'ingress', 'write']]);
assert.equal(withoutServer[0].upstream_scope, 'room');
assert.equal(relayExpiryRows(expiry, null, [other + '/' + local])[0].upstream_scope, 'outside-focus');
const afterRead = structuredClone(expiry);
afterRead[0].frontier.packets[0].stages.raw = null;
assert.deepEqual(relayExpiryRows(afterRead, joined, [source + '/' + local])[0].missing, ['raw'], 'later page data cannot fill a missing pre-acceptance stage');
assert.equal(trace.expiryFrontier(other).packets.find(packet => packet.kind === 2), undefined);
const nativeOnly = bytes(other, 2);
trace.recordEngine('native', other, nativeOnly.subarray(57).toString('hex'), 1, '530', 0);
const frontier = trace.expiryFrontier(other);
const nativeOnlyPin = frontier.packets.find(packet => packet.kind === 2);
assert.equal(nativeOnlyPin.stages.raw, undefined);
assert.equal(nativeOnlyPin.stages.sdk, undefined);
const nativeOnlyReceipt = {};
const original = JSON.parse(consoleLines[0].slice(prefix.length));
postReleaseCheckpoint(nativeOnlyReceipt, prefix + JSON.stringify({
  ...original, frontier, uuid: format(other), endpoint: frozen.indexOf(format(other)) + 1, page_ms: performance.now(),
}), {controller_ms: 101, controller_order: 3}, frozen, format(local));
assert.equal(nativeOnlyReceipt.checkpoint_error, undefined);
const nativeOnlyInput = nativeOnlyReceipt.native_expiry.frontier.packets.find(packet => packet.kind === 2);
assert.equal(nativeOnlyInput.seq, '530');
assert.ok(nativeOnlyInput.stages.native.ordinal > 0);
assert.equal(nativeOnlyInput.stages.sdk, null);
assert.equal(nativeOnlyInput.stages.raw, null);
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_trace.cjs'),
                        str(ROOT / 'scripts/reference/browser/native_online.cjs'), str(ROOT / 'scripts/reference/browser/native_relay_control.cjs')],
                       check=True, timeout=10)

    def test_same_link_pressure_requires_original_and_exact_blocked_packets(self):
        # Value: protects=pressure confined to the raw boundary; fails_when=missing originals or leaked stamped packets pass; seam=control receipt
        script = r"""
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { checkSameLinkRetention, exerciseSameLinkRetention } = require(process.argv[1]);
const [sender, recipient, room] = ['11', '22', '33'].map(byte => byte.repeat(16));
const stage = () => Object.fromEntries(['sync', 'input', 'quality'].map(family => [family, { events: [] }]));
function packetBytes(kind) {
  const envelope = Buffer.alloc(kind === 2 ? 109 : 103);
  Buffer.from(`4653523101${room}${sender}${recipient}`, 'hex').copy(envelope);
  envelope.writeUInt32LE(envelope.length - 57, 53);
  Buffer.from(room, 'hex').copy(envelope, 57);
  envelope.writeUInt32LE(0x000252f5, 73);
  envelope.writeUInt16LE(1, 77);
  envelope.writeUInt32LE(kind, 81);
  return envelope;
}
function fixture() {
  const server = { room, roster: [sender, recipient], streams: { ingress: stage(), write: stage() } };
  const source = { room, local: sender, sockets: 1, streams: { send: stage(), raw: stage(), sdk: stage(), native: stage() } };
  const reporter = { room, local: recipient, sockets: 1, streams: { send: stage(), raw: stage(), sdk: stage(), native: stage() } };
  const before = { started_ms: 25, frontier: [], raw_watermark: { input: 2, quality: 2 } };
  const resumed = { resumed_ms: 35, deadline_ms: 40, delivery_gate: 1, frontier: { room, sender, recipient, packets: [] } };
  const ordinals = [];
  for (const [family, kind] of [['input', 2], ['quality', 4]]) {
    const envelope = packetBytes(kind);
    const digest = createHash('sha256').update(envelope).digest('hex');
    for (let ordinal = 1; ordinal <= 522; ordinal++) {
      const seq = String(ordinal * 2 + (kind === 2 ? 0 : 1));
      const packet = { sender, recipient, epoch: 1, seq, kind, envelope_bytes: envelope.length, envelope_sha256: digest,
        ordinal, socket_ordinal: Number(seq) };
      source.streams.send[family].events.push(packet);
      server.streams.ingress[family].events.push(packet);
      server.streams.write[family].events.push({ ...packet, actual_recipient: recipient });
      const raw = { ...packet, at_ms: ordinal === 1 ? 20 : ordinal === 2 ? 24 : 30 };
      if (ordinal === 1) {
        before.frontier.push({ ...packet, family });
        reporter.streams.raw[family].events.push(raw);
        reporter.streams.sdk[family].events.push(packet);
        reporter.streams.native[family].events.push({ ...packet, code: 0 });
      } else if (ordinal === 2) {
        // Already queued at the gate. Only the resume pin retains these receiver observations.
        resumed.frontier.packets.push({ kind, epoch: 1, seq, envelope: envelope.toString('hex'),
          stages: { raw: { ordinal, at_ms: 24 }, sdk: { ordinal, at_ms: 26 }, native: { ordinal, at_ms: 27 } } });
      } else {
        raw.delivery_blocked = true;
        raw.delivery_gate = 1;
        reporter.streams.raw[family].events.push(raw);
        ordinals.push(packet.socket_ordinal);
      }
    }
  }
  return { server, source, reporter, before, resumed, ordinals };
}
function qualify({ server, source, reporter, before, resumed, ordinals }) {
  return checkSameLinkRetention(server, [source, reporter], before, resumed, ordinals);
}
assert.equal(qualify(fixture()).pressure.quality.count, 520);
assert.deepEqual(qualify(fixture()).frontier.map(row => row.seq), ['4', '5']);
for (const [change, diagnostic] of [
  [f => f.server.streams.ingress.input.events.splice(1, 1), /lost the original input packet stage/],
  [f => delete f.resumed.frontier.packets[0].stages.raw, /lost the original input packet stage/],
  [f => { f.resumed.frontier.packets[0].stages.raw.at_ms = f.before.started_ms; f.before.raw_watermark.input = 1; }, /lost the original input packet stage/],
  [f => { f.resumed.frontier.packets[0].stages.raw.at_ms = f.before.started_ms; f.before.raw_watermark.input = '2'; }, /invalid raw ordinal watermark/],
  [f => f.ordinals.splice(f.ordinals.length - 8), /needs over 512 new quality arrivals/],
  [f => f.reporter.streams.raw.quality.events[4].delivery_blocked = false, /did not stop at raw arrival/],
  [f => f.reporter.streams.raw.quality.events[4].delivery_gate = 2, /did not stop at raw arrival/],
  [f => f.reporter.streams.raw.quality.events[4].at_ms = 36, /did not stop at raw arrival/],
  [f => f.reporter.streams.sdk.quality.events.push(f.reporter.streams.raw.quality.events[4]), /did not stop at raw arrival/],
]) {
  const control = fixture();
  change(control);
  assert.throws(() => qualify(control), diagnostic);
}

(async () => {
  const { server, source, reporter, before, resumed, ordinals } = fixture();
  const page = wire => ({
    evaluate(run, arg) {
      globalThis.window = { fortressNativeWire: wire };
      return run(arg);
    },
    async waitForFunction(run, arg) {
      const value = this.evaluate(run, arg);
      return { jsonValue: async () => value, dispose: async () => {} };
    },
  });
  function receiptBytes(receipt) {
    const encoded = structuredClone(receipt);
    for (const groups of Object.values(encoded.streams)) {
      for (const { events } of Object.values(groups)) {
        for (const packet of events) {
          packet.bytes = packetBytes(packet.kind).toString('base64');
          delete packet.envelope_bytes;
          delete packet.envelope_sha256;
        }
      }
    }
    return encoded;
  }
  const sourcePage = page({ pressureRelayLink: () => ordinals, relayWireTrace: () => receiptBytes(source) });
  const reporterPage = page({ blockRelayLink: () => before, relayWireTrace: () => receiptBytes(reporter), resumeBlockedRelay(stamps) {
    assert.equal(stamps.length, 1040);
    assert.equal(stamps.filter(stamp => stamp.kind === 4).length, 520);
    return resumed;
  } });
  const result = await exerciseSameLinkRetention([sourcePage, reporterPage], [{ uuid: sender }, { uuid: recipient }], async select => {
    for (const change of [
      writes => writes.push({ ...writes[2] }),
      writes => writes[2].actual_recipient = 'unaddressed',
      writes => writes[2].envelope_sha256 = 'different',
      writes => writes[2].kind = 5,
    ]) {
      const incomplete = structuredClone(server);
      change(incomplete.streams.write.quality.events);
      assert.equal(select(incomplete), null, 'unconfirmed addressed write must leave the gate closed');
    }
    return select(server);
  });
  assert.equal(result.pressure.input.count, 520);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_relay_control.cjs')], check=True, timeout=10)

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

    def test_native_warmup_keeps_exact_input_stages_without_a_final_read(self):
        # Value: protects=input and reverse ACK evidence; fails_when=unavailable stages are inferred or exact bytes are overwritten; seam=warmup console
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire, createWarmupBarrier, WARMUP_CHECKPOINT } = require(process.argv[1]);
const { createRelayWireTrace, decodeRelayDelivery } = require(process.argv[2]);
const roster = Array.from({length: 8}, (_, i) => (i + 16).toString(16).repeat(16));
const [sender, receiver, other] = roster;
const room = '01'.repeat(16);
const payload = (kind, start, ack) => {
  const result = Buffer.alloc(kind === 2 ? 109 : 32);
  result.set(Buffer.from(room, 'hex'));
  result.set([0xf5, 0x52, 2, 0, 1], 16);
  result.writeUInt32LE(kind, 24);
  if (kind === 2) {
    result.writeBigUInt64LE(8n, 28);
    result.writeInt32LE(start, 92);
    result.writeInt32LE(ack, 96);
    result.writeBigUInt64LE(1n, 100);
    result[108] = 17;
  } else {
    result.writeInt32LE(ack, 28);
  }
  return result;
};
const relayFrame = (payload, from, to) => {
  const frame = Buffer.alloc(57 + payload.length);
  frame.set([70, 83, 82, 49, 1]);
  frame.set(Buffer.from(room + from + to, 'hex'), 5);
  frame.writeUInt32LE(payload.length, 53);
  frame.set(payload, 57);
  return frame;
};
const name = text => Buffer.concat([Buffer.from([0xa0 + text.length]), Buffer.from(text)]);
const delivery = (frame, from, seq) => Buffer.concat([Buffer.from([0x85]), name('from_player'),
  Buffer.from([0xc4, 16]), Buffer.from(from, 'hex'), name('encoding'), name('message_pack'),
  name('payload'), Buffer.from([0xc4, frame.length]), frame, name('seq'), Buffer.from([seq]), name('epoch'), Buffer.from([1])]);
class Socket {
  static OPEN = 1;
  readyState = Socket.OPEN;
  addEventListener(name, listener) { this[name] = listener; }
  send() { if (this.reject) throw new Error('socket send failed'); }
}
let time = 1;
const barrier = createWarmupBarrier(8, () => time);
barrier.bindSession(room);
function makeWire(local, index) {
  const window = {}, tasks = [];
  const realm = {
    window, performance: {now: () => time}, console: {debug: value => barrier.record(index, value)},
    setTimeout: callback => tasks.push(callback),
    Uint8Array, ArrayBuffer, DataView, WebSocket: Socket, RTCPeerConnection: class {},
  };
  runInNewContext(`(${instrumentNativeWire})(false, ${JSON.stringify(WARMUP_CHECKPOINT)}, (${createRelayWireTrace})('', 512, 45000, (${decodeRelayDelivery})))`, realm);
  const socket = new window.WebSocket(), wire = window.fortressNativeWire;
  wire.bind(room, local, roster);
  return { socket, wire, tasks };
}
const { socket, wire, tasks } = makeWire(receiver, 1);
const reverse = makeWire(sender, 0);
const input9 = payload(2, 9, 8);
socket.message({data: delivery(relayFrame(input9, sender, receiver), sender, 11)});
tasks.shift()?.();
const early = barrier.checkpoints[1]?.input_link;
assert.ok(early, 'warmup checkpoint must carry the addressed raw input');
assert.equal(early.sender, sender);
assert.equal(early.recipient, receiver);
assert.equal(early.raw.first.payload, input9.toString('hex'));
assert.equal(early.raw.first.start_frame, 9);
assert.equal(early.raw.first.ack_frame, 8);
assert.equal(early.raw.first.seq, '11');
assert.equal(early.raw.first.epoch, 1);
assert.equal(early.sdk.first, null);
assert.equal(early.native.first, null);
assert.equal(early.ack.first, null);
const input10 = payload(2, 10, 9);
wire.observeWarmupInput('sdk', sender, input9.toString('hex'), -1);
wire.observeWarmupInput('native', sender, input9.toString('hex'), 6);
wire.observeWarmupInput('native', sender, input9.toString('hex'), 0);
wire.observeWarmupInput('sdk', other, input10.toString('hex'), -1);
wire.observeWarmupInput('sdk', sender, input10.toString('hex'), 0);
wire.observeWarmupInput('native', sender, 'g'.repeat(12), 0);
const malformed = Buffer.from(input10);
malformed.writeBigUInt64LE(2n, 100);
socket.message({data: delivery(relayFrame(malformed, sender, receiver), sender, 14)});
const input11 = payload(2, 11, 9);
socket.message({data: relayFrame(input11, sender, receiver)});
const unstamped = wire.warmupStatus().input_link.raw.recent;
assert.ok(unstamped, 'addressed bytes survive without a physical stamp');
assert.equal(unstamped.payload, input11.toString('hex'));
assert.equal(unstamped.epoch, null);
assert.equal(unstamped.seq, null);
socket.message({data: delivery(relayFrame(input10, sender, receiver), other, 15)});
const mismatched = wire.warmupStatus().input_link.raw.recent;
assert.equal(mismatched.payload, input10.toString('hex'));
assert.equal(mismatched.epoch, null);
assert.equal(mismatched.seq, null);
socket.message({data: relayFrame(input10, other, receiver)});
socket.message({data: relayFrame(input10, sender, other)});
socket.message({data: delivery(relayFrame(input10, sender, receiver), sender, 12)});
socket.message({data: delivery(relayFrame(input9, sender, receiver), sender, 13)});
const ack = payload(3, null, 10);
socket.send(relayFrame(ack, receiver, other));
socket.send(relayFrame(ack, other, sender));
socket.reject = true;
assert.throws(() => socket.send(relayFrame(ack, receiver, sender)), /socket send failed/);
assert.equal(wire.warmupStatus().input_link.ack.count, 0);
socket.reject = false;
socket.send(relayFrame(ack, receiver, sender));
reverse.socket.message({data: delivery(relayFrame(ack, receiver, sender), receiver, 21)});
reverse.tasks.shift()?.();
const earlyAck = barrier.checkpoints[0]?.ack_link;
assert.ok(earlyAck, 'the watched reverse ACK must be observed on its addressed receiver');
assert.equal(earlyAck.sender, receiver);
assert.equal(earlyAck.recipient, sender);
assert.equal(earlyAck.raw.first.payload, ack.toString('hex'));
assert.equal(earlyAck.raw.first.start_frame, null);
assert.equal(earlyAck.raw.first.ack_frame, 10);
assert.equal(earlyAck.raw.first.seq, '21');
assert.equal(earlyAck.sdk.first, null);
assert.equal(earlyAck.native.first, null);
const ack11 = payload(3, null, 11);
reverse.socket.message({data: relayFrame(ack11, receiver, sender)});
reverse.socket.message({data: relayFrame(ack11, other, sender)});
reverse.socket.message({data: relayFrame(ack11, receiver, other)});
reverse.socket.message({data: relayFrame(input9, receiver, sender)});
reverse.wire.observeWarmupInput('sdk', receiver, ack.toString('hex'), -1);
reverse.wire.observeWarmupInput('native', receiver, ack.toString('hex'), 6);
reverse.wire.observeWarmupInput('native', receiver, ack.toString('hex'), 0);
reverse.wire.observeWarmupInput('sdk', other, ack11.toString('hex'), -1);
reverse.wire.observeWarmupInput('sdk', receiver, input9.toString('hex'), -1);
time = 1050;
const nativeSlots = roster.slice(1).map((_, i) => ({
  slot: i + 1, receipt_frame: 16, connected: i !== 1, pending_output: i, gossip_bound: i === 0 ? 8 : i === 1 ? 17 : 16,
}));
reverse.wire.recordWarmupTick(0, 0, 8, 20, 'playing', 16, 8, JSON.stringify(nativeSlots));
reverse.wire.finishWarmup('playing', 16, 12);
const ackSample = barrier.checkpoints[0].ack_link;
assert.deepEqual(barrier.checkpoints[0].native_frontier, { at_ms: 1050, frame: 16, confirmed: 8, slots: nativeSlots });
assert.equal(ackSample.raw.count, 2);
assert.equal(ackSample.raw.recent.ack_frame, 11);
assert.equal(ackSample.raw.recent.seq, null);
assert.equal(ackSample.sdk.count, 1);
assert.equal(ackSample.native.count, 2);
assert.equal(ackSample.native.first.code, 6);
assert.equal(ackSample.native.recent.code, 0);
reverse.socket.message({data: relayFrame(ack11, receiver, sender)});
reverse.wire.observeWarmupInput('native', receiver, ack11.toString('hex'), 0);
assert.equal(reverse.wire.warmupStatus().ack_link.raw.count, 2);
assert.equal(reverse.wire.warmupStatus().ack_link.native.count, 2);
const ordinaryRecent = wire.warmupStatus().input_link.raw.recent;
assert.equal(ordinaryRecent.seq, '12', 'return to initial bytes on the same lane preserves the most recent distinct delivery');
assert.equal(ordinaryRecent.payload, input10.toString('hex'));
const privateWire = Buffer.concat([Buffer.from([1]), delivery(relayFrame(input9, sender, receiver), sender, 11)]);
socket.message({data: privateWire});
wire.finishWarmup('playing', 20, 12);
assert.deepEqual(barrier.errors, Array(8).fill(null));
const sample = barrier.checkpoints[1].input_link;
assert.equal(sample.raw.count, 6);
assert.equal(sample.raw.first.seq, '11', 'duplicates cannot change the earliest exact delivery');
assert.equal(sample.raw.first.lane, undefined);
assert.equal(sample.raw.recent.seq, sample.raw.first.seq);
assert.equal(sample.raw.recent.payload, sample.raw.first.payload);
assert.equal(sample.raw.recent.lane, 'addressed', 'an equal payload and stamp can arrive on a different lane');
assert.equal(barrier.inputErrors[1], null);
assert.equal(sample.sdk.count, 1);
assert.equal(sample.sdk.recent, null);
assert.equal(sample.native.count, 2);
assert.equal(sample.native.first.code, 6);
assert.equal(sample.native.recent.code, 0);
assert.equal(sample.native.recent.payload, input9.toString('hex'));
assert.equal(sample.ack.count, 1);
assert.equal(sample.ack.first.ack_frame, 10);
assert.equal(sample.ack.first.payload, ack.toString('hex'));
wire.observeWarmupInput('native', sender, input10.toString('hex'), 0);
socket.message({data: relayFrame(input10, sender, receiver)});
socket.send(relayFrame(ack, receiver, sender));
assert.equal(wire.warmupStatus().input_link.native.count, 2);
assert.equal(wire.warmupStatus().input_link.raw.count, 6);
assert.equal(wire.warmupStatus().input_link.ack.count, 1);
const wrongAck = JSON.parse(JSON.stringify(barrier.checkpoints[0].ack_link));
wrongAck.raw.first.payload = '00'.repeat(32);
const wrongBounds = nativeSlots.map((slot, index) => index === 0 ? { ...slot, gossip_bound: 17 } : slot);
const foreignSession = createWarmupBarrier(8, () => time);
foreignSession.bindSession('ff'.repeat(16));
foreignSession.record(0, WARMUP_CHECKPOINT + JSON.stringify(barrier.checkpoints[0]));
assert.match(foreignSession.ackErrors[0], /invalid warmup ACK link/);
assert.equal(foreignSession.errors[0], null);
const wrong = JSON.parse(JSON.stringify(barrier.checkpoints[1]));
wrong.input_link.sender = other;
const brokenStream = JSON.parse(JSON.stringify(barrier.checkpoints[1]));
brokenStream.input_link.raw.count = 0;
barrier.record(2, WARMUP_CHECKPOINT + JSON.stringify(brokenStream));
assert.match(barrier.inputErrors[2], /invalid warmup input link/);
assert.equal(barrier.errors[2], null);
assert.equal(barrier.checkpoints[2].input_link, undefined);
(async () => {
  const gate = createWarmupBarrier(8, () => time);
  await gate.wait(async () => {
    for (const [index, recipient] of roster.entries()) {
      const page = { ...wrong, recipient, links: roster.filter(sender => sender !== recipient).map(sender => ({sender})),
        input_link: index === 1 ? wrong.input_link : undefined, ack_link: index === 0 ? wrongAck : undefined,
        native_frontier: index === 0 ? { at_ms: 1050, frame: 16, confirmed: 8, slots: wrongBounds } : undefined };
      gate.record(index, WARMUP_CHECKPOINT + JSON.stringify(page));
    }
  }, 50);
  assert.equal(gate.received.filter(value => value !== null).length, 8, 'invalid optional evidence cannot block the warmup gate');
  assert.match(gate.inputErrors[1], /invalid warmup input link/);
  assert.equal(gate.errors[1], null);
  assert.equal(gate.checkpoints[1].input_link, undefined);
  assert.match(gate.ackErrors[0], /invalid warmup ACK link/);
  assert.equal(gate.checkpoints[0].ack_link, undefined);
  assert.match(gate.nativeErrors[0], /invalid warmup native frontier/);
  assert.equal(gate.checkpoints[0].native_frontier, undefined);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs'),
                        str(ROOT / 'scripts/reference/browser/native_relay_trace.cjs')], check=True, timeout=10)

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

    def test_native_relay_release_signal_requires_every_prepared_page(self):
        # Value: protects=room-wide release through prepared browser requests; fails_when=release needs a second evaluation or signals a partial room; seam=HTTP
        script = r"""
const assert = require('node:assert/strict');
const http = require('node:http');
const { captureAndReleaseInput, createReleaseSignal, recordReleaseTiming, releaseDeliveryTiming } = require(process.argv[1]);
const signal = createReleaseSignal(2);
let redirectsFollowed = 0;
const server = http.createServer((req, res) => {
  if (req.url === '/redirect') res.writeHead(302, { Location: '/unexpected' }).end();
  else if (req.url === '/unexpected') { redirectsFollowed++; res.writeHead(204).end(); }
  else if (!signal.handle(req, res)) res.writeHead(404).end();
});
async function run() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = 'http://127.0.0.1:' + server.address().port;
  const path = index => origin + signal.paths[index];
  assert.deepEqual(signal.timings(), signal.paths.map(path => ({
    path, request_dispatched_ms: null, request_received_ms: null, first_write_ms: null, handoff_ms: null, finished_ms: null,
    continuation: null, resource: null,
  })));
  let evaluations = 0, releases = 0;
  global.window = { fortressNative: { state: 'playing' }, fortressNativeWire: {
    status: () => ({ holding: true }),
    holdProgress: () => ({}),
    release: () => ++releases,
  } };
  const page = { evaluate(callback, argument) { evaluations++; return callback(argument); } };
  const first = captureAndReleaseInput(page, 0, path(0));
  await new Promise(resolve => server.once('request', resolve));
  assert.throws(() => signal.release(performance.now() + 500), /relay release requests unavailable/);
  const last = captureAndReleaseInput(page, 1, path(1));
  await signal.ready;
  assert.equal(releases, 0);
  assert.equal((await fetch(path(0))).status, 409);
  assert.equal((await fetch(path(0), { method: 'POST' })).status, 405);
  assert.equal(releases, 0);
  assert.ok(signal.timings().every(receipt => receipt.request_received_ms !== null && receipt.first_write_ms === null));
  signal.release(performance.now() + 500);
  const receipts = await Promise.all([first, last]);
  assert.deepEqual(receipts.map(receipt => receipt.index), [0, 1]);
  assert.equal(evaluations, 2);
  const receipt = signal.timings()[0];
  assert.ok(receipt.request_received_ms <= receipt.first_write_ms && receipt.first_write_ms <= receipt.handoff_ms && receipt.handoff_ms <= receipt.finished_ms);
  assert.equal(receipt.continuation, null);
  assert.equal(receipt.resource, null);
  const entered = { path: signal.paths[0], requested_ms: 10, continued_ms: 510, status: 204 };
  const resource = { path: signal.paths[0], fetch_start_ms: 10, response_start_ms: null, response_end_ms: 25, response_status: null };
  assert.equal(recordReleaseTiming(receipt, JSON.stringify({ ...resource, path: signal.paths[1] }), 700), false);
  assert.equal(recordReleaseTiming(receipt, JSON.stringify({ ...resource, fetch_start_ms: 26 }), 700), false);
  assert.equal(recordReleaseTiming(receipt, JSON.stringify(resource), 700), true);
  assert.equal(recordReleaseTiming(receipt, JSON.stringify(entered), 701), true);
  assert.equal(recordReleaseTiming(receipt, JSON.stringify({ ...entered, continued_ms: 615 }), 800), false);
  assert.deepEqual(receipt.resource, { fetch_start_ms: 10, request_start_ms: null, response_start_ms: null, response_end_ms: 25,
    response_status: null, controller_ms: 700 });
  assert.deepEqual(receipt.continuation, { requested_ms: 10, continued_ms: 510, status: 204, controller_ms: 701 });
  assert.equal(releases, 2);
  assert.equal((await fetch(path(0))).status, 409);
  assert.throws(() => signal.release(performance.now() + 500), /relay release requests unavailable/);
  const redirect = { path: origin + '/redirect', request_dispatched_ms: 1, request_received_ms: 3,
    resource: { fetch_start_ms: 2, response_end_ms: 4, response_status: 302, controller_ms: 10 } };
  assert.ok(releaseDeliveryTiming(redirect).offset_ms, 'a resource timing entry alone can otherwise supply an offset');
  console.debug = text => {
    assert.ok(text.startsWith('timing '));
    recordReleaseTiming(redirect, text.slice('timing '.length), 11);
  };
  await assert.rejects(captureAndReleaseInput(page, 0, redirect.path, 'timing '), /fetch failed/);
  assert.equal(redirectsFollowed, 0);
  assert.equal(redirect.fetch_failed, true);
  assert.equal(redirect.response_mismatch, undefined);
  assert.equal(releaseDeliveryTiming(redirect).offset_ms, null);
  assert.equal(releases, 2);
}
const deadline = setTimeout(() => { throw new Error('relay release signal test did not settle'); }, 3000);
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  clearTimeout(deadline);
  signal.cancel();
  server.close();
});
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_release_controls_delay_only_the_selected_boundary(self):
        # Value: protects=independent host and page delays; fails_when=either delay is skipped or survives cancellation
        script = r"""
const assert = require('node:assert/strict');
const { assertReleaseDelay, captureAndReleaseInput, createReleaseSignal } = require(process.argv[1]);
let timer;
let now = 100;
global.performance = { now: () => now };
global.setTimeout = (callback, delay) => {
  assert.equal(delay, 450);
  assert.equal(timer, undefined);
  timer = callback;
  return callback;
};
global.clearTimeout = callback => {
  assert.equal(callback, timer);
  timer = undefined;
};
const advance = () => {
  const callback = timer;
  assert.ok(callback);
  timer = undefined;
  now += 450;
  callback();
};

for (const outcome of ['delivered', 'cancelled', 'expired']) {
  const host = createReleaseSignal(1, 450);
  let finish;
  const response = {
    socket: {}, writeHead(code) { assert.equal(code, 204); return this; },
    once(event, callback) { assert.equal(event, 'finish'); finish = callback; },
    end() { assert.equal(this.destroyed, undefined); finish(); },
    destroy() { this.destroyed = true; },
  };
  assert.equal(host.handle({ url: host.paths[0], method: 'GET' }, response), true);
  host.release(now + (outcome === 'expired' ? 449 : 500));
  const [receipt] = host.timings();
  assert.equal(receipt.handoff_ms, null);
  assert.equal(receipt.finished_ms, null);
  if (outcome === 'cancelled') host.cancel();
  else advance();
  assert.equal(timer, undefined);
  assert.equal(response.destroyed, outcome === 'delivered' ? undefined : true);
  assert.equal(receipt.handoff_ms, outcome === 'delivered' ? receipt.first_write_ms + 450 : null);
  assert.equal(receipt.finished_ms, outcome === 'delivered' ? receipt.first_write_ms + 450 : null);
}

(async () => {
  const receipt = { request_dispatched_ms: 2000, request_received_ms: 2700, first_write_ms: 2701, handoff_ms: 2702, finished_ms: 3151,
    resource: { fetch_start_ms: 550, response_end_ms: 1250, response_status: 204, controller_ms: 3600 } };
  assert.throws(() => assertReleaseDelay([receipt], 'delivery'), /lacks the delivery delay/);
  assertReleaseDelay([{ ...receipt, handoff_ms: 3151 }], 'delivery');
  assert.throws(() => assertReleaseDelay([{ ...receipt, handoff_ms: 3160 }], 'delivery'), /lacks release delivery timing/);
  assert.throws(() => assertReleaseDelay([receipt], 'continuation'), /lacks the continuation delay/);
  const continuation = { status: 204, controller_ms: 3900, fetch_resolved_ms: 1252, continued_ms: 1702 };
  assertReleaseDelay([{ ...receipt, continuation }], 'continuation');
  assert.throws(() => assertReleaseDelay([{ ...receipt, continuation: { ...continuation, status: 500 } }], 'continuation'),
    /lacks release delivery timing/);
  assert.throws(() => assertReleaseDelay([{ ...receipt, resource: null, handoff_ms: 3151 }], 'delivery'), /lacks release delivery timing/);
  console.debug = () => {};
  const page = { evaluate(callback, argument) { return callback(argument); } };
  for (const budget of ['1000000', '400000']) {
    global.fetch = async (url, options) => {
      assert.equal(options.redirect, 'error');
      return { url, status: 204, headers: new Headers({ 'X-Fortress-Release-Budget-Us': budget }) };
    };
    global.window = { fortressNative: { state: 'playing' }, fortressNativeWire: { status: () => ({}), release: () => 'released' } };
    const release = captureAndReleaseInput(page, 0, 'https://localhost/native-release/control', '', 450);
    await Promise.resolve();
    assert.equal(window.fortressNativeStalled, undefined);
    advance();
    if (budget === '1000000') assert.equal((await release).release, 'released');
    else {
      await assert.rejects(release, /native relay release deadline/);
      assert.equal(window.fortressNativeStalled, undefined);
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_release_uses_network_landmarks_to_bound_handoff(self):
        # Value: protects=causal release bounds; fails_when=fetch dispatch jitter hides host handoff or a contradictory landmark supplies a bound
        script = r"""
const assert = require('node:assert/strict');
const { releaseDeliveryTiming } = require(process.argv[1]);
const receipt = { request_dispatched_ms: 2000, request_received_ms: 2700, first_write_ms: 2701, handoff_ms: 3151, finished_ms: 3152,
  resource: { fetch_start_ms: 550, request_start_ms: 1200, response_start_ms: 1660, response_end_ms: 1670, response_status: 204, controller_ms: 3200 } };
const cap = { page_ms: 1650 };
assert.deepEqual(releaseDeliveryTiming(receipt, cap), {
  offset_ms: { min: 1479, max: 1502 }, write_to_response_end_ms: { min: 450, max: 473 },
  handoff_to_response_end_ms: { min: 0, max: 23 }, hold_cap_to_response_end_ms: 20,
});
const earlyResponseStart = { ...receipt, resource: { ...receipt.resource, response_start_ms: 1200.02 } };
assert.deepEqual(releaseDeliveryTiming(earlyResponseStart, cap), releaseDeliveryTiming(receipt, cap));
for (const request_start_ms of [549, 1671]) {
  const outOfOrder = { ...receipt, resource: { ...receipt.resource, request_start_ms } };
  assert.deepEqual(releaseDeliveryTiming(outOfOrder, cap), {
    offset_ms: null, write_to_response_end_ms: null, handoff_to_response_end_ms: null, hold_cap_to_response_end_ms: null,
  });
}
const absent = { ...receipt, resource: { ...receipt.resource, request_start_ms: null, response_start_ms: null } };
assert.deepEqual(releaseDeliveryTiming(absent, cap), {
  offset_ms: { min: 1479, max: 2152 }, write_to_response_end_ms: { min: 450, max: 499 },
  handoff_to_response_end_ms: { min: 0, max: 49 }, hold_cap_to_response_end_ms: 20,
});
const contradictory = { ...receipt, resource: { ...receipt.resource, request_start_ms: 1600 } };
assert.equal(releaseDeliveryTiming(contradictory, cap).offset_ms, null);
assert.equal(releaseDeliveryTiming(contradictory, cap).handoff_to_response_end_ms, null);
assert.equal(releaseDeliveryTiming(contradictory, cap).hold_cap_to_response_end_ms, 20);
assert.equal(releaseDeliveryTiming({ ...receipt, handoff_ms: 3199 }).handoff_to_response_end_ms, null);
assert.equal(releaseDeliveryTiming({ ...receipt, resource: { ...receipt.resource, response_status: 500 } }, cap).hold_cap_to_response_end_ms, null);
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_release_matches_its_resource_before_or_after_continuation(self):
        # Value: protects=independent release clocks and exact resource identity; fails_when=timing needs the other event or matches a foreign fetch
        script = r"""
const assert = require('node:assert/strict');
const { captureAndReleaseInput, recordReleaseTiming, releaseDeliveryTiming } = require(process.argv[1]);
const path = '/native-release/control';
const prefix = 'timing ';
global.location = { href: 'http://localhost/test' };
global.window = { fortressNative: { state: 'playing' }, fortressNativeWire: { status: () => ({}), release: () => 'released' } };
const page = { evaluate(callback, argument) { return callback(argument); } };

async function run(responseDelay, continuationDelay, { unavailable = false, status = 204, nearDeadline = false } = {}) {
  const receipt = { path, request_dispatched_ms: 3000, request_received_ms: 3004, first_write_ms: 3010,
    continuation: null, resource: null };
  let now = 10;
  let controller = 3000 + responseDelay + continuationDelay + 100;
  const received = controller;
  let observe;
  let disconnected = false;
  let resume;
  global.performance = { now: () => now };
  global.PerformanceObserver = class {
    static supportedEntryTypes = unavailable ? [] : ['resource'];
    constructor(callback) { observe = entries => callback({ getEntries: () => entries }); }
    observe(options) { assert.deepEqual(options, { type: 'resource' }); }
    disconnect() { disconnected = true; }
  };
  console.debug = message => {
    assert.ok(message.startsWith(prefix));
    assert.equal(recordReleaseTiming(receipt, message.slice(prefix.length), ++controller), true);
    if (nearDeadline && receipt.continuation) now = 1006;
  };
  global.fetch = () => new Promise(resolve => { resume = resolve; });
  const released = captureAndReleaseInput(page, 0, path, prefix);
  const resource = { name: new URL(path, location.href).href, initiatorType: 'fetch',
    fetchStart: 10, requestStart: 11, responseStart: 9, responseEnd: 22 + responseDelay, responseStatus: status };
  if (!unavailable) {
    observe([{ ...resource, name: resource.name + '?other' }, { ...resource, initiatorType: 'xmlhttprequest' }]);
    assert.equal(disconnected, false);
    assert.equal(receipt.resource, null);
    if (continuationDelay) {
      observe([resource]);
      assert.equal(receipt.continuation, null);
      assert.equal(disconnected, true);
    }
  }
  const continued = now = resource.responseEnd + continuationDelay;
  resume({ url: resource.name, status, headers: new Headers({ 'X-Fortress-Release-Budget-Us': '1000000' }) });
  if (status === 204) assert.equal((await released).release, 'released');
  else await assert.rejects(released, /native relay release signal returned HTTP 409/);
  assert.deepEqual(receipt.continuation,
    { requested_ms: 10, continued_ms: continued, status, controller_ms: received + (continuationDelay ? 2 : 1) });
  if (unavailable) {
    assert.equal(receipt.resource, null);
  } else {
    if (!continuationDelay) {
      assert.equal(receipt.resource, null);
      observe([{ ...resource, responseStart: 0 }]);
    }
    assert.equal(disconnected, true);
    assert.deepEqual(receipt.resource, { fetch_start_ms: 10, request_start_ms: 11,
      response_start_ms: continuationDelay ? 9 : null, response_end_ms: 22 + responseDelay,
      response_status: status, controller_ms: received + (continuationDelay ? 1 : 2) });
    assert.equal(receipt.continuation.continued_ms - receipt.resource.response_end_ms, continuationDelay);
    assert.deepEqual(releaseDeliveryTiming(receipt), {
      offset_ms: { min: 2988, max: 2995 },
      write_to_response_end_ms: status === 204 ? { min: Math.max(0, responseDelay - 2), max: responseDelay + 9 } : null,
      handoff_to_response_end_ms: null,
      hold_cap_to_response_end_ms: null,
    });
    const resourceOnly = { ...receipt, continuation: null };
    assert.deepEqual(releaseDeliveryTiming(resourceOnly), releaseDeliveryTiming(receipt));
    for (const observed of [3009, 3010 + responseDelay - 3]) {
      const early = { ...receipt.resource, controller_ms: observed };
      assert.equal(releaseDeliveryTiming({ ...receipt, resource: early }).write_to_response_end_ms, null);
    }
    const unknown = { ...receipt.resource, response_status: null };
    assert.equal(releaseDeliveryTiming({ ...resourceOnly, resource: unknown }).write_to_response_end_ms, null);
    assert.deepEqual(releaseDeliveryTiming({ ...receipt, resource: unknown }), releaseDeliveryTiming(receipt));
    const earlyContinuation = { ...receipt.continuation, controller_ms: 3009 };
    assert.equal(releaseDeliveryTiming({ ...receipt, resource: unknown, continuation: earlyContinuation }).write_to_response_end_ms, null);
    const failed = { ...receipt.resource, response_status: 0 };
    assert.equal(releaseDeliveryTiming({ ...receipt, resource: failed }).write_to_response_end_ms, null);
    assert.equal(releaseDeliveryTiming({ ...receipt, first_write_ms: 5000 }).write_to_response_end_ms, null);
  }
  assert.equal(releaseDeliveryTiming({ ...receipt, resource: null }).write_to_response_end_ms, null);
}

let completed = false;
process.once('beforeExit', code => {
  if (code === 0 && !completed) throw new Error('relay release timing control did not finish');
});
(async () => {
  await run(450, 0);
  await run(0, 450);
  await run(0, 0, { unavailable: true });
  await run(0, 0, { status: 409 });
  await run(983, 0, { nearDeadline: true });
  completed = true;
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_release_rejects_disconnected_and_late_pages(self):
        # Value: protects=release only for the original live requests and before cutoff; fails_when=socket replacement or a late reply releases input; seam=HTTP and page
        script = r"""
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { captureAndReleaseInput, createReleaseSignal, recordReleaseTiming, releaseDeliveryTiming } = require(process.argv[1]);
let now = 300;
global.performance = { now: () => now };
function request(signal, index) {
  const response = Object.assign(new EventEmitter(), {
    socket: { destroyed: false },
    writeHead(status, headers) { this.status = status; this.headers = headers; return this; },
    end() { this.writableEnded = true; },
    destroy() { this.destroyed = true; this.emit('close'); },
  });
  assert.equal(signal.handle({ url: signal.paths[index], method: 'GET' }, response), true);
  return response;
}
async function run() {
  const disconnected = createReleaseSignal(2);
  const first = request(disconnected, 0);
  const live = request(disconnected, 1);
  await disconnected.ready;
  first.socket.destroyed = true;
  assert.throws(() => disconnected.release(900), /relay release requests unavailable/, 'socket liveness precedes the response close event');
  assert.equal(live.status, undefined);
  first.destroy();
  assert.equal(request(disconnected, 0).status, 409, 'a replacement cannot regain a disconnected slot');
  assert.throws(() => disconnected.release(900), /relay release requests unavailable/);
  assert.equal(live.status, undefined, 'refuse the whole room after a disconnect');
  disconnected.cancel();
  assert.equal(live.destroyed, true);

  global.window = { fortressNative: { state: 'playing' }, fortressNativeWire: {
    status: () => ({}), release() { assert.fail('a late response started the FIFO drain'); },
  } };
  const page = { evaluate(callback, argument) { return callback(argument); } };
  let deliver;
  global.fetch = () => new Promise(resolve => { deliver = resolve; });
  const delayed = captureAndReleaseInput(page, 0, 'https://localhost/prepared');
  const checked = assert.rejects(delayed, /native relay release deadline/);
  now = 900;
  deliver({ url: 'https://localhost/prepared', status: 204, headers: new Headers({ 'X-Fortress-Release-Budget-Us': '600000' }) });
  await checked;
  assert.equal(window.fortressNativeStalled, undefined, 'a late response cannot publish even its stalled snapshot');
  for (const response of [{ url: 'https://localhost/another-nonce' }, { url: 'https://localhost/prepared', redirected: true }]) {
    const receipt = { path: 'https://localhost/prepared', request_dispatched_ms: 300, request_received_ms: 302, first_write_ms: 320,
      handoff_ms: 320, finished_ms: 321,
      resource: { fetch_start_ms: 10, request_start_ms: 11, response_end_ms: 30, response_status: 204, controller_ms: 330 } };
    assert.ok(releaseDeliveryTiming(receipt).handoff_to_response_end_ms);
    console.debug = text => assert.ok(recordReleaseTiming(receipt, text.slice('timing '.length), 331));
    global.fetch = async () => ({ ...response, status: 204, headers: new Headers({ 'X-Fortress-Release-Budget-Us': '600000' }) });
    await assert.rejects(captureAndReleaseInput(page, 0, receipt.path, 'timing '), /does not match the release request/);
    assert.equal(releaseDeliveryTiming(receipt).handoff_to_response_end_ms, null);
    assert.equal(window.fortressNativeStalled, undefined);
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')], check=True, timeout=10)

    def test_native_relay_release_drains_originals_in_order_while_control_passes(self):
        # Value: protects=bounded FIFO recovery on the real socket hook; fails_when=release bursts or overtakes; seam=browser send
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
const released = [], releasedPackets = [], turns = [];
class Socket {
  static OPEN = 1;
  readyState = Socket.OPEN;
  bufferedAmount = 0;
  addEventListener(kind, callback) { this[kind] = callback; }
  send(bytes) {
    released.push(bytes.at(-1));
    releasedPackets.push(Array.from(bytes));
  }
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
  const otherRecipient = relay(2, 100);
  otherRecipient.fill(3, 21, 37);
  socket.message({ data: otherRecipient });
  const addressed = otherRecipient.slice();
  addressed.fill(1, 37, 53);
  socket.message({ data: addressed });
  assert.equal(wire.status().relay_trace.broadcasts, 2);
  assert.equal(wire.status().relaySenders['03'.repeat(16)], 1);
  assert.equal(wire.status().relayInputSenders['03'.repeat(16)], 1);
  otherRecipient[73] = 0;
  assert.throws(() => socket.message({ data: otherRecipient }), /native gameplay wire header/);
  assert.equal(wire.status().relay_trace.broadcasts, 2);
  wire.arm();
  for (let i = 0; i < 33; i++) {
    const bytes = relay(2, i);
    socket.send(bytes);
    bytes.fill(0);
  }
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
  assert.deepEqual(releasedPackets.filter(bytes => bytes.at(-1) !== 99), Array.from({length: 34}, (_, i) => Array.from(relay(2, i))));
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

  let now = 10;
  const timed = { ...realm, window: {}, performance: { now: () => now }, WebSocket: class extends Socket {}, RTCPeerConnection: class {} };
  runInNewContext(`(${instrumentNativeWire})()`, timed);
  const timedWire = timed.window.fortressNativeWire;
  const timedSocket = new timed.window.WebSocket();
  timedWire.bind('00'.repeat(16), '01'.repeat(16));
  timedWire.arm();
  for (let i = 0; i < 33; i++) timedSocket.send(relay(2, i));
  const deadline = assert.rejects(timedWire.release(11000), /native relay release deadline/);
  assert.equal(timedWire.status().released, 16, 'the first batch has time to release');
  now = 11;
  turns.shift()();
  await deadline;
  assert.equal(timedWire.status().released, 16, 'no further batch can start at the cutoff');

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
const evidence = (depth, accepted) => ({observed_us: 6000, sdk_queued: depth, sdk_peak: 710, sdk_before_poll: 708,
  service_started_us: 5800, service_gap_us: 1200, service_gap_peak_us: 2500,
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
const {observed_us, sdk_before_poll, service_started_us, service_gap_us, service_gap_peak_us} = peers[2].native_expiry.expiry;
assert.deepEqual([observed_us, sdk_before_poll, service_started_us, service_gap_us, service_gap_peak_us], [6000, 708, 5800, 1200, 2500]);
for (const invalid of [
  {sdk_before_poll: 711}, {service_started_us: 6001}, {service_gap_us: 2501}, {service_gap_us: 5801, service_gap_peak_us: 6000},
]) {
  const malformed = {};
  postReleaseCheckpoint(malformed, prefix + JSON.stringify({kind: 'native_expiry', endpoint: 8, uuid: uuids[6], page_ms: 6,
    expiry: {...evidence(0, null), ...invalid}}), incoming(150), roster, uuids[2]);
  assert.match(malformed.checkpoint_error, /invalid native expiry evidence/);
  assert.equal(malformed.native_expiry, undefined);
}
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
  await captureAndReleaseInput(page, 0);
  now++;
  Object.assign(window.fortressNative, { turns: 22, confirmed: 40 });
  observe();
  await assert.rejects(readConfirmedHistory(page, 40, 4, 2), /controller receipt unavailable/);
  for (let i = 0; i < 5; i++) {
    now++;
    heartbeat();
  }
  postReleaseCheckpoint(checkpoints, 'fortress native post-release {"kind":"heartbeat"}', { controller_ms: now });
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
  const unavailable = { async evaluate() { throw new Error('release evaluation unavailable'); } };
  await assert.rejects(captureAndReleaseInput(unavailable, 0), /release evaluation unavailable/);
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
  const expiry = {observed_us: 6000, sdk_queued: -1, sdk_peak: 0, sdk_before_poll: -1,
    service_started_us: 6000, service_gap_us: -1, service_gap_peak_us: 0, last_accepted: null};
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
        # Value: protects=engine turns and published history; fails_when=earlier progress replaces the baseline or final reads erase receipts; seam=browser entrypoint
        script = r"""
const assert = require('node:assert/strict');
const { AsyncLocalStorage } = require('node:async_hooks');
const { runMain, _load: load } = require('node:module');
const entrypoint = process.argv[1];
const control = process.argv[2];
const rejecting = control.startsWith('rejection');
const stuck = control === 'same frame' || control === 'rejection and timeout';
const historyControl = control.startsWith('history ');
const lateExpiry = control === 'history late trace';
const expiryLink = '00000000000000000000000000000002/00000000000000000000000000000001';
const realm = new AsyncLocalStorage();
const windows = [];
const roster = [1, 2].map(value => '00000000-0000-0000-0000-00000000000' + value);
const unavailable = () => new Promise(() => {});
let now = 0;
global.performance = { now: () => ++now };
Object.defineProperty(global, 'window', { get: () => realm.getStore() });
global.location = { href: 'https://127.0.0.1/test' };
global.PerformanceObserver = class {
  static supportedEntryTypes = ['resource'];
  constructor(callback) { window.resourceObserver = entries => callback({ getEntries: () => entries }); }
  observe() {}
  disconnect() {}
};
console.debug = text => window.publishTiming(text);
const timeout = global.setTimeout;
global.setTimeout = (callback, ms, ...args) => timeout(callback, [5000, 30000].includes(ms) ? 20 : ms, ...args);
let releaseRequest;
global.fetch = path => new Promise(resolve => {
  const owner = window;
  const requested = performance.now();
  const response = { socket: { destroyed: false }, once(event, callback) { assert.equal(event, 'finish'); this.finish = callback; },
    writeHead(status, headers) { this.status = status; this.headers = new Headers(headers); return this; },
    end() {
      this.writableEnded = true;
      this.finish();
      const at = performance.now();
      resolve({ url: path, status: this.status, headers: this.headers });
      setImmediate(() => realm.run(owner, () => owner.resourceObserver([{
        name: new URL(path, location.href).href, initiatorType: 'fetch', fetchStart: requested, responseStart: at, responseEnd: at, responseStatus: this.status,
      }])));
    } };
  if (!releaseRequest({ url: new URL(path).pathname, method: 'GET' }, response)) throw new Error('fixture release request was not handled');
});
global.requestAnimationFrame = callback => {
  if (window.index === 1 && stuck) return;
  window.fortressNative.frame++;
  callback();
};
function makePage() {
  const index = windows.length;
  const state = { state: 'lobby', room: 'test', command_code: 0, ready_enabled: true, start_enabled: true,
    frame: 18, confirmed: 0, turns: 20, stalls: 0, prediction: 12, restores: 2, history_limit: 128,
    uuid: roster[index], frozen_roster: roster, slot: index, session_id: '01'.repeat(16), room_id: 'test' };
  const events = {};
  let lateBaseline;
  let publishHistory;
  let released = 0;
  const hold = () => ({ at_ms: performance.now(), held: { mesh: 0, relay: 1 }, bytes: 1, queued: 1 - released, released });
  function mark(kind, fields = {}) {
    const { state: status, frame, confirmed, turns, restores } = state;
    const sample = { kind, page_ms: performance.now(), state: status, frame, confirmed, turns, restores, ...fields };
    events.console({ text: () => 'fortress native post-release ' + JSON.stringify(sample) });
  }
  function expire() {
    const uuid = roster[1 - index];
    const sender = uuid.replaceAll('-', ''), recipient = state.uuid.replaceAll('-', '');
    const envelope = Buffer.alloc(103);
    Buffer.from('4653523101' + state.session_id + sender + recipient, 'hex').copy(envelope);
    envelope.writeUInt32LE(46, 53);
    Buffer.from(state.session_id, 'hex').copy(envelope, 57);
    envelope.writeUInt32LE(0x000252f5, 73);
    envelope.writeUInt16LE(1, 77);
    envelope.writeUInt32LE(4, 81);
    mark('native_expiry', { endpoint: 2 - index, uuid,
      frontier: { room: state.session_id, sender, recipient, packets: [{ kind: 4, epoch: 1, seq: '1',
        envelope: envelope.toString('hex'), stages: { native: { ordinal: 1, at_ms: performance.now() } } }] },
      expiry: { observed_us: 3000000, sdk_queued: 0, sdk_peak: 51, sdk_before_poll: 2,
        service_started_us: 2999900, service_gap_us: 100, service_gap_peak_us: 500, last_accepted: null } });
  }
  const pageWindow = { index, fortressNative: state, fortressNativeReady: true, publishTiming: text => events.console({ text: () => text }),
    set fortressNativeCapture({ id, frames }) {
      if ((index === 1 && control === 'history missing') || (index === 0 && control === 'history rejected first')) return;
      const rows = {}, snapshots = {};
      for (let frame = 0; frame < frames; frame++) {
        rows[frame] = frame >= 12 && frame % 2 === 0 ? [0, 0] : [1, 2];
        snapshots[frame + 1] = '01';
      }
      if (index === 1 && control === 'history divergent') snapshots[frames] = 'ff';
      const publish = () => {
        mark('history_published', { frames });
        publishHistory({ text: () => 'fortress native history ' + JSON.stringify({ id, frames, rows, snapshots }) });
      };
      if (index === 1 && ['history staggered', 'history rejected first'].includes(control)) setImmediate(publish);
      else publish();
      if (control === 'history staggered' && index === 0) expire();
    },
    fortressNativePostRelease: { mark(kind, frames, progress) { mark(kind, { frames, ...progress }); }, arm() {}, setTarget() {} },
    fortressNativeWire: {
      arm() { state.stalls++; return hold(); },
      holdProgress: hold, recordHoldReadiness: hold, status: () => ({}),
      holdConditions: () => [true, true],
      relayWireTrace(selected) {
        if (lateExpiry && index === 1) expire();
        return { selected, streams: {} };
      },
      holdObservation: () => ({ ...hold(), control_round_trips: 1, buffered_bytes: 0, traffic: [] }),
      async release() {
        released = 1;
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
      if (historyControl && operation.toString().includes('wire: window.fortressNativeWire.status()')) {
        if (index === 0 && control !== 'history staggered' && !lateExpiry) expire();
        throw new Error('fixture post-history expiry');
      }
      if (operation.toString().includes('warmupStatus()')) {
        if (lateExpiry && index === 0) setImmediate(expire);
        if (control === 'history rejected first') throw new Error('fixture diagnostic RPC failed');
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
    async waitForEvent(event, options) {
      if (!historyControl) throw Error('fixture stops after the engine turn');
      assert.equal(event, 'console');
      if (index === 0 && control === 'history rejected first') throw new Error('fixture capture RPC failed');
      if (index === 1 && control === 'history missing') return unavailable();
      return new Promise(resolve => { publishHistory = message => {
        assert.equal(options.predicate(message), true);
        resolve();
      }; });
    },
  };
}
require('node:module')._load = function (name, ...args) {
  if (lateExpiry && name === './native_relay_control.cjs') {
    return { ...load.call(this, name, ...args), async bindRelayServer() {},
      createRelayServerReader: () => async (_select, _timeout, links) => {
        assert.deepEqual(links, [expiryLink], 'the delayed console expiry must focus the server trace');
        return {};
      },
      joinRelayReceipts: (_server, _pages, expiries) => ({ rows: [], joined: expiries.map(expiry => expiry.uuid) }) };
  }
  if (name === './online_host.cjs') {
    return { createHost: async (_root, _endpoint, _cert, _key, _port, handler) => {
      releaseRequest = handler;
      return { proxyPairs: [], server: { address: () => ({ port: 1 }), close: callback => callback() } };
    } };
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
if (lateExpiry) {
  process.env.FORTRESS_RELAY_TRACE_SCOPE = 'fixture-trace-scope';
  process.env.FORTRESS_RELAY_TRACE_OUTPUT = 'fixture-trace-output';
  process.argv.push('--trace-relay-wire');
}
runMain();
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        for control in ('baseline timeout', 'same frame', 'higher frame', 'rejection', 'rejection and timeout',
                        'history complete', 'history missing', 'history divergent', 'history staggered', 'history rejected first', 'history late trace'):
            with self.subTest(control=control):
                run = subprocess.run([*command, control], capture_output=True, encoding='utf-8', timeout=10)
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertEqual(run.stdout, '')
                report_line, _, failure = run.stderr.partition('\n')
                report = json.loads(report_line)
                if control in ('history complete', 'history divergent', 'history staggered', 'history late trace'):
                    expected_phase = 'post-capture status'
                elif control in ('higher frame', 'history missing', 'history rejected first'):
                    expected_phase = 'confirmed history capture'
                else:
                    expected_phase = 'post-confirmation engine turn'
                self.assertEqual(report['phase'], expected_phase)
                if control in ('baseline timeout', 'same frame', 'rejection and timeout'):
                    self.assertIn('absolute native post-confirmation engine turn deadline', failure)
                if control.startswith('rejection'):
                    self.assertIn('fixture baseline RPC failed', failure)
                self.assertEqual(report['target_frames'], 40)
                self.assertNotIn('compared_frames', report)
                self.assertEqual([state['status'] for state in report['states']], ['rejected', 'rejected'])
                if control.startswith('history '):
                    evidence = report['historyEvidence']
                    first, second = evidence['receipts']
                    captured = second if control == 'history rejected first' else first
                    self.assertEqual(captured['rows']['39'], [1, 2])
                    self.assertEqual(captured['snapshots']['40'], '01')
                    self.assertEqual(captured['slot'], int(control == 'history rejected first'))
                    self.assertEqual(captured['frames'], 40)
                    if control == 'history rejected first':
                        self.assertIn('fixture capture RPC failed', failure)
                        self.assertIsNone(first)
                        self.assertNotIn('compared_frames', evidence)
                    elif control == 'history missing':
                        self.assertIsNone(second)
                        self.assertNotIn('compared_frames', evidence)
                    else:
                        self.assertEqual(second['slot'], 1)
                        self.assertIn('fixture post-history expiry', failure)
                        self.assertEqual(report['departureCommands'], [])
                        reporter = report['postRelease'][0]
                        self.assertLess(reporter['history_published']['page_ms'], reporter['native_expiry']['page_ms'])
                        if control == 'history divergent':
                            self.assertNotIn('compared_frames', evidence)
                            self.assertIn('canonical state at frame 40', evidence['comparison_error'])
                        else:
                            self.assertEqual(evidence['compared_frames'], 40)
                        if control == 'history late trace':
                            link = '00000000000000000000000000000002/00000000000000000000000000000001'
                            self.assertEqual(report['expiryLinks'], [link])
                            self.assertEqual(report['relayWire'], [{'selected': [link], 'streams': {}}] * 2)
                            self.assertNotIn('relayJoinError', report)
                            self.assertEqual(report['relayJoined']['joined'], ['00000000-0000-0000-0000-000000000002'])
                            self.assertEqual(report['postRelease'][1]['native_expiry']['uuid'], '00000000-0000-0000-0000-000000000001')
                            self.assertEqual([peer.get('checkpoint_error') for peer in report['postRelease']], [None, None])
                            self.assertEqual([(f"{row['sender']}/{row['recipient']}", row['upstream_scope']) for row in report['relayExpiryRows']],
                                             [(link, 'focused'), ('/'.join(reversed(link.split('/'))), 'outside-focus')])
                            self.assertEqual([(row['anchor_write'], row['page_coverage'], row['following_writes']) for row in report['relayExpiryTraffic']],
                                             [(None, 'unavailable', []), (None, 'unavailable', [])])
                        if control == 'history staggered':
                            self.assertLess(reporter['native_expiry']['controller_order'],
                                            report['postRelease'][1]['history_published']['controller_order'])
                self.assertEqual(len(report['releaseTiming']), 2)
                for timing in report['releaseTiming']:
                    self.assertEqual(timing['continuation']['status'], 204)
                    self.assertIsNotNone(timing['finished_ms'])
                    self.assertLessEqual(timing['request_dispatched_ms'], timing['request_received_ms'])
                    self.assertIsNotNone(timing['write_to_response_end_ms'])
                    self.assertGreater(timing['resource']['controller_ms'], timing['continuation']['controller_ms'])
                if control != 'history rejected first':
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
  Boolean(closeEvidence({index, channel, attempt:1}, before, closed, closer, clocks, {attempt:1, channel, sentAt}).proof);
const frame = '    at fortressNativeSend_5 (:5:27)';
assert.deepEqual(reportedChannel('Error sending binary data\n' + frame), {channel:5, attempt:null});
assert.deepEqual(reportedChannel('    at fortressNativeSend_5_1234 (:5:27)'), {channel:5, attempt:1234});
for (const stack of [frame + '\n' + frame, frame + '\n at fortressNativeSend_5_bad (:5:27)', 'at unrelated (:5:27)',
  'at fortressNativeSend_5_9007199254740992 (:5:27)', 'at fortressNativeSend_5_0 (:5:27)', 'at fortressNativeSend_05_1 (:5:27)']) {
  assert.deepEqual(reportedChannel(stack), {channel:null, attempt:null});
}
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

    def test_native_webkit_records_the_exact_send_after_preparing_its_tag(self):
        # Value: protects=actual native send timing; fails_when=tag preparation is included or a stale attempt is reused; seam=browser wire observer
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require(process.argv[1]);
let now = 0;
let sent;
let plannedState = 'connecting';
let plannedBuffer = 0;
class Connection {
  close() {}
  addEventListener() {}
  createDataChannel() {
    return {
      id: 3, get readyState() { return plannedState; }, get bufferedAmount() { return plannedBuffer; }, addEventListener() {},
      send() {
        sent = { at: now * 1000, readyState: plannedState, bufferedAmount: plannedBuffer, stack: new Error().stack };
        plannedState = 'closed';
        plannedBuffer = 0;
      },
    };
  }
}
const window = { crossOriginIsolated: true };
runInNewContext(`(${instrumentNativeWire})(true, '')`, {
  window, WebSocket: class {}, RTCPeerConnection: Connection,
  performance: { now: () => now },
  Function: function(...args) { now += 5; plannedState = now === 15 ? 'open' : 'closing'; plannedBuffer = now; return Function(...args); },
});
const first = new Connection().createDataChannel('first', {});
const second = new Connection().createDataChannel('second', {});
const wire = window.fortressNativeWire;
wire.observeDeparture();
const send = channel => {
  channel.send(new ArrayBuffer(1));
  const [, index, tag] = sent.stack.match(/fortressNativeSend_(\d+)_(\d+)/).map(Number);
  return { index, tag, at: sent.at, readyState: sent.readyState, bufferedAmount: sent.bufferedAmount };
};
const a = send(first);
// Older witnesses encoded preparation time in the name itself.
const recorded = wire.departureSends ? wire.departureSends([a.tag])[a.tag]?.sentAt : a.tag;
assert.equal(recorded, a.at, 'timestamp must be taken at the native send');
assert.equal(a.readyState, 'open');
assert.equal(plannedState, 'closed');
const actual = wire.departureSends([a.tag])[a.tag];
assert.equal(actual?.readyState, a.readyState, 'channel readiness must be owned at the native send');
assert.equal(actual?.bufferedAmount, a.bufferedAmount, 'queue size must be owned at the native send');
const b = send(second);
assert.equal(b.tag, a.tag + 1);
assert.equal(b.index, a.index + 1);
assert.equal(wire.departureSends([b.tag])[b.tag]?.channel, b.index);
assert.equal(wire.departureSends([b.tag])[b.tag]?.readyState, 'closing');
assert.equal(wire.departureSends([b.tag])[b.tag]?.bufferedAmount, b.bufferedAmount);
for (let i = 0; i < 4096; ++i) first.send(new ArrayBuffer(1));
const latest = send(second);
const receipts = wire.departureSends([a.tag, b.tag, latest.tag, latest.tag + 1]);
assert.equal(receipts[a.tag] ?? null, null, 'older attempts must be evicted');
assert.equal(receipts[b.tag] ?? null, null, 'a reused slot must not return its old attempt');
assert.equal(receipts[latest.tag]?.sentAt, latest.at);
assert.equal(receipts[latest.tag + 1] ?? null, null, 'an unobserved attempt has no receipt');
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_joins_exact_engine_send_to_first_tagged_boundary(self):
        # Value: protects=exact engine-to-DOM send attribution; fails_when=wrong bytes/peer or another attempt joins; seam=browser wire and controller
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { closeEvidence, frozenMeshSendRoutes, instrumentNativeWire, matchCloseObservations } = require(process.argv[1]);
const window = { crossOriginIsolated: true };
let now = 10;
class Connection {
  constructor(local, remote) {
    this.localDescription = { sdp: `a=ice-ufrag:${local}` };
    this.remoteDescription = { sdp: `a=ice-ufrag:${remote}` };
  }
  close() {}
  addEventListener() {}
  createDataChannel() {
    return { id: 3, readyState: 'open', bufferedAmount: 12, send() {}, addEventListener() {} };
  }
}
runInNewContext(`(${instrumentNativeWire})(true, '', undefined, 'close ')`, {
  window, WebSocket: class {}, RTCPeerConnection: Connection, ArrayBuffer, Uint8Array, DataView,
  performance: { now: () => now },
});
const wire = window.fortressNativeWire;
const connection = new Connection('a', 'b');
const channel = connection.createDataChannel('gameplay', {});
const wrongChannel = new Connection('c', 'd').createDataChannel('gameplay', {});
const uuids = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333'];
const [sender, recipient, bystander] = uuids;
const session = Buffer.alloc(16, 42);
const bytes = Buffer.concat([session, Buffer.from([0xf5, 0x52, 2, 0, 0, 0, 0, 0, 5, 0, 0, 0, 6])]);
const other = Buffer.from(bytes);
other[other.length - 1]++;
wire.bind(session.toString('hex'), sender, uuids);
assert.equal(wire.meshSendTracing(), false);
assert.equal(wire.beginMeshSend(recipient, bytes.toString('hex')), 0);
const before = [[{ index: 0, local: 'a', remote: 'b' }, { index: 1, local: 'c', remote: 'd' }],
  [{ index: 19, local: 'b', remote: 'a' }], [{ index: 8, local: 'd', remote: 'c' }]];
const identities = { uuids, roster: uuids };
const [frozenRoutes] = frozenMeshSendRoutes(before, identities);
assert.deepEqual(frozenRoutes.map(({ index, player }) => [index, player]), [[0, recipient], [1, bystander]]);
const ambiguous = [[...before[0], { ...before[0][0], index: 23 }], ...before.slice(1)];
assert.deepEqual(frozenMeshSendRoutes(ambiguous, identities)[0].map(route => route.index), [1]);
wire.observeDeparture(frozenRoutes);
assert.equal(wire.meshSendTracing(), true);
assert.equal(wire.beginMeshSend(sender, bytes.toString('hex')), 0);
assert.equal(wire.beginMeshSend(recipient, 'X'.repeat(58)), 0);
const send = wire.beginMeshSend(recipient, bytes.toString('hex'));
now = 11;
channel.send(other);
wrongChannel.send(bytes);
now = 12;
connection.signalingState = 'closed';  // Keep the frozen SDP. The DOM wrapper still attempts the send.
channel.send(bytes);
channel.send(bytes);  // Only the first matching DOM call belongs to this one addressed send.
now = 13;
wire.endMeshSend(send + 1, 13);
wire.endMeshSend(send, 9);
channel.send(bytes);  // An identical later payload cannot inherit the previous engine attempt.
const wrongPeer = wire.beginMeshSend(bystander, bytes.toString('hex'));
channel.send(bytes);
wire.endMeshSend(wrongPeer, 0);
const nested = wire.beginMeshSend(recipient, bytes.toString('hex'));
assert.equal(wire.beginMeshSend('', bytes.toString('hex')), 0);
channel.send(bytes);
wire.endMeshSend(nested, 0);
const replaced = wire.beginMeshSend(recipient, bytes.toString('hex'));
connection.remoteDescription = { sdp: 'a=ice-ufrag:replacement' };
channel.send(bytes);
wire.endMeshSend(replaced, 0);
const sends = wire.departureSends([1, 2, 3, 4, 5, 6, 7, 8]);
const errors = Object.values(sends).map(({ attempt, channel }) => ({ index: 0, channel, attempt }));
const observations = [new Map(), new Map(), new Map()];
const report = { partialSnapshots: [{ sends }], clocks: [] };
const expected = { id: send, player: recipient, bytes: bytes.length, enteredAt: 10000, returnedAt: 13000, code: 9 };
const records = matchCloseObservations(errors, before, observations, report, identities);
assert.deepEqual(records.map(record => record.engineSend), [null, null, expected, null, null, null, null, null]);
const proof = receipt => closeEvidence(errors[2], before[0], before, null, undefined, receipt, identities);
assert.deepEqual(proof(sends[3]).engineSend, expected);
for (const change of [{ enteredAt: 12001 }, { returnedAt: 11999 }, { code: -1 }, { id: '1' }, { bytes: 1201 }, { player: bystander }]) {
  const original = sends[3].engineSend;
  sends[3].engineSend = { ...original, ...change };
  const [invalid] = matchCloseObservations([errors[2]], before, observations, report, identities);
  assert.equal(invalid.engineSend, null, 'malformed boundary must not be attributed');
  assert.equal(invalid.sentAt, 12000, 'tagged send evidence remains available without the engine receipt');
  assert.equal(proof(sends[3]).engineSend, undefined, 'direct close proof also checks the exact recipient and boundary');
  sends[3].engineSend = original;
}
const [withoutRoster] = matchCloseObservations([errors[2]], before, observations, report);
assert.equal(withoutRoster.engineSend, null);
assert.equal(closeEvidence(errors[2], before[0], before, null, undefined, sends[3]).engineSend, undefined);
const stale = { partialSnapshots: [{ sends: { 3: { ...sends[3], attempt: 4 } } }],
  proofs: [{ ...errors[2], sentAt: 12000 }] };
const [prior] = matchCloseObservations([errors[2]], before, observations, stale, identities);
assert.equal(prior.sentAt, 12000);
assert.equal(prior.engineSend, null, 'a prior timestamp cannot validate the engine boundary of the wrong attempt');
wire.stopObservingDeparture();
assert.equal(wire.meshSendTracing(), false);
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_close_observations_survive_delayed_snapshot(self):
        # Value: protects=independent exact close receipts; fails_when=stages collapse or a different route joins; seam=browser wire and controller
        script = r"""
const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire, recordCloseObservation, matchCloseObservations } = require(process.argv[1]);
let now = 10;
const observed = [new Map(), new Map()];
let emissions = 0;
const uuids = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'];
const identities = { uuids, roster: uuids };
class Connection {
  signalingState = 'stable';
  remoteDescription = { sdp: 'a=ice-ufrag:sender' };
  get localDescription() {
    if (this.signalingState === 'closed') throw new Error('Peer connection is closed');
    return { sdp: 'a=ice-ufrag:closer' };
  }
  addEventListener() {}
  createDataChannel() {
    return { id: 3, send() {}, addEventListener(kind, callback) { this[kind + 'Event'] = callback; }, close() { now += 2; } };
  }
  close() { now += 2; this.signalingState = 'closed'; }
}
const prefix = 'close ';
const window = {};
runInNewContext(`(${instrumentNativeWire})(false, '', undefined, 'close ')`, {
  window, WebSocket: class {}, RTCPeerConnection: Connection,
  performance: { now: () => now },
  console: { debug: text => {
    emissions++;
    recordCloseObservation(observed[0], text.slice(prefix.length), now + 500, identities, 0);
  } },
});
const connection = new Connection();
const channel = connection.createDataChannel('gameplay', {});
channel.close();
now = 30;
connection.close();
now = 40;
channel.closeEvent();
now = 45;
channel.closeEvent();
const wire = window.fortressNativeWire;
wire.bind('abcdef0123456789abcdef0123456789', uuids[0], uuids);
wire.recordMeshDeparture('sdk_player_left', uuids[1]);  // Before observation starts.
assert.equal(observed[0].size, 3);
wire.observeDeparture();
now = 46;
wire.recordMeshDeparture('sdk_player_left', uuids[1]);
now = 47;
wire.recordMeshDeparture('mesh_remove_peer', uuids[1], true);
wire.recordMeshDeparture('mesh_remove_peer', uuids[1], false);  // A duplicate does not replace exact first evidence.
wire.recordMeshDeparture('sdk_player_left', uuids[0]);
for (const value of [
  { kind: 'mesh_remove_peer', player: uuids[1], had_peer: 1 },
  { kind: 'sdk_player_left', player: uuids[1], had_peer: false },
  { kind: 'sdk_player_left', player: uuids[0] },
  { kind: 'sdk_player_left', player: '33333333-3333-3333-3333-333333333333' },
]) recordCloseObservation(observed[0], JSON.stringify({ ...value, page_us: 48000 }), 548, identities, 0);
assert.equal(observed[0].size, 5);
assert.equal(emissions, 5, 'a duplicate departure must not emit another receipt');
const before = [[{ index: 0, local: 'closer', remote: 'sender' }], [{ index: 17, local: 'sender', remote: 'closer' }]];
const error = { index: 1, channel: 17, attempt: 279, received_ms: 600 };
const report = {
  partialSnapshots: [null, { sends: { 279: { channel: 17, attempt: 279, sentAt: 47199, readyState: 'open', bufferedAmount: 49 } } }],
  clocks: [{ offsetMin: 9900, offsetMax: 10100 }, { offsetMin: -5100, offsetMax: -4900 }],
};
const [receipt] = matchCloseObservations([error], before, observed, report, identities);
assert.equal(receipt.attempt, 279);
assert.equal(receipt.sentAt, 47199);
assert.deepEqual(receipt.sendState, { readyState: 'open', bufferedAmount: 49 });
assert.equal(receipt.received_ms, 600);
assert.deepEqual(receipt.lifecycle, [
  { owner: 0, kind: 'sdk_player_left', player: uuids[1], page_us: 46000, received_ms: 546, minimumGapUs: -14001, maximumGapUs: -13601 },
  { owner: 0, kind: 'mesh_remove_peer', player: uuids[1], had_peer: true, page_us: 47000, received_ms: 547,
    minimumGapUs: -15001, maximumGapUs: -14601 },
]);
assert.deepEqual(receipt.observations.map(({ owner, kind, page_us, received_ms }) => [owner, kind, page_us, received_ms]), [
  [0, 'channel_close_called', 10000, 512],
  [0, 'channel_close_event', 40000, 540],
  [0, 'connection_close_called', 30000, 532],
]);
assert.deepEqual(receipt.observations.map(({ minimumGapUs, maximumGapUs }) => [minimumGapUs, maximumGapUs]),
  [[21999, 22399], [-8001, -7601], [1999, 2399]]);
const [wrong] = matchCloseObservations([error], [[{ ...before[0][0], index: 2 }], before[1]], observed);
assert.deepEqual(wrong.observations, []);
const [ambiguous] = matchCloseObservations([error], [...before, before[0]], [...observed, new Map()]);
assert.deepEqual(ambiguous.observations, []);
assert.deepEqual(matchCloseObservations([{ ...error, attempt: null }], before, observed), []);
const early = new Connection();
early.remoteDescription = null;
const pending = early.createDataChannel('pending', {});
now = 50;
pending.close();
early.remoteDescription = connection.remoteDescription;
pending.close();
assert.deepEqual(observed[0].get('1:channel_close_called'), {
  kind: 'channel_close_called', index: 1, local: 'closer', remote: null, page_us: 50000, received_ms: 552,
});
const newRoute = new Connection();
newRoute.createDataChannel('restarted', {});
assert.equal(window.fortressNativeWire.sctpStatus()[2].remote, 'sender');
newRoute.remoteDescription = { sdp: 'a=ice-ufrag:replacement' };
assert.equal(window.fortressNativeWire.sctpStatus()[2].remote, 'replacement');
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
const tagged = {index:1, channel:17, attempt:3};
const receipt = {channel:17, attempt:3, sentAt:47199, readyState:'open', bufferedAmount:256};
const fail = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks, receipt);
assert.deepEqual(JSON.parse(JSON.stringify(fail)), {
  ...tagged, sentAt:47199, sendState:{readyState:'open', bufferedAmount:256}, closer:null, before, sender,
  counterparts:[{...closer, owner:0}], minimumGapUs:1999, maximumGapUs:2399, proof:null,
});
const timed = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks, {...receipt, sentAt:47200});
assert.equal(timed.minimumGapUs, 2000);
assert.equal(timed.maximumGapUs, 2400);
assert.equal(timed.proof, 'clock-order');
for (const invalid of [null, {...receipt, sentAt:'47200'}, {...receipt, sentAt:-1},
  {...receipt, attempt:4, sentAt:47200}, {...receipt, channel:18, sentAt:47200}]) {
  const rejected = closeEvidence({...tagged, sentAt:999999}, [before], [[closer], [sender]], null, clocks, invalid);
  assert.equal(rejected.sentAt, null);
  assert.equal(rejected.sendState, null);
  assert.equal(rejected.minimumGapUs, null);
  assert.equal(rejected.proof, null);
}
for (const malformed of [undefined, 'connected', 'OPEN']) {
  const sample = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks, {...receipt, sentAt:47200, readyState:malformed});
  assert.equal(sample.sendState, null);
  assert.equal(sample.proof, 'clock-order', 'optional sender state cannot alter close proof');
}
for (const malformed of [-1, Infinity, 0.5, '256']) {
  const sample = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks, {...receipt, bufferedAmount:malformed});
  assert.equal(sample.sendState, null);
}
const early = closeEvidence(tagged, [before], [[closer], [sender]], null, clocks, {...receipt, sentAt:46799});
assert.equal(early.maximumGapUs, 1999);
assert.equal(early.proof, null);
const aborted = closeEvidence(tagged, [before], [[closer], [{...sender, closeAborts:2}]], null, clocks, receipt);
assert.equal(aborted.minimumGapUs, 1999);
assert.equal(aborted.proof, 'sctp-abort');
const missing = closeEvidence(tagged, [before], [[], [sender]], null, clocks);
assert.deepEqual(missing.counterparts, []);
assert.equal(missing.minimumGapUs, null);
assert.equal(missing.maximumGapUs, null);
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
const receipt = {channel:17, attempt:3, sentAt:47200, readyState:'open', bufferedAmount:128};
const sample = (links, offset, sends = {}) => ({
  evaluate: async (_read, { attempts }) => {
    const start = now;
    const snapshot = links();
    await Promise.resolve();
    now = Math.max(now, start + 1);
    assert.deepEqual(attempts, offset === -5000 ? [3] : []);
    return {links:snapshot, sampledAt:start * 1000 - offset + 500, sends};
  },
});
const initial = [{wire:{sctp:[reciprocal]}}, {wire:{sctp:[before]}}];
const warning = [{index:1, channel:17, attempt:3}];
const sender = sample(() => [before], -5000, {3:receipt});
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
  const growing = [...warning];
  const secondReceipt = { ...receipt, attempt: 4 };
  const requested = [];
  const extraWarning = {
    evaluate: async (_read, { attempts }) => {
      requested.push(attempts);
      if (requested.length === 1) growing.push({ index: 1, channel: 17, attempt: 4 });
      return { links: [before], sampledAt: now * 1000 + 5000,
        sends: Object.fromEntries(attempts.map(attempt => [attempt, attempt === 3 ? receipt : secondReceipt])) };
    },
  };
  await waitForCloseProofs([sample(() => [reciprocal], 10000), extraWarning], initial, growing, report, {
    clocks, clock, delay: async ms => { now = requested.length === 2 ? 5025 : now + ms; },
  });
  assert.deepEqual(requested, [[3], [3, 4]]);
  assert.deepEqual(report.proofs.map(proof => [proof.attempt, proof.proof]), [[3, 'clock-order'], [4, 'clock-order']]);

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
  await assert.rejects(waitForCloseProofs([sample(() => [reciprocal], 10000, {3:receipt}), sample(() => [before], -5000)],
    initial, warning, report, { clocks, clock, delay: expire }), /WebKit close evidence deadline/);
  assert.equal(report.proofs[0].sentAt, null, 'a receipt from another page cannot prove the send');

  now = 25;
  const crashReport = {};
  const crashed = { evaluate: async () => { throw Error('Page crashed'); } };
  await assert.rejects(waitForCloseProofs([late, crashed], initial, warning, crashReport, { clocks, clock, delay: pause }),
    error => error instanceof AggregateError && error.errors[0].message.includes('peer 1') && error.errors[0].cause.message === 'Page crashed');
  assert.deepEqual(crashReport.snapshotErrors, [{index:1, reason:'Error: Page crashed'}]);
  assert.deepEqual(crashReport.partialSnapshots, [{received_ms:26, links:[reciprocal], sends:{}}, null]);
  assert.deepEqual(crashReport.clockSamples, [{before:[], after:[{offsetMin:9459, offsetMax:10541}]}, {before:[], after:[]}]);
  assert.deepEqual(crashReport.proofs, [{...warning[0], sentAt:null, sendState:null, closer:null, before, sender:null,
    counterparts:[{...reciprocal, owner:0}], minimumGapUs:null, maximumGapUs:null, proof:null}]);

  now = 25;
  let senderReads = 0;
  const interrupted = { evaluate: (...args) => ++senderReads === 1 ? sender.evaluate(...args) : crashed.evaluate() };
  const interruptedReport = {};
  await assert.rejects(waitForCloseProofs([ambiguous, interrupted], initial, warning, interruptedReport, { clocks, clock, delay: pause }),
    /WebKit close snapshots failed/);
  assert.deepEqual(interruptedReport.partialSnapshots, [
    {received_ms:52, links:[{...reciprocal, closedAt:30001}], sends:{}}, {received_ms:26, links:[before], sends:{3:receipt}},
  ]);
  assert.equal(interruptedReport.proofs[0].proof, null);
  assert.deepEqual(interruptedReport.proofs[0].sendState, { readyState: 'open', bufferedAmount: 128 });

  const lateReply = sample(() => { now = 5025; return [before]; }, -5000);
  now = 25;
  const lateReport = {};
  await assert.rejects(waitForCloseProofs([late, lateReply], initial, warning, lateReport, { clocks, clock, delay: pause }),
    /WebKit close evidence deadline/);
  assert.deepEqual(lateReport.partialSnapshots, [null, null]);
  assert.deepEqual(lateReport.clockSamples.map(page => page.after), [[], []]);
  assert.deepEqual(lateReport.proofs, [{...warning[0], sentAt:null, sendState:null, closer:null, before, sender:null,
    counterparts:[], minimumGapUs:null, maximumGapUs:null, proof:null}]);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        command = ['node', '-e', script, str(ROOT / 'scripts/reference/browser/native_online.cjs')]
        subprocess.run(command, check=True, timeout=10)

    def test_native_webkit_partial_snapshots_refine_the_exact_close_gap(self):
        # Value: protects=partial close receipt; fails_when=a crashed bystander erases the sender, counterpart or clock bounds; seam=room verifier
        script = r"""
const assert = require('node:assert/strict');
const { waitForCloseProofs } = require(process.argv[1]);
const before = {index:17, local:'sender', remote:'leaver', closeAborts:0, closed:false};
const counterpart = {index:18, local:'leaver', remote:'sender', closeAborts:0, closed:true, connectionClosed:true, closedAt:30000};
const initial = [counterpart, before, null].map(link => ({ wire:{ sctp:link ? [link] : [] } }));
const warning = [{index:1, channel:17, attempt:3}];
const clocks = [{offsetMin:9500, offsetMax:10500}, {offsetMin:-5500, offsetMax:-4500}, {offsetMin:0, offsetMax:1000}];
const crashed = {evaluate: async () => { throw Error('Page crashed'); }};

(async () => {
  for (const [channel, sentAt, counterpartRoute, expectedGap] of [
    [17, 47081, counterpart, 1999],
    [17, 47082, counterpart, 2000],
    [19, 47082, counterpart, null],
    [17, 47082, {...counterpart, remote:'different'}, null],
  ]) {
    const report = {};
    const leaver = {evaluate: async () => ({links:[counterpartRoute], sampledAt:50000, sends:{}})};
    const sender = {evaluate: async () => ({links:[before], sampledAt:65000, sends:{3:{channel, attempt:3, sentAt}}})};
    await assert.rejects(waitForCloseProofs([leaver, sender, crashed], initial, warning, report, {clocks, clock:() => 60}),
      error => error instanceof AggregateError && error.errors[0].message.includes('peer 2') && error.errors[0].cause.message === 'Page crashed');
    assert.deepEqual(report.clocks, [{offsetMin:9959, offsetMax:10041}, {offsetMin:-5041, offsetMax:-4959}, clocks[2]]);
    assert.deepEqual(report.clockSamples.map(page => page.after.length), [1, 1, 0]);
    assert.deepEqual(report.partialSnapshots.map(snapshot => snapshot?.links ?? null), [[counterpartRoute], [before], null]);
    assert.equal(report.proofs.length, 1);
    const [receipt] = report.proofs;
    assert.equal(receipt.sentAt, channel === 17 ? sentAt : null);
    assert.deepEqual(receipt.sender, before);
    assert.deepEqual(receipt.counterparts, counterpartRoute.remote === 'sender' ? [{...counterpart, owner:0}] : []);
    assert.equal(receipt.minimumGapUs, expectedGap);
    assert.equal(receipt.maximumGapUs, expectedGap === null ? null : expectedGap + 164);
    assert.equal(receipt.proof, null);
  }

  let now = 60;
  let round = 0;
  const report = {};
  const send = {channel:17, attempt:3, sentAt:47081};
  const provedSend = {channel:17, attempt:4, sentAt:47082};
  const leaver = {evaluate: async () => {
    if (++round === 3) throw Error('Page crashed');
    return {links:[counterpart], sampledAt:now * 1000 - 10000, sends:{}};
  }};
  const sendsByRound = [{3:send, 4:provedSend}, {3:send}, {}];
  const sender = {evaluate: async () => ({
    links:[before], sampledAt:now * 1000 + (round === 2 ? 4999 : 5000), sends:sendsByRound[round - 1],
  })};
  await assert.rejects(waitForCloseProofs([leaver, sender], initial.slice(0, 2), [...warning, {...warning[0], attempt:4}], report, {
    clocks:clocks.slice(0, 2), clock:() => now, delay:async ms => { now += ms; },
  }), /WebKit close snapshots failed/);
  assert.deepEqual(report.partialSnapshots.map(snapshot => [snapshot.received_ms, snapshot.sends]), [[85, {}], [110, {}]]);
  assert.equal(report.proofs[0].sentAt, send.sentAt);
  assert.equal(report.proofs[0].minimumGapUs, 2000);
  assert.deepEqual(report.proofs.map(receipt => receipt.proof), [null, null]);
  assert.deepEqual(report.lastCompleteProofs.map(receipt => [receipt.attempt, receipt.minimumGapUs, receipt.proof]), [
    [4, 2000, 'clock-order'], [3, 2000, 'clock-order'],
  ]);
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

    def test_native_webkit_departure_calibration_retains_failures_and_stops_late_reads(self):
        # Value: protects=partial clock calibration; fails_when=hung renderer prevents cleanup or a late reply writes evidence; seam=controller calibration
        script = r"""
const assert = require('node:assert/strict');
const { calibrateDepartureClocks } = require(process.argv[1]);
(async () => {
  const report = {};
  const pending = Promise.withResolvers();
  let reads = 0, now = 0;
  const stalled = { evaluate: async () => ++reads === 1 ? 0 : pending.promise };
  const crashed = { evaluate: async () => { throw new Error('Page crashed'); } };
  const working = { evaluate: async () => 0 };
  await assert.rejects(calibrateDepartureClocks([working, stalled, crashed], report, () => now, 40),
    error => error instanceof AggregateError && error.errors.length === 2
      && error.errors[0].cause.message === 'absolute native peer 1 departure clock deadline'
      && error.errors[1].cause.message === 'Page crashed');
  assert.deepEqual(report.clockSamples.map(page => page.before.length), [3, 1, 0]);
  assert.deepEqual(report.calibrationErrors, [
    {index:1, reason:'Error: absolute native peer 1 departure clock deadline'}, {index:2, reason:'Error: Page crashed'},
  ]);
  assert.ok(report.clocks[0]);
  assert.deepEqual(report.clocks.slice(1), [null, null]);
  pending.resolve(40000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 2);
  assert.equal(report.clockSamples[1].before.length, 1);

  now = 10;
  const late = { evaluate: async () => { now = 50; return 1000; } };
  const expired = {};
  await assert.rejects(calibrateDepartureClocks([late], expired, () => now, 40), /WebKit departure clock calibration failed/);
  assert.deepEqual(expired.clockSamples, [{before:[], after:[]}]);
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
    evaluate: async (_read, { timed }) => {
      sampled[index].push(timed);
      const offsets = [10000, contradictory && sampled[index].length === 1 ? 0 : -5000];
      return {links:[link], sampledAt:now * 1000 - offsets[index], sends:index ? {3:{channel:17, attempt:3, sentAt}} : {}};
    },
  }));
  const proof = waitForCloseProofs(pages, initial, [{index:1, channel:17, attempt:3}], report, {
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
  assert.deepEqual(short.report.partialSnapshots, [
    {received_ms:125, links:[reciprocal], sends:{}}, {received_ms:125, links:[before], sends:{3:{channel:17, attempt:3, sentAt:47081}}},
  ]);
  assert.deepEqual(short.report.clockSamples, [
    {before:[], after:Array(4).fill({offsetMin:9959, offsetMax:10041})},
    {before:[], after:Array(4).fill({offsetMin:-5041, offsetMax:-4959})},
  ]);

  const conflict = await collect(52000, before, true);
  await assert.rejects(conflict.proof, /WebKit close evidence deadline .*peer 1 channel 17/);
  assert.equal(conflict.report.clocks[1], null);
  assert.deepEqual(conflict.report.clockSamples[1].after[0], {offsetMin:-41, offsetMax:41});
  assert.equal(conflict.report.proofs[0].minimumGapUs, null);
  assert.equal(conflict.report.proofs[0].maximumGapUs, null);

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
