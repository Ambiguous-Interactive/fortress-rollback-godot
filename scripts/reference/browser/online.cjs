// Value: runs the shipped online scene; real keyboard, SDK sockets, recovery and new-room lifecycle.
const fs = require('node:fs');
const https = require('node:https');
const net = require('node:net');
const path = require('node:path');
const { instrument } = require('./webrtc.cjs');

function delayedInputs() {
  const create = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = create.call(this, label, options);
    const send = channel.send.bind(channel);
    let held = 0;
    channel.send = bytes => {
      const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
        : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
      if (view && view.length >= 8 && view[6] === 3 && held++ < 25) {
        const owned = view.slice();
        window.fortressOnlineDelayed++;
        setTimeout(() => { if (channel.readyState === 'open') send(owned); }, 250);
      } else send(bytes);
    };
    return channel;
  };
  window.fortressOnlineDelayed = 0;
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
  const server = https.createServer({ cert: fs.readFileSync(process.env.FORTRESS_TLS_CERT),
    key: fs.readFileSync(process.env.FORTRESS_TLS_KEY) }, (request, response) => {
    const filename = path.resolve(root, '.' + decodeURIComponent(new URL(request.url, 'http://localhost').pathname));
    if (!filename.startsWith(root + path.sep)) { response.writeHead(403); response.end(); return; }
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    response.setHeader('Content-Type', { '.wasm': 'application/wasm', '.js': 'application/javascript', '.html': 'text/html' }[path.extname(filename)]
      || 'application/octet-stream');
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
      upstream.pipe(socket); socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
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
      await page.addInitScript(instrument, { endpoint, count: 2, index, faults: false, corrupt: false,
        defaultFactory: false, mixed: false, mixedDefault: false, disableFallback: false });
      await page.addInitScript(delayedInputs);
      await page.addInitScript(value => { window.fortressOnlineCorrupt = value; }, corrupt);
      pages.push(page);
      await page.goto(`https://127.0.0.1:${server.address().port}/index.html`);
      await wait(page, () => window.fortressOnlineReady === true);
    }
    const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
    for (let round = 0; round < (corrupt ? 1 : 2); round++) {
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
      rounds.push({ room, peers });
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
        if (!corrupt) {
          rounds[round].suspension = await suspend('expired', 2500);
          await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'failed')));
          const before = await Promise.all(pages.map(page => page.evaluate(() => window.fortressOnline.frame)));
          await new Promise(resolve => setTimeout(resolve, 250));
          rounds[round].frozen_frames = await Promise.all(pages.map((page, index) => page.evaluate(frame => ({
            before: frame, after: window.fortressOnline.frame, state: window.fortressOnline.state }), before[index])));
        }
        await Promise.all(pages.map(page => command(page, 'leave')));
      }
      await Promise.all(pages.map(page => wait(page, () => window.fortressOnline.state === 'offline')));
      await Promise.all(pages.map(page => wait(page, () => window.fortressResources.channels.every(channel => channel.readyState === 'closed')
        && window.fortressResources.connections.every(connection => connection.connectionState === 'closed'))));
      rounds[round].teardown = await Promise.all(pages.map(page => page.evaluate(() => ({
        channels: window.fortressResources.channels.length,
        channels_closed: window.fortressResources.channels.filter(channel => channel.readyState === 'closed').length,
        connections: window.fortressResources.connections.length,
        connections_closed: window.fortressResources.connections.filter(connection => connection.connectionState === 'closed').length,
      }))));
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, corrupt, browser_instances: 2, rounds, errors, teardown: true }));
  } catch (error) {
    const states = await Promise.all(pages.map(page => page.evaluate(() => window.fortressOnline).catch(() => null)));
    console.error(JSON.stringify({ failure: String(error), states, errors, logs }));
    throw error;
  } finally {
    await Promise.all(browsers.map(browser => browser.close()));
    await new Promise(resolve => server.close(resolve));
  }
}
module.exports = { pauseElapsed };
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
