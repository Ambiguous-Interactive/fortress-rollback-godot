// Value: runs the shipped online scene; real keyboard, SDK sockets, recovery and new-room lifecycle.
const fs = require('node:fs');
const https = require('node:https');
const { createHost } = require('./online_host.cjs');
const path = require('node:path');
const { instrument } = require('./webrtc.cjs');

function delayedInputs() {
  window.fortressRestartFault = { armed: false, pressure: false, held: [], dropped: 0, pending: 0, reads: 0 };
  const channelLifetimes = new WeakMap();
  const gate = { lastLifetime: 0, identity: null, active: false, packets: [], bytes: 0, released: 0, releases: 0, failure: '',
    arm(expected) {
      if (this.active || this.packets.length) throw new Error('prediction gate already active');
      const value = window.fortressOnline;
      if (!value || value.room !== expected?.room || value.room_id !== expected?.room_id
          || !value.room || !value.room_id || !/^[a-f0-9]{32}$/.test(value.session_id)
          || !Number.isSafeInteger(value.game_lifetime) || value.game_lifetime <= this.lastLifetime
          || value.predicted_frame !== -1 || value.predicted_lifetime !== 0) throw new Error('prediction gate room lifetime invalid');
      this.identity = { room: value.room, room_id: value.room_id, session_id: value.session_id, game_lifetime: value.game_lifetime };
      this.lastLifetime = value.game_lifetime;
      this.active = true; this.bytes = 0; this.released = 0; this.releases = 0; this.failure = '';
    },
    current() {
      const value = window.fortressOnline;
      if (!value || !this.identity || Object.keys(this.identity).some(key => value[key] !== this.identity[key])) {
        this.failure = 'prediction gate room lifetime replaced';
        throw new Error(this.failure);
      }
      return value;
    },
    hold(channel, send, view) {
      this.current();
      const session = Array.from(view.slice(8, 24), byte => byte.toString(16).padStart(2, '0')).join('');
      if (session !== this.identity.session_id || (channelLifetimes.has(channel) && channelLifetimes.get(channel) !== this.identity.game_lifetime))
        throw new Error('prediction gate packet/channel lifetime mismatch');
      channelLifetimes.set(channel, this.identity.game_lifetime);
      if (this.failure) throw new Error(this.failure);
      if (this.packets.length >= 256 || this.bytes + view.byteLength > 262144) {
        this.failure = 'prediction gate capacity exceeded';
        throw new Error(this.failure);
      }
      const owned = view.slice();
      this.packets.push({ channel, send, owned }); this.bytes += owned.byteLength;
      window.fortressOnlineDelayed++;
    },
    release() {
      if (this.failure) throw new Error(this.failure);
      if (!this.active) throw new Error('prediction gate inactive');
      const value = this.current();
      if (!(value.predicted_frame >= 2) || value.predicted_lifetime !== this.identity.game_lifetime) throw new Error('prediction step missing');
      if (!this.packets.length) throw new Error('prediction gate has no original inputs');
      if (this.packets.some(packet => packet.channel.readyState !== 'open')) {
        this.failure = 'prediction gate channel closed';
        throw new Error(this.failure);
      }
      for (const packet of this.packets) { packet.send(packet.owned); this.released++; }
      this.packets = []; this.bytes = 0; this.active = false; this.releases++;
    },
    summary() { return { active: this.active, pending: this.packets.length, bytes: this.bytes,
      released: this.released, releases: this.releases, failure: this.failure, ...this.identity }; },
  };
  window.fortressPredictionGate = gate;
  const create = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = create.call(this, label, options);
    const send = channel.send.bind(channel);
    channelLifetimes.set(channel, window.fortressOnline?.game_lifetime);
    channel.addEventListener('message', event => {
      if (!window.fortressStaleExpected) return;
      const hex = Array.from(new Uint8Array(event.data), byte => byte.toString(16).padStart(2, '0')).join('');
      if (hex === window.fortressStaleExpected) window.fortressStaleReceived = (window.fortressStaleReceived || 0) + 1;
    });
    const buffered = Object.getOwnPropertyDescriptor(RTCDataChannel.prototype, 'bufferedAmount')?.get;
    if (channel.id === 3 && buffered) Object.defineProperty(channel, 'bufferedAmount', { get() {
      if (window.fortressRestartFault.pressure) { window.fortressRestartFault.reads++; return 262144; }
      return buffered.call(channel);
    } });
    channel.send = bytes => {
      const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
        : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
      const fault = window.fortressRestartFault;
      if (view && view.length >= 8 && view[6] === 3 && fault.armed && fault.held.length < 1) {
        const owned = view.slice();
        fault.held.push(Array.from(owned, byte => byte.toString(16).padStart(2, '0')).join(''));
        fault.pending++;
        setTimeout(() => {
          if (channel.readyState === 'open') send(owned); else fault.dropped++;
          fault.pending--;
        }, 5000);
      } else if (view && view.length >= 8 && view[6] === 3 && gate.active) {
        gate.hold(channel, send, view);
      } else send(bytes);
    };
    return channel;
  };
  window.fortressOnlineDelayed = 0;
}

