// Value: constructor tracking charges orphan connections that never create a data channel.
const assert = require('node:assert/strict');
const test = require('node:test');
const { instrument } = require('./webrtc.cjs');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

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
