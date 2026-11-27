const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { EventEmitter, once } = require('node:events');
const { test } = require('node:test');
const { joinFirefoxFrames, observeFirefoxFrames } = require('./native_firefox_frames.cjs');

const carrier = Buffer.concat([Buffer.from([1]), Buffer.from('known addressed carrier')]);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = hash(carrier);
const recipient = 'ab'.repeat(16);
const endpoint = 'wss://127.0.0.1:443/v3/ws?trace_page=1';
const packet = { sender: 'cd'.repeat(16), recipient, epoch: 2, seq: '3', envelope_sha256: 'de'.repeat(32), envelope_bytes: 91 };
const proxy = { socket: 0, ordinal: 6, inlet_ms: 0, outlet_ms: 20, carrier_sha256: digest };
const receive = { room: 'ef'.repeat(16), refused: 0, sockets: [{ page_index: 1 }, { page_index: 0 }],
  rows: [{ ...packet, proxy: [proxy], message: [] }] };

function fakePage() {
  const source = new EventEmitter();
  return {
    page: { _connection: { toImpl: () => source } },
    socket(url = endpoint) {
      const socket = new EventEmitter();
      socket.url = () => url;
      source.emit('websocket', socket);
      return (data, timestamp = 94) => socket.emit('framereceived', { opcode: 2, data, wallTimeMs: timestamp });
    },
  };
}

// Value: protects=bounded exact frame evidence; fails_when=rollover, malformed data or an unbound page yields a match; why_new=Gecko timestamp boundary; seam=server events.
test('Firefox frame receipts bind exact observed carriers to the frozen recipient and unique proxy', () => {
  const { page, socket } = fakePage();
  const observers = [, observeFirefoxFrames(page, endpoint, 2)];
  const frame = socket();
  socket(endpoint + 'other')(carrier.toString('base64'));
  frame('AX=='); // The byte is 1, but padding bits are nonzero.
  frame(Buffer.alloc(2049, 1).toString('base64'));
  frame(carrier.toString('base64'), NaN);
  const bytes = n => Buffer.from([1, n]);
  frame(bytes(4).toString('base64'));
  frame(carrier.toString('base64'));
  frame(bytes(5).toString('base64'));

  const join = (input = receive, roster = [, recipient], failurePublishedMs = 0) => joinFirefoxFrames(observers, input, roster, failurePublishedMs);
  const result = join();
  assert.deepEqual(result.pages, [{ index: 1, recipient, supported: true, sockets: 1, count: 3, omitted: 1, rejected: 3, proxy: [0] }]);
  assert.equal(result.coverage, 'debugger-callback-dependent');
  const row = result.rows[0];
  assert.equal(row.status, 'observed');
  assert.deepEqual(row.observation, {
    proxy_ordinal: 6, ordinal: 2, gecko_ms: 94, controller_ms: row.observation.controller_ms,
    carrier_sha256: digest, callback_after_failure_publication: true,
  });
  assert.equal(join(receive, [, recipient], performance.now()).rows[0].observation.callback_after_failure_publication, false);
  assert.equal(join(receive, [recipient]).rows.length, 0);
  const withWrites = (...proxy) => join({ ...receive, rows: [{ ...packet, proxy }] }).rows[0];
  for (const input of [{ inlet_ms: performance.now() }, { carrier_sha256: hash(bytes(4)) }, { socket: 1 }]) {
    const row = withWrites({ ...proxy, ...input });
    assert.equal(row.status, 'unobserved');
    assert.equal(row.observation, undefined);
  }
  assert.equal(withWrites(proxy, { ...proxy, ordinal: 7 }).status, 'ambiguous');
  assert.equal(join({ ...receive, sockets: [{ page_index: 0 }] }).rows[0].status, 'unavailable');
  assert.equal(join({ ...receive, sockets: [...receive.sockets, { page_index: 1 }] }).rows[0].status, 'ambiguous');
  assert.equal(join({ ...receive, refused: 1 }).rows[0].status, 'unavailable');
  frame(carrier.toString('base64'));
  frame(carrier.toString('base64'));
  assert.equal(join().rows[0].status, 'ambiguous');
  socket();
  assert.equal(join().rows[0].status, 'ambiguous');
  assert.equal(joinFirefoxFrames([, observeFirefoxFrames({}, endpoint)], receive, [, recipient]).rows[0].status, 'unavailable');
});

// Value: protects=Gecko receive clock identifies the exact carrier before a busy page handles it; fails_when=receipt uses callback time; why_new=real Firefox; seam=loopback.
test('Gecko records the exact frame before the busy Firefox page sends its acknowledgement',
  { skip: process.env.FORTRESS_TEST_FIREFOX_FRAMES !== '1', timeout: 20000 }, async () => {
    const { createServer } = require('node:http');
    const { setTimeout: pause } = require('node:timers/promises');
    const ack = 'handled exact carrier';
    const server = createServer((_request, response) => response.end(`<script>
      const ws = new WebSocket('ws://' + location.host + '/v3/ws?trace_page=1');
      ws.binaryType = 'arraybuffer';
      ws.onopen = () => {
        ws.send('ready');
        const until = performance.now() + 650;
        while (performance.now() < until) {}
      };
      ws.onmessage = event => {
        if (new Uint8Array(event.data).join(',') === ${JSON.stringify([...carrier].join(','))}) ws.send(${JSON.stringify(ack)});
      };
    </script>`));
    let browser;
    let socket;
    let inlet_ms;
    try {
      server.on('upgrade', (request, upgraded) => {
        socket = upgraded;
        const token = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + token + '\r\n\r\n');
        socket.once('data', async () => {
          await pause(85);
          if (socket.destroyed) return;
          inlet_ms = performance.now();
          socket.write(Buffer.concat([Buffer.from([0x82, carrier.length]), carrier]));
        });
      });
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      const host = `127.0.0.1:${server.address().port}`;
      const { firefox } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
      browser = await firefox.launch({ executablePath: process.env.FORTRESS_FIREFOX_EXECUTABLE });
      const page = await browser.newPage();
      const target = `ws://${host}/v3/ws?trace_page=1`;
      const sample = observeFirefoxFrames(page, target);
      const handled = new Promise(resolve => {
        page._connection.toImpl(page).on('websocket', ws => {
          if (ws.url() !== target) return;
          ws.on('framesent', ({ opcode, data, wallTimeMs }) => {
            if (opcode === 1 && data === ack) resolve(wallTimeMs);
          });
        });
      });
      await page.goto(`http://${host}`);
      const sent = await Promise.race([handled, pause(5000, null, { ref: false })]);
      assert.ok(Number.isFinite(sent), 'missing same-socket handler acknowledgement');
      await browser.close();
      browser = undefined;
      const input = { ...receive, rows: [{ ...packet, proxy: [{ ...proxy, inlet_ms }] }] };
      const [row] = joinFirefoxFrames([, sample], input, [, recipient]).rows;
      assert.equal(row.status, 'observed');
      const earlier = sent - row.observation.gecko_ms;
      assert.ok(earlier >= 300, `Gecko received the exact carrier only ${earlier} ms before its handler acknowledgement`);
      console.log(`Firefox received exact carrier ${digest} ${earlier.toFixed(3)} ms before its handler acknowledgement`);
    } finally {
      await browser?.close();
      socket?.destroy();
      server.close();
    }
  });