function instrumentSockets() {
  window.fortressResources.websockets = [];
  const nativeSocket = window.WebSocket;
  window.WebSocket = new Proxy(nativeSocket, {
    construct(target, args, newTarget) {
      const socket = Reflect.construct(target, args, newTarget);
      window.fortressResources.websockets.push(socket);
      const buffered = Object.getOwnPropertyDescriptor(nativeSocket.prototype, 'bufferedAmount')?.get;
      if (buffered) Object.defineProperty(socket, 'bufferedAmount', { get() {
        if (window.fortressRestartFault?.pressure) { window.fortressRestartFault.reads++; return 262144; }
        return buffered.call(socket);
      } });
      return socket;
    },
  });
}

async function registerOnlineInit(page, options) {
  const initialize = new Function('options', `
    (${instrument.toString()})(options);
    (${instrumentSockets.toString()})();
    (${delayedInputs.toString()})();
    window.fortressOnlineCorrupt = options.onlineCorrupt;
  `);
  await page.addInitScript(initialize, options);
}

function resourceCounts() {
  const resources = window.fortressResources;
  return {
    channels: resources.channels.length,
    channels_closed: resources.channels.filter(channel => channel.readyState === 'closed').length,
    connections: resources.connections.length,
    connections_closed: resources.connections.filter(connection => connection.connectionState === 'closed').length,
    ice_closed: resources.connections.filter(connection => connection.iceConnectionState === 'closed').length,
    websockets: resources.websockets.length,
    websockets_closed: resources.websockets.filter(socket => socket.readyState === WebSocket.CLOSED).length,
  };
}

async function pauseElapsed(milliseconds, now = () => process.hrtime.bigint(), sleep = value => new Promise(resolve => setTimeout(resolve, value))) {
  const started = now();
  const duration = BigInt(milliseconds) * 1000000n;
  let elapsed = now() - started;
  while (elapsed < duration) {
    await sleep(Math.max(1, Math.ceil(Number(duration - elapsed) / 1000000)));
    elapsed = now() - started;
  }
  return Number(elapsed / 1000n);
}

// Value: the elapsed time of one sub-step, in whole microseconds.
function elapsedMicros(started) {
  return Number((process.hrtime.bigint() - started) / 1000n);
}

// Value: the browser reports the elapsed time of its own sub-steps, so the receipt names them.
async function measured(timings, name, operation) {
  const started = process.hrtime.bigint();
  try {
    return await operation();
  } finally {
    timings[name] = elapsedMicros(started);
  }
}

async function collectDiagnostics(pages, command) {
  const diagnostics = [];
  for (const page of pages) {
    const before = await page.evaluate(() => ({ state: window.fortressOnline.state, restores: window.fortressOnline.restores, frame: window.fortressOnline.frame }));
    if (before.state !== 'offline') throw new Error('diagnostic export requires a stopped offline match');
    await page.evaluate(() => {
      window.fortressStorageCalls = 0;
      window.fortressStorageOriginals = [Storage.prototype.setItem, IDBFactory.prototype.open];
      const unavailable = () => { window.fortressStorageCalls++; throw new Error('storage unavailable'); };
      Storage.prototype.setItem = unavailable;
      IDBFactory.prototype.open = unavailable;
    });
    try {
      const pending = page.waitForEvent('download', { timeout: 10000 });
      await command(page, 'diagnostics');
      const download = await pending;
      const report = JSON.parse(fs.readFileSync(await download.path(), 'utf8'));
      const after = await page.evaluate(() => ({ state: window.fortressOnline.state, restores: window.fortressOnline.restores, frame: window.fortressOnline.frame,
        storage_calls: window.fortressStorageCalls }));
      if (after.state !== 'offline' || after.frame !== before.frame || after.restores !== before.restores)
        throw new Error('diagnostic export advanced or resumed an offline match');
      diagnostics.push({ before, after, filename: download.suggestedFilename(), report });
    } finally {
      await page.evaluate(() => {
        [Storage.prototype.setItem, IDBFactory.prototype.open] = window.fortressStorageOriginals;
      });
    }
  }
  return diagnostics;
}


