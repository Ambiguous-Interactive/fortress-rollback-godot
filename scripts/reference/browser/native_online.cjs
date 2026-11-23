const assert = require('node:assert/strict');
const { setImmediate: flush } = require('node:timers/promises');
const { createHost } = require('./online_host.cjs');
const { placeFirefox } = require('./webrtc_display.cjs');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const INPUTS = [[1, ['KeyA']], [2, ['KeyD']], [4, ['KeyW']], [8, ['KeyS']],
  [5, ['KeyA', 'KeyW']], [6, ['KeyD', 'KeyW']], [9, ['KeyA', 'KeyS']], [10, ['KeyD', 'KeyS']]];
const GATE_FRAME = 12;
const HISTORY_FRAMES = 40;
const PAGE_BOOT_MS = 60000;
const DIAGNOSTIC_MS = 5000;
const CLOSE_MS = 10000;
const WEBKIT_CLOSED_STREAM = 'Error sending binary data through RTCDataChannel.';

function browserOptions(name) {
  const executablePath = process.env[`FORTRESS_${name.toUpperCase()}_EXECUTABLE`];
  if (!executablePath) throw new Error(`missing executable for ${name}`);
  switch (name) {
    case 'chromium':
      return { executablePath, headless: true,
        args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
          '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'] };
    case 'firefox':
      return { executablePath, headless: false,
        firefoxUserPrefs: { 'webgl.force-enabled': true, 'webgl.disabled': false, 'toolkit.shutdown.fastShutdownStage': 0 } };
    case 'webkit':
      return { executablePath, headless: false };
  }
  throw new Error(`unknown browser ${name}`);
}

