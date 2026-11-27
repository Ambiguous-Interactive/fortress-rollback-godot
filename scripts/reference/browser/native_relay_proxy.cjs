const { createHash } = require('node:crypto');
const { Writable } = require('node:stream');
const { decodeRelayDelivery } = require('./native_relay_trace.cjs');

const CARRIER_CAP = 2048;
const EVENT_CAP = 8192;
const SOCKET_CAP = 16;

function createFrameReader() {
  const httpHeader = Buffer.alloc(16384);
  const frameHeader = Buffer.alloc(10);
  const payload = Buffer.alloc(CARRIER_CAP);
  let handshake = true;
  let closed = false;
  let httpBytes = 0;
  let headerBytes = 0;
  let headerSize = 2;
  let remaining = 0;
  let readingPayload = false;
  let fragmented = 0;
  let opcode = 0;
  let final = false;
  let capture = false;
  let size = 0;
  let tooLarge = false;
  let skipped = 0;
  let error = null;

  function push(chunk) {
    const messages = [];
    let offset = 0;
    while (offset < chunk.length && !error) {
      if (handshake) {
        httpHeader[httpBytes++] = chunk[offset++];
        if (httpBytes >= 4 && httpHeader.subarray(httpBytes - 4, httpBytes).toString('latin1') === '\r\n\r\n') {
          if (!/^HTTP\/1\.1 101 /.test(httpHeader.subarray(0, httpBytes).toString('latin1'))) error = 'WebSocket upgrade failed';
          handshake = false;
        } else if (httpBytes === httpHeader.length) error = 'WebSocket upgrade exceeded trace header capacity';
        continue;
      }
      if (!readingPayload) {
        const bytes = Math.min(headerSize - headerBytes, chunk.length - offset);
        chunk.copy(frameHeader, headerBytes, offset, offset + bytes);
        headerBytes += bytes;
        offset += bytes;
        if (headerBytes < headerSize) break;
        if (headerSize === 2) {
          const length = frameHeader[1];
          if ((frameHeader[0] & 0x70) || (length & 0x80)) {
            error = 'unsupported WebSocket frame flags';
            break;
          }
          headerSize = length === 126 ? 4 : length === 127 ? 10 : 2;
          if (headerSize !== 2) continue;
        }
        const length = headerSize === 10 ? frameHeader.readBigUInt64BE(2) : BigInt(headerSize === 4 ? frameHeader.readUInt16BE(2) : frameHeader[1]);
        opcode = frameHeader[0] & 0x0f;
        final = Boolean(frameHeader[0] & 0x80);
        const control = opcode >= 8 && opcode <= 10;
        if ((headerSize === 4 && length < 126n) || (headerSize === 10 && length < 65536n) || (closed && !control)) {
          error = 'invalid WebSocket frame boundary';
          break;
        }
        if (length > BigInt(Number.MAX_SAFE_INTEGER) || (control ? !final || length > 125n
          : opcode === 0 ? !fragmented : fragmented || (opcode !== 1 && opcode !== 2))) {
          error = 'invalid WebSocket frame sequence';
          break;
        }
        if (opcode === 2) {
          size = 0;
          tooLarge = false;
        }
        capture = opcode === 2 || (opcode === 0 && fragmented === 2);
        remaining = Number(length);
        if (capture && remaining > CARRIER_CAP - size) tooLarge = true;
        readingPayload = true;
      }
      const bytes = Math.min(remaining, chunk.length - offset);
      if (capture && !tooLarge) {
        chunk.copy(payload, size, offset, offset + bytes);
        size += bytes;
      }
      offset += bytes;
      remaining -= bytes;
      if (remaining) continue;
      if (capture && final) {
        if (tooLarge) skipped++;
        else messages.push(Buffer.from(payload.subarray(0, size)));
      }
      if (opcode === 8) closed = true;
      if (opcode < 8) fragmented = final ? 0 : opcode || fragmented;
      readingPayload = false;
      headerBytes = 0;
      headerSize = 2;
    }
    return messages;
  }
  return { push, status: () => ({ skipped, error }) };
}