async function watchReplay(page, command, recording, diagnostic, timings) {
  await command(page, 'watch_replay');
  const control = button => command(page, 'viewer_control', { button });
  const choose = async buffer => {
    const pending = page.waitForEvent('filechooser', { timeout: 10000 });
    await control('Open replay');
    const chooser = await pending;
    await chooser.setFiles({ name: 'fortress-online.frrp', mimeType: 'application/octet-stream', buffer });
  };
  const bytes = Buffer.from(recording.hex, 'hex');
  const initial = await measured(timings, 'replay_import_us', async () => {
    await choose(bytes);
    await page.waitForFunction(() => window.fortressOnline.viewer.frames > 0, null, { timeout: 10000 });
    const opened = await page.evaluate(() => window.fortressOnline.viewer);
    if (opened.frame !== 0 || opened.playing) throw new Error('viewer did not open paused');
    return opened;
  });
  let stepped, paused, restarted, rejected, completed, forward, backward;
  await measured(timings, 'replay_playback_us', async () => {
    await control('Step');
    stepped = await page.evaluate(() => window.fortressOnline.viewer);
    if (stepped.frame !== 1 || stepped.playing) throw new Error('viewer single step failed');
    await control('Play');
    await page.waitForFunction(() => window.fortressOnline.viewer.frame >= 4, null, { timeout: 10000 });
    await control('Pause');
    paused = await page.evaluate(() => window.fortressOnline.viewer);
    await page.waitForTimeout(100);
    if (paused.playing || await page.evaluate(() => window.fortressOnline.viewer.frame) !== paused.frame)
      throw new Error('viewer advanced while paused');
    await control('Restart');
    restarted = await page.evaluate(() => window.fortressOnline.viewer);
    if (restarted.frame !== 0 || restarted.state !== initial.state || restarted.playing) throw new Error('viewer restart failed');
    await choose(Buffer.from('malformed replay'));
    await page.waitForFunction(() => window.fortressOnline.viewer.message.includes('Could not open'), null, { timeout: 10000 });
    rejected = await page.evaluate(() => window.fortressOnline.viewer);
    if (rejected.frames !== initial.frames || rejected.frame !== 0 || rejected.state !== initial.state)
      throw new Error('failed import replaced the recording');
    await control('Play');
    await page.waitForFunction(() => window.fortressOnline.viewer.message.startsWith('Replay complete.'), null, { timeout: 30000 });
    completed = await page.evaluate(() => window.fortressOnline.viewer);
    if (completed.playing || completed.frame !== initial.frames || completed.state !== recording.playback.canonical)
      throw new Error('viewer differs from independently validated replay');
    await command(page, 'viewer_target', { frame: 6 });
    await control('Go');
    await page.waitForFunction(() => window.fortressOnline.viewer.frame === 6, null, { timeout: 10000 });
    backward = await page.evaluate(() => window.fortressOnline.viewer);
    await command(page, 'viewer_target', { frame: 12 });
    await control('Go');
    await page.waitForFunction(() => window.fortressOnline.viewer.frame === 12, null, { timeout: 10000 });
    forward = await page.evaluate(() => window.fortressOnline.viewer);
    if (forward.playing || backward.playing) throw new Error('navigation did not finish paused');
    await page.screenshot({ path: diagnostic.replace('-events.log', '-viewer.png') });
  });
  return { initial, stepped, paused, restarted, rejected, completed, forward, backward };
}

