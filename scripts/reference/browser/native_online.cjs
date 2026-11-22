const assert = require('node:assert/strict');
const { setImmediate: flush } = require('node:timers/promises');
const { createHost } = require('./online_host.cjs');

const INPUTS = [[1, ['KeyA']], [2, ['KeyD']], [4, ['KeyW']], [8, ['KeyS']],
  [5, ['KeyA', 'KeyW']], [6, ['KeyD', 'KeyW']], [9, ['KeyA', 'KeyS']], [10, ['KeyD', 'KeyS']]];
const GATE_FRAME = 12;
const HISTORY_FRAMES = 40;

function instrumentNativeWire() {
  const active = [];
  const resources = { rtc: [], sockets: [] };
  let session;
  let holding = false;
  let armed = false;
  let totalBytes = 0;
  let released = 0;
  const counts = { mesh: 0, relay: 0 };
  const held = { mesh: 0, relay: 0 };
  const nativeBytes = bytes => bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
    : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
  const matches = (bytes, offset) => session && offset + session.length < bytes.length
    && session.every((byte, index) => bytes[offset + index] === byte);
  function send(route, sender, nativeSend, data, isGame) {
    if (!isGame) return nativeSend.call(sender, data);
    counts[route]++;
    if (!holding) return nativeSend.call(sender, data);
    if (active.length >= 1024 || totalBytes + data.byteLength > 1024 * 1024) throw new Error('native packet hold exceeded bounds');
    const owned = nativeBytes(data).slice();
    active.push(() => nativeSend.call(sender, owned));
    totalBytes += owned.byteLength;
    held[route]++;
  }
  const createChannel = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = createChannel.call(this, label, options);
    resources.rtc.push(channel);
    const nativeSend = channel.send;
    channel.send = data => {
      const view = nativeBytes(data);
      return send('mesh', channel, nativeSend, data, channel.id === 3 && view && matches(view, 0));
    };
    return channel;
  };
  const nativeSocket = WebSocket;
  window.WebSocket = new Proxy(nativeSocket, { construct(target, args, newTarget) {
    const socket = Reflect.construct(target, args, newTarget);
    resources.sockets.push(socket);
    return socket;
  } });
  const socketSend = nativeSocket.prototype.send;
  nativeSocket.prototype.send = function(data) {
    const view = nativeBytes(data);
    let found = false;
    // The SDK prepends its own binary envelope before the FSR1 relay header.
    // Validate both the relay session and the native session at payload offset 57.
    if (view && session) for (let index = 0; index + 73 < view.length; index++) {
      if (view[index] === 70 && view[index + 1] === 83 && view[index + 2] === 82 && view[index + 3] === 49
          && view[index + 4] === 1 && matches(view, index + 5) && matches(view, index + 57)) {
        found = true;
        break;
      }
    }
    return send('relay', this, socketSend, data, found);
  };
  window.fortressNativeWire = {
    bind(hash) {
      if (session || !/^[0-9a-f]{32}$/.test(hash)) throw new Error('invalid native room session');
      session = hash.match(/../g).map(value => parseInt(value, 16));
    },
    arm() {
      if (!armed) {
        armed = true;
        holding = true;
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
    },
    status() {
      return { armed, holding, counts: { ...counts }, held: { ...held }, released, totalBytes,
        rtc: resources.rtc.map(channel => [channel.id, channel.readyState]), sockets: resources.sockets.map(socket => socket.readyState) };
    },
  };
}

