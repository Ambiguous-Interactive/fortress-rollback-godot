const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { test } = require('node:test');
const { runInNewContext } = require('node:vm');
const { instrumentNativeWire } = require('./native_online.cjs');
const { createRelayWireTrace } = require('./native_relay_trace.cjs');
const { createRelayHold, RELAY_HOLD_PREFIX } = require('./native_relay_hold.cjs');
const { readRelayWireReceipt } = require('./native_relay_control.cjs');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const [room, first, second, other] = ['11', '22', '33', '44'].map(value => value.repeat(16));
const token = '12'.repeat(16);
const bytes = value => Buffer.from(value, 'hex');
const sha256 = packet => createHash('sha256').update(packet).digest('hex');
const name = text => Buffer.concat([Buffer.from([0xa0 + text.length]), Buffer.from(text)]);

function envelope(sender, recipient, kind, value = token) {
  const payload = Buffer.concat([bytes(room), bytes('f552020001000000'), Buffer.from([kind, 0, 0, 0]),
    Buffer.alloc(kind === 4 ? 2 : kind === 2 ? 8 : 0), bytes(value)]);
  return Buffer.concat([bytes('4653523101' + room + sender + recipient), Buffer.from([payload.length, 0, 0, 0]), payload]);
}

function delivered(packet, sender, epoch, seq) {
  return Buffer.concat([bytes('85'), name('from_player'), bytes('c410' + sender), name('encoding'), name('message_pack'),
    name('payload'), Buffer.from([0xc4, packet.length]), packet, name('seq'), Buffer.from([seq]), name('epoch'), Buffer.from([epoch])]);
}

function serverEvent(packet, epoch, seq, ordinal, socket_ordinal) {
  const sender = packet.subarray(21, 37).toString('hex');
  const recipient = packet.subarray(37, 53).toString('hex');
  return { sender, recipient, kind: packet[81], epoch, seq: String(seq), ordinal, socket_ordinal, at_ns: 4000 + ordinal,
    envelope_bytes: packet.length, envelope_sha256: sha256(packet), payload_sha256: sha256(packet.subarray(57)) };
}

