const { createHash } = require('node:crypto');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const FRAME_CAP = 8192;
const CARRIER_CAP = 2048;
const BASE64_CAP = 4 * Math.ceil(CARRIER_CAP / 3);

async function observeChromiumFrames(context, page, endpoint, { capacity = FRAME_CAP, timeout = 5000 } = {}) {
  const abort = new AbortController();
  const { signal } = abort;
  try {
    return await boundedRoom(async () => {
      const session = await context.newCDPSession(page);
      const detach = () => { void session.detach().catch(() => {}); };
      if (signal.aborted) {
        detach();
        return null;
      }
      signal.addEventListener('abort', detach, { once: true });
      try {
        return await listenForFrames(session, endpoint, capacity);
      } catch (error) {
        if (!signal.aborted) detach();
        throw error;
      } finally {
        signal.removeEventListener('abort', detach);
      }
    }, timeout, 'Chromium frame observer');
  } catch {
    abort.abort();
    return null;
  }
}

async function listenForFrames(session, endpoint, capacity) {
  const frames = [];
  let requestId;
  let sockets = 0;
  let count = 0;
  let rejected = 0;
  let rejectedThroughMs;
  let omittedThroughMs;
  let closedAtMs;
  session.once('close', () => { closedAtMs = performance.now(); });
  session.on('Network.webSocketCreated', ({ requestId: id, url }) => {
    if (url !== endpoint) return;
    if (++sockets === 1) requestId = id;
  });
  session.on('Network.webSocketFrameReceived', ({ requestId: id, timestamp, response }) => {
    if (sockets !== 1 || !requestId || id !== requestId || response?.opcode !== 2) return;
    const controller_ms = performance.now();
    const at_ms = timestamp * 1000;
    const payload = response.payloadData;
    if (!Number.isFinite(timestamp) || at_ms <= 0 || at_ms > Number.MAX_SAFE_INTEGER || response.mask !== false
      || typeof payload !== 'string' || !payload.length || payload.length > BASE64_CAP) {
      rejected++;
      rejectedThroughMs = controller_ms;
      return;
    }
    const bytes = Buffer.from(payload, 'base64');
    if (bytes.length > CARRIER_CAP || bytes.toString('base64') !== payload) {
      rejected++;
      rejectedThroughMs = controller_ms;
      return;
    }
    const slot = count % capacity;
    omittedThroughMs = frames[slot]?.controller_ms ?? omittedThroughMs;
    frames[slot] = { ordinal: ++count, at_ms, controller_ms,
      carrier_sha256: createHash('sha256').update(bytes).digest('hex') };
  });
  // The WebSocket event is independent of buffered HTTP resource bodies.
  await session.send('Network.enable', { maxTotalBufferSize: 0, maxResourceBufferSize: 0 });
  return {
    snapshot: () => ({ status: closedAtMs === undefined ? 'attached' : 'detached', sockets, request_id: requestId, count,
      omitted: count - frames.length, rejected, cutoff_ms: performance.now(), closed_at_ms: closedAtMs,
      omitted_through_ms: omittedThroughMs, rejected_through_ms: rejectedThroughMs, frames: [...frames] }),
    close: () => closedAtMs === undefined ? session.detach() : Promise.resolve(),
  };
}

module.exports = { observeChromiumFrames };
