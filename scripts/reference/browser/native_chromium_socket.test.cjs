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

test('Chromium TLS receive leads the busy page callback on the same NetLog clock',
  { skip: process.env.FORTRESS_TEST_CHROMIUM_SOCKET !== '1', timeout: 20000 }, async () => {
    const { execFileSync } = require('node:child_process');
    const { mkdir, mkdtemp, readFile, rm } = require('node:fs/promises');
    const { createServer } = require('node:https');
    const { tmpdir } = require('node:os');
    const { join } = require('node:path');
    const { setTimeout: pause } = require('node:timers/promises');
    const { createChromiumCapture, proxySocketAddress } = require('./native_chromium_socket.cjs');
    const directory = await mkdtemp(join(tmpdir(), 'fortress-socket-control-'));
    const keyPath = join(directory, 'key.pem');
    const certPath = join(directory, 'cert.pem');
    let server, socket, browser;
    try {
      execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
        '-keyout', keyPath, '-out', certPath], { stdio: 'ignore', timeout: 5000 });
      const html = `<script>
        const socket = new WebSocket('wss://' + location.host + '/v3/ws?trace_page=0');
        socket.binaryType = 'arraybuffer';
        socket.onopen = () => {
          socket.send('ready');
          const until = performance.now() + 750;
          while (performance.now() < until) {}
        };
        socket.onmessage = async event => {
          await fetch('/handled-exact-carrier');
          console.log(new TextDecoder().decode(event.data));
        };
      </script>`;
      server = createServer({ key: await readFile(keyPath), cert: await readFile(certPath) }, (request, response) =>
        response.end(request.url === '/' ? html : 'ok'));
      let proxySocket;
      let written;
      server.on('upgrade', (request, upgraded) => {
        socket = upgraded;
        proxySocket = proxySocketAddress(request, socket);
        const accept = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        socket.write(Buffer.concat([handshake.subarray(0, -2), Buffer.from(`Sec-WebSocket-Accept: ${accept}\r\n\r\n`)]));
        written = new Promise((resolve, reject) => socket.once('data', () => {
          pause(75).then(() => socket.write(frame, error => error ? reject(error) : resolve()));
        }));
      });
      await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
      const endpoint = `127.0.0.1:${server.address().port}`;
      const exportParent = join(directory, 'long-export-path-'.repeat(6));
      await mkdir(exportParent);
      const capture = await createChromiumCapture(join(exportParent, 'web'));
      const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
      browser = await chromium.launch({ executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE, args: capture.args });
      const page = await browser.newPage({ ignoreHTTPSErrors: true });
      const handled = page.waitForEvent('console', { predicate: msg => msg.text() === carrier.toString(), timeout: 10000 });
      await page.goto(`https://${endpoint}/`);
      await handled;
      await written;
      await browser.close();
      browser = undefined;
      const { log } = await readChromiumLog(capture.args[0].slice('--log-net-log='.length));
      const seen = await capture.finish(endpoint, { ...receive, sockets: [proxySocket] }, [recipient]);
      assert.equal(seen.status, 'recorded');
      const [exact] = seen.rows;
      assert.equal(exact.status, 'observed');
      assert.equal(exact.observation.carrier_sha256, digest);
      const markers = log.events.filter(event => event.type === log.constants.logEventTypes.SSL_SOCKET_BYTES_SENT
        && event.params?.bytes && Buffer.from(event.params.bytes, 'base64').includes('GET /handled-exact-carrier '));
      assert.equal(markers.length, 1);
      const earlier = Number(markers[0].time) - exact.observation.at_ms;
      assert.ok(earlier >= 300, `TLS receipt preceded the page marker by only ${earlier} ms`);
      console.log(`Chromium received exact carrier ${digest} ${earlier} ms before the page handler marker`);
    } finally {
      await browser?.close();
      socket?.destroy();
      server?.close();
      await rm(directory, { recursive: true, force: true });
    }
  });
