const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { test } = require('node:test');
const { joinChromiumSocket, readChromiumLog } = require('./native_chromium_socket.cjs');

const host = '127.0.0.1:44000';
const local = '127.0.0.1:44001';
const carrier = Buffer.from('exact carrier');
const frame = Buffer.concat([Buffer.from([0x82, carrier.length]), carrier]);
const handshake = Buffer.from('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
const digest = createHash('sha256').update(carrier).digest('hex');
const constants = { logEventTypes: { TCP_CONNECT: 1, SSL_SOCKET_BYTES_RECEIVED: 2 },
  logSourceType: { SOCKET: 3 }, logEventPhase: { PHASE_END: 2 } };
const recipient = '22'.repeat(16);
const address = { browser_endpoint: local, page_index: 0 };
const carrierMatch = { socket: 0, ordinal: 3, outlet_ms: 999, carrier_sha256: digest };
const row = { sender: '11'.repeat(16), recipient, epoch: 1, seq: '42', proxy: [carrierMatch] };
const receive = { room: '33'.repeat(16), sockets: [address], rows: [row] };

const connection = (id, endpoint = local, time = 40) => ({
  source: { id, type: 3 }, type: 1, phase: 2, params: { local_address: endpoint, remote_address: host },
  time: String(time),
});
const incoming = (id, time, bytes) => ({
  source: { id, type: 3 }, type: 2, phase: 0, time: String(time),
  params: { bytes: bytes.toString('base64'), byte_count: bytes.length },
});
const collect = (events, seen = receive, fixtureRecipients = [recipient], capture = 'recorded') =>
  joinChromiumSocket({ constants, events }, capture, host, seen, fixtureRecipients).rows[0];

test('socket receipt reassembles exact carrier and keeps completion on the NetLog clock', () => {
  const events = [connection(7), connection(8, '127.0.0.1:44002'), incoming(8, 50, Buffer.concat([handshake, frame])),
    incoming(7, 70, Buffer.concat([handshake, frame.subarray(0, 5)])), incoming(7, 80, frame.subarray(5))];
  const result = collect(events);
  assert.equal(result.status, 'observed');
  assert.deepEqual(result.observation, { socket: 0, proxy_ordinal: 3, carrier_sha256: digest, netlog_source: 7, at_ms: 80 });
  assert.equal(result.seq, '42');
  assert.equal(result.recipient, recipient);
  assert.equal(collect(events, { ...receive, rows: [{ ...row, proxy: [{ ...carrierMatch, outlet_ms: null }] }] }).status, 'observed');
  assert.equal(collect(events, { ...receive, rows: [{ ...row, proxy: [{ ...carrierMatch, carrier_sha256: 'other' }] }] }).status, 'unavailable');
  assert.equal(collect(events, receive, ['wrong-recipient']).status, 'unavailable');
});

test('expiry ordering requires a calibrated document and a unique carrier on the expired link', () => {
  const sample = { page_ms: 20, time_origin_ms: 1700000000000 };
  const calibration = { start_ms: 60, end_ms: 62, sample };
  const expiry = { uuid: '11111111-1111-1111-1111-111111111111', page_ms: 59, chromium_service: {
    before: { ...sample, page_ms: 40 }, after: { ...sample, page_ms: 58 },
  } };
  const observe = ({ at = 75, clocks = [calibration], expiries = [expiry], input = receive } = {}) => joinChromiumSocket({
    constants, events: [connection(7), incoming(7, at, Buffer.concat([handshake, frame]))],
  }, 'recorded', host, input, [recipient], clocks, expiries).rows[0];

  assert.deepEqual(observe().observation.expiry_timing, { order: 'before', min_gap_ms: -27, max_gap_ms: -2 });
  assert.equal(observe({ at: 77 }).observation.expiry_timing.order, 'unresolved', 'bound equality');
  assert.equal(observe({ at: 85 }).observation.expiry_timing.order, 'unresolved', 'overlap');
  assert.equal(observe({ at: 103 }).observation.expiry_timing.order, 'after');
  assert.equal(observe({ clocks: [{ ...calibration, sample: { ...sample, time_origin_ms: 1 } }] }).observation.expiry_timing.order, 'unresolved');
  assert.equal(observe({ clocks: [{ ...calibration, end_ms: 59 }] }).observation.expiry_timing.order, 'unresolved');
  assert.equal(observe({ clocks: [] }).observation.expiry_timing.order, 'unresolved');
  const huge = { ...sample, page_ms: Number.MAX_VALUE };
  for (const badClock of [{ ...calibration, start_ms: Number.MAX_VALUE, end_ms: Number.MAX_VALUE }, { ...calibration, sample: huge }]) {
    const badExpiry = { ...expiry, page_ms: huge.page_ms, chromium_service: { before: huge, after: huge } };
    assert.deepEqual(observe({ clocks: [badClock], expiries: [badExpiry] }).observation.expiry_timing, { order: 'unresolved', reason: 'invalid' });
  }
  assert.equal(observe({ expiries: [{ ...expiry, uuid: '44444444-4444-4444-4444-444444444444' }] }).observation.expiry_timing, undefined);
  assert.equal(observe({ input: { ...receive, rows: [{ ...row, proxy: [carrierMatch, carrierMatch] }] } }).observation, undefined);
});

// Value: protects=exact Blink carrier on the tagged socket; fails_when=foreign or evicted frames can order expiry; seam=CDP event stream.
test('Chromium renderer receipts bind the exact tagged connection and preserve timing uncertainty', async () => {
  const { EventEmitter } = require('node:events');
  const { observeChromiumFrames } = require('./native_chromium_frames.cjs');
  const session = new EventEmitter();
  session.send = async (method, params) => {
    assert.equal(method, 'Network.enable');
    assert.deepEqual(params, { maxTotalBufferSize: 0, maxResourceBufferSize: 0 });
  };
  const endpoint = 'wss://127.0.0.1:44000/v3/ws?trace_page=0';
  const observe = await observeChromiumFrames({ newCDPSession: async () => session }, {}, endpoint, { capacity: 2 });
  const created = (requestId, url = endpoint) => session.emit('Network.webSocketCreated', { requestId, url });
  const emit = (requestId, at, payload = carrier) => session.emit('Network.webSocketFrameReceived', {
    requestId, timestamp: at / 1000, response: { opcode: 2, mask: false, payloadData: payload.toString('base64') },
  });
  const clock = { page_ms: 20, time_origin_ms: 1700000000000 };
  const calibration = { start_ms: 60, end_ms: 62, sample: clock };
  const expiry = { uuid: '11111111-1111-1111-1111-111111111111', page_ms: 59, chromium_service: {
    before: { ...clock, page_ms: 40 }, after: { ...clock, page_ms: 58 },
  } };
  const exact = { ...row, proxy: [{ ...carrierMatch, inlet_ms: 0 }] };
  const events = [connection(7), incoming(7, 70, Buffer.concat([handshake, frame]))];
  const collect = (packet = exact, input = receive, since = 0, selected = events, snapshot = observe.snapshot()) => joinChromiumSocket(
    { constants, events: selected }, 'recorded', host,
    { ...input, rows: [{ ...packet, proxy: packet.proxy.map(write => ({ ...write, inlet_ms: since })) }] },
    [recipient], [calibration], [expiry], [snapshot]).rows[0].renderer;

  created('foreign', endpoint + '&other');
  emit('foreign', 72);
  assert.equal(collect().status, 'unavailable');
  created('relay');
  emit('unowned', 72);
  emit('relay', 74, Buffer.from('wrong carrier'));
  assert.equal(collect().status, 'unobserved');
  emit('relay', 86);
  const match = collect();
  assert.equal(match.status, 'observed');
  assert.equal(match.observation.request_id, 'relay');
  assert.equal(match.observation.at_ms, 86);
  assert.equal(match.observation.expiry_timing.order, 'unresolved');
  assert.equal(collect(exact, receive, 0, [...events, incoming(7, 71, frame)]).status, 'ambiguous', 'the carrier appeared twice at TLS');
  assert.equal(collect(exact, receive, 0, [connection(8), ...events]).status, 'ambiguous', 'two TLS sources claim the proxy endpoint');
  assert.equal(collect(exact, { ...receive, sockets: [address, address] }).status, 'ambiguous');
  assert.equal(collect(exact, { ...receive, refused: 1 }).status, 'unavailable');
  const snapshot = observe.snapshot();
  for (const inlet of [snapshot.cutoff_ms, snapshot.cutoff_ms + 1]) {
    assert.equal(collect(exact, receive, inlet, events, snapshot).status, 'outside_capture');
  }
  emit('relay', 95);
  assert.equal(collect().status, 'ambiguous');
  emit('relay', 101, Buffer.from('another carrier'));
  assert.equal(collect().status, 'truncated', 'an omitted candidate can have been written after inlet');
  const beforeRejected = performance.now();
  emit('relay', NaN);
  assert.deepEqual(collect(exact, receive, beforeRejected), { status: 'incomplete', reason: 'rejected_candidates' });
  assert.equal(collect(exact, receive, performance.now()).status, 'unobserved', 'earlier rejected candidates cannot belong to a later inlet');
  session.emit('close');
  assert.deepEqual(collect(exact, receive, performance.now()), { status: 'incomplete', reason: 'session_detached' });
  created('replacement');
  assert.equal(collect().status, 'ambiguous');
});

// Value: protects=bounded optional observer setup; fails_when=late attach enables Network; seam=CDP session lifecycle.
test('a late Chromium renderer observer detaches without enabling the network domain', async () => {
  const { EventEmitter } = require('node:events');
  const { setImmediate: nextTurn } = require('node:timers/promises');
  const { observeChromiumFrames } = require('./native_chromium_frames.cjs');
  const session = new EventEmitter();
  let detach = 0;
  let enable = 0;
  session.detach = async () => { detach++; };
  session.send = async () => { enable++; };
  const { promise, resolve } = Promise.withResolvers();
  assert.equal(await observeChromiumFrames({ newCDPSession: () => promise }, {}, '', { timeout: 5 }), null);
  resolve(session);
  await nextTurn();
  assert.equal(detach, 1);
  assert.equal(enable, 0);

  const enabling = Promise.withResolvers();
  session.send = async () => { enable++; await enabling.promise; };
  assert.equal(await observeChromiumFrames({ newCDPSession: async () => session }, {}, '', { timeout: 5 }), null);
  assert.equal(detach, 2);
  assert.equal(enable, 1);
  enabling.resolve();
  await nextTurn();
  assert.equal(detach, 2, 'the abandoned session is detached exactly once');
});

test('missing, truncated, duplicate and unbound socket evidence do not imply non-delivery', async () => {
  assert.deepEqual(await readChromiumLog('/not-a-capture'), { status: 'unavailable' });
  const complete = incoming(7, 70, Buffer.concat([handshake, frame]));
  assert.equal(collect([complete]).status, 'unavailable');
  assert.equal(collect([connection(7), { ...complete, params: { byte_count: 999 } }]).status, 'truncated');
  const malformed = { ...complete, params: { ...complete.params, bytes: '@' + complete.params.bytes } };
  assert.equal(collect([connection(7), malformed]).status, 'truncated');
  assert.equal(collect([connection(7, local, 71), complete]).status, 'truncated');
  assert.equal(collect([connection(7), incoming(7, 80, Buffer.concat([handshake, frame.subarray(0, 5)])),
    incoming(7, 70, frame.subarray(5))]).status, 'truncated');
  const rolled = joinChromiumSocket({ constants, events: [complete] }, 'truncated', host, receive, [recipient]);
  assert.equal(rolled.status, 'truncated');
  assert.equal(rolled.rows[0].status, 'unavailable');
  assert.equal(collect([connection(7), connection(8), complete]).status, 'ambiguous');
  assert.equal(collect([connection(7), complete, incoming(7, 90, frame)]).status, 'ambiguous');
  assert.equal(collect([connection(7), complete], { ...receive, rows: [{ ...row, proxy: [carrierMatch, carrierMatch] }] }).status, 'ambiguous');
  assert.equal(collect([connection(7), complete], { ...receive, sockets: [address, address] }).status, 'ambiguous');

  const secondAddress = { ...address, browser_endpoint: '127.0.0.1:44002' };
  const secondConnection = [connection(8, secondAddress.browser_endpoint), { ...complete, source: { id: 8, type: 3 } }];
  const secondCarrier = { ...carrierMatch, socket: 1 };
  const secondSocket = { ...receive, sockets: [address, secondAddress], rows: [{ ...row, proxy: [secondCarrier] }] };
  assert.equal(collect(secondConnection, secondSocket).status, 'ambiguous', 'one page cannot claim two proxy sockets');
  const separatePage = { ...secondSocket, sockets: [address, { ...secondAddress, page_index: 1 }] };
  assert.equal(collect(secondConnection, separatePage, [null, recipient]).status, 'observed');
  assert.equal(collect(secondConnection, separatePage, [recipient, null]).status, 'unavailable', 'socket belongs to an untraced engine');
  assert.equal(collect(secondConnection, { ...separatePage, refused: 1 }, [null, recipient]).status, 'unavailable');
});

test('raw capture read is bounded and identifies unfinished or oversized logs', async () => {
  const { mkdtemp, rm, truncate, writeFile } = require('node:fs/promises');
  const { tmpdir } = require('node:os');
  const { join } = require('node:path');
  const directory = await mkdtemp(join(tmpdir(), 'fortress-socket-limit-'));
  const path = join(directory, 'netlog.json');
  try {
    await writeFile(path, '{"events":[');
    assert.deepEqual(await readChromiumLog(path), { status: 'truncated' });
    await truncate(path, 37 * 1024 * 1024);
    assert.deepEqual(await readChromiumLog(path), { status: 'truncated' });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('capture cleanup failure preserves the matched socket observation', async t => {
  const fs = require('node:fs/promises');
  const { tmpdir } = require('node:os');
  const { join } = require('node:path');
  const directory = await fs.mkdtemp(join(tmpdir(), 'fortress-socket-cleanup-'));
  const remove = fs.rm;
  const source = require.resolve('./native_chromium_socket.cjs');
  const original = require.cache[source];
  try {
    t.mock.method(fs, 'rm', async () => { throw new Error('controlled cleanup failure'); });
    delete require.cache[source];
    const { createChromiumCapture } = require(source);
    const capture = await createChromiumCapture(join(directory, 'web'));
    const path = capture.args[0].slice('--log-net-log='.length);
    await fs.writeFile(path, JSON.stringify({ constants, events: [connection(7), incoming(7, 70, Buffer.concat([handshake, frame]))] }));
    const result = await capture.finish(host, receive, [recipient]);
    assert.equal(result.rows[0].status, 'observed');
    assert.equal(result.cleanup_failed, true);
  } finally {
    require.cache[source] = original;
    await remove(directory, { recursive: true, force: true });
  }
});

// Value: protects=TLS completion ordering on the native expiry turn; fails_when=late callback replaces receipt time; why_new=real Chromium clocks; seam=loopback.
test('Chromium TLS and assembled renderer receipts distinguish an occupied native service turn',
  { skip: process.platform !== 'linux' || process.env.FORTRESS_TEST_CHROMIUM_SOCKET !== '1', timeout: 20000 }, async () => {
    const { execFileSync } = require('node:child_process');
    const { EventEmitter } = require('node:events');
    const { mkdir, mkdtemp, readFile, rm } = require('node:fs/promises');
    const { createServer } = require('node:https');
    const { tmpdir } = require('node:os');
    const { join } = require('node:path');
    const { setTimeout: pause } = require('node:timers/promises');
    const { observeChromiumFrames } = require('./native_chromium_frames.cjs');
    const { calibrateChromiumClock, createChromiumCapture, proxySocketAddress, readChromiumClock } = require('./native_chromium_socket.cjs');
    const { instrumentPostRelease, postReleaseCheckpoint } = require('./native_online.cjs');
    const directory = await mkdtemp(join(tmpdir(), 'fortress-socket-control-'));
    const keyPath = join(directory, 'key.pem');
    const certPath = join(directory, 'cert.pem');
    let server, socket, browser;
    try {
      execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
        '-keyout', keyPath, '-out', certPath], { stdio: 'ignore', timeout: 5000 });
      const payloads = ['before', carrier.toString(), 'after'];
      const digests = payloads.map(value => createHash('sha256').update(value).digest('hex'));
      const prefix = 'fortress native post-release ';
      const sender = '11111111-1111-1111-1111-111111111111';
      const receiver = '22222222-2222-2222-2222-222222222222';
      const nativeEvidence = { observed_us: 800000, sdk_queued: 0, sdk_peak: 0, sdk_before_poll: 0,
        service_started_us: 400000, service_gap_us: 16667, service_gap_peak_us: 20000, last_accepted: null };
      const html = `<script>
        window.start = () => {
          const socket = new WebSocket('wss://' + location.host + '/v3/ws?trace_page=0');
          const trace = window.fortressNativePostRelease;
          socket.binaryType = 'arraybuffer';
          socket.onopen = () => {
            trace.bindDeparture(${JSON.stringify(receiver)}, ${JSON.stringify([sender, receiver])});
            console.debug('relay socket opened');
          };
          socket.onmessage = async event => {
            const text = new TextDecoder().decode(event.data);
            if (text === 'before') setTimeout(() => {
              trace.beginNativeService();
              socket.send('during');
              const until = performance.now() + 750;
              while (performance.now() < until) {}
              trace.recordDeparture('native_expiry', 1, ${JSON.stringify(JSON.stringify(nativeEvidence))}, true);
            }, 75);
            if (text === ${JSON.stringify(carrier.toString())}) await fetch('/handled-exact-carrier');
            console.log(text);
          };
        };
      </script>`;
      server = createServer({ key: await readFile(keyPath), cert: await readFile(certPath) }, (request, response) =>
        response.end(request.url === '/' ? html : 'ok'));
      let proxySocket;
      const inlets = [];
      const send = async index => {
        await pause(75);
        const bytes = Buffer.from(payloads[index]);
        if (socket.destroyed) return;
        inlets[index] = performance.now();
        if (index === 1) {
          socket.write(Buffer.concat([Buffer.from([0x02, 3]), bytes.subarray(0, 3)]));
          await pause(25);
          if (!socket.destroyed) socket.write(Buffer.concat([Buffer.from([0x80, bytes.length - 3]), bytes.subarray(3)]));
        } else socket.write(Buffer.concat([Buffer.from([0x82, bytes.length]), bytes]));
      };
      server.on('upgrade', (request, upgraded) => {
        socket = upgraded;
        proxySocket = proxySocketAddress(request, socket);
        const accept = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        socket.write(Buffer.concat([handshake.subarray(0, -2), Buffer.from(`Sec-WebSocket-Accept: ${accept}\r\n\r\n`)]));
        // The page sends once, from inside the service turn. A partial read already proves the send started.
        socket.once('data', () => void send(1));
      });
      await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
      const endpoint = `127.0.0.1:${server.address().port}`;
      const exportParent = join(directory, 'long-export-path-'.repeat(6));
      await mkdir(exportParent);
      const capture = await createChromiumCapture(join(exportParent, 'web'));
      const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
      browser = await chromium.launch({ executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE, args: capture.args });
      const page = await browser.newPage({ ignoreHTTPSErrors: true });
      const cdp = await page.context().newCDPSession(page);
      const delivery = new EventEmitter();
      delivery.send = cdp.send.bind(cdp);
      delivery.detach = cdp.detach.bind(cdp);
      const frameEvent = 'Network.webSocketFrameReceived';
      const socketEvent = 'Network.webSocketCreated';
      cdp.on(socketEvent, event => delivery.emit(socketEvent, event));
      const firstPayload = Buffer.from(payloads[0]).toString('base64');
      const lastPayload = Buffer.from(payloads[2]).toString('base64');
      const lastFrame = Promise.withResolvers();
      let held, heldAt, expiryReceivedMs;
      cdp.on(frameEvent, event => {
        if (event.response.payloadData === firstPayload && expiryReceivedMs === undefined) {
          held = event;
          heldAt = performance.now();
          return;
        }
        delivery.emit(frameEvent, event);
        if (event.response.payloadData === lastPayload) lastFrame.resolve();
      });
      const observe = await observeChromiumFrames({ newCDPSession: async () => delivery }, page, `wss://${endpoint}/v3/ws?trace_page=0`);
      await page.addInitScript(`(${instrumentPostRelease})(${JSON.stringify(prefix)}, 40, ${readChromiumClock}, 'chromium_service');`);
      const reporter = {};
      page.on('console', message => {
        const value = message.text();
        if (value === 'relay socket opened') void send(0);
        if (!value.startsWith(prefix)) return;
        expiryReceivedMs = performance.now();
        postReleaseCheckpoint(reporter, value, { controller_ms: expiryReceivedMs, controller_order: 1 }, [sender, receiver], receiver);
        if (held) delivery.emit(frameEvent, held);
        void send(2);
      });
      await page.goto(`https://${endpoint}/`);
      const calibration = await calibrateChromiumClock(page);
      await Promise.all([
        ...payloads.map(value => page.waitForEvent('console', { predicate: msg => msg.text() === value, timeout: 10000 })),
        page.evaluate(() => window.start()),
      ]);
      await Promise.race([lastFrame.promise, pause(4000, undefined, { ref: false }).then(() => {
        throw new Error('missing final DevTools frame before capture cutoff');
      })]);
      const snapshot = observe.snapshot();
      await observe.close();
      await browser.close();
      browser = undefined;
      const { log } = await readChromiumLog(capture.args[0].slice('--log-net-log='.length));
      const input = { ...receive, sockets: [proxySocket], rows: digests.map((carrier_sha256, index) => ({ ...row, seq: String(index + 42),
        proxy: [{ ...carrierMatch, ordinal: index + 3, carrier_sha256, inlet_ms: inlets[index] }] })) };
      assert.ok(reporter.native_expiry, reporter.checkpoint_error);
      const seen = await capture.finish(endpoint, input, [recipient], [calibration], [reporter.native_expiry], [snapshot]);
      assert.equal(seen.status, 'recorded');
      assert.equal(seen.expiries[0].status, 'bounded');
      assert.deepEqual(seen.rows.map(row => row.observation?.expiry_timing?.order), ['before', 'unresolved', 'after']);
      const renderer = seen.rows.map(row => row.renderer?.observation);
      assert.equal(renderer[0]?.expiry_timing.order, 'before');
      assert.ok(heldAt < expiryReceivedMs && renderer[0].controller_ms > expiryReceivedMs, 'held debugger delivery follows native expiry receipt');
      assert.notEqual(renderer[1]?.expiry_timing.order, 'before');
      assert.equal(renderer[2]?.expiry_timing.order, 'after');
      assert.equal(renderer[1].carrier_sha256, digest, 'one digest for the complete fragmented binary message');
      assert.equal(seen.renderer.pages[0].status, 'attached');
      assert.equal(seen.renderer.pages[0].count, 3, 'one observer event per complete message');
      const [, exact] = seen.rows;
      assert.equal(exact.status, 'observed');
      assert.equal(exact.observation.carrier_sha256, digest);
      const markers = log.events.filter(event => event.type === log.constants.logEventTypes.SSL_SOCKET_BYTES_SENT
        && event.params?.bytes && Buffer.from(event.params.bytes, 'base64').includes('GET /handled-exact-carrier '));
      assert.equal(markers.length, 1);
      const tlsToRenderer = renderer[1].at_ms - exact.observation.at_ms;
      assert.ok(tlsToRenderer >= 300, `TLS receipt preceded the renderer by only ${tlsToRenderer} ms`);
      const earlier = Number(markers[0].time) - exact.observation.at_ms;
      assert.ok(earlier >= 300, `TLS receipt preceded the page marker by only ${earlier} ms`);
      console.log(JSON.stringify({ tls_timing: seen.rows.map(row => row.observation.expiry_timing),
        blink_timing: renderer.map(frame => frame.expiry_timing), delayed_page_handler_ms: earlier,
        tls_to_blink_ms: tlsToRenderer, debugger_delivery_delay_ms: renderer[0].controller_ms - heldAt }));
    } finally {
      await browser?.close();
      socket?.destroy();
      server?.close();
      await rm(directory, { recursive: true, force: true });
    }
  });
