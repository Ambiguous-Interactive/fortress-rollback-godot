// Value: constructor tracking charges orphan connections that never create a data channel.
const assert = require('node:assert/strict');
const test = require('node:test');
const { instrument, isDropCanonicalFailure, resourcesClosed, closeDepartingRtc } = require('./webrtc.cjs');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { pauseElapsed, registerOnlineInit, collectDiagnostics, measured } = require('./online.cjs');

// Value: download latency cannot extend gameplay; the real collector accepts only retained offline matches and restores storage methods on failure.
test('diagnostic downloads require an offline match that stays frozen throughout completion', async () => {
  const temporary = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'fortress-download-'));
  const filename = path.join(temporary, 'report.json');
  fs.writeFileSync(filename, '{"observed":true}');
  try {
    for (const mutation of ['none', 'live-before', 'frame', 'restores', 'state']) {
      const storage = () => {};
      const context = vm.createContext({ window: { fortressOnline: {
        state: mutation === 'live-before' ? 'playing' : 'offline', frame: 110, restores: 2,
      } }, Storage: class {}, IDBFactory: class {} });
      context.Storage.prototype.setItem = storage;
      context.IDBFactory.prototype.open = storage;
      let commands = 0, downloads = 0;
      const page = {
        async evaluate(operation) { return vm.runInContext(`(${operation.toString()})()`, context); },
        waitForEvent(kind) {
          assert.equal(kind, 'download');
          downloads++;
          return Promise.resolve({ suggestedFilename: () => 'fortress-diagnostics.json', async path() {
            await Promise.resolve();
            if (mutation === 'frame') context.window.fortressOnline.frame++;
            if (mutation === 'restores') context.window.fortressOnline.restores++;
            if (mutation === 'state') context.window.fortressOnline.state = 'playing';
            return filename;
          } });
        },
      };
      const result = collectDiagnostics([page], async (_page, kind) => { assert.equal(kind, 'diagnostics'); commands++; });
      if (mutation === 'none') {
        const reports = await result;
        assert.equal(reports.length, 1);
        assert.equal(reports[0].report.observed, true);
        assert.equal(reports[0].before.frame, reports[0].after.frame);
      } else {
        await assert.rejects(result, /diagnostic export (?:requires|advanced or resumed)/);
      }
      assert.equal(commands, mutation === 'live-before' ? 0 : 1);
      assert.equal(downloads, commands);
      assert.equal(context.Storage.prototype.setItem, storage);
      assert.equal(context.IDBFactory.prototype.open, storage);
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

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

// Value: the browser publishes the elapsed time of its own sub-steps, including a rejected one.
test('browser sub-steps report their elapsed time', async () => {
  const timings = {};
  await measured(timings, 'replay_import_us', async () => { await new Promise(resolve => setTimeout(resolve, 5)); });
  assert.equal(typeof timings.replay_import_us, 'number');
  assert.ok(Number.isInteger(timings.replay_import_us) && timings.replay_import_us >= 0);
  await assert.rejects(measured(timings, 'failed_us', async () => { throw new Error('the sub-step failed'); }), /the sub-step failed/);
  assert.equal(typeof timings.failed_us, 'number');
  assert.ok(Number.isInteger(timings.failed_us) && timings.failed_us >= 0);
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
async function failedRoom(hung = false, pair = ['chromium', 'chromium']) {
  const launches = [];
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
            connections: [{ connectionState: 'closed', iceConnectionState: 'closed', signalingState: 'closed',
              get localDescription() { throw new Error('Peer connection is closed'); },
              get remoteDescription() { throw new Error('Peer connection is closed'); } },
              { connectionState: 'connected', iceConnectionState: 'connected', signalingState: 'stable',
                localDescription: { sdp: 'v=0\r\na=candidate:owned\r\n' }, remoteDescription: null }],
          } },
        }));
      }
      return Promise.resolve('ROOM');
    },
  };
  const browser = { version() { return '141.0.7390.37'; }, async close() {}, async newContext() {
    return { async newPage() { return page; }, async close() { closed = true; } };
  } };
  const server = { on() {}, listen(port, host, ready) { ready(); }, address() { return { port: 123 }; }, close() {} };
  const moduleValue = { exports: {} };
  const fakeRequire = name => {
    if (name === './webrtc_display.cjs') return { async placeFirefox() { return { x: 0, y: 0 }; } };
    if (name === './webrtc_watchdog.cjs') return { boundedRoom: operation => operation(), async waitGameplay() { throw original; } };
    if (name === 'fake-playwright') return Object.fromEntries(['chromium', 'firefox'].map(engine => [engine, { async launch(options) {
      launches.push({ engine, options });
      return { ...browser, version() { return engine === 'chromium' ? '141.0.7390.37' : '142.0.1'; } };
    } }]));
    if (name === 'node:https') return { createServer() { return server; } };
    if (name === 'node:fs') return { readFileSync() { return ''; } };
    return require(name);
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc.cjs'), 'utf8') + '\nmodule.exports.main = main;', {
    module: moduleValue, require: fakeRequire, setTimeout: setTimer, clearTimeout: clearTimer,
    process: { argv: ['node', 'probe', '/export', 'ws://127.0.0.1:1/v3/ws', 'clean'],
      env: { FORTRESS_PLAYWRIGHT_PACKAGE: 'fake-playwright', FORTRESS_BROWSER_PAIR: JSON.stringify(pair) } },
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
  assert.deepEqual(launches.map(value => value.engine), pair);
  for (const value of launches) {
    assert.equal(value.options.headless, value.engine === 'chromium');
    if (value.engine === 'firefox') assert.deepEqual(JSON.parse(JSON.stringify(value.options.firefoxUserPrefs)),
      { 'webgl.force-enabled': true, 'webgl.disabled': false, 'toolkit.shutdown.fastShutdownStage': 0 });
  }
  assert.deepEqual(failure.browsers, pair.map(name => ({ name, version: name === 'chromium' ? '141.0.7390.37' : '142.0.1' })));
  assert.equal(failure.failed_rooms.length, 1);
  const peers = failure.failed_rooms[0].peers;
  assert.equal(peers.length, 2);
  for (const peer of peers) {
    if (hung) assert.equal(peer.failure, 'diagnostic_timeout');
    else { assert.equal(peer.rtc.sent, 88); assert.equal(peer.rtc.received, 77);
      assert.equal(peer.rtc.connections[0].local_candidates, null);
      assert.deepEqual(peer.rtc.connections[1].local_candidates, ['a=candidate:owned']);
      assert.equal(peer.rtc.channels[0].buffered_amount, 17); assert.equal(peer.rtc.channels[0].ready_state, 'open'); }
  }
}