function instrumentNativeWire() {
  const active = [];
  const resources = { rtc: [], sockets: [] };
  const ice = new Map();
  let session, localUuid;
  let holding = false;
  let holdAll = false;
  let armed = false;
  let holdStarted = null;
  let holdEnded = null;
  let totalBytes = 0;
  let released = 0;
  const counts = { mesh: 0, relay: 0 };
  const relayRecipients = new Map();
  const relaySenders = new Map();
  const held = { mesh: 0, relay: 0 };
  const controlDuringHold = { sent: 0, received: 0 };
  const nativeBytes = bytes => bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
    : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
  const matches = (bytes, offset) => session && offset + session.length < bytes.length
    && session.every((byte, index) => bytes[offset + index] === byte);
  const inputKind = 2;
  function nativeKind(bytes, offset) {
    // The pinned Fortress codec uses an eight-byte header and a little-endian u32 body tag.
    const at = offset + session.length;
    if (bytes.length < at + 12 || bytes[at] !== 0xf5 || bytes[at + 1] !== 0x52 || bytes[at + 2] !== 2 || bytes[at + 3] !== 0) {
      throw new Error('native gameplay wire header differs from the pinned codec');
    }
    return new DataView(bytes.buffer, bytes.byteOffset + at + 8, 4).getUint32(0, true);
  }
  const hex = bytes => Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  function relayAddresses(data) {
    const view = nativeBytes(data);
    if (!session || !view) return null;
    // The SDK binary envelope precedes FSR1, followed by the tagged native payload.
    for (let index = 0; index + 73 < view.length; index++) {
      if (view[index] === 70 && view[index + 1] === 83 && view[index + 2] === 82 && view[index + 3] === 49
          && view[index + 4] === 1 && matches(view, index + 5) && matches(view, index + 57)) {
        return { sender: hex(view.subarray(index + 21, index + 37)), recipient: hex(view.subarray(index + 37, index + 53)),
          kind: nativeKind(view, index + 57) };
      }
    }
    return null;
  }
  const increment = (counts, uuid) => counts.set(uuid, (counts.get(uuid) ?? 0) + 1);
  const ufrag = description => description?.sdp.match(/^a=ice-ufrag:([\w+/]+)\r?$/m)?.[1];
  function receive(kind) {
    if (holding && !holdAll && kind !== inputKind) controlDuringHold.received++;
  }
  function send(route, emit, data, kind) {
    if (kind === null) return emit(data);
    counts[route]++;
    if (!holding) return emit(data);
    if (!holdAll && kind !== inputKind) {
      const sent = emit(data);
      controlDuringHold.sent++;
      return sent;
    }
    if (active.length >= 1024 || totalBytes + data.byteLength > 1024 * 1024) throw new Error('native packet hold exceeded bounds');
    const owned = nativeBytes(data).slice();
    active.push(() => emit(owned));
    totalBytes += owned.byteLength;
    held[route]++;
  }
  const createChannel = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    if (!ice.has(this)) {
      const record = { state: this.iceConnectionState, gathering: this.iceGatheringState, host: 0, srflx: 0, prflx: 0, relay: 0, other: 0, mdns: 0 };
      ice.set(this, record);
      this.addEventListener('iceconnectionstatechange', () => {
        if (this.iceConnectionState !== 'closed') record.state = this.iceConnectionState;
      });
      this.addEventListener('icegatheringstatechange', () => { record.gathering = this.iceGatheringState; });
      this.addEventListener('icecandidate', ({ candidate }) => {
        if (!candidate?.candidate) return;
        const [, address, type] = candidate.candidate.match(/^candidate:\S+ \S+ \S+ \S+ (\S+) \S+ typ (\S+)/) ?? [];
        record[['host', 'srflx', 'prflx', 'relay'].includes(type) ? type : 'other']++;
        if (address?.endsWith('.local')) record.mdns++;
      });
    }
    const channel = createChannel.call(this, label, options);
    const record = { channel, connection: this, sent: 0, received: 0, local: null, remote: null, closeAborts: 0 };
    channel.addEventListener('error', ({ error }) => {
      if (channel.id === 3 && error?.errorDetail === 'sctp-failure' && error.message === 'User-Initiated Abort, reason=Close called') record.closeAborts++;
    });
    channel.addEventListener('message', ({ data }) => {
      const view = nativeBytes(data);
      if (channel.id === 3 && view && matches(view, 0)) {
        record.received++;
        receive(nativeKind(view, 0));
      }
    });
    resources.rtc.push(record);
    const nativeSend = channel.send;
    channel.send = data => {
      const view = nativeBytes(data);
      const kind = channel.id === 3 && view && matches(view, 0) ? nativeKind(view, 0) : null;
      return send('mesh', bytes => {
        nativeSend.call(channel, bytes);
        if (kind !== null) record.sent++;
      }, data, kind);
    };
    return channel;
  };
  const nativeSocket = WebSocket;
  const socketClose = nativeSocket.prototype.close;
  let deferredClose;
  let holdTerminalClose = false;
  nativeSocket.prototype.close = function(code, reason) {
    if (holdTerminalClose && code === 1000 && reason === 'Online example failed') {
      if (deferredClose) throw new Error('native terminal tried to close twice');
      // Godot already cleared this receive buffer. The browser would stop messages on close.
      this.onmessage = null;
      deferredClose = () => socketClose.call(this, code, reason);
      return;
    }
    return socketClose.call(this, code, reason);
  };
  window.WebSocket = new Proxy(nativeSocket, { construct(target, args, newTarget) {
    const socket = Reflect.construct(target, args, newTarget);
    resources.sockets.push(socket);
    socket.addEventListener('message', ({ data }) => {
      const packet = relayAddresses(data);
      if (packet && packet.recipient === localUuid) {
        increment(relaySenders, packet.sender);
        receive(packet.kind);
      }
    });
    return socket;
  } });
  const socketSend = nativeSocket.prototype.send;
  nativeSocket.prototype.send = function(data) {
    const packet = relayAddresses(data);
    return send('relay', bytes => {
      socketSend.call(this, bytes);
      if (packet) increment(relayRecipients, packet.recipient);
    }, data, packet?.kind ?? null);
  };
  window.fortressNativeWire = {
    bind(hash, uuid) {
      if (session || !/^[0-9a-f]{32}$/.test(hash)) throw new Error('invalid native room session');
      localUuid = uuid.replaceAll('-', '');
      session = hash.match(/../g).map(value => parseInt(value, 16));
    },
    meshOpen(peers) {
      return resources.rtc.filter(({channel, connection}) => channel.readyState === 'open' && connection.connectionState === 'connected').length === peers * 3;
    },
    arm(all = false) {
      if (!armed) {
        armed = true;
        holdAll = all;
        holding = true;
        holdStarted = performance.now();
      }
    },
    release() {
      if (!holding || !active.length) throw new Error('native packet hold did not take effect');
      holding = false;
      for (const emit of active) {
        emit();
        released++;
      }
      active.length = 0;
      holdEnded = performance.now();
    },
    // Let every peer report native expiry before a socket close can cause a room-departure event.
    holdTerminal() {
      holdTerminalClose = true;
      this.arm(true);
    },
    releaseTerminal() {
      if (!deferredClose) throw new Error('native terminal did not close its SDK socket');
      holdTerminalClose = false;
      deferredClose();
    },
    status() {
      const holdMs = holdStarted === null ? null : Math.round((holdEnded ?? performance.now()) - holdStarted);
      const sctp = resources.rtc.filter(({channel}) => channel.id === 3).map(record => {
        if ((!record.local || !record.remote) && record.connection.signalingState !== 'closed') {
          record.local = ufrag(record.connection.localDescription) ?? record.local;
          record.remote = ufrag(record.connection.remoteDescription) ?? record.remote;
        }
        return { local: record.local, remote: record.remote, closeAborts: record.closeAborts };
      });
      return { armed, holding, hold_ms: holdMs, deferredClose: Boolean(deferredClose), counts: { ...counts }, held: { ...held }, released, totalBytes,
        control_during_hold: { ...controlDuringHold },
        relayRecipients: Object.fromEntries(relayRecipients), relaySenders: Object.fromEntries(relaySenders),
        ice: [...ice.values()], sctp,
        rtc: resources.rtc.map(({channel, sent, received}) => [channel.id, channel.readyState, sent, received]),
        sockets: resources.sockets.map(socket => socket.readyState) };
    },
  };
}