test('hold console batches survive unavailable final reads and join both stamped directions', async t => {
  const previous = { debug: console.debug, performance: globalThis.performance, setInterval, clearInterval };
  t.after(() => {
    console.debug = previous.debug;
    globalThis.performance = previous.performance;
    globalThis.setInterval = previous.setInterval;
    globalThis.clearInterval = previous.clearInterval;
  });
  let now = 10, controllerNow = 800, index = 1;
  const timers = new Map();
  globalThis.performance = { now: () => now };
  globalThis.setInterval = callback => { timers.set(callback, callback); return callback; };
  globalThis.clearInterval = callback => timers.delete(callback);

  const local = createRelayWireTrace(RELAY_HOLD_PREFIX);
  const remote = createRelayWireTrace(RELAY_HOLD_PREFIX);
  const offPair = createRelayWireTrace(RELAY_HOLD_PREFIX);
  const uuids = [other, first, second];
  const receipt = createRelayHold(room, uuids);
  const messages = [];
  console.debug = text => {
    messages.push({ index, text });
    receipt.record(index, text, controllerNow++);
  };
  local.bind(room, first, uuids);
  remote.bind(room, second, uuids);
  offPair.bind(room, other, uuids);
  const report = envelope(first, second, 4);
  const reply = envelope(second, first, 5);

  local.record('send', report, 1);
  remote.recordEngine('native', first, report.subarray(57).toString('hex'), 6, '18', 0);
  local.beginHold(() => 1, now);
  index = 2;
  remote.beginHold(() => 1, now);
  index = 0;
  offPair.beginHold(() => 1, now);
  assert.equal(timers.size, 2);
  now = 11;
  local.record('send', report, 2);
  remote.record('raw', delivered(report, first, 7, 20));
  remote.recordEngine('native', first, report.subarray(57).toString('hex'), 7, '20', 0);
  remote.record('send', reply, 3);
  local.record('raw', delivered(reply, second, 8, 30)).hold_gate_match = true;
  local.record('raw', delivered(envelope(other, first, 5), other, 8, 30));
  local.record('raw', delivered(envelope(second, first, 5, '00'.repeat(16)), second, 8, 31));
  index = 1;
  now = 1010;
  [...timers.values()][0]();
  index = 2;
  [...timers.values()][1]();
  const afterFirstBatch = receipt.snapshot();
  assert.equal(afterFirstBatch.pages[0].streams.send.events.length, 1);
  assert.equal(afterFirstBatch.pages[1].streams.raw.events.length, 1);

  let finalReadStarted = false;
  const page = { evaluate() {
    finalReadStarted = true;
    return new Promise(() => {});
  } };
  const finalRead = assert.rejects(boundedRoom(() => readRelayWireReceipt(page), 5, 'final page receipt'), /final page receipt deadline/);
  await Promise.resolve();
  assert.equal(finalReadStarted, true);

  now = 1020;
  local.record('send', report, 4);
  remote.record('raw', delivered(report, first, 7, 21));
  remote.recordEngine('native', first, report.subarray(57).toString('hex'), 7, '21', 0);
  remote.record('send', reply, 5);
  local.record('raw', delivered(reply, second, 8, 32));
  index = 1;
  local.endHold('release', now);
  index = 2;
  remote.endHold('terminal', now);
  assert.equal(timers.size, 0);
  const [send] = afterFirstBatch.pages[0].streams.send.events;
  assert.equal(send.socket_ordinal, 2);
  assert.equal(afterFirstBatch.pages[0].streams.send.events.length, 1, 'later batching must not mutate an earlier snapshot');

  const ingress = [
    serverEvent(report, 7, 20, 1, 2), serverEvent(report, 7, 21, 4, 4), serverEvent(reply, 8, 30, 2, 3), serverEvent(reply, 8, 32, 5, 5),
    serverEvent(envelope(first, other, 4), 6, 20, 3, 2),
  ];
  const writes = ingress.filter(event => event.seq !== '21').map(event => ({ ...event, actual_recipient: event.recipient }));
  writes.push({ ...ingress[1], actual_recipient: other });
  const server = { room, roster: [first, second, other], clock: 'server.monotonic',
    streams: { ingress: { quality: { events: ingress } }, write: { quality: { events: writes } } } };
  await finalRead;

  const retained = receipt.snapshot(server);
  assert.deepEqual(retained.links, [first + '/' + second, second + '/' + first]);
  assert.deepEqual(retained.pages.map(page => page.end_reason), ['release', 'terminal']);
  assert.deepEqual(retained.pages.map(page => page.started_ms), [10, 10]);
  const joins = Object.fromEntries(retained.packets.filter(packet => packet.seq).map(packet => [packet.seq, packet]));
  assert.deepEqual(joins['20'].stages, { send: 2, ingress: [1], write: [1], raw: [1] });
  assert.deepEqual(joins['30'].stages, { send: 1, ingress: [2], write: [2], raw: [1] });
  assert.deepEqual(joins['21'].stages.write, [], 'an unaddressed write cannot fill a stage');
  assert.deepEqual(joins['31'].stages.ingress, []);
  assert.deepEqual(joins['31'].stages.write, []);
  assert.deepEqual(joins['31'].report_candidates, []);
  const preHold = { epoch: 6, seq: '18' };
  assert.deepEqual(joins['30'].report_candidates, [preHold, { epoch: 7, seq: '20' }]);
  assert.deepEqual(joins['30'].joined_report_candidates, [{ epoch: 7, seq: '20' }]);
  assert.deepEqual(joins['32'].report_candidates, [preHold, { epoch: 7, seq: '20' }, { epoch: 7, seq: '21' }]);
  assert.deepEqual(joins['32'].joined_report_candidates, [{ epoch: 7, seq: '20' }, { epoch: 7, seq: '21' }]);
  assert.equal(retained.pages[0].streams.raw.events[0].hold_gate_match, true);
  assert.ok(messages.every(({ index }) => index !== 0));
  const staleStamp = serverEvent(report, 6, 19, 6, 2);
  ingress.push(staleStamp);
  const withReusedOrdinal = receipt.snapshot(server).packets;
  assert.equal(withReusedOrdinal.find(packet => packet.seq === '20').stages.send, null);
  assert.ok(withReusedOrdinal.some(packet => packet.seq === null && packet.stages.send === 2));
  assert.equal(retained.server_clock, 'server.monotonic');
  assert.equal(retained.page_clock, 'page.performance.now');
  assert.equal(retained.controller_clock, 'controller.performance.now');
  assert.ok(retained.server.ingress.every(event => event.recipient !== other));

  const stale = messages.find(({ index, text }) => index === 1 && text.includes('"seq":"30"'));
  receipt.record(2, stale.text, controllerNow++);
  assert.match(receipt.snapshot().errors[2], /invalid relay hold checkpoint/);
  assert.equal(receipt.snapshot(server).packets.length, withReusedOrdinal.length);

  const malformed = createRelayHold(room, uuids);
  const [start, batch, end] = messages.filter(({ index }) => index === 1).map(({ text }) => text);
  malformed.record(1, start, 1);
  malformed.record(1, batch, 2);
  const duplicate = JSON.parse(end.slice(RELAY_HOLD_PREFIX.length));
  duplicate.streams.send.events[0].socket_ordinal = 2;
  malformed.record(1, RELAY_HOLD_PREFIX + JSON.stringify(duplicate), 3);
  assert.match(malformed.snapshot().errors[1], /invalid relay hold checkpoint packet/);
  assert.equal(malformed.snapshot(server).packets.length, 3, 'a duplicate socket ordinal cannot replace a retained send');
});


