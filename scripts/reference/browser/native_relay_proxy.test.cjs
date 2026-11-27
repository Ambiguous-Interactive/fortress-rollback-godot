const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createFrameReader } = require('./native_relay_proxy.cjs');

function frame(opcode, payload) {
  const head = Buffer.alloc(payload.length < 126 ? 2 : 4);
  head[0] = opcode;
  if (head.length === 2) head[1] = payload.length;
  else {
    head[1] = 126;
    head.writeUInt16BE(payload.length, 2);
  }
  return Buffer.concat([head, payload]);
}

test('trace reads fragmented binary messages without affecting forward bytes', () => {
  const first = Buffer.alloc(200, 14);
  const second = Buffer.from([1, 3, 5]);
  const input = Buffer.concat([Buffer.from('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n'),
    frame(2, first.subarray(0, 150)), frame(0x89, Buffer.from('ping')),
    frame(0x80, first.subarray(150)), frame(0x82, second)]);
  for (const stride of [1, 7, 127, input.length]) {
    const reader = createFrameReader();
    const received = [];
    for (let offset = 0; offset < input.length; offset += stride)
      received.push(...reader.push(input.subarray(offset, offset + stride)));
    assert.deepEqual(received, [first, second]);
    assert.deepEqual(reader.status(), { skipped: 0, error: null });
  }
});

test('oversized binary message is counted and capture resumes at the next message', () => {
  const reader = createFrameReader();
  const header = Buffer.from('HTTP/1.1 101 Switching Protocols\r\n\r\n');
  const packet = Buffer.from([1, 2]);
  const messages = reader.push(Buffer.concat([header, frame(2, Buffer.alloc(1200)), frame(0x80, Buffer.alloc(1200)), frame(0x82, packet)]));
  assert.deepEqual(messages, [packet]);
  assert.deepEqual(reader.status(), { skipped: 1, error: null });
});

const { PassThrough, Writable } = require('node:stream');
const { once } = require('node:events');
const { createHash, webcrypto } = require('node:crypto');
const { createRelayProxyTrace, joinRelayReceive, traceProxyWrites } = require('./native_relay_proxy.cjs');
const { createRelayWireTrace, decodeRelayDelivery } = require('./native_relay_trace.cjs');
const { refreshRelayReceive, relayExpiryTraffic } = require('./native_relay_proxy.cjs');

test('expiry follow-up orders server writes separately from recipient observations', () => {
  const packet = (seq, write, sender = 'source', epoch = 1) => ({
    sender, recipient: 'reporter', epoch, seq, kind: 4, family: 'quality', lane: 'addressed',
    envelope_sha256: 'digest-' + seq, envelope_bytes: 103, write: [write], raw: [], sdk: [], native: [],
  });
  const accepted = packet('900', 20);
  const earlier = packet('899', 19);
  const later = { ...packet('1', 21, 'source', 2), raw: [31, 32], sdk: [43], native: [50] };
  const other = packet('901', 22, 'other');
  const unwritten = { ...packet('2', 23, 'source', 2), write: [] };
  const expiry = { page_ms: 100, controller_ms: 18, frontier: { room: 'room', sender: 'source', recipient: 'reporter', packets: [accepted] } };
  const page = { room: 'room', local: 'reporter', clock: 'page.performance.now', streams: {
    raw: { quality: { events: [{ ordinal: 31, at_ms: 99 }, { ordinal: 32, at_ms: 101 }] } },
    sdk: { quality: { events: [{ ordinal: 43, at_ms: 100 }] } },
    native: { quality: { events: [{ ordinal: 50, at_ms: 102, code: 1 }] } },
  } };
  const receive = { room: 'room', rows: [{ ...later, message: [{ ordinal: 17, at_ms: 98 }] }] };
  const joined = { rows: [earlier, other, later, unwritten, accepted] };
  const [result] = relayExpiryTraffic([expiry], joined, [page], receive);
  assert.equal(result.anchor_write, 20);
  assert.equal(result.following_writes.length, 1);
  const [record] = result.following_writes;
  assert.equal(record.epoch, 2);
  assert.equal(record.seq, '1');
  assert.deepEqual(record.before_expiry, { message: [17], raw: [31], sdk: [], native: [] });
  assert.deepEqual(record.at_or_after_expiry, { message: [], raw: [32], sdk: [43], native: [50] });
  const acrossAnchor = { ...later, write: [19, 21] };
  const [ambiguous] = relayExpiryTraffic([expiry], { rows: [accepted, acrossAnchor] }, [page], receive);
  assert.deepEqual(ambiguous.following_writes[0].write, [21]);
  assert.deepEqual(ambiguous.following_writes[0].write_candidates, [19, 21]);
  assert.equal(ambiguous.following_writes[0].observation_write_ambiguous, true);
  assert.deepEqual(record.write_candidates, [21]);
  assert.equal(record.observation_write_ambiguous, false);
  const [missingPage] = relayExpiryTraffic([expiry], joined, [{ ...page, room: 'old-room' }], receive);
  assert.equal(missingPage.page_coverage, 'unavailable');
  assert.deepEqual(missingPage.following_writes[0].before_expiry, { message: [], raw: [], sdk: [], native: [] });
  const [missingAnchor] = relayExpiryTraffic([expiry], { rows: [later] }, [page], receive);
  assert.equal(missingAnchor.anchor_write, null);
  assert.deepEqual(missingAnchor.following_writes, []);
});

