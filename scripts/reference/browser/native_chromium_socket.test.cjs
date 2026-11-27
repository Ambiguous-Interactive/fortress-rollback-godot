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
  assert.deepEqual(observe({ clocks: [{ ...calibration, start_ms: Number.MAX_VALUE, end_ms: Number.MAX_VALUE }],
    expiries: [{ ...expiry, page_ms: huge.page_ms, chromium_service: { before: huge, after: huge } }] }).observation.expiry_timing,
  { order: 'unresolved', reason: 'invalid' });
  assert.equal(observe({ expiries: [{ ...expiry, uuid: '44444444-4444-4444-4444-444444444444' }] }).observation.expiry_timing, undefined);
  assert.equal(observe({ input: { ...receive, rows: [{ ...row, proxy: [carrierMatch, carrierMatch] }] } }).observation, undefined);
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
test('Chromium TLS receipts bound expiry while the renderer is busy',
  { skip: process.platform !== 'linux' || process.env.FORTRESS_TEST_CHROMIUM_SOCKET !== '1', timeout: 20000 }, async () => {
    const { execFileSync } = require('node:child_process');
    const { mkdir, mkdtemp, readFile, rm } = require('node:fs/promises');
    const { createServer } = require('node:https');
    const { tmpdir } = require('node:os');
    const { join } = require('node:path');
    const { setTimeout: pause } = require('node:timers/promises');
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
      const send = async index => {
        await pause(75);
        const value = payloads[index];
        if (!socket.destroyed) socket.write(Buffer.concat([Buffer.from([0x82, value.length]), Buffer.from(value)]));
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
      await page.addInitScript(`(${instrumentPostRelease})(${JSON.stringify(prefix)}, 40, ${readChromiumClock}, 'chromium_service');`);
      const reporter = {};
      page.on('console', message => {
        const value = message.text();
        if (value === 'relay socket opened') void send(0);
        if (!value.startsWith(prefix)) return;
        postReleaseCheckpoint(reporter, value, { controller_ms: performance.now(), controller_order: 1 }, [sender, receiver], receiver);
        void send(2);
      });
      await page.goto(`https://${endpoint}/`);
      const calibration = await calibrateChromiumClock(page);
      await Promise.all([
        ...payloads.map(value => page.waitForEvent('console', { predicate: msg => msg.text() === value, timeout: 10000 })),
        page.evaluate(() => window.start()),
      ]);
      await browser.close();
      browser = undefined;
      const { log } = await readChromiumLog(capture.args[0].slice('--log-net-log='.length));
      const input = { ...receive, sockets: [proxySocket], rows: digests.map((carrier_sha256, index) => ({ ...row, seq: String(index + 42),
        proxy: [{ ...carrierMatch, ordinal: index + 3, carrier_sha256 }] })) };
      assert.ok(reporter.native_expiry, reporter.checkpoint_error);
      const seen = await capture.finish(endpoint, input, [recipient], [calibration], [reporter.native_expiry]);
      assert.equal(seen.status, 'recorded');
      assert.equal(seen.expiries[0].status, 'bounded');
      assert.deepEqual(seen.rows.map(row => row.observation?.expiry_timing?.order), ['before', 'unresolved', 'after']);
      const [, exact] = seen.rows;
      assert.equal(exact.status, 'observed');
      assert.equal(exact.observation.carrier_sha256, digest);
      const markers = log.events.filter(event => event.type === log.constants.logEventTypes.SSL_SOCKET_BYTES_SENT
        && event.params?.bytes && Buffer.from(event.params.bytes, 'base64').includes('GET /handled-exact-carrier '));
      assert.equal(markers.length, 1);
      const earlier = Number(markers[0].time) - exact.observation.at_ms;
      assert.ok(earlier >= 300, `TLS receipt preceded the page marker by only ${earlier} ms`);
      console.log(JSON.stringify({ carrier_timing: seen.rows.map(row => row.observation.expiry_timing), delayed_page_handler_ms: earlier }));
    } finally {
      await browser?.close();
      socket?.destroy();
      server?.close();
      await rm(directory, { recursive: true, force: true });
    }
  });