function receivedDepartureAbort(before, after, departing) {
  const expected = before.filter(({local, remote}) => local && remote
    && departing.some(peer => peer.local === remote && peer.remote === local));
  if (expected.length !== 1) return false;
  const link = expected[0];
  return after.some(peer => peer.local === link.local && peer.remote === link.remote && peer.closeAborts > link.closeAborts);
}

function historyThrough(peers) {
  // Each observed frame is the next sample. Compare at least one later sample from every slot.
  const frames = Math.max(HISTORY_FRAMES, ...peers.map(peer => peer.frame + 2));
  assert.ok(peers.every(peer => frames <= peer.history_limit), 'post-fault samples exceeded the recorded history limit');
  return frames;
}

function compareHistory(peers, frames = HISTORY_FRAMES) {
  const ordered = [...peers].sort((first, second) => first.slot - second.slot);
  assert.deepEqual(ordered.map(peer => peer.slot), peers.map((_, index) => index), 'slots must cover the frozen roster');
  assert.equal(new Set(peers.map(peer => peer.uuid)).size, peers.length, 'each page must own a distinct player');
  assert.equal(new Set(peers.map(peer => peer.session_id)).size, 1, 'native schema/roster identity must agree');
  assert.match(peers[0].session_id, /^[0-9a-f]{32}$/);
  assert.equal(new Set(peers.map(peer => peer.room_id)).size, 1, 'all peers must be in the same SignalFish room');
  assert.ok(peers[0].room_id);
  for (let frame = 0; frame < frames; frame++) {
    const expected = ordered.map(peer => frame >= GATE_FRAME && frame % 2 === 0 ? 0 : INPUTS[peer.index][0]);
    for (const peer of peers) {
      assert.deepEqual(peer.rows[frame], expected, `input row at frame ${frame}, slot ${peer.slot}`);
      assert.match(peer.snapshots[frame + 1], /^(?:[0-9a-f]{2})+$/);
      assert.equal(peer.snapshots[frame + 1], peers[0].snapshots[frame + 1], `canonical state at frame ${frame + 1}, slot ${peer.slot}`);
    }
  }
}