test('failed room captures live RTC counters before closing contexts and preserves the original rejection', () => failedRoom());

test('browser pair selects independent Firefox launches with an available display', () => failedRoom(false, ['firefox', 'firefox']));
test('mixed browser pair launches Chromium and Firefox separately', () => failedRoom(false, ['chromium', 'firefox']));

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
    ArrayBuffer, Uint8Array, console, performance };
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


// Value: dependent browser instrumentation must initialize in one registration; Playwright leaves separate script order undefined.
test('online initialization registers once and initializes native RTC, sockets and delayed input in dependency order', async () => {
  const registrations = [];
  const page = { async addInitScript(operation, argument) { registrations.push({ operation, argument }); } };
  const options = { endpoint: 'wss://local.test', count: 2, index: 0, faults: false, corrupt: false, onlineCorrupt: true };
  await registerOnlineInit(page, options);
  assert.equal(registrations.length, 1);
  class Socket { static CLOSED = 3; constructor(url) { this.url = url; this.readyState = 1; } addEventListener() {} send() {} }
  class Connection {
    addEventListener() {}
    createDataChannel(label, configuration) {
      return { label, ...configuration, readyState: 'open', addEventListener() {}, send() {} };
    }
  }
  const context = vm.createContext({ WebSocket: Socket, RTCPeerConnection: Connection, RTCDataChannel: class {}, performance });
  context.window = context;
  for (const { operation, argument } of registrations.reverse()) {
    context.options = argument;
    vm.runInContext(`(${operation.toString()})(options)`, context);
  }
  assert.equal(context.fortressOnlineCorrupt, true);
  assert.equal(context.fortressOnlineDelayed, 0);
  assert.equal(context.fortressResources.websockets.length, 0);
  assert.equal(context.fortressResources.connections.length, 0);
  vm.runInContext(`new WebSocket('wss://local.test'); new RTCPeerConnection().createDataChannel('input', { id: 3 });`, context);
  assert.equal(context.fortressResources.websockets.length, 1);
  assert.equal(context.fortressResources.connections.length, 1);
  assert.equal(context.fortressResources.channels.length, 1);
  const source = fs.readFileSync(path.join(__dirname, 'online.cjs'), 'utf8');
  assert.equal((source.match(/await page\.addInitScript\(/g) || []).length, 1, 'the production registration boundary must stay singular');
  assert.equal((source.match(/await registerOnlineInit\(page,/g) || []).length, 1, 'each production page must use the controlled initializer');
});

// Value: a drop control cannot pass from an impossible or unrelated failure boundary.
test('drop corruption fails only at an actually compared active post-drop frame', () => {
  for (const frame of [8, 9, 10, 29, 30, 37]) {
    assert.equal(isDropCanonicalFailure({ passed: false, failure: {
      stage: 'peer_drop_gameplay', errors: [`peer_drop_canonical_${frame}`],
    } }), true);
  }
  for (const frame of ['1', '7', '38', '1000000', '08', '8junk']) {
    assert.equal(isDropCanonicalFailure({ passed: false, failure: {
      stage: 'peer_drop_gameplay', errors: [`peer_drop_canonical_${frame}`],
    } }), false);
  }
  for (const value of [null, {}, { passed: false, failure: { stage: 'peer_drop_gameplay', errors: ['peer_drop_unconfirmed'] } }])
    assert.equal(isDropCanonicalFailure(value), false);
});

// Value: actual browser teardown waits for signaling closure before contexts can hide leaked sockets.
test('drop teardown includes every tracked signaling socket', () => {
  const context = vm.createContext({ window: { fortressResources: {
    channels: [{ readyState: 'closed' }], connections: [{ connectionState: 'closed' }],
  }, fortressSockets: [{ socket: { readyState: 3 } }] }, WebSocket: { CLOSED: 3 } });
  const closed = requireSockets => vm.runInContext(`(${resourcesClosed.toString()})(${requireSockets})`, context);
  assert.equal(closed(true), true);
  for (const state of [0, 1, 2]) {
    context.window.fortressSockets.push({ socket: { readyState: state } });
    assert.equal(closed(true), false, 'an orphan or closing socket must keep the wait active');
    assert.equal(closed(false), true, 'ordinary transport modes retain their established gate');
    context.window.fortressSockets.pop();
  }
  context.window.fortressSockets = [];
  assert.equal(closed(true), false, 'an absent socket inventory cannot prove drop teardown');
  context.window.fortressSockets = [{ socket: { readyState: 3 } }];
  context.window.fortressResources.channels[0].readyState = 'open';
  assert.equal(closed(true), false);
  context.window.fortressResources.channels[0].readyState = 'closed';
  context.window.fortressResources.connections[0].connectionState = 'connected';
  assert.equal(closed(true), false);
});

// Value: readiness remains live; all endpoints acknowledge a short pause before RTC closure and release.
test('physical departure separates slow readiness from the bounded quiet close phase', async () => {
  for (const mutation of ['none', 'slow-readiness', 'slow-boundaries', 'advanced', 'released', 'not-paused', 'channel-open', 'late-pause', 'late-close']) {
    let ticks = 0;
    const events = [];
    const contexts = Array.from({ length: 3 }, (_, index) => vm.createContext({
      window: { fortressDropGo: mutation === 'released' && index === 0, fortressRtc: {},
        fortressResources: { connections: [], channels: [] } },
      document: { body: { dataset: { fortressFrame: mutation === 'advanced' && index === 0 ? '7' : '6', fortressDropReady: 'true' } } },
    }));
    const departing = contexts[2].window;
    const channels = Array.from({ length: 6 }, () => ({ readyState: 'open' }));
    departing.fortressResources.channels = channels;
    departing.fortressResources.connections = Array.from({ length: 4 }, () => ({ connectionState: 'connected', close() {
      assert.equal(events.filter(event => event.startsWith('paused')).length, 3, 'every endpoint must stop service before close');
      events.push('close');
      this.connectionState = 'closed';
      if (mutation !== 'channel-open') for (const channel of channels) channel.readyState = 'closed';
    } }));
    const pages = contexts.map((context, index) => ({
      async evaluate(operation, argument) {
        context.argument = argument;
        const result = vm.runInContext(`(${operation.toString()})(argument)`, context);
        if (context.window.fortressDropArm) {
          assert.equal(events.filter(event => event.startsWith('ready')).length, 3, 'slow readiness completes before service is stopped');
        }
        if (context.window.fortressDropGo) {
          assert.ok(channels.every(channel => channel.readyState === 'closed'), 'release must follow actual RTC closure');
          events.push(`released${index}`);
        }
        return result;
      },
      async waitForFunction(operation, argument, options) {
        const source = operation.toString();
        if (source.includes('fortressDropReady')) {
          assert.equal(options.timeout, 30000);
          assert.ok(contexts.every(value => !value.window.fortressDropArm), 'readiness waits keep endpoints unarmed');
          if (mutation === 'slow-readiness' && index === 2) ticks += 6000;
          events.push(`ready${index}`);
        } else {
          assert.ok(options.timeout > 0 && options.timeout <= 3000, 'quiet waits share the short controller deadline');
          if (source.includes('fortressDropPaused')) {
            assert.ok(contexts.every(value => value.window.fortressDropArm), 'all endpoints are armed before pause acknowledgement');
            if (mutation === 'late-pause' && index === 2) ticks += 3000;
            if (mutation === 'slow-boundaries' && index === 2) ticks += 1000;
            context.document.body.dataset.fortressDropPaused = mutation === 'not-paused' && index === 2 ? 'false' : 'true';
            events.push(`paused${index}`);
          } else {
            if (mutation === 'late-close') ticks += 3000;
            if (mutation === 'slow-boundaries') ticks += 1000;
          }
        }
        if (!vm.runInContext(`(${source})()`, context)) throw new Error('not ready');
      },
    }));
    if (['none', 'slow-readiness', 'slow-boundaries'].includes(mutation)) {
      await closeDepartingRtc(pages, () => ticks);
      assert.deepEqual(JSON.parse(JSON.stringify(departing.fortressRtc.departure)), {
        frame: 6, survivor_frames: [6, 6], connections_created: 4, channels_created: 6, connections_closed: 4, channels_closed: 6,
      });
      assert.ok(contexts.every(context => context.window.fortressDropGo === true));
      assert.equal(events.filter(event => event.startsWith('released')).length, 3);
    } else {
      await assert.rejects(closeDepartingRtc(pages, () => ticks));
      assert.equal(events.filter(event => event.startsWith('released')).length, 0);
    }
  }
});

// Value: a lost inventory answer must retry exact owned bytes through the real channel send wrapper.
test('peer-drop answer loss drops one inventory report and passes its exact retry', () => {
  const sent = [];
  class Connection {
    addEventListener() {}
    createDataChannel(label, options) {
      return { label, ...options, addEventListener() {}, send(bytes) { sent.push(new Uint8Array(bytes).slice()); } };
    }
  }
  global.WebSocket = class { send() {} };
  global.RTCPeerConnection = Connection;
  global.window = { RTCPeerConnection: Connection };
  global.document = { body: { dataset: { fortressFrame: '7' } } };
  try {
    instrument({ endpoint: 'wss://localhost', count: 3, index: 1, peerDrop: true, dropAnswer: true });
    const channel = new window.RTCPeerConnection().createDataChannel('unreliable', { id: 3 });
    const packet = new Uint8Array(104);
    packet.set([70, 82, 71, 80, 2, 0, 12, 0]);
    packet[40] = 60;
    packet[44] = 2;
    packet[45] = 1;
    const ready = packet.slice(); ready[45] = 2;
    channel.send(ready);
    channel.send(packet);
    assert.equal(sent.length, 1, 'the inventory report must be lost at the physical send boundary');
    const changed = packet.slice(); changed[52] = 1;
    channel.send(changed);
    assert.equal(window.fortressRtc.answerLoss.retries, 0, 'another operation cannot count as retry evidence');
    channel.send(packet.buffer);
    packet[55] = 9;
    assert.equal(sent.length, 3);
    assert.equal(window.fortressRtc.answerLoss.dropped, 1);
    assert.equal(window.fortressRtc.answerLoss.retries, 1);
    assert.equal(window.fortressRtc.answerLoss.packet, Buffer.from(sent[2]).toString('hex'));
  } finally {
    delete global.WebSocket;
    delete global.window;
    delete global.RTCPeerConnection;
    delete global.document;
  }
});

// Value: actual original inputs remain held until prediction, across retries and room reuse.
function predictionFixture() {
  const sent = [], timers = [];
  class Channel {
    constructor() { this.id = 3; this.readyState = 'open'; }
    addEventListener() {}
    send(bytes) { sent.push(Array.from(bytes)); }
    get bufferedAmount() { return 0; }
  }
  class Connection { createDataChannel() { return new Channel(); } }
  const source = fs.readFileSync(path.join(__dirname, 'online.cjs'), 'utf8');
  const code = source.slice(source.indexOf('function delayedInputs()'), source.indexOf('\nfunction instrumentSockets()'));
  const context = vm.createContext({ window: { fortressOnline: { room: 'FIRST', room_id: 'room-first', session_id: '01'.repeat(16),
    game_lifetime: 1, predicted_frame: -1, predicted_lifetime: 0 } }, RTCPeerConnection: Connection, RTCDataChannel: Channel,
    setTimeout(callback) { timers.push(callback); }, Uint8Array, ArrayBuffer });
  vm.runInContext(`${code}; delayedInputs();`, context);
  return { context, sent, timers, createChannel: () => new Connection().createDataChannel(), channel: new Connection().createDataChannel(), window: context.window };
}
const predictionInput = () => { const bytes = new Uint8Array(25); bytes.set([70, 82, 71, 80, 2, 0, 3, 0]); bytes.fill(1, 8); return bytes; };

test('prediction barrier owns exact originals and blocks retries until explicit predicted-step release', () => {
  const f = predictionFixture();
  assert.ok(f.window.fortressPredictionGate, 'online input delay needs an explicit prediction barrier');
  const gate = f.window.fortressPredictionGate;
  gate.arm({ room: 'FIRST', room_id: 'room-first' });
  const original = predictionInput();
  for (let i = 0; i < 26; i++) f.channel.send(original);
  original[8] = 9;
  f.timers.forEach(callback => callback());
  assert.equal(f.sent.length, 0, 'elapsed timers and retransmission count cannot release an original');
  const handshake = predictionInput(); handshake[6] = 1;
  f.channel.send(handshake);
  assert.equal(f.sent.length, 1, 'handshake/control remains live');
  assert.throws(() => gate.release(), /prediction/);
  assert.equal(f.sent.length, 1);
  Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 1 });
  gate.release();
  assert.equal(f.sent.length, 27);
  assert.ok(f.sent.slice(1).every(packet => packet[8] === 1), 'sender mutation cannot alter held originals');
  assert.equal(gate.summary().released, 26);
  assert.throws(() => gate.release(), /inactive/);
  Object.assign(f.window.fortressOnline, { game_lifetime: 2, predicted_frame: -1, predicted_lifetime: 0 });
  gate.arm({ room: 'FIRST', room_id: 'room-first' });
  assert.equal(gate.summary().released, 0);
  f.channel = f.createChannel();
  f.channel.send(predictionInput());
  assert.equal(f.sent.length, 27, 'a new room has its own active barrier');
  f.channel.readyState = 'closed';
  Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 2 });
  assert.throws(() => gate.release(), /closed/);
  assert.equal(f.sent.length, 27, 'a closed old channel cannot publish successful delivery');
});

