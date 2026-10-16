// Value: runs the shipped online scene; real keyboard, SDK sockets, recovery and new-room lifecycle.
const fs = require('node:fs');
const https = require('node:https');
const { createHost } = require('./online_host.cjs');
const path = require('node:path');
const { instrument } = require('./webrtc.cjs');

function delayedInputs() {
  window.fortressRestartFault = { armed: false, pressure: false, held: [], dropped: 0, pending: 0, reads: 0 };
  const create = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = create.call(this, label, options);
    const send = channel.send.bind(channel);
    channel.addEventListener('message', event => {
      if (!window.fortressStaleExpected) return;
      const hex = Array.from(new Uint8Array(event.data), byte => byte.toString(16).padStart(2, '0')).join('');
      if (hex === window.fortressStaleExpected) window.fortressStaleReceived = (window.fortressStaleReceived || 0) + 1;
    });
    let held = 0;
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
      } else if (view && view.length >= 8 && view[6] === 3 && held++ < 25) {
        const owned = view.slice();
        window.fortressOnlineDelayed++;
        setTimeout(() => { if (channel.readyState === 'open') send(owned); }, 250);
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
  const wait = async (page, expression, timeout = 30000) => {
    await page.waitForFunction(expression, null, { timeout });
    if (errors.length) throw new Error(JSON.stringify(errors));
  };
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
      await registerOnlineInit(page, { endpoint, count: 2, index, faults: false, corrupt: false,
        defaultFactory: false, mixed: false, mixedDefault: false, disableFallback: false, onlineCorrupt: corrupt });
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
      await Promise.all(pages.map(page => command(page, 'ready')));
      await wait(pages[0], () => window.fortressOnline.start_enabled);
      await pages[0].keyboard.down('KeyD');
      await pages[1].keyboard.down('KeyW');
      await command(pages[0], 'start');
      await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.frame >= (window.fortressOnlineCorrupt ? 12 : 45), 90000)));
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
      await pages[0].keyboard.up('KeyD');
      await pages[1].keyboard.up('KeyW');
      await pages[0].keyboard.down('KeyS');
      await pages[1].keyboard.down('KeyA');
      await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.confirmed >= (window.fortressOnlineCorrupt ? 20 : 100), 90000)));
      await Promise.all([pages[0].keyboard.up('KeyS'), pages[1].keyboard.up('KeyA')]);
      if (round === 0 && !corrupt) await pages[0].screenshot({ path: diagnostic.replace('-events.log', '.png') });
      const peers = await Promise.all(pages.map((page, index) => page.evaluate(pageIndex => ({ ...window.fortressOnline, page_index: pageIndex,
        rtc: { ...window.fortressRtc, channels: window.fortressRtc.channels.slice(-3) }, delayed: window.fortressOnlineDelayed }), index)));
      const diagnostics = [];
      for (const page of pages) {
        const before = await page.evaluate(() => ({ restores: window.fortressOnline.restores, frame: window.fortressOnline.frame }));
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
          const after = await page.evaluate(() => ({ restores: window.fortressOnline.restores, frame: window.fortressOnline.frame,
            storage_calls: window.fortressStorageCalls }));
          diagnostics.push({ before, after, filename: download.suggestedFilename(), report });
        } finally {
          await page.evaluate(() => {
            [Storage.prototype.setItem, IDBFactory.prototype.open] = window.fortressStorageOriginals;
          });
        }
      }
      rounds.push({ room, peers, diagnostics });
      if (round === 4 && !corrupt) {
        rounds[round].stale_sent = await Promise.all(pages.map(page => page.evaluate(() => window.fortressStaleSent)));
        rounds[round].stale_received = await Promise.all(pages.map(page => page.evaluate(() => window.fortressStaleReceived)));
      }
      if (suspension) rounds[round].suspension = suspension;
      if (round === 0 && !corrupt) {
        await command(pages[0], 'leave');
        await wait(pages[1], () => window.fortressOnline.state === 'failed');
        const before = await pages[1].evaluate(() => ({ state: window.fortressOnline.state,
          message: window.fortressOnline.message, frame_before: window.fortressOnline.frame }));
        await pages[1].waitForTimeout(250);
        const after = await pages[1].evaluate(() => ({ state: window.fortressOnline.state, frame_after: window.fortressOnline.frame }));
        rounds[round].terminal = { ...before, ...after };
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
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, corrupt, browser_instances: 2, rounds, errors, teardown: true }));
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
module.exports = { pauseElapsed, instrumentSockets, resourceCounts, registerOnlineInit };
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