async function closeAll(items, close, kind) {
  const settled = await Promise.allSettled(items.map((item, index) =>
    boundedRoom(() => close(item), CLOSE_MS, `native ${kind} ${index} close`)));
  return settled.filter(result => result.status === 'rejected').map(result => result.reason);
}

async function run(root, endpoint, mode, players, browserPair) {
  const startup = mode === 'mesh-startup';
  const liveClose = mode === 'mesh-close';
  const mixed = startup || liveClose;
  const route = mixed ? 'mesh' : mode;
  const playwright = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const { server, proxyPairs } = await createHost(root, endpoint, process.env.FORTRESS_TLS_CERT, process.env.FORTRESS_TLS_KEY);
  const origin = `https://127.0.0.1:${server.address().port}`;
  const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
  const pages = [];
  const bootstrap_ms = [];
  const contexts = [];
  const errors = [];
  const departureErrors = [];
  const failures = [];
  const browsers = [];
  const browserPeers = [];
  let result;
  let phase = 'launch';
  let sequence = 0;
  const wait = async (page, condition, argument = null, timeout = 30000) => {
    const handle = await page.waitForFunction(condition, argument, { timeout });
    await handle.dispose();
    if (errors.length) throw new Error(JSON.stringify(errors));
  };
  const command = async (page, kind, values = {}) => {
    const id = ++sequence;
    await page.evaluate(value => { window.fortressNativeCommand = value; }, { id, kind, ...values });
    await wait(page, expected => window.fortressNative?.command_id === expected, id);
    const state = await page.evaluate(() => window.fortressNative);
    assert.equal(state.command_code, 0, `${kind} failed: ${state.message}`);
  };
  const observe = (group = pages) => Promise.all(group.map((page, index) => page.evaluate(index => ({
    index, ...window.fortressNative, wire: window.fortressNativeWire.status()
  }), index)));
  try {
    for (const name of browserPair) browsers.push(await playwright[name].launch(browserOptions(name)));
    for (let index = 0; index < players; index++) {
      const started = performance.now();
      const browser = browsers[index % browsers.length];
      const name = browser.browserType().name();
      const viewport = { width: 480, height: 360 };
      const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport });
      contexts.push(context);
      const page = await context.newPage();
      pages.push(page);
      const display = name === 'firefox' ? await placeFirefox(page, index) : null;
      browserPeers.push({ index, name, version: browser.version(), display });
      page.on('pageerror', error => {
        const expectedClosure = phase === 'departure' && route === 'mesh' && index < players - 1
          && name === 'webkit' && error.name === '' && error.message === WEBKIT_CLOSED_STREAM;
        const errorList = expectedClosure ? departureErrors : errors;
        errorList.push({ index, phase, text: String(error) });
      });
      page.on('console', message => {
        const text = message.text();
        if (text.includes('SCRIPT ERROR:') || text.startsWith('ERROR:')) errors.push({ index, phase, text });
      });
      page.on('requestfailed', request => {
        const url = new URL(request.url());
        errors.push({ index, phase, host: url.host, path: url.pathname, method: request.method(), resource: request.resourceType(),
          code: request.failure()?.errorText });
      });
      await page.addInitScript(instrumentNativeWire);
      await page.goto(`${origin}/index.html`);
      await wait(page, () => window.fortressNativeReady === true, null, PAGE_BOOT_MS);
      bootstrap_ms.push(Math.round(performance.now() - started));
    }
    phase = 'lobby';
    function connect(page, index, room) {
      return command(page, 'connect', { endpoint: socketEndpoint, name: `Player ${index}`, room, route, players,
        wait_for_full_mesh: mode === 'mesh' });
    }
    await connect(pages[0], 0, '');
    await wait(pages[0], () => window.fortressNative.state === 'lobby' && window.fortressNative.room !== '');
    const room = await pages[0].evaluate(() => window.fortressNative.room);
    await Promise.all(pages.slice(1).map((page, index) => connect(page, index + 1, room)));
    await Promise.all(pages.map(page => wait(page, () => window.fortressNative.ready_enabled)));
    await Promise.all(pages.map(page => command(page, 'ready')));
    await wait(pages[0], () => window.fortressNative.start_enabled);
    await Promise.all(pages.map(async (page, index) => {
      for (const key of INPUTS[index][1]) await page.keyboard.down(key);
    }));
    const joined = mixed ? await observe() : [];
    const roster = joined.map(peer => peer.uuid).sort();
    if (startup) {
      await command(pages[0], 'block_startup', { uuid: joined[1].uuid });
      await command(pages[1], 'block_startup', { uuid: joined[0].uuid });
    }
    phase = startup ? 'startup with one closed channel pair' : 'warmup';
    await command(pages[0], 'start');
    await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
      && window.fortressNative.confirmed >= frame, GATE_FRAME, 45000)));
    let armed, stalled, direct, afterClose;
    let comparedFrames = HISTORY_FRAMES;
    if (liveClose) {
      phase = 'physical channel close';
      direct = await observe();
      for (const peer of direct) {
        assert.deepEqual(peer.relay_peers, [], 'the room must begin on direct links');
        assert.ok(peer.wire.counts.mesh > 0 && peer.wire.counts.relay === 0);
        assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      }
      await command(pages[0], 'close_link', { uuid: joined[1].uuid });
      await Promise.all(pages.slice(0, 2).map(page => wait(page, count => window.fortressNativeWire.status().rtc
        .filter(([id, state]) => id === 3 && state === 'closed').length === count, 1)));
      afterClose = await observe();
      comparedFrames = historyThrough(afterClose);
    }
    if (!mixed) {
      phase = 'prediction stall';
      // Arming on each local frame can strand a slower peer before its own
      // gate. Let every endpoint confirm the warmup while routes are open.
      armed = await Promise.all(pages.map(page => page.evaluate(() => {
        const { frame, stalls, confirmed } = window.fortressNative;
        window.fortressNativeWire.arm();
        return { frame, stalls, confirmed };
      })));
      await Promise.all(pages.map((page, index) => wait(page, threshold => {
        const { state, stalls, prediction } = window.fortressNative;
        if (state === 'failed') return true;
        if (state !== 'playing' || stalls <= threshold.stalls || prediction < threshold.frame) return false;
        const wire = window.fortressNativeWire.status();
        return wire.held[threshold.route] > 0 && wire.control_during_hold.sent > 0 && wire.control_during_hold.received > 0;
      },
      { route, stalls: armed[index].stalls, frame: GATE_FRAME }, 45000)));
      stalled = await observe();
      for (const peer of stalled) {
        assert.equal(peer.state, 'playing', peer.message);
      }
      comparedFrames = historyThrough(stalled);
      await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.release())));
      phase = 'corrected history';
      await Promise.all(pages.map((page, index) => wait(page, target => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= target.frame && window.fortressNative.restores > target.restores,
      { frame: comparedFrames, restores: stalled[index].restores }, 45000)));
    } else {
      phase = 'mixed confirmed history';
      await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= frame, comparedFrames)));
    }
    // A waiting step can publish confirmation before dispatching a correction.
    const confirmedHistory = await observe();
    await Promise.all(pages.map((page, index) => wait(page, frame => window.fortressNative.state === 'playing'
      && window.fortressNative.frame > frame, confirmedHistory[index].frame)));
    await Promise.all(pages.map(page => page.evaluate(() => { window.fortressNativeCapture = true; })));
    await Promise.all(pages.map(page => wait(page, frame => !!window.fortressNative.snapshots?.[frame], comparedFrames)));
    const peers = await observe();
    compareHistory(peers, comparedFrames);
    const other = route === 'mesh' ? 'relay' : 'mesh';
    for (const peer of peers) {
      assert.equal(peer.movement_errors, 0, 'game must respond to every observed input');
      assert.equal(peer.game_frame, peer.frame, 'driver and game frame must agree');
      if (mixed) {
        const affected = peer.index < 2;
        const expectedCloseState = startup && affected ? 0 : liveClose && peer.index === 0 ? 1 : -1;
        assert.equal(peer.closed_channel_state, expectedCloseState, 'the target channel must close at the specified lifecycle boundary');
        assert.deepEqual(peer.relay_peers, affected ? [joined[1 - peer.index].uuid] : [], 'fallback must target only the closed pair');
        assert.deepEqual(peer.sdk_roster.sort(), roster, 'the original SDK roster must stay in the room');
        if (startup && affected) {
          assert.ok(peer.previous_transport_delay < 3000000 && peer.transport_start_delay >= 3000000, 'fallback must start on the first tick after grace');
        } else {
          assert.ok(peer.open_mesh_wait_ticks <= 2, 'a complete direct mesh must start once the engine observes its channels');
        }
        const recipient = affected ? joined[1 - peer.index].uuid.replaceAll('-', '') : null;
        assert.deepEqual(Object.keys(peer.wire.relayRecipients), recipient ? [recipient] : [], 'relay must send only to the closed pair');
        assert.deepEqual(Object.keys(peer.wire.relaySenders), recipient ? [recipient] : [], 'only the closed pair must receive addressed relay');
        const open = peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open');
        assert.equal(open.length, players - (affected ? 2 : 1));
        assert.ok(open.every(([, , sent, received]) => sent > 0 && received > 0), 'every healthy channel must carry direct gameplay both ways');
        if (liveClose) {
          assert.ok(peer.wire.rtc.every(([id, state, sent, received], index) => id !== 3 || state !== 'open'
            || (sent > afterClose[peer.index].wire.rtc[index][2] && received > afterClose[peer.index].wire.rtc[index][3])),
          'each unaffected channel must exchange gameplay after the close');
          if (peer.index === 0) assert.ok(peer.closed_channel_frame < comparedFrames, 'physical close must precede confirmed history');
        }
        continue;
      }
      const before = stalled[peer.index];
      if (route === 'mesh') {
        assert.ok(peer.started_on_full_mesh, 'the direct-only room must start with every physical channel connected');
        assert.ok(peer.open_mesh_wait_ticks <= 2, 'a complete direct mesh must start when the engine sees its channels');
      }
      assert.ok(peer.saves > 0 && peer.advances > peer.frame && peer.restores > before.restores, 'save, load and re-advance must run');
      assert.ok(before.frame > GATE_FRAME && before.confirmed < before.frame - 1, 'gate must force prediction beyond confirmation');
      assert.ok(before.wire.holding && before.wire.held[route] > 0, 'native bytes must be held on the selected physical route');
      assert.ok(before.wire.control_during_hold.sent > 0 && before.wire.control_during_hold.received > 0, 'control traffic must keep flowing during the input hold');
      assert.ok(!peer.wire.holding && peer.wire.totalBytes > 0 && peer.wire.released === peer.wire.held[route], 'held originals must be released');
      assert.equal(peer.wire.counts[other], 0, 'native traffic must use the selected physical route');
      if (route === 'mesh') assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      else assert.deepEqual(peer.wire.rtc, [], 'initial relay must avoid WebRTC channel creation');
    }
    await Promise.all(pages.map(page => page.evaluate(() => { window.fortressNativeCapture = false; })));
    const survivors = liveClose ? pages : pages.slice(0, -1);
    let interruption;
    if (liveClose) {
      phase = 'native interruption';
      await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.holdTerminal())));
      await Promise.all(pages.map(page => wait(page, () => window.fortressNative.interrupted.length > 0 && window.fortressNative.state === 'playing')));
      interruption = await observe();
      for (const peer of interruption) {
        assert.deepEqual(peer.sdk_roster.sort(), roster);
        assert.deepEqual(peer.wire.sockets, [1], 'SDK signaling must remain connected during the outage');
        assert.ok(peer.wire.holding && peer.wire.held.mesh > 0, 'direct gameplay must be held');
        assert.equal(peer.wire.held.relay > 0, peer.index < 2, 'relay gameplay for the closed pair must also be held');
      }
    } else {
      phase = 'departure';
      const departing = pages.at(-1);
      await command(departing, 'leave');
      await wait(departing, () => window.fortressNative.state === 'offline');
    }
    await Promise.all(survivors.map(page => wait(page, () => window.fortressNative.state === 'failed' && window.fortressNative.terminated)));
    const terminal = await observe(survivors);
    await Promise.all(survivors.map((page, index) => wait(page, turns => window.fortressNative.turns >= turns + 8, terminal[index].turns)));
    const after = await observe(survivors);
    for (const [index, peer] of after.entries()) {
      const before = terminal[index];
      assert.equal(peer.state, 'failed');
      assert.ok(peer.terminated && peer.reason !== 0 && peer.message);
      if (liveClose) {
        assert.equal(peer.terminal_detail, 'disconnected', 'the native protocol must report expiry');
        assert.deepEqual(peer.sdk_roster.sort(), roster, 'the original SDK roster must survive until native expiry');
        assert.deepEqual(peer.wire.sockets, [1], 'SDK room must survive the outage until native expiry');
        assert.ok(peer.wire.deferredClose, 'the app must initiate native terminal cleanup');
        assert.deepEqual([peer.saves, peer.restores, peer.advances], peer.failure_tick_callbacks, 'no callback may run on or after native expiry');
      }
      for (const key of ['frame', 'confirmed', 'reason', 'terminal_detail', 'message', 'game_frame', 'saves', 'restores', 'advances'])
        assert.equal(peer[key], before[key], `terminal ${key} changed for survivor ${index}`);
    }
    for (const { index } of departureErrors) {
      assert.ok(receivedDepartureAbort(peers[index].wire.sctp, after[index].wire.sctp, peers.at(-1).wire.sctp),
        `WebKit send failure for survivor ${index} lacked an observed SCTP abort on the departing link`);
    }
    phase = 'teardown';
    if (liveClose) await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.releaseTerminal())));
    await Promise.all(survivors.map(page => command(page, 'leave')));
    await Promise.all(pages.map(page => wait(page, () => {
      const { sockets, rtc } = window.fortressNativeWire.status();
      return window.fortressNative.state === 'offline' && sockets.every(state => state === WebSocket.CLOSED)
        && rtc.every(([, state]) => state === 'closed');
    })));
    result = { passed: true, route: mode, players, compared_frames: comparedFrames, browser_peers: browserPeers, bootstrap_ms, armed, stalled,
      direct, afterClose, peers, interruption, terminal, after, departureErrors };
  } catch (error) {
    failures.push(error);
    const states = await Promise.allSettled(pages.map((page, index) => boundedRoom(() => page.evaluate(() => ({
      ...window.fortressNative, wire: window.fortressNativeWire?.status()
    })), DIAGNOSTIC_MS, `native peer ${index} diagnostics`)));
    const diagnostics = states.map(state => state.status === 'fulfilled' ? state : { status: state.status, reason: String(state.reason) });
    console.error(JSON.stringify({ phase, browser_peers: browserPeers, bootstrap_ms, errors, departureErrors, states: diagnostics }));
  } finally {
    failures.push(...await closeAll(contexts, context => context.close(), 'context'));
    failures.push(...await closeAll(browsers, owner => owner.close(), 'browser'));
    for (const { socket, upstream } of proxyPairs) {
      socket.destroy();
      upstream.destroy();
    }
    failures.push(...await closeAll([server], owner => new Promise((resolve, reject) =>
      owner.close(error => error ? reject(error) : resolve())), 'host'));
  }
  await flush();
  if (errors.length) failures.push(new Error(JSON.stringify(errors)));
  if (failures.length) throw new AggregateError(failures, `native online witness failed in ${phase}`);
  return result;
}

if (require.main === module) {
  const [root, endpoint, route, size, profile = 'chromium'] = process.argv.slice(2);
  const browserPair = profile.split('-');
  const validPair = browserPair.length <= 2 && new Set(browserPair).size === browserPair.length
    && browserPair.every(name => ['chromium', 'firefox', 'webkit'].includes(name));
  const validRoom = (['mesh-startup', 'mesh-close'].includes(route) && size === '4') || (['mesh', 'relay'].includes(route) && ['2', '4', '8'].includes(size));
  if (!validRoom || !validPair) {
    console.error('usage: native_online.cjs EXPORT ENDPOINT mesh|relay 2|4|8, or mesh-startup|mesh-close 4, with optional browser pair');
    process.exitCode = 1;
  } else run(root, endpoint, route, Number(size), browserPair).then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = { compareHistory, instrumentNativeWire, receivedDepartureAbort };
