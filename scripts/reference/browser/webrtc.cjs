// Real independent exported Godot instances, with faults at the browser data-channel boundary.
const fs = require('node:fs');
const https = require('node:https');
const net = require('node:net');
const path = require('node:path');
const { waitGameplay, waitDefaultSetup, boundedRoom } = require('./webrtc_watchdog.cjs');
const { placeFirefox } = require('./webrtc_display.cjs');
const FIREFOX_PREFS = { 'webgl.force-enabled': true, 'webgl.disabled': false };

async function closeDepartingRtc(pages, now = () => performance.now()) {
  await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
  const deadline = now() + 3000;
  let active = true;
  const remaining = () => {
    if (!active || now() >= deadline) throw new Error('physical departure phase deadline');
    return Math.ceil(deadline - now());
  };
  try {
    await boundedRoom(async () => {
      await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropArm = true; })));
      remaining();
      await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropPaused === 'true', null, { timeout: remaining() })));
      remaining();
      const held = await Promise.all(pages.map(page => page.evaluate(() => ({
        frame: Number(document.body.dataset.fortressFrame), released: window.fortressDropGo === true,
        paused: document.body.dataset.fortressDropPaused === 'true',
      }))));
      remaining();
      if (held.some(value => value.frame !== 6 || value.released || !value.paused))
        throw new Error('peer-drop endpoint advanced before physical departure');
      await pages[2].evaluate(frames => {
        const resources = window.fortressResources;
        window.fortressRtc.departure = { frame: Number(document.body.dataset.fortressFrame), survivor_frames: frames,
          connections_created: resources.connections.length, channels_created: resources.channels.length };
        for (const connection of resources.connections) connection.close();
      }, held.slice(0, 2).map(value => value.frame));
      remaining();
      await pages[2].waitForFunction(() => window.fortressResources.channels.every(channel => channel.readyState === 'closed')
        && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), null, { timeout: remaining() });
      remaining();
      await pages[2].evaluate(() => {
        const resources = window.fortressResources;
        window.fortressRtc.departure.connections_closed = resources.connections.filter(connection => connection.connectionState === 'closed').length;
        window.fortressRtc.departure.channels_closed = resources.channels.filter(channel => channel.readyState === 'closed').length;
      });
      remaining();
      await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropGo = true; })));
      remaining();
    }, 3000, 'physical departure');
  } finally { active = false; }
}