test('prediction barrier fails closed on packet and byte capacity and cannot reset pending work', () => {
  for (const size of [25, 65536]) {
    const f = predictionFixture(), gate = f.window.fortressPredictionGate;
    assert.ok(gate);
    gate.arm({ room: 'FIRST', room_id: 'room-first' });
    const packet = new Uint8Array(size); packet.set(predictionInput());
    const limit = Math.min(256, Math.floor(262144 / size));
    for (let i = 0; i < limit; i++) f.channel.send(packet);
    assert.throws(() => gate.arm(), /active/);
    assert.throws(() => f.channel.send(packet), /capacity/);
    assert.equal(f.sent.length, 0);
    Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 1 });
    assert.throws(() => gate.release(), /capacity/);
    assert.equal(f.sent.length, 0);
  }
});

// Value: new physical channels cannot reuse an old room's predicted callback or readiness.
test('prediction barrier rejects stale and replaced room lifetimes before physical delivery', () => {
  const f = predictionFixture(), gate = f.window.fortressPredictionGate;
  const first = { room: 'FIRST', room_id: 'room-first', session_id: '01'.repeat(16), game_lifetime: 1, predicted_frame: -1, predicted_lifetime: 0 };
  f.window.fortressOnline = first;
  gate.arm({ room: first.room, room_id: first.room_id });
  f.channel.send(predictionInput());
  first.predicted_frame = 2; first.predicted_lifetime = 1;
  gate.release();
  f.channel.readyState = 'closed';
  assert.throws(() => gate.arm({ room: 'SECOND', room_id: 'room-second' }), /lifetime|room|prediction/);
  assert.equal(f.sent.length, 1);
  f.window.fortressOnline = { ...first, room: 'SECOND', room_id: 'room-second', session_id: '02'.repeat(16),
    game_lifetime: 2, predicted_frame: -1, predicted_lifetime: 0 };
  gate.arm({ room: 'SECOND', room_id: 'room-second' });
  const replacement = f.createChannel();
  const packet = predictionInput(); packet.fill(2, 8, 24);
  replacement.send(packet);
  f.window.fortressOnline = { ...first };
  assert.throws(() => gate.release(), /lifetime|room/);
  assert.equal(f.sent.length, 1, 'old callback cannot release the replacement channel');
});