function createRelayProxyTrace(socketAddress) {
  const sockets = [];
  let refused = 0;
  const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  const trace = {
    open(address) {
      if (sockets.length === SOCKET_CAP) {
        refused++;
        return null;
      }
      const reader = createFrameReader();
      const events = [];
      let count = 0;
      let rejected = 0;
      function inlet(chunk) {
        const at_ms = performance.now();
        return reader.push(chunk).flatMap(bytes => {
          if (bytes[0] !== 1) return [];
          const delivery = decodeRelayDelivery(bytes);
          const envelope = delivery?.envelope;
          if (!envelope || envelope.length < 85 || envelope.length > 1257
              || envelope.readUInt32BE(0) !== 0x46535231 || envelope[4] !== 1 || envelope.readUInt32LE(53) !== envelope.length - 57
              || envelope.subarray(21, 37).toString('hex') !== delivery.from) {
            rejected++;
            return [];
          }
          const sender = delivery.from;
          const event = { ordinal: ++count, inlet_ms: at_ms, outlet_ms: null, room: envelope.subarray(5, 21).toString('hex'),
            sender, recipient: envelope.subarray(37, 53).toString('hex'), epoch: delivery.epoch, seq: delivery.seq, lane: 'addressed',
            envelope_bytes: envelope.length, envelope_sha256: hash(envelope), carrier_sha256: hash(bytes) };
          events[(count - 1) % EVENT_CAP] = event;
          return [event];
        });
      }
      sockets.push({ snapshot: () => ({ ...address, count, omitted: count - events.length, rejected, ...reader.status(), events: [...events]
        .sort((a, b) => a.ordinal - b.ordinal).map(event => ({ ...event })) }) });
      return inlet;
    },
    forward(upstream, socket, request) {
      const inlet = trace.open(socketAddress?.(request, socket));
      if (inlet) traceProxyWrites(upstream, socket, inlet, trace.beforeForward);
      else upstream.pipe(socket);
    },
    snapshot: () => ({ clock: 'controller.performance.now', refused, sockets: sockets.map(socket => socket.snapshot()) }),
  };
  return trace;
}

function traceProxyWrites(upstream, socket, inlet, beforeForward) {
  const pending = [];
  const observe = chunk => { pending.push(inlet(chunk)); };
  const forwarding = new Writable({
    write(chunk, _encoding, done) {
      const events = pending.shift();
      const forward = () => {
        socket.write(chunk, error => {
          if (!error) {
            const at_ms = performance.now();
            for (const event of events) event.outlet_ms = at_ms;
          }
          done(error);
        });
      };
      if (!beforeForward || !events.length) forward();
      else Promise.resolve().then(() => beforeForward(events)).then(forward, done);
    },
    final(done) { socket.end(done); },
  });
  forwarding.on('error', () => { socket.destroy(); upstream.destroy(); });
  socket.once('close', () => forwarding.destroy());
  forwarding.once('close', () => {
    upstream.off('data', observe);
    pending.length = 0;
  });
  upstream.on('data', observe);
  upstream.pipe(forwarding);
}

module.exports = { createFrameReader, createRelayProxyTrace, joinRelayReceive, refreshRelayReceive, relayExpiryTraffic, traceProxyWrites };

function packetKey({ sender, recipient, epoch, seq, envelope_sha256, envelope_bytes }) {
  return `${sender}/${recipient}/${epoch}/${seq}/${envelope_bytes}/${envelope_sha256}`;
}

function joinRelayReceive(joined, proxy, pages, room) {
  const carriers = new Map();
  const pageStreams = {};
  for (const page of pages ?? []) {
    if (!page?.carriers) continue;
    if (page.room !== room) continue;
    const { events, ...coverage } = page.carriers;
    pageStreams[page.local] = { ...coverage, started_ms: page.carrier_capture_started_ms,
      raw_omitted: Object.fromEntries(Object.entries(page.streams.raw).map(([family, stream]) => [family, stream.omitted])) };
    const decoded = new Map();
    for (const stream of Object.values(page.streams.raw)) {
      for (const packet of stream.events ?? []) if (packet.carrier_ordinal !== undefined) decoded.set(packet.carrier_ordinal, packet);
    }
    for (const event of events) {
      const id = `${page.local}/${event.carrier_sha256}`;
      if (!carriers.has(id)) carriers.set(id, []);
      carriers.get(id).push({ ...event, decoded: decoded.get(event.ordinal) });
    }
  }
  const byStamp = new Map();
  const sockets = proxy.sockets.map(({ events, ...coverage }, socket) => {
    for (const { ordinal, inlet_ms, outlet_ms, carrier_sha256, ...packet } of events) {
      if (packet.room !== room) continue;
      const id = packetKey(packet);
      if (!byStamp.has(id)) byStamp.set(id, []);
      byStamp.get(id).push({ socket, ordinal, inlet_ms, outlet_ms, carrier_sha256 });
    }
    return coverage;
  });
  const proxyIncomplete = !sockets.length || proxy.refused > 0 || sockets.some(socket => socket.error || socket.omitted || socket.skipped || socket.rejected);
  const rows = (joined?.rows ?? []).filter(row => row.lane === 'addressed' && row.write.length).map(row => {
    const { sender, recipient, epoch, seq, kind, envelope_sha256, envelope_bytes } = row;
    const proxyMatches = byStamp.get(packetKey(row)) ?? [];
    const completed = proxyMatches.filter(event => event.outlet_ms !== null);
    const message = [...new Set(completed.map(event => event.carrier_sha256))].flatMap(digest =>
      (carriers.get(`${recipient}/${digest}`) ?? []).map(({ decoded, ...event }) =>
        ({ ...event, decoded: decoded !== undefined && packetKey(decoded) === packetKey(row) })));
    const browserCoverage = pageStreams[recipient];
    const ordered = browserCoverage && completed.every(event => event.outlet_ms <= browserCoverage.started_ms);
    let first_unobserved = null;
    let coverage_gap = null;
    if (!proxyMatches.length) {
      if (proxyIncomplete) coverage_gap = 'proxy_capture';
      else first_unobserved = 'proxy_inlet';
    } else if (!completed.length) {
      if (proxyIncomplete) coverage_gap = 'proxy_capture';
      else first_unobserved = 'proxy_outlet';
    } else if (!message.length) {
      if (proxyIncomplete) coverage_gap = 'proxy_capture';
      else if (!browserCoverage || browserCoverage.omitted || browserCoverage.skipped) coverage_gap = 'browser_capture';
      else if (!ordered) coverage_gap = 'capture_order';
      else first_unobserved = 'browser_message';
    } else if (!message.some(event => event.decoded)) {
      if (proxyIncomplete) coverage_gap = 'proxy_capture';
      else if (browserCoverage.omitted || browserCoverage.skipped || browserCoverage.raw_omitted[row.family]) coverage_gap = 'decoder_capture';
      else first_unobserved = 'relay_decode';
    }
    return { sender, recipient, epoch, seq, kind, envelope_sha256, envelope_bytes, proxy: proxyMatches,
      message, first_unobserved, coverage_gap };
  });
  return { clock: proxy.clock, room, refused: proxy.refused, sockets, pages: pageStreams, rows };
}