test('relay hold keeps the first observations at capacity without changing the reply gate', async () => {
  const result = createRelayHold(room, [first, second, other], 2);
  const trace = createRelayWireTrace;
  let now = 10, scheduler;
  const emitted = [];
  class Socket {
    static OPEN = 1;
    readyState = 1;
    bufferedAmount = 0;
    addEventListener(_kind, receive) { this.receive = receive; }
    send(packet) { emitted.push(packet); }
  }
  const realm = {
    window: {}, WebSocket: Socket, RTCPeerConnection: class {}, Uint8Array, ArrayBuffer, DataView, performance: { now: () => now },
    console: { debug: text => result.record(0, text, now * 4) },
    setInterval: callback => { scheduler = callback; return 1; },
    clearInterval: () => { scheduler = null; },
  };
  runInNewContext(`(${instrumentNativeWire})(false, '', (${trace})(${JSON.stringify(RELAY_HOLD_PREFIX)}, 2))`, realm);
  const { fortressNativeWire: wire, WebSocket } = realm.window;
  const socket = new WebSocket();
  wire.bind(room, first, [other, first, second]);
  const send = (kind, value) => socket.send(envelope(first, second, kind, value));
  const reply = (sender, seq, value) => socket.receive({ data: delivered(envelope(sender, first, 5, value), sender, 8, seq) });

  send(4);
  wire.arm();
  reply(second, 1);
  reply(other, 2);
  assert.equal(wire.status().control_round_trips.relay, 0, 'a pre-hold report and an unrelated endpoint cannot satisfy readiness');
  send(4);
  send(2);
  assert.equal(wire.recordHoldReadiness('relay'), null);
  now = 11;
  reply(second, 3);
  assert.ok(wire.recordHoldReadiness('relay'));
  reply(second, 4);
  assert.equal(wire.status().control_round_trips.relay, 1, 'a duplicate reply cannot satisfy readiness again');
  now = 1010;
  scheduler();
  for (let index = 5; index <= 7; index++) send(4, index.toString(16).padStart(2, '0').repeat(16));
  await wire.release();
  assert.equal(scheduler, null);
  const { send: sent, raw } = result.snapshot().pages[0].streams;
  assert.deepEqual(raw.events.map(event => [event.seq, event.hold_gate_match]), [['1', undefined], ['3', true]]);
  assert.equal(raw.count, 3);
  assert.equal(raw.omitted, 1);
  assert.deepEqual(sent.events.map(event => event.socket_ordinal), [2, 3]);
  assert.equal(sent.count, 4);
  assert.equal(sent.omitted, 2);
  assert.equal(Buffer.from(emitted.at(-1)).readUInt32LE(81), 2, 'held input sends only during release');
});
