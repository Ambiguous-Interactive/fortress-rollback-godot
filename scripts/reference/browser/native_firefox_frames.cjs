const { createHash } = require('node:crypto');

const FRAME_CAP = 8192;
const CARRIER_CAP = 2048;
const BASE64_CAP = 4 * Math.ceil(CARRIER_CAP / 3);

function observeFirefoxFrames(page, endpoint, capacity = FRAME_CAP) {
  // The pinned in-process Playwright server preserves Gecko's frame timestamp.
  let source;
  try {
    source = page._connection?.toImpl?.(page);
  } catch {
    // This private observer may be unavailable when the Playwright backend changes.
  }
  if (typeof source?.on !== 'function') return () => ({ supported: false, sockets: 0, count: 0, omitted: 0, rejected: 0, frames: [] });
  const frames = [];
  let sockets = 0;
  let count = 0;
  let rejected = 0;
  source.on('websocket', socket => {
    if (socket.url() !== endpoint || ++sockets !== 1) return;
    socket.on('framereceived', ({ opcode, data, wallTimeMs }) => {
      if (opcode !== 2 || sockets !== 1) return;
      if (!Number.isFinite(wallTimeMs) || wallTimeMs <= 0 || typeof data !== 'string' || !data.length || data.length > BASE64_CAP) {
        rejected++;
        return;
      }
      const bytes = Buffer.from(data, 'base64');
      if (bytes.length > CARRIER_CAP || bytes.toString('base64') !== data) {
        rejected++;
        return;
      }
      if (bytes[0] !== 1) return;
      frames[count % capacity] = { ordinal: ++count, gecko_ms: wallTimeMs, controller_ms: performance.now(),
        carrier_sha256: createHash('sha256').update(bytes).digest('hex') };
    });
  });
  return () => ({ supported: true, sockets, count, omitted: count - frames.length, rejected, frames: [...frames] });
}

function joinFirefoxFrames(observers, receive, recipients = [], failurePublishedMs) {
  const streams = new Map();
  const pages = [];
  for (const [index, snapshot] of observers.entries()) {
    if (!snapshot) continue;
    const { frames, ...coverage } = snapshot();
    const recipient = recipients[index] ?? null;
    const proxy = (receive?.sockets ?? []).flatMap((socket, ordinal) => socket.page_index === index ? [ordinal] : []);
    pages.push({ index, recipient, ...coverage, proxy });
    if (!recipient) continue;
    const byDigest = new Map();
    for (const frame of frames) {
      const digest = frame.carrier_sha256;
      if (!byDigest.has(digest)) byDigest.set(digest, []);
      byDigest.get(digest).push(frame);
    }
    streams.set(recipient, { ...coverage, proxy, byDigest });
  }
  const rows = (receive?.rows ?? []).flatMap(({ message, first_unobserved, coverage_gap, proxy, ...packet }) => {
    const stream = streams.get(packet.recipient);
    if (!stream) return [];
    let status = 'unobserved';
    let observation;
    if (!stream.supported || !stream.sockets || !stream.proxy.length || receive.refused) status = 'unavailable';
    else if (stream.sockets > 1 || stream.proxy.length > 1 || proxy.length > 1) status = 'ambiguous';
    else if (proxy.length === 1 && proxy[0].socket === stream.proxy[0] && Number.isFinite(proxy[0].inlet_ms)) {
      const [write] = proxy;
      const matching = (stream.byDigest.get(write.carrier_sha256) ?? []).filter(frame => frame.controller_ms > write.inlet_ms);
      if (matching.length > 1) status = 'ambiguous';
      else if (matching.length === 1) {
        status = 'observed';
        observation = { proxy_ordinal: write.ordinal, ...matching[0],
          callback_after_failure_publication: failurePublishedMs === undefined ? undefined : matching[0].controller_ms > failurePublishedMs };
      }
    }
    return [{ ...packet, status, observation }];
  });
  return { clock: 'firefox.gecko.websocket.time_ms', callback_clock: 'controller.performance.now',
    coverage: 'debugger-callback-dependent', room: receive?.room, pages, rows };
}

module.exports = { observeFirefoxFrames, joinFirefoxFrames };