test('expiry follow-up preserves ambiguous writes and tolerates incomplete page evidence', () => {
  const accepted = { sender: 'sender', recipient: 'recipient', family: 'input', kind: 2, epoch: 3, seq: '42',
    envelope_sha256: 'one', envelope_bytes: 116, lane: 'addressed', write: [20, 30], raw: [], sdk: [], native: [] };
  const later = { ...accepted, seq: '43', envelope_sha256: 'two', write: [21], raw: [7] };
  const expiry = { page_ms: 20, frontier: { room: 'room', sender: accepted.sender, recipient: accepted.recipient, packets: [accepted] } };
  const page = { room: 'room', local: accepted.recipient, clock: 'page.performance.now', streams: {
    raw: { input: { events: [{ ordinal: 7, at_ms: 15 }] } },
  } };
  const joined = { rows: [accepted, later] };
  const [result] = relayExpiryTraffic([expiry], joined, [page]);
  assert.deepEqual(result.anchor_candidates, [20, 30]);
  assert.equal(result.anchor_write, null);
  assert.deepEqual(result.following_writes, []);
  const unique = { rows: [{ ...accepted, write: [20] }, later] };
  const [partial] = relayExpiryTraffic([expiry], unique, [page]);
  assert.equal(partial.page_coverage, 'partial');
  assert.deepEqual(partial.following_writes[0].before_expiry.raw, [7]);
  const [ambiguous] = relayExpiryTraffic([expiry], unique, [page, page]);
  assert.equal(ambiguous.page_coverage, 'ambiguous');
  assert.deepEqual(ambiguous.following_writes[0].before_expiry.raw, []);
});

function deliveryWire(sender, recipient, room) {
  const envelope = Buffer.alloc(103);
  envelope.write('FSR1');
  envelope[4] = 1;
  room.copy(envelope, 5);
  sender.copy(envelope, 21);
  recipient.copy(envelope, 37);
  envelope.writeUInt32LE(46, 53);
  room.copy(envelope, 57);
  envelope.writeUInt32LE(0x000252f5, 73);
  envelope.writeUInt16LE(1, 77);
  envelope.writeUInt32LE(4, 81);
  const text = value => Buffer.concat([Buffer.from([0xa0 | value.length]), Buffer.from(value)]);
  const binary = value => Buffer.concat([Buffer.from([0xc4, value.length]), value]);
  return Buffer.concat([Buffer.from([1, 0x85]), text('from_player'), binary(sender), text('encoding'), text('message_pack'),
    text('payload'), binary(envelope), text('epoch'), Buffer.from([3]), text('seq'), Buffer.from([42])]);
}

