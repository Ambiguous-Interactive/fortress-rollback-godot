// Value: constructor tracking charges orphan connections that never create a data channel.
const assert = require('node:assert/strict');
const test = require('node:test');
const { instrument } = require('./webrtc.cjs');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { pauseElapsed } = require('./online.cjs');

// Value: suspension duration follows the monotonic clock even when a timer callback runs early.
test('actual suspension wait cannot finish early after timer truncation', async () => {
  for (const milliseconds of [750, 2500]) {
    let ticks = 1000000000n;
    const waits = [];
    const elapsed = await pauseElapsed(milliseconds, () => ticks, async value => {
      waits.push(value);
      ticks += BigInt(value) * 1000000n - 198000n;
    });
    assert.ok(elapsed >= milliseconds * 1000, 'the actual pause must meet its strict observation threshold');
    assert.deepEqual(waits, [milliseconds, 1], 'an early callback rearms only the remaining duration');
  }
});

test('all constructed peer connections must close, including channel-free orphans', () => {
  class Connection {
    constructor() { this.connectionState = 'new'; this.iceConnectionState = 'new'; this.channels = []; }
    addEventListener() {}
    createDataChannel(label, options) {
      const channel = { label, ...options, readyState: 'open', maxPacketLifeTime: null, maxRetransmits: null,
        addEventListener() {}, send() {} };
      this.channels.push(channel);
      return channel;
    }
    close() { this.connectionState = 'closed'; this.channels.forEach(channel => { channel.readyState = 'closed'; }); }
  }
  global.WebSocket = class { send() {} };
  global.RTCPeerConnection = Connection;
  global.window = { RTCPeerConnection: Connection };
  try {
    instrument({ endpoint: 'wss://localhost', count: 2, index: 0, faults: false, corrupt: false, defaultFactory: false });
    const used = new window.RTCPeerConnection();
    const orphan = new window.RTCPeerConnection();
    used.createDataChannel('unreliable', { id: 3, negotiated: true, ordered: false });
    assert.equal(window.fortressResources.connections.length, 2);
    assert.equal(window.fortressResources.channels.length, 1);
    used.close();
    assert.equal(window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), false);
    orphan.close();
    assert.equal(window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), true);
  } finally {
    delete global.WebSocket;
    delete global.window;
    delete global.RTCPeerConnection;
  }
});

// Value: protects=failed-room socket evidence; fails_when=context cleanup precedes capture; why_new=successful teardown tests omit rejection; seam=actual main in VM.
async function failedRoom(hung = false) {
  const output = [];
  const timers = new Map();
  const delays = [];
  let serial = 0;
  const setTimer = (callback, delay) => { delays.push(delay); timers.set(++serial, callback); return serial; };
  const clearTimer = id => timers.delete(id);
  let closed = false;
  const original = new Error('original gameplay refusal');
  const page = {
    on() {}, async addInitScript() {}, async goto() {}, async waitForFunction() {},
    evaluate(operation, argument) {
      if (operation.toString().includes('fortressResources')) {
        assert.equal(closed, false, 'capture must precede context destruction');
        if (hung) return new Promise(() => {});
        return Promise.resolve(vm.runInNewContext(`(${operation.toString()})(argument)`, { argument,
          performance: { now: () => 123 }, document: { body: { dataset: { fortressFrame: '28' } } },
          window: { fortressRtc: { sent: 88, received: 77, dropped: 0, reordered: 0, pending: 0, active: 0,
            channels: [{ sent: 88, received: 77 }] }, fortressResources: {
            channels: [{ id: 3, label: 'unreliable', readyState: 'open', bufferedAmount: 17,
              ordered: false, maxPacketLifeTime: 1, maxRetransmits: null }],
            connections: [{ connectionState: 'connected', iceConnectionState: 'connected', signalingState: 'stable' }],
          } },
        }));
      }
      return Promise.resolve('ROOM');
    },
  };
  const browser = { async close() {}, async newContext() {
    return { async newPage() { return page; }, async close() { closed = true; } };
  } };
  const server = { on() {}, listen(port, host, ready) { ready(); }, address() { return { port: 123 }; }, close() {} };
  const moduleValue = { exports: {} };
  const fakeRequire = name => {
    if (name === './webrtc_watchdog.cjs') return { boundedRoom: operation => operation(), async waitGameplay() { throw original; } };
    if (name === 'fake-playwright') return { chromium: { async launch() { return browser; } } };
    if (name === 'node:https') return { createServer() { return server; } };
    if (name === 'node:fs') return { readFileSync() { return ''; } };
    return require(name);
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc.cjs'), 'utf8') + '\nmodule.exports.main = main;', {
    module: moduleValue, require: fakeRequire, setTimeout: setTimer, clearTimeout: clearTimer,
    process: { argv: ['node', 'probe', '/export', 'ws://127.0.0.1:1/v3/ws', 'clean'], env: { FORTRESS_PLAYWRIGHT_PACKAGE: 'fake-playwright' } },
    console: { log() {}, error(value) { output.push(value); } },
  });
  const running = moduleValue.exports.main();
  if (hung) {
    for (let turn = 0; turn < 500 && timers.size < 2; turn++) await Promise.resolve();
    assert.equal(timers.size, 2, 'both pages start bounded diagnostics independently');
    assert.deepEqual(delays, [1000, 1000]);
    for (const callback of [...timers.values()]) callback();
  }
  await assert.rejects(running, error => error === original);
  assert.equal(timers.size, 0, 'capture timers are released');
  const failure = JSON.parse(output[0]);
  assert.equal(failure.failure, String(original));
  assert.equal(failure.failed_rooms.length, 1);
  const peers = failure.failed_rooms[0].peers;
  assert.equal(peers.length, 2);
  for (const peer of peers) {
    if (hung) assert.equal(peer.failure, 'diagnostic_timeout');
    else { assert.equal(peer.rtc.sent, 88); assert.equal(peer.rtc.received, 77);
      assert.equal(peer.rtc.channels[0].buffered_amount, 17); assert.equal(peer.rtc.channels[0].ready_state, 'open'); }
  }
}