function compareHistory(peers) {
  const ordered = [...peers].sort((first, second) => first.slot - second.slot);
  assert.deepEqual(ordered.map(peer => peer.slot), peers.map((_, index) => index), 'slots must cover the frozen roster');
  assert.equal(new Set(peers.map(peer => peer.uuid)).size, peers.length, 'each page must own a distinct player');
  assert.equal(new Set(peers.map(peer => peer.session_id)).size, 1, 'native schema/roster identity must agree');
  assert.match(peers[0].session_id, /^[0-9a-f]{32}$/);
  assert.equal(new Set(peers.map(peer => peer.room_id)).size, 1, 'all peers must be in the same SignalFish room');
  assert.ok(peers[0].room_id);
  for (let frame = 0; frame < HISTORY_FRAMES; frame++) {
    const expected = ordered.map(peer => frame >= GATE_FRAME && frame % 2 === 0 ? 0 : INPUTS[peer.index][0]);
    for (const peer of peers) {
      assert.deepEqual(peer.rows[frame], expected, `input row at frame ${frame}, slot ${peer.slot}`);
      assert.match(peer.snapshots[frame + 1], /^(?:[0-9a-f]{2})+$/);
      assert.equal(peer.snapshots[frame + 1], peers[0].snapshots[frame + 1], `canonical state at frame ${frame + 1}, slot ${peer.slot}`);
    }
  }
}

async function closeAll(items, close) {
  const settled = await Promise.allSettled(items.map(item => Promise.resolve().then(() => close(item))));
  return settled.filter(result => result.status === 'rejected').map(result => result.reason);
}