async function inspectDiagnostic(page, command, report, diagnostic, timings) {
  const control = button => command(page, 'diagnostic_control', { button });
  const choose = async data => {
    const pending = page.waitForEvent('filechooser', { timeout: 10000 });
    await control('Open diagnostic');
    const chooser = await pending;
    await chooser.setFiles({ name: 'fortress-diagnostics.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(data)) });
  };
  const observe = () => page.evaluate(() => window.fortressOnline.diagnostic_viewer);
  let initial, stepped, restarted, rejected, completed, diverged;
  await measured(timings, 'diagnostic_viewer_us', async () => {
    await command(page, 'inspect_diagnostic');
    await choose(report);
    await page.waitForFunction(() => window.fortressOnline.diagnostic_viewer.status.loaded, null, { timeout: 10000 });
    initial = await observe();
    await control('Step');
    stepped = await observe();
    await control('Restart');
    restarted = await observe();
    await choose({ invalid: true });
    await page.waitForFunction(() => window.fortressOnline.diagnostic_viewer.message.includes('This viewer needs'), null, { timeout: 10000 });
    rejected = await observe();
    await control('Play');
    await page.waitForFunction(() => window.fortressOnline.diagnostic_viewer.status.complete, null, { timeout: 15000 });
    completed = await observe();
    await page.screenshot({ path: diagnostic.replace('-events.log', '-diagnostic-viewer.png') });
    const corrupt = JSON.parse(JSON.stringify(report));
    const changed = corrupt.trace.frames.find((row, index) => index > 0 && row.state_available);
    if (!changed) throw new Error('diagnostic window needs a later canonical boundary');
    const bytes = Buffer.from(changed.state, 'hex'); bytes[24] ^= 1; changed.state = bytes.toString('hex');
    await choose(corrupt);
    await page.waitForFunction(() => window.fortressOnline.diagnostic_viewer.status.rows_consumed === 0, null, { timeout: 10000 });
    await control('Play');
    await page.waitForFunction(() => window.fortressOnline.diagnostic_viewer.status.failure.kind === 'state', null, { timeout: 15000 });
    diverged = await observe();
    if (diverged.status.failure.frame !== changed.frame || diverged.status.failure.byte !== 24)
      throw new Error('diagnostic viewer did not localize deliberately corrupted canonical bytes');
  });
  return { initial, stepped, restarted, rejected, completed, diverged };
}

async function collectReplay(pages, command, diagnostic) {
  const page = pages[1];
  const before = await page.evaluate(() => ({ state: window.fortressOnline.state, frame: window.fortressOnline.frame,
    restores: window.fortressOnline.restores }));
  if (before.state !== 'failed') throw new Error('replay download requires a stopped failed match');
  const disabledPeer = await pages[0].evaluate(() => !window.fortressOnline.replay_enabled);
  const peers = await Promise.all(pages.map(peer => peer.evaluate(() => ({ slot: window.fortressOnline.slot, inputs: window.fortressOnline.inputs }))));
  const pending = page.waitForEvent('download', { timeout: 10000 });
  await command(page, 'replay');
  const download = await pending;
  const bytes = fs.readFileSync(await download.path());
  if (bytes.length > 16384) throw new Error('online witness replay exceeds its short-match byte bound');
  await download.saveAs(diagnostic.replace('-events.log', '-replay.frrp'));
  await command(page, 'validate_replay', { hex: bytes.toString('hex') });
  // Value: real exported commands accept hex/JSON overhead and reject excess; earlier short replays missed the envelope limit; seam=none.
  const playback = await page.evaluate(() => window.fortressOnline.replay_playback);
  const commandLimit = 2 * 16384 + 1024;
  const boundary = await page.evaluate(({ hex, limit }) => {
    const id = window.fortressOnlineCommand.id + 1;
    const value = { hex, padding: '', kind: 'validate_replay', id };
    value.padding = ' '.repeat(limit - JSON.stringify(value).length);
    return value;
  }, { hex: bytes.toString('hex'), limit: commandLimit });
  await command(page, 'validate_replay', { hex: boundary.hex, padding: boundary.padding });
  const accepted = await page.evaluate(() => ({ length: JSON.stringify(window.fortressOnlineCommand).length,
    playback: window.fortressOnline.replay_playback, id: window.fortressOnline.command_id }));
  if (accepted.length !== commandLimit || JSON.stringify(accepted.playback) !== JSON.stringify(playback))
    throw new Error('maximum command envelope did not preserve actual replay playback');
  await page.evaluate(limit => {
    window.fortressOnlineEnvelopeObservation = window.fortressOnline;
    const value = window.fortressOnlineCommand;
    value.id += 1;
    value.padding = '';
    value.padding = ' '.repeat(limit + 1 - JSON.stringify(value).length);
  }, commandLimit);
  await page.waitForFunction(() => window.fortressOnline !== window.fortressOnlineEnvelopeObservation, null, { timeout: 10000 });
  const rejected = await page.evaluate(() => ({ length: JSON.stringify(window.fortressOnlineCommand).length,
    id: window.fortressOnline.command_id }));
  if (rejected.length !== commandLimit + 1 || rejected.id !== accepted.id)
    throw new Error('oversized command envelope was accepted');
  for (const [length, expected] of [[16384, 1], [16385, 3]]) {
    await command(page, 'validate_replay', { hex: Buffer.alloc(length).toString('hex') });
    const result = await page.evaluate(() => window.fortressOnline.replay_playback);
    if (result.decode_code !== expected) throw new Error(`binary replay boundary ${length}: ${JSON.stringify(result)}`);
  }
  await command(page, 'validate_replay', { hex: bytes.toString('hex') });
  const after = await page.evaluate(() => ({ state: window.fortressOnline.state, frame: window.fortressOnline.frame,
    restores: window.fortressOnline.restores }));
  return { command_boundaries: { accepted: accepted.length, rejected: rejected.length, binary_limit: 16384 },
    filename: download.suggestedFilename(), hex: bytes.toString('hex'), before, after, disabled_peer: disabledPeer, peers,
    playback: await page.evaluate(() => window.fortressOnline.replay_playback) };
}

async function main() {
  const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const root = path.resolve(process.argv[2]);
  const endpoint = process.argv[3];
  const corrupt = process.argv[4] === 'corrupt';
  const diagnostic = process.argv[5];
  const errors = [];
  const logs = [];
  const { server, proxyPairs, proxy } = await createHost(root, endpoint, process.env.FORTRESS_TLS_CERT, process.env.FORTRESS_TLS_KEY);
  const browsers = [], pages = [], sessions = [], rounds = [];
  let nextCommand = 0;
  const command = async (page, kind, values = {}) => {
    const id = ++nextCommand;
    await page.evaluate(value => { window.fortressOnlineCommand = value; }, { ...values, kind, id });
    await page.waitForFunction(expected => window.fortressOnline?.command_id === expected, id, { timeout: 10000 });
  };
  const wait = async (page, expression, timeout = 30000, argument = null) => {
    await page.waitForFunction(expression, argument, { timeout });
    if (errors.length) throw new Error(JSON.stringify(errors));
  };
  // Value: a rejected wait names the observed peers, so a timing failure is diagnosable from the artifact.
  const observe = async () => Promise.all(pages.map((page, index) => page.evaluate(pageIndex => ({
    page_index: pageIndex, state: window.fortressOnline?.state, frame: window.fortressOnline?.frame,
    confirmed: window.fortressOnline?.confirmed, restores: window.fortressOnline?.restores,
    corrupt: window.fortressOnline?.corrupt, terminal_reason: window.fortressOnline?.terminal_reason,
    failure: window.fortressOnline?.failure, inputs: (window.fortressOnline?.inputs || []).slice(-8),
  }), index).catch(() => null)));
  const suspend = async (label, duration) => {
    await Promise.all(pages.map(page => page.evaluate(value => { window.fortressOnlineResumeLabel = value; }, label)));
    await Promise.all(sessions.map(async session => {
      const paused = new Promise(resolve => session.once('Debugger.paused', resolve));
      await session.send('Debugger.pause');
      await paused;
    }));
    const elapsed = await pauseElapsed(duration);
    await Promise.all(sessions.map(session => session.send('Debugger.resume')));
    await Promise.all(pages.map(page => page.waitForFunction(value => window.fortressOnline?.resume?.label === value.label
      && window.fortressOnline.resume.gap_us >= value.minimum, { label, minimum: duration * 1000 }, { timeout: 30000 })));
    return { label, method: 'cdp-debugger-pause', requested_ms: duration, frozen_elapsed_us: elapsed,
      peers: await Promise.all(pages.map(page => page.evaluate(() => ({ ...window.fortressOnline.resume,
        session_id: window.fortressOnline.session_id, epoch_us: window.fortressOnline.epoch_us })))) };
  };
  try {
    for (let index = 0; index < 2; index++) {
      const browser = await chromium.launch({ headless: true, timeout: 30000, executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
        args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-background-timer-throttling'] });
      browsers.push(browser);
      const context = await browser.newContext({ ignoreHTTPSErrors: true });
      const page = await context.newPage();
      const session = await context.newCDPSession(page);
      await session.send('Debugger.enable');
      sessions.push(session);
      page.on('pageerror', error => errors.push(String(error)));
      page.on('console', message => {
        const text = message.text();
        fs.appendFileSync(diagnostic, JSON.stringify({ index, text }) + '\n');
        if (logs.length < 128) logs.push(text);
        if (text.includes('SCRIPT ERROR:') || text.startsWith('ERROR:')) errors.push(text);
      });
      // Only the joiner corrupts its restored state, so the clean peer stays a healthy observer and the
      // desync between them is a certainty rather than a coincidence of two matching corruptions.
      await registerOnlineInit(page, { endpoint, count: 2, index, faults: false, corrupt: false,
        defaultFactory: false, mixed: false, mixedDefault: false, disableFallback: false, onlineCorrupt: corrupt && index === 1 });
      pages.push(page);
      await page.goto(`https://127.0.0.1:${server.address().port}/index.html`);
      await wait(page, () => window.fortressOnlineReady === true);
    }
    const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
    for (let round = 0; round < (corrupt ? 1 : 5); round++) {
      await command(pages[0], 'create', { endpoint: socketEndpoint, name: 'Creator' });
      await wait(pages[0], () => window.fortressOnline.state === 'lobby' && window.fortressOnline.room !== '');
      const room = await pages[0].evaluate(() => window.fortressOnline.room);
      await command(pages[1], 'join', { endpoint: socketEndpoint, name: 'Joiner', room });
      await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.ready_enabled)));
      await Promise.all(pages.map((page, index) => command(page, 'ready', {
        capture_trace: !corrupt && round === 0 && index === 0, record_replay: !corrupt && round === 0 && index === 1 })));
      // The room identity is observed while the room is open, so a round that ends in a failure keeps its evidence.
      const identity = await Promise.all(pages.map((page, index) => page.evaluate(pageIndex => ({
        page_index: pageIndex, room: window.fortressOnline.room, room_id: window.fortressOnline.room_id,
        uuid: window.fortressOnline.uuid }), index)));
      await wait(pages[0], () => window.fortressOnline.start_enabled);
      await pages[0].keyboard.down('KeyD');
      await pages[1].keyboard.down('KeyW');
      await Promise.all(pages.map(page => page.evaluate(expected => window.fortressPredictionGate.arm(expected), { room, room_id: identity[0].room_id })));
      await command(pages[0], 'start');
      // Keep handshake service live while originals are held. Both actual simulation callbacks
      // must consume a predicted remote input before either sender releases its original bytes.
      await Promise.all(pages.map(page => wait(page, () => window.fortressPredictionGate.current().predicted_frame >= 2
        && window.fortressOnline.predicted_lifetime === window.fortressOnline.game_lifetime, 90000)));
      if (corrupt) {
        // Originals still bound advancement to the prediction window. Install both physical second
        // directions before correction can resume either peer and reach the first checksum exchange.
        await Promise.all([pages[0].keyboard.up('KeyD'), pages[1].keyboard.up('KeyW')]);
        await Promise.all([pages[0].keyboard.down('KeyS'), pages[1].keyboard.down('KeyA')]);
      }
      const prediction = await Promise.all(pages.map((page, index) => page.evaluate(pageIndex => {
        const frame = window.fortressOnline.predicted_frame;
        const before = window.fortressPredictionGate.summary();
        window.fortressPredictionGate.release();
        return { page_index: pageIndex, frame, before, after: window.fortressPredictionGate.summary() };
      }, index)));
      await Promise.all(pages.map(page => wait(page, target => window.fortressOnline.frame >= target, 90000, corrupt ? 12 : 45)));
      if (round === 3 && !corrupt) await Promise.all(pages.map(page => command(page, 'capture_callbacks')));
      if (round === 4 && !corrupt) {
        const payloads = rounds[3].server_restart.boundary.map(value => value.fault.held[0]);
        await Promise.all(pages.map((page, index) => page.evaluate(payload => {
          window.fortressStaleExpected = payload; window.fortressStaleReceived = 0;
        }, payloads[1 - index])));
        await Promise.all(pages.map((page, index) => page.evaluate(payload => {
          const channel = window.fortressResources.channels.slice(-3).find(value => value.id === 3);
          const bytes = Uint8Array.from(payload.match(/../g), value => parseInt(value, 16));
          window.fortressStaleSent = payload;
          channel.send(bytes);
        }, payloads[index])));
        await Promise.all(pages.map(page => command(page, 'old_callbacks')));
      }
      const suspension = round === 0 && !corrupt ? await suspend('short', 750) : null;
      if (!corrupt) {
        await pages[0].keyboard.up('KeyD');
        await pages[1].keyboard.up('KeyW');
        await pages[0].keyboard.down('KeyS');
        await pages[1].keyboard.down('KeyA');
      }
      await Promise.all(pages.map(page => wait(page, target => window.fortressOnline.confirmed >= target, 90000, corrupt ? 20 : 100)));
      let desyncPage = -1;
      if (corrupt) {
        // The corruption is applied while a peer restores a snapshot. Every peer must reach one restore
        // before the control judges the round, so the outcome never depends on when a remote input arrives.
        await Promise.all(pages.map(page => page.waitForFunction(() => window.fortressOnline?.restores >= 1, null, { timeout: 90000 })
          .catch(async error => { throw new Error(`the corrupt control observed no restore: ${JSON.stringify(await observe())}`); })));
        if (errors.length) throw new Error(JSON.stringify(errors));
        // The corrupted state must be caught by the production desync detection before the round is judged.
        desyncPage = await Promise.any(pages.map((page, position) => page.waitForFunction(() => {
          const value = window.fortressOnline;
          return value?.state === 'failed' && value?.terminal_reason === 18;
        }, null, { timeout: 90000 }).then(() => position))).catch(async () => {
          throw new Error(`the corrupt control observed no desync: ${JSON.stringify(await observe())}`);
        });
        if (errors.length) throw new Error(JSON.stringify(errors));
      }
      await Promise.all([pages[0].keyboard.up('KeyS'), pages[1].keyboard.up('KeyA')]);
      if (round === 0 && !corrupt) await pages[0].screenshot({ path: diagnostic.replace('-events.log', '.png') });
      const peers = await Promise.all(pages.map((page, index) => page.evaluate(pageIndex => ({ ...window.fortressOnline, page_index: pageIndex,
        rtc: { ...window.fortressRtc, channels: window.fortressRtc.channels.slice(-3) }, delayed: window.fortressOnlineDelayed }), index)));
      rounds.push({ room, peers, diagnostics: [], identity, prediction });
      if (corrupt) {
        rounds[round].corrupt_control = { restores: peers.map(peer => peer.restores),
          corrupt_page: peers.find(peer => peer.corrupt)?.page_index, desync_page: desyncPage,
          desync_reason: peers[desyncPage].terminal_reason };
      }
      if (round === 4 && !corrupt) {
        rounds[round].stale_sent = await Promise.all(pages.map(page => page.evaluate(() => window.fortressStaleSent)));
        rounds[round].stale_received = await Promise.all(pages.map(page => page.evaluate(() => window.fortressStaleReceived)));
      }
      if (suspension) rounds[round].suspension = suspension;
      if (round === 0 && !corrupt) {
        const captureBefore = await pages[1].evaluate(() => ({ frame: window.fortressOnline.frame,
          restores: window.fortressOnline.restores }));
        await command(pages[1], 'finish_replay');
        await wait(pages[1], () => window.fortressOnline.replay_captured);
        rounds[round].replay_capture = await pages[1].evaluate(before => ({ before,
          frame: window.fortressOnline.frame, code: window.fortressOnline.replay_capture_code,
          captured: window.fortressOnline.replay_captured }), captureBefore);
        await command(pages[0], 'leave');
        await wait(pages[1], () => window.fortressOnline.state === 'failed');
        const before = await pages[1].evaluate(() => ({ state: window.fortressOnline.state,
          message: window.fortressOnline.message, frame_before: window.fortressOnline.frame }));
        await pages[1].waitForTimeout(250);
        const after = await pages[1].evaluate(() => ({ state: window.fortressOnline.state, frame_after: window.fortressOnline.frame }));
        rounds[round].terminal = { ...before, ...after };
        rounds[round].replay_download = await collectReplay(pages, command, diagnostic);
        for (const original of rounds[round].replay_download.peers)
          rounds[round].peers.find(peer => peer.slot === original.slot).inputs = original.inputs;
        await command(pages[1], 'leave');
      } else {
        if (!corrupt && round === 1) {
          rounds[round].suspension = await suspend('expired', 2500);
          await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'failed')));
          await Promise.all(pages.map(page => wait(page, () =>
            window.fortressResources.channels.every(channel => channel.readyState === 'closed')
            && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'
              && connection.iceConnectionState === 'closed')
            && window.fortressResources.websockets.every(socket => socket.readyState === WebSocket.CLOSED))));
          rounds[round].failure_resources = await Promise.all(pages.map(page => page.evaluate(resourceCounts)));
          const before = await Promise.all(pages.map(page => page.evaluate(() => window.fortressOnline.frame)));
          await pauseElapsed(250);
          rounds[round].frozen_frames = await Promise.all(pages.map((page, index) => page.evaluate(frame => ({
            before: frame, after: window.fortressOnline.frame, state: window.fortressOnline.state }), before[index])));
        } else if (!corrupt && round === 2) {
          const pairs = Array.from(proxyPairs);
          if (pairs.length !== 2) throw new Error('socket loss requires both live signaling proxy pairs');
          const openSockets = await Promise.all(pages.map(page => page.evaluate(() =>
            window.fortressResources.websockets.filter(socket => socket.readyState === WebSocket.OPEN).length)));
          proxy.refuseUpgrades = true;
          const refusedBefore = proxy.refusedUpgrades;
          for (const pair of pairs) { pair.socket.destroy(); pair.upstream.destroy(); }
          await new Promise((resolve, reject) => {
            const probe = https.request({ host: '127.0.0.1', port: server.address().port, path: '/v3/ws', rejectUnauthorized: false,
              headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'AAAAAAAAAAAAAAAAAAAAAA==' } });
            probe.on('error', resolve);
            probe.on('upgrade', () => reject(new Error('proxy accepted an upgrade during socket outage')));
            probe.setTimeout(5000, () => { probe.destroy(); reject(new Error('refused upgrade probe timed out')); });
            probe.end();
          });
          await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'failed')));
          await Promise.all(pages.map(page => wait(page, () =>
            window.fortressResources.channels.every(channel => channel.readyState === 'closed')
            && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'
              && connection.iceConnectionState === 'closed')
            && window.fortressResources.websockets.every(socket => socket.readyState === WebSocket.CLOSED))));
          const before = await Promise.all(pages.map(page => page.evaluate(() => ({
            frame: window.fortressOnline.frame, session_id: window.fortressOnline.session_id }))));
          const heldElapsed = await pauseElapsed(750);
          proxy.refuseUpgrades = false;
          const reopenedElapsed = await pauseElapsed(250);
          const terminal = await Promise.all(pages.map((page, index) => page.evaluate(value => ({
            state: window.fortressOnline.state, message: window.fortressOnline.message,
            frame_before: value.frame, frame_after: window.fortressOnline.frame,
            session_before: value.session_id, session_after: window.fortressOnline.session_id,
          }), before[index])));
          const closed = await Promise.all(pages.map(page => page.evaluate(resourceCounts)));
          rounds[round].socket_loss = { kind: 'signaling-websocket-socket-loss', method: 'tls-proxy-destroy-both-pairs',
            proxy_pairs_before: pairs.length, destroyed_pairs: pairs.filter(pair => pair.socket.destroyed && pair.upstream.destroyed).length,
            proxy_pairs_after: proxyPairs.size, open_websockets_before: openSockets, upgrades_refused: true,
            refused_upgrade_attempts: proxy.refusedUpgrades - refusedBefore, held_elapsed_us: heldElapsed, reopened_elapsed_us: reopenedElapsed,
            reopened: true, before_user_leave: true, terminal, resources: closed };
        }
        if (!corrupt && round === 3) {
          const control = async kind => {
            const response = await fetch(process.env.FORTRESS_SERVER_CONTROL + '/' + kind, { method: 'POST', body: '', signal: AbortSignal.timeout(30000) });
            const value = await response.json();
            if (!response.ok) throw new Error(JSON.stringify(value));
            return value;
          };
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressRestartFault.armed = true; })));
          await Promise.all(pages.map(page => wait(page, () => window.fortressRestartFault.pending > 0)));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressRestartFault.pressure = true; })));
          await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.relay_pending > 0)));
          const boundary = await Promise.all(pages.map(page => page.evaluate(() => ({
            frame: window.fortressOnline.frame, session_id: window.fortressOnline.session_id,
            pending: window.fortressOnline.pending, relay_pending: window.fortressOnline.relay_pending,
            inputs: window.fortressOnline.inputs,
            fault: { ...window.fortressRestartFault },
          }))));
          const stopped = await control('stop');
          await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'failed')));
          const first = await Promise.all(pages.map(page => page.evaluate(() => ({ ...window.fortressOnline }))));
          await Promise.all(pages.map(page => wait(page, () =>
            window.fortressResources.channels.every(channel => channel.readyState === 'closed')
            && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'
              && connection.iceConnectionState === 'closed')
            && window.fortressResources.websockets.every(socket => socket.readyState === WebSocket.CLOSED))));
          const heldElapsed = await pauseElapsed(750);
          await Promise.all(pages.map(page => wait(page, () => window.fortressRestartFault.pending === 0)));
          const started = await control('start');
          const restartedElapsed = await pauseElapsed(250);
          const terminal = await Promise.all(pages.map((page, index) => page.evaluate(before => ({
            state: window.fortressOnline.state, first_message: before.message, message: window.fortressOnline.message,
            frame_before: before.frame, frame_after: window.fortressOnline.frame,
            session_before: before.session_id, session_after: window.fortressOnline.session_id,
            pending: window.fortressOnline.pending, relay_pending: window.fortressOnline.relay_pending,
            delayed_pending: window.fortressRestartFault.pending, delayed_dropped: window.fortressRestartFault.dropped,
          }), first[index])));
          rounds[round].server_restart = { stopped, started, boundary, terminal, held_elapsed_us: heldElapsed,
            restarted_elapsed_us: restartedElapsed, before_user_leave: true,
            resources: await Promise.all(pages.map(page => page.evaluate(resourceCounts))) };
          await Promise.all(pages.map(page => page.evaluate(() => {
            window.fortressRestartFault.armed = false; window.fortressRestartFault.pressure = false;
          })));
        }
        await Promise.all(pages.map(page => command(page, 'leave')));
      }
      await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'offline')));
      await Promise.all(pages.map(page => wait(page, () => window.fortressResources.channels.every(channel => channel.readyState === 'closed')
        && window.fortressResources.connections.every(connection => connection.connectionState === 'closed' && connection.iceConnectionState === 'closed')
        && window.fortressResources.websockets.every(socket => socket.readyState === WebSocket.CLOSED))));
      rounds[round].teardown = await Promise.all(pages.map(page => page.evaluate(resourceCounts)));
      rounds[round].diagnostics = await collectDiagnostics(pages, command);
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    const timings = {};
    const viewer = corrupt ? null : await watchReplay(pages[1], command, rounds[0].replay_download, diagnostic, timings);
    const diagnostic_viewer = corrupt ? null : await inspectDiagnostic(pages[0], command, rounds[0].diagnostics[0].report, diagnostic, timings);
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, corrupt, browser_instances: 2, rounds, viewer, diagnostic_viewer, timings, errors, teardown: true }));
  } catch (error) {
    const states = await Promise.all(pages.map(page => page.evaluate(() => window.fortressOnline).catch(() => null)));
    const resources = await Promise.all(pages.map(page => page.evaluate(resourceCounts).catch(() => null)));
    console.error(JSON.stringify({ failure: String(error), states, resources, errors, logs }));
    throw error;
  } finally {
    await Promise.all(browsers.map(browser => browser.close()));
    await new Promise(resolve => server.close(resolve));
  }
}
module.exports = { pauseElapsed, instrumentSockets, resourceCounts, registerOnlineInit, collectDiagnostics, measured, elapsedMicros };
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
