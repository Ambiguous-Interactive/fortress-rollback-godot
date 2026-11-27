const { createHash } = require('node:crypto');
const { mkdtemp, open, rm } = require('node:fs/promises');
const { dirname, join } = require('node:path');
const { createFrameReader } = require('./native_relay_proxy.cjs');

const LOG_MIB = 32;
const LOG_LIMIT = LOG_MIB * 1024 * 1024;
// Chromium uses a rolling file. Allow for its constants and final state in addition to event bytes.
const READ_LIMIT = LOG_LIMIT + 4 * 1024 * 1024;
const PAGE_CLOCK_PRECISION_MS = 2;
const validClockMs = value => Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER;

function readChromiumClock() {
  return { page_ms: performance.now(), time_origin_ms: performance.timeOrigin };
}

async function calibrateChromiumClock(page) {
  // Linux Chromium TimeTicks and Node hrtime use the same system monotonic clock.
  const now = () => Number(process.hrtime.bigint() / 1000n) / 1000;
  const start_ms = now();
  const sample = await page.evaluate(readChromiumClock);
  return { start_ms, end_ms: now(), sample };
}

function chromiumServiceSamples(samples) {
  const project = sample => validClockMs(sample?.page_ms) && validClockMs(sample.time_origin_ms) && sample.time_origin_ms > 0
    ? { page_ms: sample.page_ms, time_origin_ms: sample.time_origin_ms } : null;
  const [before, after] = Array.isArray(samples) && samples.length === 2 ? samples : [];
  return { before: project(before), after: project(after) };
}

function chromiumExpiryWindow(calibration, expiry) {
  const { start_ms, end_ms, sample } = calibration ?? {};
  const { before, after } = expiry.chromium_service ?? {};
  if (!calibration || !before || !after) return { status: 'unavailable' };
  const timestamps = [start_ms, end_ms, sample?.page_ms, sample?.time_origin_ms, before.page_ms, after.page_ms, expiry.page_ms];
  if (!timestamps.every(validClockMs) || start_ms <= 0 || end_ms < start_ms || sample.time_origin_ms <= 0
    || sample.page_ms > before.page_ms || before.page_ms > after.page_ms || after.page_ms > expiry.page_ms
    || before.time_origin_ms !== sample.time_origin_ms || after.time_origin_ms !== sample.time_origin_ms) return { status: 'invalid' };
  const min_netlog_ms = start_ms + (before.page_ms - sample.page_ms) - PAGE_CLOCK_PRECISION_MS;
  const max_netlog_ms = end_ms + (after.page_ms - sample.page_ms) + PAGE_CLOCK_PRECISION_MS;
  if (!(min_netlog_ms > 0 && min_netlog_ms <= max_netlog_ms && max_netlog_ms <= Number.MAX_SAFE_INTEGER)) return { status: 'invalid' };
  return { status: 'bounded', min_netlog_ms, max_netlog_ms };
}

function chromiumExpiryTiming(window, at_ms) {
  if (window.status !== 'bounded') return { order: 'unresolved', reason: window.status };
  const min_gap_ms = at_ms - window.max_netlog_ms;
  // NetLog serializes TimeTicks by truncating to whole milliseconds.
  const max_gap_ms = at_ms + 1 - window.min_netlog_ms;
  return { order: max_gap_ms < 0 ? 'before' : min_gap_ms > 0 ? 'after' : 'unresolved', min_gap_ms, max_gap_ms };
}

async function readChromiumLog(path) {
  try {
    const file = await open(path, 'r');
    try {
      const { size } = await file.stat();
      if (!size) return { status: 'unavailable' };
      if (size > READ_LIMIT) return { status: 'truncated' };
      const data = Buffer.alloc(size);
      const { bytesRead } = await file.read(data, 0, size, 0);
      if (bytesRead !== size) return { status: 'truncated' };
      return { status: size >= LOG_LIMIT * 0.9 ? 'truncated' : 'recorded', log: JSON.parse(data.toString('utf8')) };
    } finally {
      await file.close();
    }
  } catch (error) {
    return { status: error instanceof SyntaxError ? 'truncated' : 'unavailable' };
  }
}

async function createChromiumCapture(root) {
  let directory;
  try {
    directory = await mkdtemp(join(dirname(root), '.chromium-netlog-'));
  } catch {
    return { finish: async () => ({ status: 'unavailable' }) };
  }
  const path = join(directory, 'netlog.json');
  return {
    args: [`--log-net-log=${path}`, '--net-log-capture-mode=Everything', `--net-log-max-size-mb=${LOG_MIB}`],
    async finish(host, receive, recipients, calibrations, nativeExpiries) {
      let receipt;
      try {
        const { status, log } = await readChromiumLog(path);
        receipt = joinChromiumSocket(log, status, host, receive, recipients, calibrations, nativeExpiries);
      } finally {
        try {
          await rm(directory, { recursive: true, force: true });
        } catch {
          if (receipt) receipt.cleanup_failed = true;
        }
      }
      return receipt;
    },
  };
}

function proxySocketAddress(request, socket) {
  const page = /^\/v3\/ws\?trace_page=([0-7])$/.exec(request.url);
  if (!page || socket.remoteAddress !== '127.0.0.1') return {};
  return { page_index: Number(page[1]), browser_endpoint: `${socket.remoteAddress}:${socket.remotePort}` };
}