test('settled proxy capture keeps original anchors and detects late duplicates', () => {
  const sender = Buffer.alloc(16, 17);
  const recipient = Buffer.alloc(16, 34);
  const room = Buffer.alloc(16, 51);
  const carrier = deliveryWire(sender, recipient, room);
  const proxy = createRelayProxyTrace();
  const socket = proxy.open({ page_index: 1, browser_endpoint: '127.0.0.1:44001' });
  const [first] = socket(Buffer.concat([Buffer.from('HTTP/1.1 101 Switching Protocols\r\n\r\n'), frame(0x82, carrier)]));
  const joined = { rows: [{ ...first, kind: 4, write: [1] }] };
  const original = joinRelayReceive(joined, proxy.snapshot(), [], first.room);
  const refresh = () => refreshRelayReceive(original, joined, proxy.snapshot());
  assert.deepEqual(refresh().rows[0].proxy, original.rows[0].proxy);
  socket(frame(0x82, carrier));
  assert.deepEqual(refresh().rows[0].proxy.map(write => write.ordinal), [1, 2], 'late duplicate makes the carrier ambiguous');
  assert.deepEqual(original.rows[0].proxy.map(write => write.ordinal), [1], 'published failure remains intact');

  const settled = proxy.snapshot();
  settled.sockets[0].events.shift();
  assert.deepEqual(refreshRelayReceive(original, joined, settled).rows[0].proxy, [], 'rollover cannot substitute a new ordinal');
});

test('an unchanged addressed carrier distinguishes forwarding from decoding', async () => {
  const sender = Buffer.alloc(16, 17);
  const recipient = Buffer.alloc(16, 34);
  const room = Buffer.alloc(16, 51);
  const carrier = deliveryWire(sender, recipient, room);
  const envelope = decodeRelayDelivery(carrier).envelope;
  const hex = bytes => bytes.toString('hex');
  const stamp = { sender: hex(sender), recipient: hex(recipient), lane: 'addressed', epoch: 3, seq: '42', kind: 4, family: 'quality',
    envelope_bytes: envelope.length, envelope_sha256: createHash('sha256').update(envelope).digest('hex'), write: [1], raw: [] };
  const original = Buffer.concat([Buffer.from('HTTP/1.1 101 Switching Protocols\r\n\r\n'), frame(0x82, carrier)]);
  globalThis.crypto ??= webcrypto;
  const proxy = createRelayProxyTrace();
  const browser = createRelayWireTrace('', 512, 45000, decodeRelayDelivery, true);
  browser.bind(hex(room), hex(recipient), [hex(sender), hex(recipient)]);
  const upstream = new PassThrough();
  const socketWrites = [];
  const socket = new Writable({ write(chunk, _encoding, callback) { socketWrites.push(chunk); callback(); } });
  const browserReader = createFrameReader();
  const inlet = Promise.withResolvers();
  const resume = Promise.withResolvers();
  traceProxyWrites(upstream, socket, proxy.open(), () => { inlet.resolve(); return resume.promise; });
  const trace = async () => {
    const carrier_capture_started_ms = performance.now();
    const page = { ...await browser.freeze(), carrier_capture_started_ms };
    return joinRelayReceive({ rows: [stamp] }, proxy.snapshot(), [page], hex(room)).rows[0];
  };
  const sent = once(socket, 'finish');
  upstream.end(original);
  await inlet.promise;
  assert.equal((await trace()).first_unobserved, 'proxy_outlet');
  resume.resolve();
  await sent;
  assert.deepEqual(Buffer.concat(socketWrites), original);
  assert.equal((await trace()).first_unobserved, 'browser_message');
  const [message] = browserReader.push(Buffer.concat(socketWrites));
  assert.deepEqual(message, carrier);
  const carrierOrdinal = browser.recordCarrier(message);
  const stalled = await trace();
  assert.equal(stalled.first_unobserved, 'relay_decode');
  assert.equal(stalled.message.length, 1);
  browser.record('raw', message, null, carrierOrdinal);
  assert.equal((await trace()).first_unobserved, null);
});