test('failed room captures live RTC counters before closing contexts and preserves the original rejection', () => failedRoom());

test('hung RTC diagnostics expire independently after one second without replacing the original rejection', () => failedRoom(true));
// Value: pressure must block one link only, preserve physical state, and end at the exact frame boundary.
test('mixed pressure keeps unrelated channels healthy and releases the same physical channel at frame sixteen', () => {
  class Channel {
    constructor(options) { Object.assign(this, options); this.nativeBuffered = 7; this.readyState = 'open'; this.sent = []; }
    get bufferedAmount() { return this.nativeBuffered; }
    addEventListener() {}
    send(bytes) { this.sent.push(bytes); }
  }
  class Connection {
    constructor() { this.connectionState = 'connected'; this.iceConnectionState = 'connected'; }
    addEventListener() {}
    createDataChannel(label, options) { return new Channel({ label, ...options }); }
  }
  global.RTCDataChannel = Channel;
  global.RTCPeerConnection = Connection;
  global.WebSocket = class { send() {} };
  global.window = { RTCPeerConnection: Connection };
  global.document = { body: { dataset: { fortressFrame: '3' } } };
  try {
    instrument({ count: 4, index: 0, mixed: true, mixedDefault: true, faults: false });
    const blocked = new window.RTCPeerConnection().createDataChannel('unreliable', { id: 3 });
    const healthy = new window.RTCPeerConnection().createDataChannel('unreliable', { id: 3 });
    assert.equal(blocked.bufferedAmount, 7);
    document.body.dataset.fortressFrame = '4';
    assert.equal(blocked.bufferedAmount, 262144);
    assert.equal(healthy.bufferedAmount, 7);
    assert.equal(blocked.readyState, 'open');
    const bytes = new Uint8Array([1, 2, 3]);
    healthy.send(bytes);
    assert.deepEqual(healthy.sent, [bytes]);
    document.body.dataset.fortressFrame = '15';
    assert.equal(blocked.bufferedAmount, 262144);
    document.body.dataset.fortressFrame = '16';
    assert.equal(blocked.bufferedAmount, 7);
    document.body.dataset.fortressFrame = '20';
    blocked.send(bytes);
    assert.deepEqual(blocked.sent, [bytes]);
    const rows = window.fortressRtc.channels;
    assert.equal(rows[0].blockedReads, 2);
    assert.equal(rows[0].mixedSent, 0);
    assert.equal(rows[0].restoredSent, 1);
    assert.equal(rows[1].mixedSent, 1);
    const socket = new WebSocket();
    socket.send('control');
    socket.send(bytes);
    assert.equal(window.fortressRtc.binarySent, 1);
    assert.equal(window.fortressMixedDefault, true);
  } finally {
    for (const name of ['window', 'document', 'WebSocket', 'RTCPeerConnection', 'RTCDataChannel']) delete global[name];
  }
});

// Value: physical outage closes only the correlated unreliable link at frame four, with actual close events.
test('physical close records the explicit channel handle even when payloads match', () => {
  class Channel {
    constructor(options) { Object.assign(this, options); this.readyState = 'open'; this.handlers = {}; }
    get bufferedAmount() { return 0; }
    addEventListener(name, handler) { this.handlers[name] = handler; }
    close() { this.readyState = 'closed'; this.handlers.close(); }
    send() { assert.equal(this.readyState, 'open'); }
  }
  class Connection {
    addEventListener() {}
    createDataChannel(label, options) { return new Channel({ label, ...options }); }
  }
  const context = { window: { RTCPeerConnection: Connection }, RTCPeerConnection: Connection,
    RTCDataChannel: Channel, WebSocket: class { send() {} }, document: { body: { dataset: { fortressFrame: '2' } } },
    ArrayBuffer, Uint8Array, console };
  vm.runInNewContext(`(${instrument.toString()})({ endpoint: 'wss://localhost', count: 4, index: 0,
    mixed: true, physicalClose: true })`, context);
  const connection = new context.window.RTCPeerConnection();
  const first = connection.createDataChannel('unreliable', { id: 3 });
  const selected = connection.createDataChannel('unreliable', { id: 3 });
  first.send(new Uint8Array([1]));
  selected.send(new Uint8Array([1]));
  const records = context.window.fortressRtc.channels;
  context.document.body.dataset.fortressFrame = '4';
  selected.close();
  assert.equal(first.readyState, 'open');
  assert.equal(selected.readyState, 'closed');
  assert.equal(records[1].closeInitiatedFrame, 4);
  assert.equal(records[1].physicalCloseFrame, 4);
  assert.equal(records[0].blockedLink, false);
  assert.equal(records[1].blockedLink, true);
  assert.equal(records[1].blockedReads, 0);
  assert.equal(first.readyState, 'open', 'the outage cannot move to another healthy endpoint');
  context.document.body.dataset.fortressGameplayDone = 'true';
  first.close();
  assert.equal(records[0].physicalCloseFrame, null, 'teardown cannot manufacture outage evidence');
});