function instrument({ endpoint, count, index, faults, corrupt, defaultFactory, mixed, mixedDefault,
  disableFallback, physicalClose = false, peerDrop = false, dropCorrupt = false, dropClose = false }) {
  window.fortressEndpoint = endpoint;
  window.fortressPlayers = count;
  window.fortressLocal = index;
  window.fortressFaultActive = false;
  window.fortressCorrupt = corrupt;
  window.fortressDefaultFactory = defaultFactory;
  window.fortressMixed = mixed;
  window.fortressMixedDefault = mixedDefault;
  window.fortressDisableFallback = disableFallback;
  window.fortressPhysicalClose = physicalClose;
  window.fortressPeerDrop = peerDrop;
  window.fortressDropCorrupt = dropCorrupt;
  window.fortressDropClose = dropClose;
  window.fortressRtc = { channels: [], sent: 0, received: 0, dropped: 0, reordered: 0, pending: 0, active: 0 };
  const evidence = window.fortressRtc;
  evidence.binarySent = 0;
  evidence.maximumRelayBuffered = 0;
  evidence.captureError = false;
  window.fortressScheduling = { frames: 0, first: performance.now(), last: null };
  if (typeof requestAnimationFrame === 'function') {
    const frame = now => { window.fortressScheduling.frames++; window.fortressScheduling.last = now; requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
  }
  window.fortressSockets = [];
  const nativeSocket = WebSocket;
  window.WebSocket = new Proxy(nativeSocket, { construct(target, args, newTarget) {
    const socket = Reflect.construct(target, args, newTarget);
    const record = { socket, received: 0, opened: false, failed: false, close_code: null };
    window.fortressSockets.push(record);
    socket.addEventListener('message', () => { record.received++; });
    socket.addEventListener('open', () => { record.opened = true; });
    socket.addEventListener('error', () => { record.failed = true; });
    socket.addEventListener('close', event => { record.close_code = event.code; });
    return socket;
  } });
  const websocketSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function(bytes) {
    if (typeof bytes !== 'string') evidence.binarySent++;
    const result = websocketSend.call(this, bytes);
    evidence.maximumRelayBuffered = Math.max(evidence.maximumRelayBuffered, this.bufferedAmount || 0);
    return result;
  };
  const remember = (list, bytes) => {
    const frame = Number(document.body?.dataset.fortressFrame ?? -1);
    if (!mixed || frame < 0 || frame >= 4) return;
    const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
      : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
    if (!view || view.length > 1024) { evidence.captureError = true; return; }
    const hex = Array.from(view, byte => byte.toString(16).padStart(2, '0')).join('');
    if (!list.includes(hex)) {
      if (list.length >= 128) evidence.captureError = true;
      else list.push(hex);
    }
  };
  window.fortressResources = { connections: [], channels: [] };
  const nativeConnection = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(nativeConnection, {
    construct(target, args, newTarget) {
      const connection = Reflect.construct(target, args, newTarget);
      window.fortressResources.connections.push(connection);
      return connection;
    },
  });
  const create = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = create.call(this, label, options);
    window.fortressResources.channels.push(channel);
    const record = { options, label, id: channel.id, ordered: channel.ordered, maxPacketLifeTime: channel.maxPacketLifeTime,
      maxRetransmits: channel.maxRetransmits, negotiated: channel.negotiated, sent: 0, received: 0, closed: false };
    record.blockedReads = 0;
    record.closeInitiatedFrame = null;
    record.physicalCloseFrame = null;
    record.mixedSent = 0;
    record.restoredSent = 0;
    record.postDropReceived = 0;
    record.earlySent = [];
    record.earlyReceived = [];
    record.maximumBuffered = 0;
    const buffered = mixed ? Object.getOwnPropertyDescriptor(RTCDataChannel.prototype, 'bufferedAmount').get : null;
    const unreliableIndex = evidence.channels.filter(value => value.id === 3).length;
    record.blockedLink = Boolean(mixed && !peerDrop && !physicalClose && index === 0 && channel.id === 3 && unreliableIndex === 0);
    // Inject send pressure on one live channel; all bytes still use real sockets.
    if (record.blockedLink) {
      Object.defineProperty(channel, 'bufferedAmount', { get() {
        const frame = Number(document.body?.dataset.fortressFrame ?? -1);
        if (frame >= 4 && frame < 16) { record.blockedReads++; return 262144; }
        return buffered.call(channel);
      } });
    }
    record.connectionState = this.connectionState;
    record.iceConnectionState = this.iceConnectionState;
    this.addEventListener('connectionstatechange', () => { record.connectionState = this.connectionState;
      console.log('RTC_STATE', JSON.stringify({ id: channel.id, state: this.connectionState })); });
    this.addEventListener('iceconnectionstatechange', () => { record.iceConnectionState = this.iceConnectionState; });
    evidence.channels.push(record);
    channel.addEventListener('message', event => {
      record.received++; evidence.received++;
      if (peerDrop && Number(document.body?.dataset.fortressFrame ?? -1) >= 8) record.postDropReceived++;
      if (channel.id === 3) remember(record.earlyReceived, event.data);
    });
    if (physicalClose) {
      const close = channel.close.bind(channel);
      channel.close = () => {
        const frame = Number(document.body?.dataset.fortressFrame ?? -1);
        if (physicalClose && index === 0 && channel.id === 3 && frame === 4 && record.closeInitiatedFrame === null) {
          record.blockedLink = true;
          record.closeInitiatedFrame = frame;
        }
        close();
      };
    }
    channel.addEventListener('close', () => {
      record.closed = true;
      const frame = Number(document.body?.dataset.fortressFrame ?? -1);
      if (physicalClose && channel.id === 3 && document.body?.dataset.fortressGameplayDone !== 'true' && frame >= 0 && frame < 39)
        record.physicalCloseFrame = frame;
    });
    const send = channel.send.bind(channel);
    channel.send = bytes => {
      record.sent++;
      evidence.sent++;
      if (channel.id === 3) remember(record.earlySent, bytes);
      const frame = Number(document.body?.dataset.fortressFrame ?? -1);
      if (mixed && frame >= 4 && frame < 16) record.mixedSent++;
      if (mixed && frame >= 20) record.restoredSent++;
      if (!window.fortressFaultActive || !faults) {
        send(bytes);
        if (mixed) record.maximumBuffered = Math.max(record.maximumBuffered, buffered.call(channel));
        return;
      }
      evidence.active++;
      if (evidence.active % 17 === 0) { evidence.dropped++; return; }
      if (evidence.active % 23 === 0) {
        // Copy bytes: Godot's WASM heap can be reused before delayed delivery.
        const owned = bytes instanceof ArrayBuffer ? bytes.slice(0) : new Uint8Array(bytes).slice();
        evidence.reordered++;
        evidence.pending++;
        setTimeout(() => { if (channel.readyState === 'open') send(owned); evidence.pending--; }, 30);
        return;
      }
      send(bytes);
    };
    return channel;
  };
}

