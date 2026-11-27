const { createHash } = require('node:crypto');

const FRAME_CAP = 8192;
const CARRIER_CAP = 2048;
const BASE64_CAP = 4 * Math.ceil(CARRIER_CAP / 3);
// Cover Firefox's isolated timer precision, integer Date.now() and timestamp conversion.
const CLOCK_PRECISION_MS = 2;

function readFirefoxClock() {
  if (!globalThis.crossOriginIsolated) return null;
  const page_before_ms = performance.now();
  const wall_ms = Date.now();
  return { wall_ms, page_before_ms, page_after_ms: performance.now() };
}

function firefoxExpiryWindow(firefox_clock, page_ms) {
  if (firefox_clock === undefined) return { status: 'unavailable' };
  const [before, after] = Array.isArray(firefox_clock) && firefox_clock.length === 2 ? firefox_clock : [];
  const sample = ({ wall_ms, page_before_ms, page_after_ms } = {}) => Number.isSafeInteger(wall_ms) && wall_ms > CLOCK_PRECISION_MS
    && Number.isFinite(page_before_ms) && page_before_ms >= 0 && Number.isFinite(page_after_ms) && page_after_ms >= page_before_ms
    ? { wall_ms, page_before_ms, page_after_ms } : null;
  const samples = { before: sample(before ?? undefined), after: sample(after ?? undefined) };
  const invalid = { status: 'invalid', ...samples };
  if (!samples.before || !samples.after || after.page_before_ms < before.page_after_ms || !Number.isFinite(page_ms)
    || after.page_after_ms > page_ms || after.wall_ms < before.wall_ms) return invalid;
  const wallElapsed = after.wall_ms - before.wall_ms;
  if (wallElapsed + 2 * CLOCK_PRECISION_MS < after.page_before_ms - before.page_after_ms
    || wallElapsed - 2 * CLOCK_PRECISION_MS > after.page_after_ms - before.page_before_ms) return invalid;
  return { status: 'bounded', ...samples, min_gecko_ms: before.wall_ms - CLOCK_PRECISION_MS, max_gecko_ms: after.wall_ms + CLOCK_PRECISION_MS };
}

function expiryTiming(window, geckoMs) {
  if (window.status !== 'bounded') return { order: 'unresolved', reason: window.status };
  const min_gap_ms = geckoMs - window.max_gecko_ms;
  const max_gap_ms = geckoMs - window.min_gecko_ms;
  return { order: max_gap_ms < 0 ? 'before' : min_gap_ms > 0 ? 'after' : 'unresolved', min_gap_ms, max_gap_ms };
}

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
  let omittedThroughMs;
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
      const slot = count % capacity;
      omittedThroughMs = frames[slot]?.controller_ms ?? omittedThroughMs;
      frames[slot] = { ordinal: ++count, gecko_ms: wallTimeMs, controller_ms: performance.now(),
        carrier_sha256: createHash('sha256').update(bytes).digest('hex') };
    });
  });
  return () => ({ supported: true, sockets, count, omitted: count - frames.length, rejected,
    ...(omittedThroughMs !== undefined && { omitted_through_ms: omittedThroughMs }), frames: [...frames] });
}

function joinFirefoxFrames(observers, receive, recipients = [], failurePublishedMs, nativeExpiries = []) {
  const streams = new Map();
  const pages = [];
  for (const [index, snapshot] of observers.entries()) {
    if (!snapshot) continue;
    const { frames, ...coverage } = snapshot();
    const recipient = recipients[index] ?? null;
    const proxy = (receive?.sockets ?? []).flatMap((socket, ordinal) => socket.page_index === index ? [ordinal] : []);
    const expiry = nativeExpiries[index];
    const sender = expiry?.uuid?.replaceAll('-', '');
    const native_expiry = sender && { sender, page_ms: expiry.page_ms, ...(expiry.firefox_clock ?? { status: 'unavailable' }) };
    pages.push({ index, recipient, ...coverage, proxy, ...(native_expiry && { native_expiry }) });
    if (!recipient) continue;
    const byDigest = new Map();
    for (const frame of frames) {
      const digest = frame.carrier_sha256;
      if (!byDigest.has(digest)) byDigest.set(digest, []);
      byDigest.get(digest).push(frame);
    }
    streams.set(recipient, { ...coverage, proxy, byDigest, native_expiry });
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
        const [frame] = matching;
        const expiry = stream.native_expiry;
        observation = { proxy_ordinal: write.ordinal, ...frame,
          callback_after_failure_publication: failurePublishedMs === undefined ? undefined : frame.controller_ms > failurePublishedMs };
        if (expiry && expiry.sender === packet.sender) {
          observation.expiry_timing = stream.omitted && !(stream.omitted_through_ms <= write.inlet_ms)
            ? { order: 'unresolved', reason: 'frame_candidates_evicted' }
            : expiryTiming(expiry, frame.gecko_ms);
        }
      }
    }
    return [{ ...packet, status, observation }];
  });
  return { clock: 'firefox.gecko.websocket.time_ms', callback_clock: 'controller.performance.now',
    coverage: 'debugger-callback-dependent', room: receive?.room, pages, rows };
}

module.exports = { observeFirefoxFrames, joinFirefoxFrames, readFirefoxClock, firefoxExpiryWindow };
