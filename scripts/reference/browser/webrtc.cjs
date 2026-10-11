// Real independent exported Godot instances, with faults at the browser data-channel boundary.
const fs = require('node:fs');
const https = require('node:https');
const net = require('node:net');
const path = require('node:path');

function instrument({ endpoint, count, index, faults, corrupt, defaultFactory }) {
  window.fortressEndpoint = endpoint;
  window.fortressPlayers = count;
  window.fortressLocal = index;
  window.fortressFaultActive = false;
  window.fortressCorrupt = corrupt;
  window.fortressDefaultFactory = defaultFactory;
  window.fortressRtc = { channels: [], sent: 0, received: 0, dropped: 0, reordered: 0, pending: 0, active: 0 };
  const evidence = window.fortressRtc;
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
    record.connectionState = this.connectionState;
    record.iceConnectionState = this.iceConnectionState;
    this.addEventListener('connectionstatechange', () => { record.connectionState = this.connectionState;
      console.log('RTC_STATE', JSON.stringify({ id: channel.id, state: this.connectionState })); });
    this.addEventListener('iceconnectionstatechange', () => { record.iceConnectionState = this.iceConnectionState; });
    evidence.channels.push(record);
    channel.addEventListener('message', () => { record.received++; evidence.received++; });
    channel.addEventListener('close', () => { record.closed = true; });
    const send = channel.send.bind(channel);
    channel.send = bytes => {
      record.sent++;
      evidence.sent++;
      if (!window.fortressFaultActive || !faults) { send(bytes); return; }
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

async function main() {
  const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const root = path.resolve(process.argv[2]);
  const endpoint = process.argv[3];
  const faults = process.argv[4] === 'faults';
  const corrupt = process.argv[4] === 'corrupt';
  const defaultFactory = process.argv[4] === 'default';
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
  try {
    for (let index = 0; index < 2; index++) browsers.push(await chromium.launch({
      headless: true, executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-background-timer-throttling', '--ignore-certificate-errors'],
    }));
    for (const count of ((corrupt || defaultFactory) ? [2] : [2, 4, 8])) {
      const contexts = [];
      const pages = [];
      try {
        for (let index = 0; index < count; index++) {
          const context = await browsers[index % 2].newContext({ ignoreHTTPSErrors: true, viewport: { width: 64, height: 64 } });
          contexts.push(context);
          const page = await context.newPage();
          pages.push(page);
          page.on('pageerror', error => errors.push({ count, index, error: error.message }));
          page.on('console', message => {
            const entry = { count, index, type: message.type(), text: message.text() };
            logs.push(entry);
            if (diagnostic) fs.appendFileSync(diagnostic, JSON.stringify(entry) + '\n');
            if (message.type() === 'error') errors.push({ count, index, error: message.text() });
          });
          await page.addInitScript(instrument, { endpoint: `wss://127.0.0.1:${server.address().port}/v3/ws`, count, index, faults, corrupt, defaultFactory });
          await page.goto(`https://127.0.0.1:${server.address().port}/index.html`);
        }
        await pages[0].waitForFunction(() => document.body.dataset.fortressRoom !== undefined, null, { timeout: 60000 });
        const room = await pages[0].evaluate(() => document.body.dataset.fortressRoom);
        await Promise.all(pages.slice(1).map(page => page.evaluate(value => { window.fortressRoom = value; }, room)));
        if (!defaultFactory) {
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressHandshakeReady === 'true'
            || document.body.dataset.fortressGameplayDone === 'true' || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 120000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstStepReady = true; })));
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressFrame === '0' || document.body.dataset.fortressGameplayDone === 'true'
            || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 10000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstDeliveryReady = true; })));
        }
        {
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressGameplayDone === 'true'
            || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 120000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressTeardownArmed = true; })));
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressTeardownArmed === 'true',
            null, { timeout: 10000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressTeardownReady = true; })));
        }
        await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressWebrtc !== undefined,
          null, { timeout: 120000 })));
        try {
          await Promise.all(pages.map(page => page.waitForFunction(() => window.fortressResources.channels.every(channel => channel.readyState === 'closed')
            && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), null, { timeout: 10000 })));
        } catch (error) {
          const resources = await Promise.all(pages.map(page => page.evaluate(() => ({
            result: document.body.dataset.fortressWebrtc,
            connections: window.fortressResources.connections.map(connection => ({ state: connection.connectionState,
              ice: connection.iceConnectionState, signaling: connection.signalingState })),
            channels: window.fortressResources.channels.map(channel => ({ id: channel.id, state: channel.readyState })),
          }))));
          throw new Error(JSON.stringify({ teardown: resources, cause: String(error) }));
        }
        const peers = await Promise.all(pages.map(page => page.evaluate(() => ({
          result: JSON.parse(document.body.dataset.fortressWebrtc), rtc: { ...window.fortressRtc, teardown: {
            channels: window.fortressResources.channels.filter(channel => channel.readyState === 'closed').length,
            connections_created: window.fortressResources.connections.length,
            connections: window.fortressResources.connections.filter(connection => connection.connectionState === 'closed').length } },
        }))));
        if (errors.length) throw new Error(JSON.stringify({ errors, peers }));
        for (const peer of peers) {
          if (!corrupt && !defaultFactory && peer.result.passed !== true) throw new Error(JSON.stringify(peers));
          if (corrupt && (peer.result.passed !== false || peer.result.failure.stage !== 'gameplay'
            || peer.result.failure.errors.length !== 1 || !/^canonical_prefix_frame_[1-9][0-9]*$/.test(peer.result.failure.errors[0])))
            throw new Error(JSON.stringify({ control: 'wrong_failure_boundary', peers }));
          if (defaultFactory && (peer.result.passed !== false || peer.result.failure.stage !== 'handshake'
            || JSON.stringify(peer.result.failure.errors) !== JSON.stringify(['direct_poll_3_peer_0'])))
            throw new Error(JSON.stringify({ control: 'wrong_channel_policy_boundary', peers }));
        }
        records.push({ players: count, peers });
      } finally {
        await Promise.all(contexts.map(context => context.close()));
      }
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, browser: 'Chromium', version: browsers[0].version(), browser_instances: 2, faults, corrupt, defaultFactory, records, errors }));
  } catch (error) {
    console.error(JSON.stringify({ failure: String(error), errors, records, logs }));
    throw error;
  } finally {
    await Promise.all(browsers.map(browser => browser.close()));
    server.close();
  }
}

module.exports = { instrument };
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