function refreshRelayReceive(original, joined, proxy) {
  const settled = joinRelayReceive(joined, proxy, [], original.room);
  // Both joins use the same ordered server rows and stable proxy socket indices.
  settled.rows = settled.rows.map((row, index) => {
    const previous = original.rows[index].proxy;
    if (previous.length > 1) return { ...row, proxy: previous };
    if (row.proxy.length !== 1) return row;
    const [old] = previous;
    const [current] = row.proxy;
    if (old?.socket === current.socket && old.ordinal === current.ordinal) return row;
    return { ...row, proxy: [] };
  });
  return settled;
}

function relayExpiryTraffic(expiries, joined, pages, receive) {
  const rows = joined?.rows ?? [];
  const messages = new Map((receive?.rows ?? []).map(row => [packetKey(row), row.message]));
  return expiries.flatMap(({ page_ms, controller_ms, frontier }) => {
    if (!frontier) return [];
    const { room, sender, recipient } = frontier;
    const matchedPages = (pages ?? []).filter(page => page?.room === room && page.local === recipient && page.clock === 'page.performance.now');
    const page = matchedPages.length === 1 ? matchedPages[0] : null;
    return frontier.packets.map(packet => {
      const family = packet.kind === 2 ? 'input' : 'quality';
      const link = rows.filter(row => row.sender === sender && row.recipient === recipient && row.family === family);
      const anchor = link.find(row => row.lane === packet.lane && packetKey(row) === packetKey(packet));
      const anchor_candidates = anchor?.write ?? [];
      const anchor_write = anchor_candidates.length === 1 ? anchor_candidates[0] : null;
      const stages = ['raw', 'sdk', 'native'];
      const marks = stages.map(stage => page?.streams?.[stage]?.[family]?.events);
      const byOrdinal = Object.fromEntries(stages.map((stage, index) => [stage,
        new Map((Array.isArray(marks[index]) ? marks[index] : []).map(event => [event?.ordinal, event]))]));
      const page_coverage = page ? (marks.every(Array.isArray) ? 'retained' : 'partial') : matchedPages.length ? 'ambiguous' : 'unavailable';
      const following_writes = anchor_write === null ? [] : link.flatMap(row => {
        const write = row.write.filter(ordinal => ordinal > anchor_write);
        if (row === anchor || !write.length) return [];
        const events = { message: page && receive?.room === room && row.lane === 'addressed' ? messages.get(packetKey(row)) ?? [] : [] };
        for (const stage of stages) events[stage] = row[stage].map(ordinal => byOrdinal[stage].get(ordinal)).filter(Boolean);
        const partition = before => Object.fromEntries(Object.entries(events).map(([stage, marks]) =>
          [stage, marks.filter(mark => Number.isFinite(mark.at_ms) && (mark.at_ms < page_ms) === before).map(mark => mark.ordinal)]));
        const { lane, epoch, seq, kind, envelope_bytes, envelope_sha256 } = row;
        return [{ lane, epoch, seq, kind, envelope_bytes, envelope_sha256, write, write_candidates: row.write,
          observation_write_ambiguous: write.length !== row.write.length, before_expiry: partition(true), at_or_after_expiry: partition(false) }];
      });
      following_writes.sort((a, b) => a.write[0] - b.write[0]);
      const { lane, epoch, seq, envelope_sha256 } = packet;
      return { room, sender, recipient, family, page_ms, controller_ms, lane, epoch, seq, envelope_sha256, anchor_candidates, anchor_write,
        page_coverage, following_writes };
    });
  });
}