// Value: a current callback cannot authorize original bytes or physical channels from another session.
test('prediction barrier rejects old channels, old packet sessions, and old callback lifetimes', () => {
  for (const stale of ['channel', 'packet', 'callback']) {
    const f = predictionFixture(), gate = f.window.fortressPredictionGate;
    Object.assign(f.window.fortressOnline, { room: 'SECOND', room_id: 'room-second', session_id: '02'.repeat(16), game_lifetime: 2 });
    gate.arm({ room: 'SECOND', room_id: 'room-second' });
    const channel = stale === 'channel' ? f.channel : f.createChannel();
    const packet = predictionInput();
    if (stale !== 'packet') packet.fill(2, 8, 24);
    if (stale !== 'callback') assert.throws(() => channel.send(packet), /lifetime/);
    else {
      channel.send(packet);
      Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 1 });
      assert.throws(() => gate.release(), /prediction/);
      Object.assign(f.window.fortressOnline, { predicted_lifetime: 2 });
      gate.release();
      assert.equal(f.sent.length, 1, 'a fresh callback on the matching lifetime is the green control');
    }
    if (stale !== 'callback') assert.equal(f.sent.length, 0);
  }
});

// Value: real retries between browser evaluations must enter the same atomic release receipt.
test('prediction release receipt includes originals arriving after the prediction wait', async () => {
  const source = fs.readFileSync(path.join(__dirname, 'online.cjs'), 'utf8');
  const start = source.indexOf('      const prediction = await Promise.all(');
  const end = source.indexOf('      await Promise.all(pages.map(page => wait(page, target =>', start);
  assert.ok(start >= 0 && end > start);
  const fixtures = [predictionFixture(), predictionFixture()];
  for (const f of fixtures) {
    f.window.fortressPredictionGate.arm({ room: 'FIRST', room_id: 'room-first' });
    f.channel.send(predictionInput());
    Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 1 });
  }
  const pages = fixtures.map(f => ({ async evaluate(operation, argument) {
    // A real original/retry can enter on every browser turn while the host awaits evaluations.
    if (f.window.fortressPredictionGate.active) f.channel.send(predictionInput());
    const result = vm.runInContext(`(${operation.toString()})(${JSON.stringify(argument)})`, f.context);
    if (f.window.fortressPredictionGate.active) f.channel.send(predictionInput());
    return result;
  } }));
  const execute = new (Object.getPrototypeOf(async function() {}).constructor)('pages', `${source.slice(start, end)}; return prediction;`);
  const receipts = await execute(pages);
  receipts.forEach((receipt, index) => {
    assert.ok(receipt.before.pending >= 2, 'receipt includes the input arriving after prediction readiness');
    assert.equal(receipt.after.released, receipt.before.pending, 'capture and release have no intervening browser turn');
    assert.equal(fixtures[index].sent.length, receipt.after.released);
    assert.equal(receipt.after.pending, 0);
  });
});