function isDropCanonicalFailure(witness) {
  const failure = witness?.failure;
  return witness?.passed === false && failure?.stage === 'peer_drop_gameplay' && Array.isArray(failure.errors)
    && failure.errors.length === 1 && typeof failure.errors[0] === 'string'
    && /^peer_drop_canonical_(?:[89]|[12][0-9]|3[0-7])$/.test(failure.errors[0]);
}

function resourcesClosed(requireSockets) {
  return window.fortressResources.channels.every(channel => channel.readyState === 'closed')
    && window.fortressResources.connections.every(connection => connection.connectionState === 'closed')
    && (!requireSockets || (window.fortressSockets.length > 0
      && window.fortressSockets.every(record => record.socket.readyState === WebSocket.CLOSED)));
}

async function captureFailure(pages, players) {
  return Promise.all(pages.slice(0, 8).map(async (page, index) => {
    let timer;
    try {
      return await Promise.race([page.evaluate(limit => {
        const evidence = window.fortressRtc;
        const resources = window.fortressResources;
        const candidates = (connection, field) => {
          if (connection.connectionState === 'closed') return null;
          return (connection[field]?.sdp || '').split('\r\n').filter(row => row.startsWith('a=candidate:')).slice(0, 16).map(row => row.slice(0, 512));
        };
        return { index: limit.index, captured_ms: performance.now(), frame: document.body.dataset.fortressFrame,
          scheduling: { ...window.fortressScheduling, hidden: document.hidden, focused: document.hasFocus?.() },
          sockets: (window.fortressSockets || []).slice(0, 4).map(record => ({ opened: record.opened, failed: record.failed,
            close_code: record.close_code, received: record.received, state: record.socket.readyState, buffered: record.socket.bufferedAmount })),
          rtc: { sent: evidence.sent, received: evidence.received, dropped: evidence.dropped, reordered: evidence.reordered,
            pending: evidence.pending, active: evidence.active,
            channels: resources.channels.slice(0, 3 * (limit.players - 1)).map((channel, slot) => ({
              id: channel.id, label: channel.label, ready_state: channel.readyState, buffered_amount: channel.bufferedAmount,
              ordered: channel.ordered, max_packet_life_time: channel.maxPacketLifeTime, max_retransmits: channel.maxRetransmits,
              sent: evidence.channels[slot]?.sent, received: evidence.channels[slot]?.received,
              blocked_reads: evidence.channels[slot]?.blockedReads,
            })),
            connections: resources.connections.slice(0, 2 * (limit.players - 1)).map(connection => ({
              state: connection.connectionState, ice: connection.iceConnectionState, signaling: connection.signalingState,
              local_candidates: candidates(connection, 'localDescription'),
              remote_candidates: candidates(connection, 'remoteDescription'),
            })),
          } };
      }, { index, players }), new Promise(resolve => {
        timer = setTimeout(() => resolve({ index, failure: 'diagnostic_timeout' }), 1000);
      })]);
    } catch {
      return { index, failure: 'diagnostic_evaluation_failed' };
    } finally { clearTimeout(timer); }
  }));
}

