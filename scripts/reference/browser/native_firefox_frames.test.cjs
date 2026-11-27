const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { EventEmitter, once } = require('node:events');
const { test } = require('node:test');
const { joinFirefoxFrames, observeFirefoxFrames, readFirefoxClock, firefoxExpiryWindow } = require('./native_firefox_frames.cjs');
const { instrumentPostRelease, postReleaseCheckpoint } = require('./native_online.cjs');

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

test('expiry clock bounds stay on the reporting page, expired sender and exact carrier', () => {
  const { page, socket } = fakePage();
  const observers = [, observeFirefoxFrames(page, endpoint)];
  const frame = socket();
  frame(carrier.toString('base64'), 100);
  const expiry = { uuid: 'cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd', page_ms: 25 };
  const sample = (wall_ms, page) => ({ wall_ms, page_before_ms: page - 0.1, page_after_ms: page + 0.1 });
  const withWindow = (before, after) => ({ ...expiry, firefox_clock: firefoxExpiryWindow([before, after], expiry.page_ms) });
  const bounds = wall => withWindow(sample(wall, 10), sample(wall + 10, 20));
  const join = (expiries, input = receive) => joinFirefoxFrames(observers, input, [, recipient], 0, expiries).rows[0];
  for (const [wall, order, range] of [[120, 'before', [-32, -18]], [70, 'after', [18, 32]], [95, 'unresolved', [-7, 7]]]) {
    const row = join([, bounds(wall)]);
    assert.equal(row.observation.expiry_timing.order, order);
    assert.deepEqual([row.observation.expiry_timing.min_gap_ms, row.observation.expiry_timing.max_gap_ms], range);
    assert.equal(row.observation.callback_after_failure_publication, true);
  }
  for (const after of [null, sample(119, 20), sample(300, 20), sample(130, 30)]) {
    assert.deepEqual(join([, withWindow(sample(120, 10), after)]).observation.expiry_timing, { order: 'unresolved', reason: 'invalid' });
  }
  assert.deepEqual(join([, expiry]).observation.expiry_timing, { order: 'unresolved', reason: 'unavailable' });
  for (const wall of [102, 88]) assert.equal(join([, bounds(wall)]).observation.expiry_timing.order, 'unresolved');
  assert.equal(join([bounds(120)]).observation.expiry_timing, undefined);
  assert.equal(join([, { ...bounds(120), uuid: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' }]).observation.expiry_timing, undefined);
  const wrongCarrier = { ...receive, rows: [{ ...packet, proxy: [{ ...proxy, carrier_sha256: hash(Buffer.from('other')) }] }] };
  assert.equal(join([, bounds(120)], wrongCarrier).observation, undefined);
  socket();
  assert.equal(join([, bounds(120)]).observation, undefined);
});

// Value: protects=Gecko-to-native ordering despite callback delay; fails_when=callback time or overlapping bounds decide order; why_new=real Firefox; seam=loopback.
test('Gecko source frames bracket expiry even when Firefox delays the debugger callback',
  { skip: process.env.FORTRESS_TEST_FIREFOX_FRAMES !== '1', timeout: 20000 }, async () => {
    const { createServer } = require('node:http');
    const { setTimeout: pause } = require('node:timers/promises');
    const carriers = [carrier, Buffer.from([1, 10]), Buffer.from([1, 11])];
    const digests = carriers.map(hash);
    const sender = 'cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd';
    const local = 'abababab-abab-abab-abab-abababababab';
    const prefix = 'fortress native post-release ';
    const nativeEvidence = { observed_us: 800000, sdk_queued: 0, sdk_peak: 0, sdk_before_poll: 0,
      service_started_us: 400000, service_gap_us: 16667, service_gap_peak_us: 20000, last_accepted: null };
    const server = createServer((_request, response) => {
      response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
      response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
      response.end(`<script>
        const ws = new WebSocket('ws://' + location.host + '/v3/ws?trace_page=1');
        const trace = window.fortressNativePostRelease;
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => {
          trace.bindDeparture(${JSON.stringify(local)}, ${JSON.stringify([local, sender])});
          const start = performance.now();
          ws.send('ready');
          while (performance.now() < start + 400) {}
          trace.beginNativeService();
          while (performance.now() < start + 850) {}
          trace.recordDeparture('native_expiry', 2, ${JSON.stringify(JSON.stringify(nativeEvidence))}, true);
          while (performance.now() < start + 1100) {}
        };
        ws.onmessage = event => {
          const index = ${JSON.stringify(carriers.map(bytes => [...bytes].join(',')))}.indexOf(new Uint8Array(event.data).join(','));
          if (index !== -1) ws.send('handled carrier ' + index);
        };
      </script>`);
    });
    let browser;
    let socket;
    let expiryCallbackMs;
    let firstCallbackWallMs;
    const inlet = [];
    const sent = [];
    const reporter = {};
    const send = index => {
      if (socket.destroyed) return;
      inlet[index] = performance.now();
      const bytes = carriers[index];
      socket.write(Buffer.concat([Buffer.from([0x82, bytes.length]), bytes]));
    };
    try {
      server.on('upgrade', (request, upgraded) => {
        socket = upgraded;
        const token = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + token + '\r\n\r\n');
        socket.once('data', () => {
          setTimeout(send, 80, 0).unref();
          setTimeout(send, 560, 1).unref();
        });
      });
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      const host = `127.0.0.1:${server.address().port}`;
      const { firefox } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
      browser = await firefox.launch({ executablePath: process.env.FORTRESS_FIREFOX_EXECUTABLE });
      const page = await browser.newPage();
      const target = `ws://${host}/v3/ws?trace_page=1`;
      const snapshot = observeFirefoxFrames(page, target);
      await page.addInitScript(`(${instrumentPostRelease})(${JSON.stringify(prefix)}, 40, ${readFirefoxClock});`);
      page.on('console', message => {
        const text = message.text();
        if (!text.startsWith(prefix)) return;
        expiryCallbackMs = performance.now();
        postReleaseCheckpoint(reporter, text, { controller_ms: expiryCallbackMs, controller_order: 1 }, [local, sender], local);
        setTimeout(send, 40, 2).unref();
      });
      const handled = new Promise(resolve => {
        page._connection.toImpl(page).on('websocket', ws => {
          if (ws.url() !== target) return;
          ws.on('framereceived', ({ opcode, data }) => {
            if (opcode === 2 && data === carrier.toString('base64')) firstCallbackWallMs = Date.now();
          });
          ws.on('framesent', ({ opcode, data, wallTimeMs }) => {
            const index = typeof data === 'string' ? /^handled carrier ([012])$/.exec(data)?.[1] : undefined;
            if (opcode !== 1 || index === undefined) return;
            sent[index] = wallTimeMs;
            if (carriers.every((_, index) => Number.isFinite(sent[index]))) resolve();
          });
        });
      });
      await page.goto(`http://${host}`);
      await Promise.race([handled, pause(8000, null, { ref: false }).then(() => { throw new Error('missing exact carrier acknowledgements'); })]);
      await browser.close();
      browser = undefined;
      assert.ok(reporter.native_expiry, reporter.checkpoint_error);
      const input = { ...receive, rows: digests.map((carrier_sha256, index) => ({
        ...packet, seq: String(3 + index), proxy: [{ ...proxy, ordinal: 6 + index, inlet_ms: inlet[index], carrier_sha256 }],
      })) };
      const result = joinFirefoxFrames([, snapshot], input, [, recipient], expiryCallbackMs, [, reporter.native_expiry]);
      const expiryWindow = result.pages[0].native_expiry;
      assert.equal(expiryWindow.status, 'bounded');
      assert.ok(firstCallbackWallMs > expiryWindow.max_gecko_ms, 'the first debugger notification must follow the expiry window');
      const samples = result.rows.map(({ status, observation }) => {
        assert.equal(status, 'observed');
        return observation;
      });
      assert.deepEqual(samples.map(sample => sample.expiry_timing.order), ['before', 'unresolved', 'after']);
      const earlier = sent[0] - samples[0].gecko_ms;
      const callbackDelay = samples[0].controller_ms - inlet[0];
      assert.ok(earlier >= 300, `handling followed the frame by only ${earlier} ms`);
      assert.ok(callbackDelay >= 300, `debugger notification followed the write by only ${callbackDelay} ms`);
      assert.equal(samples[2].callback_after_failure_publication, true);
      console.log(JSON.stringify({ carrier_timing: samples.map(sample => sample.expiry_timing),
        first_frame_to_handler_ms: earlier, first_write_to_debugger_ms: callbackDelay }));
    } finally {
      await browser?.close();
      socket?.destroy();
      server.close();
    }
  });