function joinChromiumSocket(log, status, host, receive, recipients = [], calibrations = [], nativeExpiries = []) {
  const clock = 'chromium.netlog.time_ms';
  const types = log?.constants?.logEventTypes;
  const socketType = log?.constants?.logSourceType?.SOCKET;
  const end = log?.constants?.logEventPhase?.PHASE_END;
  const supported = [types?.TCP_CONNECT, types?.SSL_SOCKET_BYTES_RECEIVED, socketType, end].every(Number.isInteger)
    && Array.isArray(log?.events);
  const capture = supported || status === 'truncated' ? status : 'unavailable';
  const expiryWindows = recipients.map((recipient, index) => {
    const expiry = nativeExpiries[index];
    if (!recipient || !expiry) return null;
    return { index, recipient, sender: expiry.uuid.replaceAll('-', ''), ...chromiumExpiryWindow(calibrations[index], expiry) };
  });
  const socketPlans = (receive?.sockets ?? []).map(socket => ({ socket, carriers: new Map() }));
  const rows = (receive?.rows ?? []).map(({ proxy, message, first_unobserved, coverage_gap, ...stamp }) => {
    const result = { ...stamp, status: 'unavailable' };
    if (proxy.length > 1) result.status = 'ambiguous';
    if (proxy.length !== 1) return { result };
    const candidate = proxy[0];
    const plan = socketPlans[candidate.socket];
    if (receive.refused || !plan?.socket?.browser_endpoint || recipients[plan.socket.page_index] !== stamp.recipient) return { result };
    if (socketPlans.some(other => other !== plan && (other.socket.browser_endpoint === plan.socket.browser_endpoint
      || other.socket.page_index === plan.socket.page_index))) {
      result.status = 'ambiguous';
      return { result };
    }
    const match = plan.carriers.get(candidate.carrier_sha256) ?? { count: 0 };
    plan.carriers.set(candidate.carrier_sha256, match);
    return { result, candidate, plan, match };
  });
  if (supported) collectSocketCarriers(log.events, types, socketType, end, host, socketPlans);
  for (const { result, candidate, plan, match } of rows) {
    if (!plan) continue;
    if (plan.ambiguous || match.count > 1) result.status = 'ambiguous';
    else if (match.count === 1) {
      result.status = 'observed';
      result.observation = { socket: candidate.socket, proxy_ordinal: candidate.ordinal, carrier_sha256: candidate.carrier_sha256,
        netlog_source: plan.source, at_ms: match.at_ms };
      const expiry = expiryWindows[plan.socket.page_index];
      if (expiry?.sender === result.sender) result.observation.expiry_timing = chromiumExpiryTiming(expiry, match.at_ms);
    } else if (plan.truncated) result.status = 'truncated';
  }
  const expiries = expiryWindows.filter(Boolean);
  return { clock, status: capture, room: receive?.room, ...(expiries.length && { expiries }), rows: rows.map(row => row.result) };
}

function netlogTime(time) {
  const number = typeof time === 'string' && /^\d+$/.test(time) ? Number(time) : NaN;
  return Number.isSafeInteger(number) ? number : NaN;
}

function collectSocketCarriers(events, types, socketType, end, host, plans) {
  const endpoints = new Map(plans.filter(plan => plan.carriers.size).map(plan => [plan.socket.browser_endpoint, plan]));
  const sources = new Map();
  for (const event of events) {
    if (event?.type !== types.TCP_CONNECT || event.source?.type !== socketType || event.phase !== end
        || event.params?.remote_address !== host || !Number.isSafeInteger(event.source.id)) continue;
    const plan = endpoints.get(event.params.local_address);
    if (!plan) continue;
    if (plan.source !== undefined || sources.has(event.source.id)) {
      plan.ambiguous = true;
      const other = sources.get(event.source.id);
      if (other) other.ambiguous = true;
      continue;
    }
    plan.source = event.source.id;
    plan.reader = createFrameReader();
    plan.last_ms = netlogTime(event.time);
    plan.truncated = !Number.isFinite(plan.last_ms);
    sources.set(plan.source, plan);
  }
  for (const event of events) {
    if (event?.type !== types.SSL_SOCKET_BYTES_RECEIVED || event.source?.type !== socketType) continue;
    const plan = sources.get(event.source.id);
    if (!plan || plan.ambiguous || plan.truncated) continue;
    const { bytes, byte_count } = event.params ?? {};
    const at_ms = netlogTime(event.time);
    const data = typeof bytes === 'string' ? Buffer.from(bytes, 'base64') : null;
    if (!data || data.length !== byte_count || data.toString('base64') !== bytes || !Number.isFinite(at_ms) || at_ms < plan.last_ms) {
      plan.truncated = true;
      continue;
    }
    plan.last_ms = at_ms;
    for (const carrier of plan.reader.push(data)) {
      const match = plan.carriers.get(createHash('sha256').update(carrier).digest('hex'));
      if (!match) continue;
      match.count++;
      match.at_ms = at_ms;
    }
    const { skipped, error } = plan.reader.status();
    plan.truncated = Boolean(skipped || error);
  }
}

module.exports = { calibrateChromiumClock, chromiumServiceSamples, createChromiumCapture, joinChromiumSocket, proxySocketAddress, readChromiumClock,
  readChromiumLog };