async function main() {
  const engines = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const browserPair = JSON.parse(process.env.FORTRESS_BROWSER_PAIR || '["chromium","chromium"]');
  if (!Array.isArray(browserPair) || browserPair.length !== 2 || browserPair.some(name => !['chromium', 'firefox'].includes(name)))
    throw new Error('invalid browser pair');
  const root = path.resolve(process.argv[2]);
  const endpoint = process.argv[3];
  const faults = process.argv[4] === 'faults';
  const corrupt = process.argv[4] === 'corrupt';
  const defaultFactory = process.argv[4] === 'default';
  const peerDrop = ['peer-drop', 'peer-drop-corrupt', 'peer-drop-close'].includes(process.argv[4]);
  const dropCorrupt = process.argv[4] === 'peer-drop-corrupt';
  const dropClose = process.argv[4] === 'peer-drop-close';
  const physicalClose = process.argv[4] === 'mixed-close';
  const mixed = ['mixed', 'mixed-default', 'mixed-disabled', 'mixed-close', 'peer-drop-close'].includes(process.argv[4]);
  const mixedDefault = process.argv[4] === 'mixed-default';
  const disableFallback = process.argv[4] === 'mixed-disabled';
  const errors = [];
  const logs = [];
  const diagnostic = process.argv[5];
  const server = https.createServer({ cert: fs.readFileSync(process.env.FORTRESS_TLS_CERT),
    key: fs.readFileSync(process.env.FORTRESS_TLS_KEY) }, (request, response) => {
    const filename = path.resolve(root, '.' + decodeURIComponent(new URL(request.url, 'http://localhost').pathname));
    if (!filename.startsWith(root + path.sep)) { response.writeHead(403); response.end(); return; }
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    const mime = { '.wasm': 'application/wasm', '.js': 'application/javascript', '.html': 'text/html' };
    response.setHeader('Content-Type', mime[path.extname(filename)] || 'application/octet-stream');
    fs.readFile(filename, (error, bytes) => { response.writeHead(error ? 404 : 200); response.end(error ? '' : bytes); });
  });
  server.on('upgrade', (request, socket, head) => {
    const backend = new URL(endpoint);
    const upstream = net.connect(Number(backend.port), '127.0.0.1', () => {
      let headers = `${request.method} ${backend.pathname} HTTP/${request.httpVersion}\r\n`;
      for (let index = 0; index < request.rawHeaders.length; index += 2)
        headers += `${request.rawHeaders[index]}: ${request.rawHeaders[index + 1]}\r\n`;
      upstream.write(headers + '\r\n');
      if (head.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browsers = [];
  const records = [];
  const failed_rooms = [];
  try {
    for (const name of browserPair) browsers.push(await engines[name].launch(name === 'chromium' ? {
      headless: true, timeout: 30000, executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-background-timer-throttling', '--ignore-certificate-errors'],
    } : { headless: false, timeout: 30000, executablePath: process.env.FORTRESS_FIREFOX_EXECUTABLE,
      firefoxUserPrefs: FIREFOX_PREFS,
    }));
    for (const count of (peerDrop ? [3] : (corrupt || defaultFactory || disableFallback) ? [2] : [2, 4, 8])) {
      const contexts = [];
      const pages = [];
      const displays = [];
      try {
        await boundedRoom(async () => {
        await boundedRoom(async () => {
        for (let index = 0; index < count; index++) {
          const context = await browsers[index % 2].newContext({ ignoreHTTPSErrors: true });
          contexts.push(context);
          const page = await context.newPage();
          pages.push(page);
          displays.push(browserPair[index % 2] === 'firefox' ? await placeFirefox(page, index) : null);
          page.on('pageerror', error => errors.push({ count, index, error: error.message }));
          page.on('console', message => {
            const entry = { count, index, type: message.type(), text: message.text() };
            logs.push(entry);
            if (diagnostic) fs.appendFileSync(diagnostic, JSON.stringify(entry) + '\n');
            if (message.type() === 'error') errors.push({ count, index, error: message.text() });
          });
          await page.addInitScript(instrument, { endpoint: `wss://127.0.0.1:${server.address().port}/v3/ws`, count, index,
            faults, corrupt, defaultFactory, mixed, mixedDefault, disableFallback, physicalClose, peerDrop, dropCorrupt, dropClose });
          await page.goto(`https://127.0.0.1:${server.address().port}/index.html`);
        }
        await pages[0].waitForFunction(() => document.body.dataset.fortressRoom !== undefined, null, { timeout: 60000 });
        const room = await pages[0].evaluate(() => document.body.dataset.fortressRoom);
        await Promise.all(pages.slice(1).map(page => page.evaluate(value => { window.fortressRoom = value; }, room)));
        if (!defaultFactory) {
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressHandshakeReady === 'true'
            || document.body.dataset.fortressGameplayDone === 'true' || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 120000 })));
          if (peerDrop) {
            const uuid = await pages[2].evaluate(() => document.body.dataset.fortressUuid);
            await Promise.all(pages.map(page => page.evaluate(value => { window.fortressDepartingUuid = value; }, uuid)));
          }
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstStepReady = true; })));
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressFrame === '0' || document.body.dataset.fortressGameplayDone === 'true'
            || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 10000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstDeliveryReady = true; })));
        } else await waitDefaultSetup(pages);
        }, 120000, 'setup');
        {
          if (peerDrop) {
            if (dropClose) await closeDepartingRtc(pages);
            else {
              await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
              await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropGo = true; })));
            }
          }
          await waitGameplay(pages);
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressTeardownArmed = true; })));
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressTeardownArmed === 'true',
            null, { timeout: 10000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressTeardownReady = true; })));
        }
        await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressWebrtc !== undefined,
          null, { timeout: 10000 })));
        try {
          await Promise.all(pages.map(page => page.waitForFunction(resourcesClosed, peerDrop, { timeout: 10000 })));
        } catch (error) {
          const resources = await Promise.all(pages.map(page => page.evaluate(() => ({
            result: document.body.dataset.fortressWebrtc,
            connections: window.fortressResources.connections.map(connection => ({ state: connection.connectionState,
              ice: connection.iceConnectionState, signaling: connection.signalingState })),
            channels: window.fortressResources.channels.map(channel => ({ id: channel.id, state: channel.readyState })),
            websockets: window.fortressSockets.map(record => record.socket.readyState),
          }))));
          throw new Error(JSON.stringify({ teardown: resources, cause: String(error) }));
        }
        const peers = await Promise.all(pages.map(page => page.evaluate(() => ({
          result: JSON.parse(document.body.dataset.fortressWebrtc), rtc: { ...window.fortressRtc, teardown: {
            channels: window.fortressResources.channels.filter(channel => channel.readyState === 'closed').length,
            connections_created: window.fortressResources.connections.length,
            connections: window.fortressResources.connections.filter(connection => connection.connectionState === 'closed').length,
            websockets_created: window.fortressSockets.length,
            websockets: window.fortressSockets.filter(record => record.socket.readyState === WebSocket.CLOSED).length } },
        }))));
        if (errors.length) throw new Error(JSON.stringify({ errors, peers }));
        for (const [index, peer] of peers.entries()) {
          if (dropCorrupt && index < 2 && !isDropCanonicalFailure(peer.result))
            throw new Error(JSON.stringify({ control: 'wrong_drop_canonical_boundary', peers }));
          if (!corrupt && !defaultFactory && !dropCorrupt && peer.result.passed !== true) throw new Error(JSON.stringify(peers));
          if (corrupt && (peer.result.passed !== false || peer.result.failure.stage !== 'gameplay'
            || peer.result.failure.errors.length !== 1 || !/^canonical_prefix_frame_[1-9][0-9]*$/.test(peer.result.failure.errors[0])))
            throw new Error(JSON.stringify({ control: 'wrong_failure_boundary', peers }));
          if (defaultFactory && (peer.result.passed !== false || peer.result.failure.stage !== 'handshake'
            || JSON.stringify(peer.result.failure.errors) !== JSON.stringify(['direct_poll_3_peer_0'])))
            throw new Error(JSON.stringify({ control: 'wrong_channel_policy_boundary', peers }));
        }
        peers.forEach((peer, index) => { peer.browser = browserPair[index % 2]; peer.display = displays[index]; });
        records.push({ players: count, peers });
        });
      } catch (error) {
        // Preserve live socket evidence before context.close destroys the failed room.
        failed_rooms.push({ players: count, peers: await captureFailure(pages, count) });
        throw error;
      } finally {
        await Promise.all(contexts.map(context => context.close()));
      }
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, browser: browserPair.join('/'),
      browsers: browsers.map((browser, index) => ({ name: browserPair[index], version: browser.version() })),
      version: browsers[0].version(), browser_instances: 2, firefox_preferences: browserPair.includes('firefox') ? FIREFOX_PREFS : null,
      faults, corrupt, defaultFactory, mixed, mixedDefault, disableFallback, physicalClose, peerDrop, dropCorrupt, dropClose, records, errors }));
  } catch (error) {
    console.error(JSON.stringify({ failure: String(error), errors, records, failed_rooms, logs, browser: browserPair.join('/'),
      version: browsers[0]?.version(), firefox_preferences: browserPair.includes('firefox') ? FIREFOX_PREFS : null,
      browsers: browsers.map((browser, index) => ({ name: browserPair[index], version: browser.version() })) }));
    throw error;
  } finally {
    await Promise.all(browsers.map(browser => browser.close()));
    server.close();
  }
}

module.exports = { instrument, isDropCanonicalFailure, resourcesClosed, closeDepartingRtc };
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