// Value: both physical second directions must already be active when corrupt rollback first unblocks.
test('corrupt control sets both physical second directions before either original release', async () => {
  const source = fs.readFileSync(path.join(__dirname, 'online.cjs'), 'utf8');
  const start = source.indexOf('      // Keep handshake service live while originals are held.');
  const end = source.indexOf('      if (round === 3 && !corrupt)', start);
  assert.ok(start >= 0 && end > start);
  const fixtures = [predictionFixture(), predictionFixture()];
  const keys = [new Set(['KeyD']), new Set(['KeyW'])];
  let predictionWaits = 0;
  const pages = fixtures.map((f, index) => ({
    keyboard: {
      async up(key) { assert.equal(predictionWaits, 2); await Promise.resolve(); keys[index].delete(key); },
      async down(key) { assert.equal(predictionWaits, 2); await Promise.resolve(); keys[index].add(key); },
    },
    async evaluate(operation, argument) {
      assert.ok(keys[0].has('KeyS') && keys[1].has('KeyA'), 'both second physical keys precede every release');
      assert.ok(!keys[0].has('KeyD') && !keys[1].has('KeyW'), 'first physical directions have ended');
      return vm.runInContext(`(${operation.toString()})(${JSON.stringify(argument)})`, f.context);
    },
  }));
  for (const f of fixtures) {
    f.window.fortressPredictionGate.arm({ room: 'FIRST', room_id: 'room-first' });
    f.channel.send(predictionInput());
    Object.assign(f.window.fortressOnline, { predicted_frame: 2, predicted_lifetime: 1 });
  }
  const wait = async () => { predictionWaits++; };
  const execute = new (Object.getPrototypeOf(async function() {}).constructor)(
    'pages', 'wait', 'corrupt', `${source.slice(start, end)}; return prediction;`);
  const receipts = await execute(pages, wait, true);
  assert.equal(receipts.length, 2);
  fixtures.forEach(f => assert.equal(f.sent.length, 1, 'the actual held original was released'));
});