async function run(root, endpoint, route, players) {
  const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const { server, proxyPairs } = await createHost(root, endpoint, process.env.FORTRESS_TLS_CERT, process.env.FORTRESS_TLS_KEY);
  const origin = `https://127.0.0.1:${server.address().port}`;
  const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
  const pages = [];
  const contexts = [];
  const errors = [];
  const failures = [];
  let browser;
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
    browser = await chromium.launch({ executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE, headless: true,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
        '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'] });
    for (let index = 0; index < players; index++) {
      const context = await browser.newContext({ ignoreHTTPSErrors: true });
      contexts.push(context);
      const page = await context.newPage();
      pages.push(page);
      page.on('pageerror', error => errors.push({ index, phase, text: String(error) }));
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
      await wait(page, () => window.fortressNativeReady === true);
    }
    phase = 'lobby';
    function connect(page, index, room) {
      return command(page, 'connect', { endpoint: socketEndpoint, name: `Player ${index}`, room, route, players });
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
    phase = 'warmup';
    await command(pages[0], 'start');
    await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
      && window.fortressNative.confirmed >= frame, GATE_FRAME, 45000)));
    phase = 'prediction stall';
    // Arming on each local frame can strand a slower peer before its own
    // gate. Let every endpoint confirm the warmup while routes are open.
    const armed = await Promise.all(pages.map(page => page.evaluate(() => {
      const { frame, stalls, confirmed } = window.fortressNative;
      window.fortressNativeWire.arm();
      return { frame, stalls, confirmed };
    })));
    await Promise.all(pages.map((page, index) => wait(page, threshold => window.fortressNative.state === 'failed'
      || (window.fortressNative.state === 'playing' && window.fortressNative.stalls > threshold.stalls
        && window.fortressNative.prediction >= threshold.frame && window.fortressNativeWire.status().held[threshold.route] > 0),
    { route, stalls: armed[index].stalls, frame: GATE_FRAME }, 45000)));
    const stalled = await observe();
    for (const [index, peer] of stalled.entries()) {
      assert.equal(peer.state, 'playing', peer.message);
      assert.ok(armed[index].frame < HISTORY_FRAMES, 'gate must affect the compared history');
    }
    await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.release())));
    phase = 'corrected history';
    await Promise.all(pages.map((page, index) => wait(page, target => window.fortressNative.state === 'playing'
      && window.fortressNative.confirmed >= target.frame && window.fortressNative.restores > target.restores,
    { frame: HISTORY_FRAMES, restores: stalled[index].restores }, 45000)));
    await Promise.all(pages.map(page => page.evaluate(() => { window.fortressNativeCapture = true; })));
    await Promise.all(pages.map(page => wait(page, () => !!window.fortressNative.snapshots?.[40])));
    const peers = await observe();
    compareHistory(peers);
    const other = route === 'mesh' ? 'relay' : 'mesh';
    for (const peer of peers) {
      const before = stalled[peer.index];
      assert.equal(peer.movement_errors, 0, 'game must respond to every observed input');
      assert.equal(peer.game_frame, peer.frame, 'driver and game frame must agree');
      assert.ok(peer.saves > 0 && peer.advances > peer.frame && peer.restores > before.restores, 'save, load and re-advance must run');
      assert.ok(before.frame > GATE_FRAME && before.confirmed < before.frame - 1, 'gate must force prediction beyond confirmation');
      assert.ok(before.wire.holding && before.wire.held[route] > 0, 'native bytes must be held on the selected physical route');
      assert.ok(!peer.wire.holding && peer.wire.totalBytes > 0 && peer.wire.released === peer.wire.held[route], 'held originals must be released');
      assert.equal(peer.wire.counts[other], 0, 'native traffic must use the selected physical route');
      if (route === 'mesh') assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      else assert.deepEqual(peer.wire.rtc, [], 'initial relay must avoid WebRTC channel creation');
    }
    await Promise.all(pages.map(page => page.evaluate(() => { window.fortressNativeCapture = false; })));
    phase = 'departure';
    const departing = pages.at(-1);
    const survivors = pages.slice(0, -1);
    await command(departing, 'leave');
    await wait(departing, () => window.fortressNative.state === 'offline');
    await Promise.all(survivors.map(page => wait(page, () => window.fortressNative.state === 'failed' && window.fortressNative.terminated)));
    const terminal = await observe(survivors);
    await Promise.all(survivors.map((page, index) => wait(page, turns => window.fortressNative.turns >= turns + 8, terminal[index].turns)));
    const after = await observe(survivors);
    for (const [index, peer] of after.entries()) {
      const before = terminal[index];
      assert.equal(peer.state, 'failed');
      assert.ok(peer.terminated && peer.reason !== 0 && peer.message);
      for (const key of ['frame', 'confirmed', 'reason', 'message', 'game_frame', 'saves', 'restores', 'advances'])
        assert.equal(peer[key], before[key], `terminal ${key} changed for survivor ${index}`);
    }
    await Promise.all(survivors.map(page => command(page, 'leave')));
    await Promise.all(pages.map(page => wait(page, () => {
      const { sockets, rtc } = window.fortressNativeWire.status();
      return window.fortressNative.state === 'offline' && sockets.every(state => state === WebSocket.CLOSED)
        && rtc.every(([, state]) => state === 'closed');
    })));
    result = { passed: true, route, players, compared_frames: HISTORY_FRAMES, armed, stalled, peers, terminal, after };
  } catch (error) {
    failures.push(error);
    const states = await Promise.allSettled(pages.map(page => page.evaluate(() => ({
      ...window.fortressNative, wire: window.fortressNativeWire?.status()
    }))));
    console.error(JSON.stringify({ phase, errors, states }));
  } finally {
    failures.push(...await closeAll(contexts, context => context.close()));
    if (browser) failures.push(...await closeAll([browser], owner => owner.close()));
    for (const { socket, upstream } of proxyPairs) {
      socket.destroy();
      upstream.destroy();
    }
    failures.push(...await closeAll([server], owner => new Promise((resolve, reject) =>
      owner.close(error => error ? reject(error) : resolve()))));
  }
  await flush();
  if (errors.length) failures.push(new Error(JSON.stringify(errors)));
  if (failures.length) throw new AggregateError(failures, `native online witness failed in ${phase}`);
  return result;
}

if (require.main === module) {
  const [root, endpoint, route, size] = process.argv.slice(2);
  if (!['mesh', 'relay'].includes(route) || !['2', '4', '8'].includes(size)) {
    console.error('usage: native_online.cjs EXPORT ENDPOINT mesh|relay 2|4|8');
    process.exitCode = 1;
  } else run(root, endpoint, route, Number(size)).then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = { compareHistory, instrumentNativeWire };