test('trace rejects nonminimal framing and binary messages after Close', () => {
  const header = Buffer.from('HTTP/1.1 101 Switching Protocols\r\n\r\n');
  for (const invalid of [
    Buffer.from([0x82, 126, 0, 1, 5]),
    Buffer.from([0x82, 127, 0, 0, 0, 0, 0, 0, 0, 1, 5]),
    Buffer.concat([frame(0x88, Buffer.alloc(0)), frame(0x82, Buffer.from([5]))]),
  ]) {
    const reader = createFrameReader();
    assert.deepEqual(reader.push(Buffer.concat([header, invalid])), []);
    assert.match(reader.status().error, /invalid WebSocket frame boundary/);
  }
});

test('inlet sees a queued chunk before an earlier TLS write finishes', async () => {
  const upstream = new PassThrough();
  const first = Promise.withResolvers();
  const resume = Promise.withResolvers();
  const entries = [];
  const socket = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
  const finished = once(socket, 'finish');
  traceProxyWrites(upstream, socket, chunk => {
    const event = { byte: chunk[0], outlet_ms: null };
    entries.push(event);
    return [event];
  }, events => {
    if (events[0].byte === 1) {
      first.resolve();
      return resume.promise;
    }
  });
  upstream.write(Buffer.from([1]));
  await first.promise;
  upstream.end(Buffer.from([2]));
  assert.deepEqual(entries, [{ byte: 1, outlet_ms: null }, { byte: 2, outlet_ms: null }]);
  resume.resolve();
  await finished;
  assert.ok(entries.every(event => event.outlet_ms !== null));
});

test('incomplete coverage and a different carrier copy cannot prove a missing or complete path', async () => {
  const sender = 'ab'.repeat(16);
  const recipient = 'cd'.repeat(16);
  const room = 'ef'.repeat(16);
  const stamp = { sender, recipient, lane: 'addressed', epoch: 3, seq: '42', kind: 4, family: 'quality',
    envelope_bytes: 103, envelope_sha256: 'digest', write: [1], raw: [] };
  const first = { ...stamp, room, ordinal: 1, inlet_ms: 1, outlet_ms: 2, carrier_sha256: 'one' };
  const other = { ...first, ordinal: 2, outlet_ms: null, carrier_sha256: 'two' };
  const page = { local: recipient, room, carrier_capture_started_ms: 3, streams: { raw: { quality: { omitted: 0 } } },
    carriers: { omitted: 0, skipped: 0, events: [{ ordinal: 1, carrier_sha256: 'two' }] } };
  const inspect = (events, pages = [page], socket = {}) =>
    joinRelayReceive({ rows: [stamp] }, { sockets: [{ ...socket, events }], refused: 0 }, pages, room).rows[0];
  const unrelated = inspect([first, other]);
  assert.deepEqual(unrelated.message, []);
  assert.equal(unrelated.first_unobserved, 'browser_message');
  assert.equal(inspect([], [page], { omitted: 8 }).coverage_gap, 'proxy_capture');
  assert.equal(inspect([other], [page], { omitted: 8 }).coverage_gap, 'proxy_capture');
  assert.equal(inspect([first], []).coverage_gap, 'browser_capture');
  assert.equal(inspect([first], [{ ...page, carrier_capture_started_ms: 1 }]).coverage_gap, 'capture_order');
  const received = { ...first, carrier_sha256: 'two' };
  stamp.raw = [7];
  page.streams.raw.quality.events = [{ ...stamp, carrier_ordinal: 7 }];
  assert.equal(inspect([received]).first_unobserved, 'relay_decode');
  page.streams.raw.quality.events = [{ ...stamp, carrier_ordinal: 1 }];
  assert.equal(inspect([received]).first_unobserved, null);
  page.streams.raw.quality.events = [];
  page.streams.raw.quality.omitted = 1;
  assert.equal(inspect([received]).coverage_gap, 'decoder_capture');
});
