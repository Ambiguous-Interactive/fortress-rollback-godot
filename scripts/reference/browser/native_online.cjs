const { assertRecoveredRoom, recoverPairs } = require('./native_recovery.cjs');
const { createRelayWireTrace } = require('./native_relay_trace.cjs');
const { assertJoinedRelayControl, bindRelayServer, createRelayServerReader, exerciseRelayDelivery, exerciseRelayRetention, exerciseSameLinkRetention,
  joinRelayReceipts, readRelayWireReceipt } = require('./native_relay_control.cjs');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { setImmediate: flush, setTimeout: pause } = require('node:timers/promises');
const { createHost } = require('./online_host.cjs');
const { placeFirefox } = require('./webrtc_display.cjs');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const INPUTS = [[1, ['KeyA']], [2, ['KeyD']], [4, ['KeyW']], [8, ['KeyS']],
  [5, ['KeyA', 'KeyW']], [6, ['KeyD', 'KeyW']], [9, ['KeyA', 'KeyS']], [10, ['KeyD', 'KeyS']]];
const GATE_FRAME = 12;
const HISTORY_FRAMES = 40;
const PAGE_BOOT_MS = 60000;
const PAGE_WAIT_MS = 30000;
const WARMUP_WAIT_MS = 45000;
const DIAGNOSTIC_MS = 5000;
const CLOSE_MS = 10000;
const CANONICAL_SNAPSHOT = /^(?:[0-9a-f]{2})+$/;
const FROZEN_UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const CLOSE_CLOCK_PRE_SAMPLES = 3;
const CLOSE_CLOCK_POST_SAMPLES = 4;
const WEBKIT_CLOSED_STREAM = 'Error sending binary data through RTCDataChannel.';
const WARMUP_CHECKPOINT = 'fortress native relay warmup ';
const POST_RELEASE_CHECKPOINT = 'fortress native post-release ';
const DEPARTURE_CHECKPOINT = 'fortress native departure ';
const HISTORY_CHECKPOINT = 'fortress native history ';
const POST_RELEASE_MARKS = new Set(['release_entered', 'correction', 'history_requested', 'history_published']);
const FRONTIER_MARKS = new Set(['corrected_frontier', 'corrected_advance']);
const LIFETIME_MARKS = new Set(['native_expiry', 'sdk_departure']);
const HOLD_MARKS = new Set(['hold_armed', 'hold_first_input', 'hold_first_control', 'hold_first_prediction', 'hold_ready', 'hold_cap', 'hold_waiting', 'hold_terminal',
  'release_started', 'release_progress', 'release_completed', 'release_socket_closed', 'release_control_socket_closed']);
const HOLD_CONDITIONS = ['stall', 'prediction', 'frontier', 'held_input', 'quality_reply'];

function createWarmupBarrier(players, clock = () => performance.now()) {
  const latest = Array(players).fill(null);
  const errors = Array(players).fill(null);
  const received = Array(players).fill(null);
  let startedAt = Infinity;
  let deadline = Infinity;
  let waiting = false;
  let complete;
  const ready = new Promise(resolve => { complete = resolve; });
  const states = new Set(['offline', 'connecting', 'joining', 'lobby', 'starting', 'playing', 'failed']);
  const isFrontier = value => states.has(value?.state) && Number.isSafeInteger(value.frame) && Number.isSafeInteger(value.confirmed);
  return {
    get checkpoints() { return latest.map(record => record?.sample ?? null); },
    errors, received,
    frontier() {
      const peers = latest.map((record, index) => {
        const { sample, received_ms } = record ?? { sample: null, received_ms: null };
        const observation = sample?.cutoff ?? sample?.ticks.at(-1) ?? null;
        let outcome = 'unobserved';
        if (observation?.state === 'failed') outcome = 'terminal';
        else if (received[index] !== null) outcome = 'gate_received';
        else if (sample?.cutoff?.reason === 'gate') outcome = received_ms >= deadline ? 'gate_received_late' : 'gate_unaccepted';
        else if (observation?.state === 'playing' && observation.confirmed >= GATE_FRAME) outcome = 'gate_observed';
        else if (observation) outcome = 'observed_below_gate';
        return { outcome, observation, received_ms };
      });
      return { deadline_ms: Number.isFinite(deadline) ? deadline : null, peers };
    },
    record(index, text) {
      if (!text.startsWith(WARMUP_CHECKPOINT) || received[index] !== null) return;
      const receivedAt = clock();
      try {
        const sample = JSON.parse(text.slice(WARMUP_CHECKPOINT.length));
        const isUuid = value => typeof value === 'string' && /^[0-9a-f]{32}$/.test(value);
        if (!isUuid(sample?.recipient) || !Number.isFinite(sample.started_ms) || sample.started_ms < 0
          || !Number.isFinite(sample.through_ms) || sample.through_ms < sample.started_ms
          || !Array.isArray(sample.links) || sample.links.length !== players - 1 || sample.links.some(link => !isUuid(link?.sender))
          || !Array.isArray(sample.ticks) || sample.ticks.length > 24 || sample.ticks.some((tick, i, ticks) => !isFrontier(tick)
            || !Number.isFinite(tick.at_ms) || tick.at_ms < (i ? ticks[i - 1].at_ms : sample.started_ms) || tick.at_ms > sample.through_ms)
          || !Number.isSafeInteger(sample.tick_count) || sample.tick_count < sample.ticks.length) throw new Error('invalid warmup checkpoint');
        const roster = [sample.recipient, ...sample.links.map(link => link.sender)];
        if (new Set(roster).size !== players) throw new Error('invalid warmup roster');
        const { cutoff } = sample;
        if (cutoff !== null && (!isFrontier(cutoff) || cutoff.at_ms !== sample.through_ms
          || !(cutoff.reason === 'failed' && cutoff.state === 'failed'
            || cutoff.reason === 'gate' && cutoff.state === 'playing' && cutoff.confirmed >= GATE_FRAME)))
          throw new Error('invalid warmup gate');
        if (cutoff?.terminal_endpoint !== undefined || cutoff?.terminal_uuid !== undefined) {
          const { terminal_endpoint: endpoint, terminal_uuid: uuid } = cutoff;
          roster.sort();
          if (cutoff.reason !== 'failed' || !Number.isInteger(endpoint) || endpoint < 1 || endpoint > players
              || !isUuid(uuid) || uuid === sample.recipient || uuid !== roster[endpoint - 1])
            throw new Error('invalid warmup expiry endpoint');
        }
        const previous = latest[index];
        const beforeStart = receivedAt < startedAt;
        const replacesPreStartGate = previous?.beforeStart && previous.sample.cutoff?.reason === 'gate' && cutoff?.reason === 'gate' && !beforeStart;
        if (sample.through_ms < previous?.sample.through_ms || (previous?.sample.cutoff && !replacesPreStartGate)) return;
        latest[index] = { sample, received_ms: receivedAt, beforeStart };
        if (!waiting || beforeStart || cutoff?.reason !== 'gate' || receivedAt >= deadline) return;
        received[index] = receivedAt;
        if (received.every(at => at !== null)) complete();
      } catch (error) {
        errors[index] ??= String(error);
      }
    },
    async wait(start, timeout) {
      startedAt = clock();
      waiting = true;
      try {
        await start();
        deadline = clock() + timeout;
        await boundedRoom(() => ready, timeout, 'native warmup');
      } finally {
        waiting = false;
      }
    },
  };
}

function instrumentPostRelease(prefix, minimumFrames) {
  let baseline;
  let corrected = false;
  const targets = new Map([[minimumFrames, 0]]);
  const frontiers = [];
  let through = minimumFrames - 1;
  let pending = [];
  let roster = [], local;
  let expired = false;
  const departed = new Set();
  function mark(kind, frames, hold) {
    if (baseline === undefined && !hold) return;
    const { state, turns, frame, confirmed, restores } = window.fortressNative;
    console.debug(prefix + JSON.stringify({ kind, page_ms: hold?.at_ms ?? performance.now(), state, turns, frame, confirmed, restores, frames,
      held: hold?.held, bytes: hold?.bytes, queued: hold?.queued, released: hold?.released,
      socket_state: hold?.socket_state, socket_stage: hold?.socket_stage, held_send: hold?.held_send,
      pending: hold?.pending, control_round_trips: hold?.control_round_trips, buffered_bytes: hold?.buffered_bytes, traffic: hold?.traffic }));
  }
  function observe(state, turns, frame, confirmed, restores, historyLimit) {
    if (baseline === undefined || restores <= baseline) return;
    const snapshot = () => ({ state, turns, frame, confirmed, restores, page_ms: performance.now() });
    if (!corrected) {
      corrected = true;
      console.debug(prefix + JSON.stringify({ ...snapshot(), kind: 'correction' }));
    }
    if (state !== 'playing') return;
    const limit = Math.min(confirmed, historyLimit);
    if (pending.some(entry => frame > entry.first.frame) || limit > through) {
      const sample = snapshot();
      pending = pending.filter(entry => {
        if (frame <= entry.first.frame) return true;
        entry.next = sample;
        return false;
      });
      if (limit > through) {
        const entry = { first: sample };
        frontiers.push({ through: limit, entry });
        pending.push(entry);
        through = limit;
      }
    }
    publishFrontiers();
  }
  function publishFrontiers() {
    for (const [frames, published] of targets) {
      if (published === 2 || frames > through) continue;
      const { entry } = frontiers.find(frontier => frontier.through >= frames);
      if (published === 0) {
        console.debug(prefix + JSON.stringify({ ...entry.first, kind: 'corrected_frontier', frames, emitted_ms: performance.now() }));
        targets.set(frames, 1);
      }
      if (entry.next) {
        console.debug(prefix + JSON.stringify({ ...entry.next, kind: 'corrected_advance', frames, emitted_ms: performance.now() }));
        targets.set(frames, 2);
      }
    }
  }
  window.fortressNativePostRelease = {
    arm(restores) {
      baseline = restores;
      setInterval(() => mark('heartbeat'), 1000);
    },
    setTarget(frames) {
      if (targets.size !== 1 || !Number.isSafeInteger(frames) || frames <= minimumFrames
          || frames > window.fortressNative.history_limit) return;
      targets.set(frames, 0);
      publishFrontiers();
    },
    bindDeparture(uuid, frozen) {
      local = uuid;
      roster = frozen;
    },
    recordDeparture(kind, remote, evidence) {
      const sdk = kind === 'sdk_departure';
      const endpoint = sdk ? roster.indexOf(remote) + 1 : remote;
      const uuid = roster[endpoint - 1];
      if (!uuid || uuid === local || (sdk ? departed.has(uuid) : expired)) return;
      if (sdk) departed.add(uuid);
      else expired = true;
      console.debug(prefix + JSON.stringify({ kind, endpoint, uuid, page_ms: performance.now(),
        expiry: evidence === undefined ? undefined : JSON.parse(evidence) }));
    },
    mark,
    observe,
  };
}

function postReleaseCheckpoint(peer, text, controller, roster, local, comparedTarget = HISTORY_FRAMES) {
  if (!text.startsWith(POST_RELEASE_CHECKPOINT)) return;
  try {
    const { kind, page_ms, state, turns, frame, confirmed, restores, frames, held, bytes, queued, released, emitted_ms, endpoint, uuid,
      expiry, socket_state, socket_stage, held_send, pending, control_round_trips, buffered_bytes, traffic } = JSON.parse(text.slice(POST_RELEASE_CHECKPOINT.length));
    if (LIFETIME_MARKS.has(kind)) {
      if (!Number.isFinite(page_ms) || page_ms < 0 || !Number.isSafeInteger(endpoint) || endpoint < 1
        || endpoint > INPUTS.length || typeof uuid !== 'string' || !FROZEN_UUID.test(uuid)) throw new Error('invalid room departure sample');
      const receipt = { kind, endpoint, uuid, page_ms, ...controller };
      if (kind === 'native_expiry') receipt.expiry = validateExpiry(expiry);
      retainDepartureCheckpoint(peer, receipt, roster, local);
      return;
    }
    const capturesHold = HOLD_MARKS.has(kind);
    const capturesFrontier = FRONTIER_MARKS.has(kind);
    if (kind !== 'heartbeat' && !POST_RELEASE_MARKS.has(kind) && !capturesHold && !capturesFrontier) return;
    const capturesHistory = capturesFrontier || kind === 'history_requested' || kind === 'history_published';
    if (!Number.isFinite(page_ms) || page_ms < 0 || typeof state !== 'string' || state.length > 32
      || ![turns, frame, confirmed, restores].every(Number.isSafeInteger)
      || (capturesHistory && (!Number.isSafeInteger(frames) || frames < 1))) throw new Error('invalid post-release sample');
    const receipt = { page_ms, state, turns, frame, confirmed, restores, ...controller };
    if (capturesHistory) receipt.frames = frames;
    if (capturesFrontier) {
      const ready = peer.hold_ready;
      if ((frames !== HISTORY_FRAMES && frames !== comparedTarget) || !ready
        || page_ms < ready.page_ms || turns <= ready.turns || restores <= ready.restores
        || state !== 'playing' || !Number.isFinite(emitted_ms) || emitted_ms < page_ms
        || kind === 'corrected_frontier' && confirmed < frames) throw new Error('invalid corrected frontier sample');
      receipt.emitted_ms = emitted_ms;
      const frontier = peer.frontiers?.[frames];
      const first = frontier?.corrected_frontier;
      if (kind === 'corrected_advance' && (!first || frame <= first.frame || turns <= first.turns || page_ms < first.page_ms))
        throw new Error('invalid corrected advance sample');
      ((peer.frontiers ??= {})[frames] ??= {})[kind] ??= receipt;
      return;
    }
    if (capturesHold) {
      if (![held?.mesh, held?.relay, bytes, queued, released].every(value => Number.isSafeInteger(value) && value >= 0)
        || held.mesh + held.relay > 1024 || bytes > 1024 * 1024 || queued + released > held.mesh + held.relay) throw new Error('invalid hold sample');
      receipt.held = { mesh: held.mesh, relay: held.relay };
      receipt.bytes = bytes;
      receipt.queued = queued;
      receipt.released = released;
      if (kind === 'hold_waiting' || kind === 'hold_terminal') {
        const remote = new Set(roster?.filter(uuid => uuid !== local).map(uuid => uuid.replaceAll('-', '')));
        if ((kind === 'hold_terminal') !== (state === 'failed') || !Array.isArray(pending)
          || new Set(pending).size !== pending.length || !pending.every(value => HOLD_CONDITIONS.includes(value))
          || ![control_round_trips, buffered_bytes].every(value => Number.isSafeInteger(value) && value >= 0)
          || pending.includes('held_input') !== (held.relay === 0) || pending.includes('quality_reply') !== (control_round_trips === 0)
          || !Array.isArray(traffic) || traffic.length > remote.size * 4 || !traffic.every(sample =>
            sample && remote.has(sample.peer) && ['send', 'receive'].includes(sample.direction) && [4, 5].includes(sample.kind)
            && typeof sample.token === 'string' && /^[0-9a-f]{32}$/.test(sample.token)
            && Number.isFinite(sample.at_ms) && sample.at_ms >= 0 && sample.at_ms <= page_ms)
          || new Set(traffic.map(({ direction, peer, kind }) => `${direction}/${peer}/${kind}`)).size !== traffic.length)
          throw new Error('invalid relay hold readiness sample');
        Object.assign(receipt, { pending, control_round_trips, buffered_bytes,
          traffic: traffic.map(({ direction, peer, kind, token, at_ms }) => ({ direction, peer, kind, token, at_ms })) });
        if (kind === 'hold_waiting') {
          if (!peer.hold_waiting || page_ms >= peer.hold_waiting.page_ms) peer.hold_waiting = receipt;
          return;
        }
      }
      if (kind === 'release_socket_closed' || kind === 'release_control_socket_closed') {
        if (![0, 2, 3].includes(socket_state) || !['before_send', 'during_send'].includes(socket_stage) || held_send !== (kind === 'release_socket_closed'))
          throw new Error('invalid relay release socket sample');
        Object.assign(receipt, { socket_state, socket_stage, held_send });
      }
      if (kind === 'release_progress') {
        if (!queued || (released !== 16 && (released === 0 || released % 128 !== 0))) throw new Error('invalid relay release progress');
        const progress = peer.release_progress ??= [];
        if (released > (progress.at(-1)?.released ?? 0)) progress.push(receipt);
        return;
      }
      if (kind === 'release_completed' && (queued !== 0 || released !== held.mesh + held.relay)) throw new Error('invalid relay release completion');
    }
    if (kind === 'heartbeat') peer.heartbeats = [...(peer.heartbeats ?? []).slice(-1), receipt];
    else peer[kind] ??= receipt;
  } catch (error) {
    peer.checkpoint_error ??= String(error);
  }
}

function validateExpiry(value) {
  const { observed_us, sdk_queued, sdk_peak, last_accepted } = value ?? {};
  const integer = (number, min, max) => Number.isSafeInteger(number) && number >= min && number <= max;
  const maximum = Number.MAX_SAFE_INTEGER;
  if (!integer(observed_us, 0, maximum) || !integer(sdk_peak, 0, maximum) || !integer(sdk_queued, -1, sdk_peak))
    throw new Error('invalid native expiry evidence');
  if (last_accepted === null) return { observed_us, sdk_queued, sdk_peak, last_accepted };
  const { accepted_us, kind, bytes } = last_accepted ?? {};
  if (!integer(accepted_us, 0, observed_us) || !integer(bytes, 17, 1200)
    || (bytes < 28 ? kind !== null : !integer(kind, 0, 0xffffffff))) throw new Error('invalid native expiry evidence');
  return { observed_us, sdk_queued, sdk_peak, last_accepted: { accepted_us, kind, bytes } };
}

function missedCorrectionDeadline(phase, error, deadline, failedAt) {
  if (!Number.isFinite(deadline) || !['input release', 'corrected history'].includes(phase)) return false;
  if (error?.name === 'TimeoutError' && failedAt >= deadline) return true;
  const message = error?.message;
  return /^absolute native (?:(?:peer \d+|relay) input release|corrected history) deadline$/.test(message)
    || /^native (?:input release exhausted|corrected history exceeded) the correction deadline$/.test(message)
    || /^(?:page\.evaluate: )?native relay release deadline(?:\n|$)/.test(message);
}

function relayReleaseEvidence(peers, uuids, correctionDeadlineReached) {
  const socket_closed_pages = [];
  const hold_cap_pages = [];
  const expiries = [];
  peers.forEach((peer, reporter_page) => {
    if (peer.release_socket_closed || peer.release_control_socket_closed) socket_closed_pages.push(reporter_page);
    if (peer.hold_cap) hold_cap_pages.push(reporter_page);
    const expiry = peer.native_expiry;
    if (!expiry || !uuids) return;
    const expired_page = uuids.indexOf(expiry.uuid);
    const sender = peers[expired_page];
    if (!sender) return;
    const candidates = [['release_entered', sender.release_entered], ['release_started', sender.release_started],
      ...(sender.release_progress ?? []).map(sample => ['release_progress', sample]), ['release_completed', sender.release_completed],
      ['release_control_socket_closed', sender.release_control_socket_closed], ['release_socket_closed', sender.release_socket_closed], ['hold_cap', sender.hold_cap]];
    const latest = candidates.filter(([, sample]) => sample && sample.controller_order < expiry.controller_order)
      .sort(([, a], [, b]) => b.controller_order - a.controller_order)[0];
    const last_release_checkpoint = latest ? { kind: latest[0], ...latest[1] } : null;
    expiries.push({ reporter_page, expired_page, uuid: expiry.uuid, endpoint: expiry.endpoint,
      expiry: expiry.expiry, controller_ms: expiry.controller_ms, controller_order: expiry.controller_order, last_release_checkpoint });
  });
  return { socket_closed_pages, hold_cap_pages, correction_deadline_reached: correctionDeadlineReached, expiries };
}

function retainDepartureCheckpoint(peer, { kind, ...receipt }, roster, local) {
  const { uuid, endpoint } = receipt;
  if (!roster) {
    const waiting = peer.unbound_lifetime ??= [];
    if (waiting.length < INPUTS.length && !waiting.some(sample => sample.kind === kind && sample.endpoint === endpoint && sample.uuid === uuid))
      waiting.push({ kind, ...receipt });
  } else if (!local || uuid === local || roster[endpoint - 1] !== uuid) {
    peer.checkpoint_error ??= 'invalid room departure identity';
  } else if (kind === 'native_expiry') {
    peer.native_expiry ??= receipt;
  } else {
    (peer.sdk_departures ??= {})[uuid] ??= receipt;
  }
}

function bindDepartureCheckpoints(peer, roster, local) {
  for (const sample of peer.unbound_lifetime ?? []) retainDepartureCheckpoint(peer, sample, roster, local);
  delete peer.unbound_lifetime;
}

function browserOptions(name) {
  const executablePath = process.env[`FORTRESS_${name.toUpperCase()}_EXECUTABLE`];
  if (!executablePath) throw new Error(`missing executable for ${name}`);
  switch (name) {
    case 'chromium':
      return { executablePath, headless: true,
        args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
          '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'] };
    case 'firefox':
      return { executablePath, headless: false,
        firefoxUserPrefs: { 'webgl.force-enabled': true, 'webgl.disabled': false, 'toolkit.shutdown.fastShutdownStage': 0 } };
    case 'webkit':
      return { executablePath, headless: false };
  }
  throw new Error(`unknown browser ${name}`);
}

function instrumentNativeWire(tagWebKitSends, warmupPrefix, relayWireTrace) {
  if (relayWireTrace) window.fortressNativeRelayTrace = relayWireTrace;
  const active = [];
  const resources = { rtc: [], sockets: [] };
  const ice = new Map();
  let session, localUuid;
  let observingDeparture = false;
  const departureSendLimit = 4096;
  const departureSendHistory = [];
  let departureSendCount = 0;
  let holding = false;
  let releasingRelay = false;
  let releaseInFlight = 0;
  const releaseSocketFailures = new Set();
  let releaseEnded = null;
  let holdFailure;
  let holdAll = false;
  let armed = false;
  const hold = { armed: null, ready: null, release: null };
  let totalBytes = 0;
  let released = 0;
  const counts = { mesh: 0, relay: 0 };
  const relayRecipients = new Map();
  const relaySenders = new Map();
  const relayInputRecipients = new Map();
  const relayInputSenders = new Map();
  let blockRecovery = false;
  const recovery = { scope: null, released: 0, delivered: [], pending: [], observed: [], drops: null, droppedOffers: 0,
    queuedKinds: { Offer: 0, IceCandidate: 0 }, receivedKinds: { Offer: 0, IceCandidate: 0 } };
  const qualityEvents = { send: [], receive: [] };
  const qualityEventCounts = { send: 0, receive: 0 };
  const lastRelayQuality = new Map();
  const qualityEventLimit = 256;
  let qualityEventCount = 0;
  let bufferedBytesPeak = 0;
  let relayBroadcasts = 0;
  const held = { mesh: 0, relay: 0 };
  const controlRoundTrips = { mesh: 0, relay: 0 };
  const holdConditions = route => [held[route] > 0, controlRoundTrips[route] > 0];
  const holdMark = () => ({ at_ms: performance.now(), held: { ...held }, bytes: totalBytes, queued: active.length + releaseInFlight, released });
  // The pinned protocol sends one report per peer at intervals above 200 ms.
  // Keep enough relay tokens for the 45-second stall witness despite FIFO delay.
  const pendingReportLimit = { mesh: 16, relay: 256 };
  const channelReports = new Map();
  const socketReports = new WeakMap();
  const traceSocketOrdinals = relayWireTrace && new WeakMap();
  let mutedRelay;
  let blockedRelay;
  let relayDelay;
  function delayRelayDelivery() {
    if (!relayWireTrace || relayDelay || resources.sockets.length !== 1 || resources.sockets[0].readyState !== WebSocket.OPEN)
      throw new Error('cannot hold relay control delivery');
    const socket = resources.sockets[0];
    const events = [];
    let bytes = 0;
    const started_ms = performance.now();
    expiredRelayDelay = null;
    const release = reason => {
      const release_ms = performance.now();
      relayDelay = null;
      clearTimeout(timer);
      for (const { event } of events) {
        replayedRelayEvents.add(event);
        socket.dispatchEvent(event);
      }
      return { started_ms, release_ms, reason, events: events.length, bytes };
    };
    const timer = setTimeout(() => { expiredRelayDelay = release('deadline'); }, 750);
    relayDelay = {
      socket,
      releaseWhenHeld(stamps) {
        if (performance.now() - started_ms >= 750) return release('deadline');
        if (stamps.length !== 2 || stamps.some(stamp => stamp.recipient !== localUuid)
            || (stamps[0].sender === stamps[1].sender && stamps[0].epoch === stamps[1].epoch && stamps[0].seq === stamps[1].seq)) return null;
        if (!stamps.every(stamp => events.some(({ packet }) => packet?.sender === stamp.sender
            && packet.recipient === stamp.recipient && packet.epoch === stamp.epoch && packet.seq === stamp.seq))) return null;
        return release('controller');
      },
      hold(event, packet) {
        bytes += event.data.byteLength ?? event.data.length * 2;
        events.push({ event, packet });
        event.stopImmediatePropagation();
        if (events.length > 256 || bytes > 256 * 1024) {
          // The current event is still being dispatched. Replay it after that turn.
          queueMicrotask(() => { if (relayDelay) expiredRelayDelay = release('capacity'); });
        }
      },
    };
    return started_ms;
  }
  const replayedRelayEvents = relayWireTrace && new WeakSet();
  let expiredRelayDelay;
  const warmupLinks = new Map();
  let roomRoster = [];
  const warmupTicks = [];
  let warmupTickCount = 0;
  let warmupStarted = null;
  let warmupCutoff = null;
  let warmupCheckpointPending = false;
  let lastWarmupCheckpoint = -Infinity;
  const nativeBytes = bytes => bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
    : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
  const matches = (bytes, offset) => session && offset + session.length < bytes.length
    && session.every((byte, index) => bytes[offset + index] === byte);
  const inputKind = 2;
  function nativePacket(bytes) {
    // The pinned Fortress codec uses an eight-byte header and a little-endian u32 body tag.
    const at = session.length;
    if (bytes.length < at + 12 || bytes[at] !== 0xf5 || bytes[at + 1] !== 0x52 || bytes[at + 2] !== 2 || bytes[at + 3] !== 0) {
      throw new Error('native gameplay wire header differs from the pinned codec');
    }
    const kind = new DataView(bytes.buffer, bytes.byteOffset + at + 8, 4).getUint32(0, true);
    // A quality report carries an i16 followed by a u128. The reply echoes the u128.
    const tokenOffset = kind === 4 ? at + 14 : at + 12;
    const token = holding && !holdAll && (kind === 4 || kind === 5) && bytes.length === tokenOffset + 16
      ? hex(bytes.subarray(tokenOffset)) : null;
    return { kind, token };
  }
  const hex = bytes => Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  function warmupStatus() {
    if (!warmupLinks.size) return null;
    return { recipient: localUuid, started_ms: warmupStarted, through_ms: warmupCutoff?.at_ms ?? performance.now(), cutoff: warmupCutoff,
      tick_count: warmupTickCount, ticks: warmupTicks.slice(),
      links: Array.from(warmupLinks, ([sender, { packets, evicted, unretained, last_replied_report }]) => ({
        sender, evicted, unretained, last_replied_report, packets: Array.from(packets, ([payload, stages]) => ({ payload, ...stages })),
      })) };
  }
  function checkpointWarmup(at) {
    lastWarmupCheckpoint = at;
    console.debug(warmupPrefix + JSON.stringify(warmupStatus()));
  }
  function scheduleWarmupCheckpoint(at) {
    if (warmupCheckpointPending || at < lastWarmupCheckpoint + 1000) return;
    warmupCheckpointPending = true;
    // Serialize only after the current browser event or Godot tick returns.
    setTimeout(() => {
      warmupCheckpointPending = false;
      if (!warmupCutoff) checkpointWarmup(performance.now());
    }, 0);
  }
  const orderedWarmupToken = token => token.match(/../g).reverse().join('');
  function forgetWarmupReport(link, payload) {
    // The pinned u128 ping is little-endian. Keep a bounded exclusion watermark.
    const token = orderedWarmupToken(payload.slice(-32));
    if (token > link.discardedThroughToken) link.discardedThroughToken = token;
  }
  function recordWarmup(stage, sender, payload, code) {
    const link = !warmupCutoff && warmupLinks.get(sender.replaceAll('-', ''));
    if (!link) return;
    const at = performance.now();
    scheduleWarmupCheckpoint(at);
    let packet = link.packets.get(payload);
    if (!packet && link.packets.size === 24) {
      // Keep the first eight and latest sixteen. Evict the whole packet record;
      // callbacks for evicted packets cannot reappear as missing raw observations.
      if (stage !== 'raw') {
        link.unretained[stage]++;
        forgetWarmupReport(link, payload);
        return;
      }
      const evicted = [...link.packets.keys()][8];
      forgetWarmupReport(link, evicted);
      link.packets.delete(evicted);
      link.evicted++;
    }
    if (!packet) {
      // Once a link has evicted anything, a new key can be a repeat of an evicted packet.
      packet = { after_eviction: link.evicted > 0, raw: null, sdk: null, native: null };
      link.packets.set(payload, packet);
    }
    if (stage === 'native') {
      packet.native ??= { first_ms: at, last_ms: at, first_code: code, last_code: code, accepted_ms: null, attempts: 0, acceptances: 0 };
      packet.native.attempts++;
      packet.native.last_ms = at;
      packet.native.last_code = code;
      if (code === 0) {
        packet.native.accepted_ms ??= at;
        if (packet.raw) packet.native.accepted_after_raw_ms ??= at;
        packet.native.acceptances++;
      }
    } else {
      packet[stage] ??= { first_ms: at, last_ms: at, count: 0 };
      packet[stage].last_ms = at;
      packet[stage].count++;
    }
  }
  function recordWarmupReply({ recipient, bytes }) {
    const link = !warmupCutoff && warmupLinks.get(recipient);
    if (!link || bytes.length !== 44 || (bytes[28] & 3) !== 0) return;
    const pong = hex(bytes.subarray(28));
    if (orderedWarmupToken(pong) <= link.discardedThroughToken) return;
    let matched;
    for (const [payload, packet] of link.packets) {
      if (!payload.endsWith(pong)) continue;
      if (matched) return;
      matched = [payload, packet];
    }
    if (!matched) return;
    const [payload, packet] = matched;
    if (packet.native?.accepted_after_raw_ms == null || packet.reply_observed_ms !== undefined || link.last_replied_report?.payload === payload) return;
    const at = performance.now();
    packet.reply_observed_ms = at;
    // The echoed reply proves protocol processing after the native inbox accepted the report.
    link.last_replied_report = { payload, raw_observed_ms: packet.raw.first_ms, native_enqueued_ms: packet.native.accepted_after_raw_ms, reply_observed_ms: at };
    scheduleWarmupCheckpoint(at);
  }
  function relayAddresses(data) {
    const view = nativeBytes(data);
    if (!session || !view) return null;
    // The SDK binary envelope precedes FSR1, followed by the tagged native payload.
    for (let index = 0; index + 73 < view.length; index++) {
      if (view[index] === 70 && view[index + 1] === 83 && view[index + 2] === 82 && view[index + 3] === 49
          && view[index + 4] === 1 && matches(view, index + 5) && matches(view, index + 57)) {
        const payload = index + 57;
        const size = new DataView(view.buffer, view.byteOffset + index + 53, 4).getUint32(0, true);
        if (size > view.length - payload) throw new Error('native relay payload exceeds its envelope');
        const bytes = view.subarray(payload, payload + size);
        return { sender: hex(view.subarray(index + 21, index + 37)), recipient: hex(view.subarray(index + 37, index + 53)),
          ...nativePacket(bytes), bytes };
      }
    }
    return null;
  }
  function readRecovery(data, direction) {
    if ((!recovery.scope && !blockRecovery) || typeof data !== 'string') return null;
    const { type, data: wire } = JSON.parse(data);
    const message = wire?.signal?.MeshRecovery;
    if (type !== 'Signal' || !message) return null;
    if (blockRecovery) return message;
    const { room, generation, peer, localEpoch, peerEpoch } = recovery.scope;
    if (wire.generation !== generation || message.v !== 1 || message.room !== room) return null;
    if (direction === 'send' && (wire.to !== peer || message.from_epoch !== localEpoch || message.to_epoch !== peerEpoch)) return null;
    if (direction === 'receive' && (wire.from !== peer || message.from_epoch !== peerEpoch || message.to_epoch !== localEpoch)) return null;
    return { ...message, generation, from: direction === 'send' ? localUuid : peer.replaceAll('-', ''),
      to: direction === 'receive' ? localUuid : peer.replaceAll('-', '') };
  }
  const isFirstRecoveryOfferTraffic = message => message?.attempt === 1 && ['Offer', 'IceCandidate'].includes(message.kind);
  function traceRelayQuality(direction, peer, { kind, token }) {
    if (token === null) return;
    // A delayed burst of incoming traffic must leave the outgoing reports available for correlation.
    const index = qualityEventCounts[direction]++ % qualityEventLimit;
    const event = { sequence: qualityEventCount++, direction, peer, kind, token, at_ms: performance.now() };
    qualityEvents[direction][index] = event;
    if (peer !== localUuid && roomRoster.includes(peer)) lastRelayQuality.set(`${direction}/${peer}/${kind}`, event);
  }
  const increment = (counts, uuid) => counts.set(uuid, (counts.get(uuid) ?? 0) + 1);
  const ufrag = description => description?.sdp.match(/^a=ice-ufrag:([\w+/]+)\r?$/m)?.[1];
  function receive(route, reports, peer, packet) {
    if (packet.kind !== 5) return;
    const tokens = reports.get(peer);
    if (tokens?.get(packet.token)) {
      tokens.set(packet.token, false);
      controlRoundTrips[route]++;
      if (controlRoundTrips.mesh + controlRoundTrips.relay === 1) window.fortressNativePostRelease?.mark('hold_first_control', undefined, holdMark());
    }
  }
  function send(route, reports, peer, emit, data, packet) {
    if (!packet) return emit(data);
    counts[route]++;
    if (!holding && !releasingRelay) return emit(data);
    if (!holdAll && packet.kind !== inputKind) {
      const sent = emit(data);
      if (reports && packet.kind === 4 && packet.token !== null) {
        if (!reports.has(peer)) reports.set(peer, new Map());
        const tokens = reports.get(peer);
        if (tokens.has(packet.token)) return sent;
        if (tokens.size === pendingReportLimit[route]) tokens.delete(tokens.keys().next().value);
        tokens.set(packet.token, true);
      }
      return sent;
    }
    if (held.mesh + held.relay >= 1024 || totalBytes + data.byteLength > 1024 * 1024) {
      if (!holdFailure) {
        holdFailure = new Error('native packet hold exceeded bounds');
        window.fortressNativePostRelease?.mark('hold_cap', undefined, holdMark());
      }
      throw holdFailure;
    }
    const owned = nativeBytes(data).slice();
    active.push(() => emit(owned, true));
    totalBytes += owned.byteLength;
    held[route]++;
    if (!holdAll && held.mesh + held.relay === 1) window.fortressNativePostRelease?.mark('hold_first_input', undefined, holdMark());
  }
  const instant = () => Math.round(performance.now() * 1000);
  const closeConnection = RTCPeerConnection.prototype.close;
  RTCPeerConnection.prototype.close = function() {
    const result = closeConnection.call(this);
    if (observingDeparture && this.signalingState === 'closed' && ice.has(this)) ice.get(this).closedAt ??= instant();
    return result;
  };
  const createChannel = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    if (!ice.has(this)) {
      const record = { state: this.iceConnectionState, gathering: this.iceGatheringState, host: 0, srflx: 0, prflx: 0, relay: 0, other: 0, mdns: 0 };
      ice.set(this, record);
      this.addEventListener('iceconnectionstatechange', () => {
        if (this.iceConnectionState !== 'closed') record.state = this.iceConnectionState;
      });
      this.addEventListener('icegatheringstatechange', () => { record.gathering = this.iceGatheringState; });
      this.addEventListener('icecandidate', ({ candidate }) => {
        if (!candidate?.candidate) return;
        const [, address, type] = candidate.candidate.match(/^candidate:\S+ \S+ \S+ \S+ (\S+) \S+ typ (\S+)/) ?? [];
        record[['host', 'srflx', 'prflx', 'relay'].includes(type) ? type : 'other']++;
        if (address?.endsWith('.local')) record.mdns++;
      });
    }
    const channel = createChannel.call(this, label, options);
    const index = resources.rtc.length;
    const record = { index, channel, connection: this, sent: 0, received: 0, local: null, remote: null,
      closeAborts: 0, closeEvents: 0, inputsSent: 0, inputsReceived: 0 };
    channel.addEventListener('close', () => { record.closeEvents++; });
    channel.addEventListener('error', ({ error }) => {
      if (channel.id === 3 && error?.errorDetail === 'sctp-failure' && error.message === 'User-Initiated Abort, reason=Close called') record.closeAborts++;
    });
    channel.addEventListener('message', ({ data }) => {
      const view = nativeBytes(data);
      if (channel.id === 3 && view && matches(view, 0)) {
        record.received++;
        const packet = nativePacket(view);
        if (packet.kind === inputKind) record.inputsReceived++;
        receive('mesh', channelReports, channel, packet);
      }
    });
    resources.rtc.push(record);
    const nativeSend = channel.send;
    // WebKit reports a native send rejection on the calling stack without throwing.
    const tagged = (name, receipt) => new Function('send', 'channel', 'receipt', 'instant',
      `return function ${name}(bytes) { ${receipt ? 'receipt.sentAt = instant(); ' : ''}send.call(channel, bytes); }`)(nativeSend, channel, receipt, instant);
    const emit = tagWebKitSends ? tagged(`fortressNativeSend_${index}`) : bytes => nativeSend.call(channel, bytes);
    channel.send = data => {
      const view = nativeBytes(data);
      const packet = channel.id === 3 && view && matches(view, 0) ? nativePacket(view) : null;
      return send('mesh', channelReports, channel, bytes => {
        if (tagWebKitSends && observingDeparture) {
          const attempt = ++departureSendCount;
          const receipt = { attempt, channel: index, sentAt: null };
          departureSendHistory[attempt % departureSendLimit] = receipt;
          tagged(`fortressNativeSend_${index}_${attempt}`, receipt)(bytes);
        } else emit(bytes);
        if (packet) record.sent++;
        if (packet?.kind === inputKind) record.inputsSent++;
      }, data, packet);
    };
    return channel;
  };
  const nativeSocket = WebSocket;
  const socketClose = nativeSocket.prototype.close;
  let deferredClose;
  let holdTerminalClose = false;
  nativeSocket.prototype.close = function(code, reason) {
    if (holdTerminalClose && code === 1000 && reason === 'Online example failed') {
      if (deferredClose) throw new Error('native terminal tried to close twice');
      // Godot already cleared this receive buffer. The browser would stop messages on close.
      this.onmessage = null;
      deferredClose = () => socketClose.call(this, code, reason);
      return;
    }
    return socketClose.call(this, code, reason);
  };
  window.WebSocket = new Proxy(nativeSocket, { construct(target, args, newTarget) {
    const socket = Reflect.construct(target, args, newTarget);
    const reports = new Map();
    socketReports.set(socket, reports);
    traceSocketOrdinals?.set(socket, 0);
    resources.sockets.push(socket);
    socket.addEventListener('message', event => {
      if (replayedRelayEvents?.has(event)) return;
      const { data } = event;
      const relayPacket = relayWireTrace?.record('raw', nativeBytes(data));
      if (blockedRelay?.socket === socket && blockedRelay.sender === relayPacket?.sender && relayPacket.kind >= 2
          && performance.now() < blockedRelay.deadline_ms) {
        relayPacket.delivery_blocked = true;
        if (relayPacket.kind === inputKind) blockedRelay.inputs++;
        if (relayPacket.kind === 4) blockedRelay.reports++;
        event.stopImmediatePropagation();
        return;
      }
      if (relayDelay?.socket === socket) relayDelay.hold(event, relayPacket);
      const incoming = readRecovery(data, 'receive');
      if (isFirstRecoveryOfferTraffic(incoming)) recovery.receivedKinds[incoming.kind]++;
      if (incoming?.kind === 'Offer') recovery.delivered.push({ ...incoming, at_ms: performance.now() });
      const packet = relayAddresses(data);
      if (!packet) return;
      relayBroadcasts++;
      if (packet.recipient === localUuid) {
        increment(relaySenders, packet.sender);
        if (!warmupCutoff && warmupLinks.has(packet.sender) && packet.kind === 4 && packet.bytes.length === 46 && (packet.bytes[30] & 3) === 0) {
          recordWarmup('raw', packet.sender, hex(packet.bytes), null);
        }
        if (packet.kind === inputKind) increment(relayInputSenders, packet.sender);
        traceRelayQuality('receive', packet.sender, packet);
        receive('relay', reports, packet.sender, packet);
      }
    });
    return socket;
  } });
  const socketSend = nativeSocket.prototype.send;
  function closedReleaseSocket(socket, socket_stage, held_send) {
    if (!releaseSocketFailures.has(held_send)) {
      releaseSocketFailures.add(held_send);
      const kind = held_send ? 'release_socket_closed' : 'release_control_socket_closed';
      window.fortressNativePostRelease?.mark(kind, undefined, { ...holdMark(), socket_state: socket.readyState, socket_stage, held_send });
    }
    const when = socket_stage === 'before_send' ? 'before' : 'during';
    throw new Error(`native relay socket closed ${when} release send`);
  }
  nativeSocket.prototype.send = function(data) {
    const outgoing = readRecovery(data, 'send');
    if (blockRecovery && outgoing) return;
    if (outgoing?.kind === 'Offer') {
      if (recovery.observed.length === 8) throw new Error('recovery sent too many scoped offers');
      recovery.observed.push({ ...outgoing, at_ms: performance.now() });
      if (recovery.drops === 'drop-all-offers') {
        recovery.droppedOffers++;
        return;
      }
    }
    if (recovery.scope?.holdsOffer && isFirstRecoveryOfferTraffic(outgoing) && !recovery.released) {
      if (recovery.pending.length === 32) throw new Error('scoped SDP and ICE queue exceeded its bound');
      recovery.queuedKinds[outgoing.kind]++;
      recovery.pending.push({ kind: outgoing.kind, emit: () => {
        if (this.readyState !== nativeSocket.OPEN) throw new Error('recovery signaling socket closed before release');
        socketSend.call(this, data);
      } });
      return;
    }
    const packet = relayAddresses(data);
    if (mutedRelay && packet?.sender === localUuid && packet.recipient === mutedRelay.recipient) {
      if (performance.now() < mutedRelay.cutoff) {
        if (packet.kind === inputKind) mutedRelay.inputs++;
        if (packet.kind === 4) mutedRelay.reports++;
        return;
      }
      mutedRelay.last_quiet_ordinal ??= traceSocketOrdinals.get(this);
    }
    return send('relay', socketReports.get(this), packet?.recipient, (bytes, held_send = false) => {
      if (releasingRelay && packet && this.readyState !== nativeSocket.OPEN) closedReleaseSocket(this, 'before_send', held_send);
      socketSend.call(this, bytes);
      if (releasingRelay && packet && this.readyState !== nativeSocket.OPEN) closedReleaseSocket(this, 'during_send', held_send);
      if (traceSocketOrdinals && this.readyState === nativeSocket.OPEN) {
        const binary = nativeBytes(bytes);
        if (binary) {
          const ordinal = traceSocketOrdinals.get(this) + 1;
          traceSocketOrdinals.set(this, ordinal);
          relayWireTrace.record('send', binary, ordinal);
        }
      }
      if (packet && packet.sender === localUuid) {
        increment(relayRecipients, packet.recipient);
        if (packet.kind === inputKind) increment(relayInputRecipients, packet.recipient);
        bufferedBytesPeak = Math.max(bufferedBytesPeak, this.bufferedAmount);
        if (packet.kind === 5) recordWarmupReply(packet);
        traceRelayQuality('send', packet.recipient, packet);
      }
    }, data, packet?.sender === localUuid ? packet : null);
  };
  function sctpStatus() {
    return resources.rtc.filter(({channel}) => channel.id === 3).map(record => {
      if ((!record.local || !record.remote) && record.connection.signalingState !== 'closed') {
        record.local = ufrag(record.connection.localDescription) ?? record.local;
        record.remote = ufrag(record.connection.remoteDescription) ?? record.remote;
      }
      return { index: record.index, local: record.local, remote: record.remote, closeAborts: record.closeAborts, closeEvents: record.closeEvents,
        open: record.channel.readyState === 'open' && record.connection.connectionState === 'connected',
        ordered: record.channel.ordered, maxRetransmits: record.channel.maxRetransmits, maxPacketLifeTime: record.channel.maxPacketLifeTime,
        unreliable: record.channel.ordered === false && (record.channel.maxRetransmits === 0 || record.channel.maxPacketLifeTime !== null),
        inputsSent: record.inputsSent, inputsReceived: record.inputsReceived,
        closed: record.channel.readyState === 'closed', connectionClosed: record.connection.signalingState === 'closed',
        closedAt: ice.get(record.connection).closedAt ?? null };
    });
  }
  window.fortressNativeWire = {
    sctpStatus,
    bind(hash, uuid, roster = []) {
      if (session || !/^[0-9a-f]{32}$/.test(hash)) throw new Error('invalid native room session');
      localUuid = uuid.replaceAll('-', '');
      session = hash.match(/../g).map(value => parseInt(value, 16));
      roomRoster = roster.slice(0, 8).map(member => member.replaceAll('-', ''));
      relayWireTrace?.bind(hash, localUuid, roomRoster);
      if (warmupPrefix) {
        for (const sender of roomRoster) {
          if (sender !== localUuid) warmupLinks.set(sender, {
            packets: new Map(), evicted: 0, unretained: { sdk: 0, native: 0 }, discardedThroughToken: '', last_replied_report: null,
          });
        }
      }
      if (warmupLinks.size) warmupStarted = performance.now();
    },
    recordWarmup,
    async relayWireTrace(links) {
      const sockets = resources.sockets.length;
      return relayWireTrace && { ...await relayWireTrace.freeze(links), sockets };
    },
    holdRelayControl: delayRelayDelivery,
    releaseRelayControl: stamps => relayDelay?.releaseWhenHeld(stamps) ?? expiredRelayDelay,
    muteRelayLink(recipient) {
      if (!relayWireTrace || resources.sockets.length !== 1 || mutedRelay || recipient === localUuid || !roomRoster.includes(recipient))
        throw new Error('invalid relay retention link');
      const started = performance.now();
      const first_quiet_ordinal = traceSocketOrdinals.get(resources.sockets[0]);
      mutedRelay = { recipient, started, cutoff: started + 1250, first_quiet_ordinal, last_quiet_ordinal: null, inputs: 0, reports: 0 };
    },
    resumeRelayLink() {
      const sample = mutedRelay;
      mutedRelay = null;
      const last_quiet_ordinal = sample.last_quiet_ordinal ?? traceSocketOrdinals.get(resources.sockets[0]);
      return { ...sample, last_quiet_ordinal, resumed: performance.now() };
    },
    blockRelayLink(sender) {
      const socket = resources.sockets[0];
      if (!relayWireTrace || resources.sockets.length !== 1 || socket.readyState !== nativeSocket.OPEN
          || blockedRelay || sender === localUuid || !roomRoster.includes(sender)) throw new Error('invalid same-link delivery gate');
      const { frontier } = relayWireTrace.retentionSample(sender);
      if (!frontier.every(Boolean)) throw new Error('same-link control requires accepted input and quality before pressure');
      const started_ms = performance.now();
      blockedRelay = { socket, sender, started_ms, deadline_ms: started_ms + 1250, inputs: 0, reports: 0 };
      return { started_ms, frontier };
    },
    resumeBlockedRelay(stamps) {
      if (!blockedRelay) return null;
      const { sender, started_ms, deadline_ms, inputs, reports } = blockedRelay;
      if (stamps && performance.now() < deadline_ms && !relayWireTrace.hasBlockedRelayStamps(sender, started_ms, stamps)) return null;
      const resumed_ms = performance.now();
      blockedRelay = null;
      return { resumed_ms, deadline_ms, inputs, reports };
    },
    pressureRelayLink(recipient) {
      const socket = resources.sockets[0];
      if (!relayWireTrace || resources.sockets.length !== 1 || socket.readyState !== nativeSocket.OPEN)
        throw new Error('missing same-link pressure socket');
      return relayWireTrace.pressureLink(recipient, bytes => {
        socket.send(bytes);
        return traceSocketOrdinals.get(socket);
      });
    },
    repeatRelayControl(recipient, other) {
      const socket = resources.sockets[0];
      if (resources.sockets.length !== 1 || socket.readyState !== nativeSocket.OPEN) throw new Error('missing relay control socket');
      return relayWireTrace.repeatQuality(recipient, other, bytes => {
        socket.send(bytes);
        return traceSocketOrdinals.get(socket);
      });
    },
    warmupStatus,
    recordWarmupTick(before, after, budget, elapsed_us, state, frame, confirmed) {
      if (!warmupLinks.size || warmupCutoff) return;
      const at = performance.now();
      if (warmupTicks.length === 24) warmupTicks.shift();
      warmupTicks.push({ at_ms: at, before, after, budget, elapsed_us, state, frame, confirmed });
      warmupTickCount++;
      scheduleWarmupCheckpoint(at);
    },
    finishWarmup(state, frame, confirmed, terminalEndpoint = 0) {
      if (warmupLinks.size && !warmupCutoff) {
        warmupCutoff = { at_ms: performance.now(), reason: state === 'failed' ? 'failed' : 'gate', state, frame, confirmed };
        const uuid = roomRoster[terminalEndpoint - 1];
        if (state === 'failed' && warmupLinks.has(uuid)) {
          warmupCutoff.terminal_endpoint = terminalEndpoint;
          warmupCutoff.terminal_uuid = uuid;
        }
        checkpointWarmup(warmupCutoff.at_ms);
      }
    },
    blockRecovery() { blockRecovery = true; },
    observeRecovery(scope) {
      if (recovery.scope) throw new Error('recovery scope already set');
      recovery.scope = scope;
    },
    releaseRecovery(drops = null) {
      if (recovery.queuedKinds.Offer !== 1 || !recovery.pending.length || recovery.released) throw new Error('recovery SDP was not held');
      recovery.drops = drops;
      recovery.released = performance.now();
      const pending = recovery.pending.splice(0);
      for (const { kind, emit } of pending) {
        if (drops && kind === 'Offer') recovery.droppedOffers++;
        else emit();
      }
      return pending.length - recovery.droppedOffers;
    },
    meshOpen(peers) {
      return resources.rtc.filter(({channel, connection}) => channel.readyState === 'open' && connection.connectionState === 'connected').length === peers * 3;
    },
    observeDeparture() { observingDeparture = true; return window.crossOriginIsolated ? instant() : null; },
    departureSends(attempts) {
      return Object.fromEntries(attempts.flatMap(attempt => {
        const receipt = departureSendHistory[attempt % departureSendLimit];
        return receipt?.attempt === attempt ? [[attempt, receipt]] : [];
      }));
    },
    arm(all = false) {
      if (!armed) {
        armed = true;
        holdAll = all;
        holding = true;
        hold.armed = holdMark();
      }
      return hold.armed;
    },
    async release(cutoffUs = null) {
      if (!holding || !active.length) throw new Error('native packet hold did not take effect');
      holding = false;
      releasingRelay = held.relay > 0;
      hold.release = holdMark();
      // Each relay send fans out to the room. Keep originals ahead of newly sampled inputs.
      const batchSize = releasingRelay ? 16 : active.length;
      while (active.length > 0 && !holdFailure) {
        if (cutoffUs !== null && Math.ceil(performance.now() * 1000) >= cutoffUs) throw new Error('native relay release deadline');
        const batch = active.splice(0, batchSize);
        releaseInFlight = batch.length;
        for (const emit of batch) {
          emit();
          released++;
          releaseInFlight--;
        }
        if (active.length > 0) {
          if (released === batchSize || released % 128 === 0) window.fortressNativePostRelease?.mark('release_progress', undefined, holdMark());
          await new Promise(resolve => requestAnimationFrame(resolve));
        }
      }
      if (holdFailure) throw holdFailure;
      releasingRelay = false;
      releaseEnded = performance.now();
      return hold.release;
    },
    // Let every peer report native expiry before a socket close can cause a room-departure event.
    holdTerminal() {
      holdTerminalClose = true;
      this.arm(true);
    },
    releaseTerminal() {
      if (!deferredClose) throw new Error('native terminal did not close its SDK socket');
      holdTerminalClose = false;
      deferredClose();
    },
    recordHoldReadiness(route) {
      if (!holding || !holdConditions(route).every(Boolean)) return null;
      return hold.ready ??= holdMark();
    },
    holdConditions,
    holdProgress: holdMark,
    holdObservation() {
      return { ...holdMark(), control_round_trips: controlRoundTrips.relay,
        buffered_bytes: resources.sockets.reduce((total, socket) => total + socket.bufferedAmount, 0),
        traffic: Array.from(lastRelayQuality.values(), ({ sequence, ...event }) => event) };
    },
    status() {
      const holdMs = hold.armed === null ? null : Math.round((hold.release?.at_ms ?? performance.now()) - hold.armed.at_ms);
      const events = [...qualityEvents.send, ...qualityEvents.receive].sort((a, b) => a.sequence - b.sequence)
        .map(({ direction, peer, kind, token, at_ms }) => ({ direction, peer, kind, token, at_ms }));
      const releaseMs = hold.release === null ? null : Math.round((releaseEnded ?? performance.now()) - hold.release.at_ms);
      return { armed, holding, hold_ms: holdMs, release_ms: releaseMs, deferredClose: Boolean(deferredClose), counts: { ...counts }, held: { ...held }, released, totalBytes,
        hold_boundaries: { ...hold },
        control_round_trips: { ...controlRoundTrips },
        relayRecipients: Object.fromEntries(relayRecipients), relaySenders: Object.fromEntries(relaySenders),
        relayInputRecipients: Object.fromEntries(relayInputRecipients), relayInputSenders: Object.fromEntries(relayInputSenders),
        recovery: { released: recovery.released, pending: recovery.pending.length, droppedOffers: recovery.droppedOffers,
          queuedKinds: { ...recovery.queuedKinds }, receivedKinds: { ...recovery.receivedKinds },
          delivered: [...recovery.delivered], observed: [...recovery.observed] },
        relay_trace: { buffered_bytes_peak: bufferedBytesPeak, broadcasts: relayBroadcasts, events,
          event_count: qualityEventCount, direction_counts: { ...qualityEventCounts } },
        ice: [...ice.values()], sctp: sctpStatus(),
        rtc: resources.rtc.map(({channel, sent, received}) => [channel.id, channel.readyState, sent, received]),
        sockets: resources.sockets.map(socket => socket.readyState) };
    },
  };
}

function reportedChannel(stack) {
  const frames = [...(stack ?? '').matchAll(/^\s*at (?:Object\.)?fortressNativeSend_(\S+) \(/gm)];
  const tag = frames.length === 1 ? /^(0|[1-9]\d*)(?:_([1-9]\d*))?$/.exec(frames[0][1]) : null;
  if (!tag) return { channel: null, attempt: null };
  const channel = Number(tag[1]);
  const attempt = tag[2] === undefined ? null : Number(tag[2]);
  return Number.isSafeInteger(channel) && (attempt === null || Number.isSafeInteger(attempt))
    ? { channel, attempt } : { channel: null, attempt: null };
}

function clockWindow(start, end, sampledAt) {
  if (!Number.isSafeInteger(sampledAt) || sampledAt < 0) return null;
  // The isolated browser clocks coarsen by up to 20 us. Allow for two reads and integer rounding.
  return { offsetMin: start - sampledAt - 41, offsetMax: end - sampledAt + 41 };
}

function intersectClock(previous, sample) {
  if (!previous || !sample) return null;
  const offsetMin = Math.max(previous.offsetMin, sample.offsetMin);
  const offsetMax = Math.min(previous.offsetMax, sample.offsetMax);
  return offsetMin <= offsetMax ? { offsetMin, offsetMax } : null;
}

function closeEvidence({ index, channel, attempt }, linksBefore, closedByPage, closer = null, clocks, receipt) {
  const sentAt = Number.isSafeInteger(attempt) && attempt > 0 && receipt?.attempt === attempt && receipt.channel === channel
    && Number.isSafeInteger(receipt.sentAt) && receipt.sentAt >= 0 ? receipt.sentAt : null;
  const before = linksBefore.find(peer => peer.index === channel) ?? null;
  const evidence = { index, channel, attempt, sentAt, closer, before, sender: null, counterparts: [], minimumGapUs: null, maximumGapUs: null, proof: null };
  if (!before?.local || !before.remote || before.closed) return evidence;
  evidence.sender = closedByPage[index].find(peer => peer.index === channel && peer.local === before.local && peer.remote === before.remote) ?? null;
  evidence.counterparts = closedByPage.flatMap((links, owner) => owner === index ? [] : links
    .filter(peer => peer.local === before.remote && peer.remote === before.local)
    .map(peer => ({ ...peer, owner })));
  if (evidence.counterparts.length !== 1) return evidence;
  const [counterpart] = evidence.counterparts;
  const senderClock = clocks?.[index];
  const closerClock = clocks?.[counterpart.owner];
  // Compare the earliest possible send with the latest possible close.
  if (senderClock && closerClock && Number.isSafeInteger(sentAt) && Number.isSafeInteger(counterpart.closedAt)) {
    evidence.minimumGapUs = sentAt + senderClock.offsetMin - counterpart.closedAt - closerClock.offsetMax;
    evidence.maximumGapUs = sentAt + senderClock.offsetMax - counterpart.closedAt - closerClock.offsetMin;
  }
  if (closer !== null) {
    if (counterpart.owner === closer && counterpart.closed && evidence.sender?.closed) evidence.proof = 'stream-close';
  } else if (counterpart.connectionClosed && evidence.sender) {
    if (evidence.sender.closeAborts > before.closeAborts) evidence.proof = 'sctp-abort';
    else if (evidence.minimumGapUs >= 2000) evidence.proof = 'clock-order';
  }
  return evidence;
}

async function calibrateDepartureClocks(pages, report, clock = () => performance.now(), timeout = PAGE_WAIT_MS) {
  const clockSamples = pages.map(() => ({ before: [], after: [] }));
  report.clockSamples = clockSamples;
  const deadline = clock() + timeout;
  const reads = await Promise.allSettled(pages.map(async (page, index) => {
    const label = `native peer ${index} departure clock`;
    const samples = clockSamples[index].before;
    for (let attempt = 0; attempt < CLOSE_CLOCK_PRE_SAMPLES; attempt++) {
      const start = clock();
      if (start >= deadline) throw new Error(`absolute ${label} deadline`);
      const sampledAt = await boundedRoom(() => page.evaluate(() => window.fortressNativeWire.observeDeparture()), Math.ceil(deadline - start), label);
      const end = clock();
      if (end >= deadline) throw new Error(`absolute ${label} deadline`);
      samples.push(clockWindow(Math.floor(start * 1000), Math.ceil(end * 1000), sampledAt));
    }
    return samples.reduce(intersectClock);
  }));
  report.clocks = reads.map(read => read.status === 'fulfilled' ? read.value : null);
  const failed = reads.flatMap((read, index) => read.status === 'rejected' ? [{ index, reason: read.reason }] : []);
  if (failed.length) {
    report.calibrationErrors = failed.map(({ index, reason }) => ({ index, reason: String(reason) }));
    throw new AggregateError(failed.map(({ index, reason }) => new Error(`native peer ${index} departure clock failed`, { cause: reason })),
      'WebKit departure clock calibration failed');
  }
}

async function waitForCloseProofs(pages, before, errors, report, { closer = null, clocks = report.clocks, clock = () => performance.now(), delay = pause } = {}) {
  if (!errors.length) return undefined;
  report.proofs = [];
  report.clocks = clocks;
  if (clocks) report.clockSamples ??= pages.map(() => ({ before: [], after: [] }));
  const latestSnapshots = pages.map(() => null);
  report.partialSnapshots = latestSnapshots;
  let rounds = 0;
  const deadline = clock() + DIAGNOSTIC_MS;
  while (clock() < deadline) {
    const roundErrors = errors.slice();
    const requested = pages.map((_, index) => [...new Set(roundErrors
      .filter(error => error.index === index && error.attempt !== null).map(error => error.attempt))]);
    const sampleClock = Boolean(report.clocks) && rounds++ < CLOSE_CLOCK_POST_SAMPLES;
    const snapshots = await Promise.allSettled(pages.map((page, index) =>
      boundedRoom(async () => {
        const start = Math.floor(clock() * 1000);
        const { links, sampledAt, sends } = await page.evaluate(({ timed, attempts }) => ({
          sampledAt: timed && window.crossOriginIsolated ? Math.round(performance.now() * 1000) : null,
          links: window.fortressNativeWire.sctpStatus(), sends: window.fortressNativeWire.departureSends(attempts),
        }), { timed: sampleClock, attempts: requested[index] });
        const receivedAt = clock();
        return { links, sends, bound: sampleClock ? clockWindow(start, Math.ceil(receivedAt * 1000), sampledAt) : null, receivedAt };
      }, Math.max(0, Math.ceil(deadline - clock())), `native peer ${index} close snapshot`)));
    const failed = snapshots.flatMap((entry, index) => entry.status === 'rejected' ? [{ index, reason: entry.reason }] : []);
    snapshots.forEach((entry, index) => {
      if (entry.status !== 'fulfilled' || entry.value.receivedAt >= deadline) return;
      const { receivedAt, links, sends, bound } = entry.value;
      latestSnapshots[index] = { received_ms: receivedAt, links, sends };
      if (sampleClock) report.clockSamples[index].after.push(bound);
    });
    report.snapshotErrors = failed.map(({ index, reason }) => ({ index, reason: String(reason) }));
    if (failed.length) {
      throw new AggregateError(failed.map(({ index, reason }) => new Error(`native peer ${index} close snapshot failed`, { cause: reason })),
        'WebKit close snapshots failed');
    }
    if (clock() >= deadline) break;
    const links = snapshots.map(entry => entry.value.links);
    if (sampleClock) {
      report.clocks = report.clocks.map((bound, index) => intersectClock(bound, snapshots[index].value.bound));
    }
    report.proofs = roundErrors.map(error => closeEvidence(error, before[error.index].wire.sctp, links, closer, report.clocks,
      snapshots[error.index].value.sends?.[error.attempt]));
    for (const proof of report.proofs) assert.ok(proof.before, `WebKit send failure for peer ${proof.index} lacked a sending channel`);
    const remaining = deadline - clock();
    if (remaining <= 0) break;
    if (roundErrors.length === errors.length && report.proofs.every(proof => proof.proof)) return links;
    await delay(Math.min(25, remaining));
  }
  const pending = [...new Set(report.proofs.filter(proof => !proof.proof).map(proof => `peer ${proof.index} channel ${proof.channel}`))];
  throw new Error(`WebKit close evidence deadline${pending.length ? ` for ${pending.join(', ')}` : ''}`);
}

function historyThrough(peers) {
  // Each observed frame is the next sample. Compare at least one later sample from every slot.
  const frames = Math.max(HISTORY_FRAMES, ...peers.map(peer => peer.frame + 2));
  assert.ok(peers.every(peer => frames <= peer.history_limit), 'post-fault samples exceeded the recorded history limit');
  return frames;
}

async function readConfirmedHistory(page, frames, id, players) {
  assert.ok(Number.isSafeInteger(id) && id > 0, 'native history request ID must be a positive safe integer');
  assert.ok(Number.isSafeInteger(frames) && frames > 0, 'native history frame count must be a positive safe integer');
  let receipt;
  const deadline = performance.now() + PAGE_WAIT_MS;
  const publication = page.waitForEvent('console', {
    timeout: PAGE_WAIT_MS,
    predicate(message) {
      const text = message.text();
      if (receipt || !text.startsWith(HISTORY_CHECKPOINT) || performance.now() >= deadline) return false;
      let sample;
      try {
        sample = JSON.parse(text.slice(HISTORY_CHECKPOINT.length));
      } catch {
        return false;
      }
      if (sample?.id !== id || sample.frames !== frames) return false;
      const { rows, snapshots } = sample;
      if (!rows || typeof rows !== 'object' || Array.isArray(rows) || Object.keys(rows).length !== frames
        || !snapshots || typeof snapshots !== 'object' || Array.isArray(snapshots) || Object.keys(snapshots).length !== frames) return false;
      for (let frame = 0; frame < frames; frame++) {
        const row = rows[frame];
        const snapshot = snapshots[frame + 1];
        if (!Array.isArray(row) || row.length !== players || !row.every(Number.isSafeInteger)
          || typeof snapshot !== 'string' || !CANONICAL_SNAPSHOT.test(snapshot)) return false;
      }
      if (performance.now() >= deadline) return false;
      receipt = { frames, rows, snapshots };
      return true;
    },
  });
  let dispatchError;
  void Promise.resolve().then(() => page.evaluate(request => {
    window.fortressNativeCapture = request;
    window.fortressNativePostRelease?.mark('history_requested', request.frames);
  }, { id, frames })).catch(error => { dispatchError = error; });
  try {
    await publication;
  } catch (error) {
    throw dispatchError ?? error;
  }
  return receipt;
}

function compareHistory(peers, frames = HISTORY_FRAMES) {
  const ordered = [...peers].sort((first, second) => first.slot - second.slot);
  assert.deepEqual(ordered.map(peer => peer.slot), peers.map((_, index) => index), 'slots must cover the frozen roster');
  assert.equal(new Set(peers.map(peer => peer.uuid)).size, peers.length, 'each page must own a distinct player');
  assert.equal(new Set(peers.map(peer => peer.session_id)).size, 1, 'native schema/roster identity must agree');
  assert.match(peers[0].session_id, /^[0-9a-f]{32}$/);
  assert.equal(new Set(peers.map(peer => peer.room_id)).size, 1, 'all peers must be in the same SignalFish room');
  assert.ok(peers[0].room_id);
  for (let frame = 0; frame < frames; frame++) {
    const expected = ordered.map(peer => frame >= GATE_FRAME && frame % 2 === 0 ? 0 : INPUTS[peer.index][0]);
    for (const peer of peers) {
      assert.deepEqual(peer.rows[frame], expected, `input row at frame ${frame}, slot ${peer.slot}`);
      assert.match(peer.snapshots[frame + 1], CANONICAL_SNAPSHOT);
      assert.equal(peer.snapshots[frame + 1], peers[0].snapshots[frame + 1], `canonical state at frame ${frame + 1}, slot ${peer.slot}`);
    }
  }
}

async function closeAll(items, close, kind) {
  const settled = await Promise.allSettled(items.map((item, index) =>
    boundedRoom(() => close(item), CLOSE_MS, `native ${kind} ${index} close`)));
  return settled.filter(result => result.status === 'rejected').map(result => result.reason);
}

function armAndWaitForInput(page, route) {
  return page.evaluate(async ({ route, gate, conditions }) => {
    const wire = window.fortressNativeWire;
    const { frame, stalls, confirmed } = window.fortressNative;
    const armed = { frame, stalls, confirmed, hold: wire.arm() };
    window.fortressNativePostRelease?.mark('hold_armed', undefined, armed.hold);
    let sawPrediction = false;
    let lastObservation = -Infinity;
    let lastPending;
    while (true) {
      const state = window.fortressNative;
      const terminal = state.state === 'failed';
      const stalled = state.stalls > stalls;
      const predicted = state.prediction >= gate;
      const behind = state.frame > gate && state.confirmed < state.frame - 1;
      const trace = window.fortressNativePostRelease;
      if (trace) {
        const met = [stalled, predicted, behind, ...wire.holdConditions(route)];
        const pending = conditions.filter((_, index) => !met[index]);
        const signature = pending.join();
        if (terminal || signature !== lastPending || performance.now() >= lastObservation + 1000) {
          const sample = wire.holdObservation();
          lastObservation = sample.at_ms;
          lastPending = signature;
          trace.mark(terminal ? 'hold_terminal' : 'hold_waiting', undefined, { ...sample, pending });
        }
      }
      if (terminal) throw new Error(state.message);
      if (state.state === 'playing' && stalled && predicted && behind) {
        if (!sawPrediction) {
          sawPrediction = true;
          window.fortressNativePostRelease?.mark('hold_first_prediction', undefined, wire.holdProgress());
        }
        const ready = wire.recordHoldReadiness(route);
        if (ready) {
          window.fortressNativePostRelease?.mark('hold_ready', undefined, ready);
          window.fortressNativePostRelease?.arm(state.restores);
          return { armed, ready: { ...ready, frame: state.frame, confirmed: state.confirmed, restores: state.restores } };
        }
      }
      await new Promise(resolve => requestAnimationFrame(resolve));
    }
  }, { route, gate: GATE_FRAME, conditions: HOLD_CONDITIONS });
}

function createReleaseSignal(players) {
  const paths = Array.from({ length: players }, () => '/native-release/' + randomUUID());
  const responses = new Map();
  const { promise: ready, resolve } = Promise.withResolvers();
  let finished = false;
  return {
    paths,
    ready,
    handle(request, response) {
      if (!paths.includes(request.url)) return false;
      if (request.method !== 'GET') response.writeHead(405).end();
      else if (finished || responses.has(request.url)) response.writeHead(409).end();
      else {
        responses.set(request.url, { response, receivedAt: performance.now() });
        if (responses.size === players) resolve();
      }
      return true;
    },
    release(deadline) {
      assert.ok(!finished && responses.size === players
        && [...responses.values()].every(({ response }) => response.socket && !response.socket.destroyed && !response.destroyed),
      'native relay release requests unavailable');
      assert.ok(Number.isFinite(deadline) && performance.now() < deadline, 'absolute native relay input release deadline');
      finished = true;
      for (const { response, receivedAt } of responses.values()) {
        const budgetUs = Math.floor((deadline - receivedAt) * 1000);
        response.writeHead(204, { 'Cache-Control': 'no-store', 'X-Fortress-Release-Budget-Us': String(budgetUs) }).end();
      }
    },
    cancel() {
      finished = true;
      for (const { response } of responses.values()) if (!response.writableEnded && !response.destroyed) response.destroy();
    },
  };
}

function captureAndReleaseInput(page, index, signalPath = null) {
  return page.evaluate(async ({ index, signalPath }) => {
    let cutoffUs = null;
    if (signalPath !== null) {
      const requestedUs = Math.floor(performance.now() * 1000);
      const signal = await fetch(signalPath, { cache: 'no-store' });
      if (signal.status !== 204) throw new Error(`native relay release signal returned HTTP ${signal.status}`);
      const budget = signal.headers.get('X-Fortress-Release-Budget-Us');
      if (!/^\d+$/.test(budget) || !Number.isSafeInteger(Number(budget))) throw new Error('invalid native relay release budget');
      // The browser started the request before the host timed it. Allow 2 ms coarsening per browser read.
      cutoffUs = requestedUs + Number(budget) - 4000;
      if (Math.ceil(performance.now() * 1000) >= cutoffUs) throw new Error('native relay release deadline');
    }
    window.fortressNativePostRelease?.mark('release_entered');
    const wire = window.fortressNativeWire;
    const stalled = structuredClone({ index, ...window.fortressNative, wire: wire.status() });
    window.fortressNativeStalled = stalled;
    if (stalled.state !== 'playing') throw new Error(stalled.message || 'peer stopped before input release');
    window.fortressNativePostRelease?.mark('release_started', undefined, wire.holdProgress());
    stalled.release = await wire.release(cutoffUs);
    window.fortressNativePostRelease?.mark('release_completed', undefined, wire.holdProgress());
    return stalled;
  }, { index, signalPath });
}

function waitForCorrectedHistory(pages, frame, readiness, wait, timeout) {
  return Promise.all(pages.map((page, index) => wait(page, target => {
    window.fortressNativePostRelease?.setTarget(target.frame);
    return window.fortressNative.state === 'playing'
      && window.fortressNative.confirmed >= target.frame && window.fortressNative.restores > target.restores;
  },
  { frame, restores: readiness[index].page.restores }, timeout)));
}

async function waitForEngineTurn(pages, engineTurns) {
  const label = 'native post-confirmation engine turn';
  const failures = [];
  const deadline = performance.now() + PAGE_WAIT_MS;
  let active = true;
  async function sample(page, attempt, read, baseline) {
    const dispatched_ms = performance.now();
    assert.ok(dispatched_ms < deadline, `absolute ${label} deadline`);
    attempt.dispatched_ms = dispatched_ms;
    const frame = await page.evaluate(read, baseline);
    const controller_ms = performance.now();
    assert.ok(active && controller_ms < deadline, `absolute ${label} deadline`);
    assert.ok(Number.isSafeInteger(frame) && frame > (baseline ?? -1), 'invalid native engine frame observation');
    attempt.receipt = { frame, controller_ms };
    return frame;
  }
  async function observePeer(page, index) {
    const trace = engineTurns[index] = { baseline: {} };
    try {
      const baseline = await sample(page, trace.baseline, () => window.fortressNative.frame);
      if (!active) return;
      trace.advance = {};
      await sample(page, trace.advance, async baseline => {
        while (true) {
          const { state, frame } = window.fortressNative;
          if (state === 'playing' && frame > baseline) return frame;
          await new Promise(resolve => requestAnimationFrame(resolve));
        }
      }, baseline);
    } catch (error) {
      if (active) failures.push(error);
    }
  }
  try {
    await boundedRoom(() => Promise.all(pages.map(observePeer)), PAGE_WAIT_MS, label);
  } catch (error) {
    failures.push(error);
  } finally {
    active = false;
  }
  return failures;
}

async function leaveWithReceipt(page, trace) {
  const publication = page.waitForEvent('console', {
    timeout: PAGE_WAIT_MS,
    predicate(message) {
      const text = message.text();
      if (!text.startsWith(DEPARTURE_CHECKPOINT)) return false;
      let sample;
      try {
        sample = JSON.parse(text.slice(DEPARTURE_CHECKPOINT.length));
      } catch {
        return false;
      }
      if (sample?.id !== trace.id || !Number.isFinite(sample.page_ms) || sample.page_ms < 0) return false;
      const controller_ms = performance.now();
      if (sample.stage === 'entered') trace.entered ??= { page_ms: sample.page_ms, controller_ms };
      if (sample.stage !== 'published' || trace.published || !trace.entered || sample.page_ms < trace.entered.page_ms
        || !Number.isSafeInteger(sample.code) || typeof sample.state !== 'string') return false;
      trace.published = { page_ms: sample.page_ms, controller_ms, code: sample.code, state: sample.state };
      return true;
    },
  });
  trace.controller_dispatch_ms = performance.now();
  const [dispatch, receipt] = await Promise.allSettled([boundedRoom(() => page.evaluate(value => { window.fortressNativeCommand = value; },
    { id: trace.id, kind: 'leave' }), PAGE_WAIT_MS, 'native leave dispatch'), publication]);
  if (dispatch.status === 'rejected') throw dispatch.reason;
  if (receipt.status === 'rejected') throw receipt.reason;
  assert.ok(trace.published.code === 0 && trace.published.state === 'offline',
    `leave failed: command ${trace.id} returned code ${trace.published.code} in state ${trace.published.state}`);
}

async function run(root, endpoint, mode, players, browserPair, control) {
  const startup = mode === 'mesh-startup';
  const liveClose = mode === 'mesh-close';
  const overlap = mode === 'mesh-recovery-overlap';
  const recovery = mode === 'mesh-recovery' || overlap;
  const omitSecond = control === '--omit-second-replacement';
  const traceRetention = control === '--relay-retention-control';
  const traceSameLink = control === '--relay-same-link-control';
  const traceRelayWire = control === '--trace-relay-wire' || traceRetention || traceSameLink;
  const traceScopePath = traceRelayWire && process.env.FORTRESS_RELAY_TRACE_SCOPE;
  const traceReceiptPath = traceScopePath && process.env.FORTRESS_RELAY_TRACE_OUTPUT;
  const readRelayServer = traceReceiptPath && createRelayServerReader(traceReceiptPath);
  const mixed = startup || liveClose || recovery;
  const route = mixed ? 'mesh' : mode;
  const traceWarmup = route === 'relay' && players === 8;
  const warmupBarrier = traceWarmup ? createWarmupBarrier(players) : undefined;
  const postRelease = route === 'relay' ? Array.from({ length: players }, () => ({})) : undefined;
  const releaseSignal = route === 'relay' ? createReleaseSignal(players) : undefined;
  const playwright = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const { server, proxyPairs } = await createHost(root, endpoint, process.env.FORTRESS_TLS_CERT, process.env.FORTRESS_TLS_KEY, 0, releaseSignal?.handle);
  const origin = `https://127.0.0.1:${server.address().port}`;
  const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
  const pages = [];
  const bootstrap_ms = [];
  const contexts = [];
  const errors = [];
  const physicalCloseErrors = [];
  const departureErrors = [];
  const departureCommands = [];
  const failures = [];
  const browsers = [];
  const browserPeers = [];
  let result;
  let roomIdentities;
  let phase = 'launch';
  let relayControl;
  let relayRetention;
  let sameLinkRetention;
  let sequence = 0;
  let postReleaseOrder = 0;
  let correctionDeadline;
  let armed, stalled;
  let comparedFrames = HISTORY_FRAMES;
  const holdReadyReceived = Array(players).fill(null);
  const engineTurns = [];
  const physicalCloseReport = {};
  const closeReport = {};
  const wait = async (page, condition, argument = null, timeout = PAGE_WAIT_MS) => {
    const handle = await page.waitForFunction(condition, argument, { timeout });
    await handle.dispose();
    if (errors.length) throw new Error(JSON.stringify(errors));
  };
  const command = async (page, kind, values = {}) => {
    const id = ++sequence;
    await page.evaluate(value => { window.fortressNativeCommand = value; }, { id, kind, ...values });
    await wait(page, expected => window.fortressNative?.command_id === expected, id);
    const state = await page.evaluate(() => window.fortressNative);
    assert.equal(state.command_code, 0, `${kind} failed: ${state.message}`);
    return state;
  };
  const leave = async (page, index) => {
    const trace = { id: ++sequence, index, phase };
    departureCommands.push(trace);
    await leaveWithReceipt(page, trace);
    if (errors.length) throw new Error(JSON.stringify(errors));
  };
  const observe = (group = pages) => Promise.all(group.map((page, index) => page.evaluate(index => ({
    index, ...window.fortressNative, wire: window.fortressNativeWire.status()
  }), index)));
  const collectRelayWire = (links = []) => Promise.allSettled(pages.map((page, index) => boundedRoom(
    () => readRelayWireReceipt(page, links), DIAGNOSTIC_MS, `native peer ${index} relay wire receipt`)));
  try {
    for (const name of browserPair) browsers.push(await playwright[name].launch(browserOptions(name)));
    for (let index = 0; index < players; index++) {
      const started = performance.now();
      const browser = browsers[index % browsers.length];
      const name = browser.browserType().name();
      const viewport = { width: 480, height: 360 };
      const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport });
      contexts.push(context);
      const page = await context.newPage();
      pages.push(page);
      const display = name === 'firefox' ? await placeFirefox(page, index) : null;
      browserPeers.push({ index, name, version: browser.version(), display });
      page.on('pageerror', error => {
        const physicalClose = (liveClose || mode === 'mesh-recovery') && phase === 'physical channel close' && index === 1;
        const departure = route === 'mesh' && phase === 'departure' && index < players - 1;
        const webkitSend = name === 'webkit' && error.name === '' && error.message === WEBKIT_CLOSED_STREAM;
        const errorList = !webkitSend ? errors : physicalClose ? physicalCloseErrors : departure ? departureErrors : errors;
        errorList.push({ index, phase, text: String(error), ...(webkitSend ? reportedChannel(error.stack) : {}) });
      });
      page.on('crash', () => errors.push({ index, phase, text: 'Renderer crashed' }));
      page.on('console', message => {
        const text = message.text();
        warmupBarrier?.record(index, text);
        if (postRelease && text.startsWith(POST_RELEASE_CHECKPOINT)) {
          const controller = { controller_ms: performance.now(), controller_order: ++postReleaseOrder };
          postReleaseCheckpoint(postRelease[index], text, controller, roomIdentities?.roster, roomIdentities?.uuids[index], comparedFrames);
        }
        if (text.includes('SCRIPT ERROR:') || text.startsWith('ERROR:')) errors.push({ index, phase, text });
      });
      page.on('requestfailed', request => {
        const url = new URL(request.url());
        errors.push({ index, phase, host: url.host, path: url.pathname, method: request.method(), resource: request.resourceType(),
          code: request.failure()?.errorText });
      });
      // Register the browser observers in a single init script.
      const relayTraceScript = traceRelayWire ? `(${createRelayWireTrace})()` : 'undefined';
      const wireScript = `(${instrumentNativeWire})(${name === 'webkit'}, ${JSON.stringify(traceWarmup ? WARMUP_CHECKPOINT : '')}, ${relayTraceScript});`;
      await page.addInitScript(postRelease ? wireScript + `(${instrumentPostRelease})(${JSON.stringify(POST_RELEASE_CHECKPOINT)}, ${HISTORY_FRAMES});` : wireScript);
      await page.goto(`${origin}/index.html`);
      await wait(page, () => window.fortressNativeReady === true, null, PAGE_BOOT_MS);
      bootstrap_ms.push(Math.round(performance.now() - started));
    }
    phase = 'lobby';
    function connect(page, index, room) {
      return command(page, 'connect', { endpoint: socketEndpoint, name: `Player ${index}`, room, route, players,
        wait_for_full_mesh: mode === 'mesh' || recovery, observe_recovery: recovery, trace_warmup: traceWarmup });
    }
    await connect(pages[0], 0, '');
    await wait(pages[0], () => window.fortressNative.state === 'lobby' && window.fortressNative.room !== '');
    const room = await pages[0].evaluate(() => window.fortressNative.room);
    await Promise.all(pages.slice(1).map((page, index) => connect(page, index + 1, room)));
    await Promise.all(pages.map(page => wait(page, () => window.fortressNative.ready_enabled)));
    const ready = await Promise.all(pages.map(page => command(page, 'ready')));
    if (postRelease) {
      const uuids = ready.map(peer => peer.uuid);
      const roster = [...uuids].sort();
      assert.ok(roster.every(uuid => FROZEN_UUID.test(uuid)) && new Set(uuids).size === players);
      for (const peer of ready) assert.deepEqual(peer.frozen_roster, roster, 'native departure requires the frozen roster');
      roomIdentities = { uuids, roster };
      postRelease.forEach((peer, index) => bindDepartureCheckpoints(peer, roster, uuids[index]));
    }
    if (readRelayServer) await bindRelayServer(ready, traceScopePath, readRelayServer);
    await wait(pages[0], () => window.fortressNative.start_enabled);
    await Promise.all(pages.map(async (page, index) => {
      for (const key of INPUTS[index][1]) await page.keyboard.down(key);
    }));
    const joined = mixed ? await observe() : [];
    const roster = joined.map(peer => peer.uuid).sort();
    if (startup) {
      await command(pages[0], 'block_startup', { uuid: joined[1].uuid });
      await command(pages[1], 'block_startup', { uuid: joined[0].uuid });
    }
    phase = startup ? 'startup with one closed channel pair' : 'warmup';
    const start = () => command(pages[0], 'start');
    if (warmupBarrier) {
      await warmupBarrier.wait(start, WARMUP_WAIT_MS);
      if (errors.length) throw new Error(JSON.stringify(errors));
    } else {
      await start();
      await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= frame, GATE_FRAME, WARMUP_WAIT_MS)));
    }
    if (readRelayServer && players === 4 && browserPair.length === 2) {
      phase = 'relay delivery control';
      relayControl = await exerciseRelayDelivery(pages, ready, readRelayServer);
    }
    if (traceRetention) {
      phase = 'relay retention control';
      assert.ok(readRelayServer, 'relay retention control requires a trace server');
      relayRetention = await exerciseRelayRetention(pages, ready, readRelayServer);
    }
    if (traceSameLink) {
      phase = 'same-link relay retention control';
      assert.ok(readRelayServer, 'same-link relay retention control requires a trace server');
      sameLinkRetention = await exerciseSameLinkRetention(pages, ready, readRelayServer);
    }
    let direct, atClose, afterClose, restored, recoveryEvidence, closeLinks;
    if (liveClose || recovery) {
      direct = await observe();
      for (const peer of direct) {
        assert.deepEqual(peer.relay_peers, [], 'the room must begin on direct links');
        assert.ok(peer.wire.counts.mesh > 0 && peer.wire.counts.relay === 0);
        assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      }
    }
    if (recovery) {
      ({ atClose, afterClose, restored, recoveryEvidence } = await recoverPairs(direct, {
        pages, observe: () => boundedRoom(observe, 3000, 'native recovery snapshot'), command, pause, overlap, omitSecond,
        setPhase: value => { phase = value; },
      }));
      comparedFrames = historyThrough(restored);
      if (!overlap) closeLinks = await waitForCloseProofs(pages, direct, physicalCloseErrors, physicalCloseReport, { closer: 0 });
    }
    if (liveClose) {
      // Keep the fault on both routes for the independent native-expiry cell.
      await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.blockRecovery())));
      phase = 'physical channel close';
      await command(pages[0], 'close_link', { uuid: joined[1].uuid });
      await Promise.all(pages.slice(0, 2).map(page => wait(page, count => window.fortressNativeWire.status().rtc
        .filter(([id, state]) => id === 3 && state === 'closed').length === count, 1)));
      afterClose = await observe();
      comparedFrames = historyThrough(afterClose);
      phase = 'mixed confirmed history';
      closeLinks = await waitForCloseProofs(pages, direct, physicalCloseErrors, physicalCloseReport, { closer: 0 });
    }
    if (!mixed) {
      let relayRelease;
      stalled = Array(players).fill(null);
      if (releaseSignal) {
        phase = 'relay release preparation';
        // Prepare the browser requests before the hold so release avoids another debugger evaluation.
        relayRelease = Promise.all(pages.map(async (page, index) => {
          stalled[index] = await captureAndReleaseInput(page, index, releaseSignal.paths[index]);
        }));
        await boundedRoom(() => Promise.race([releaseSignal.ready, relayRelease]), PAGE_WAIT_MS, 'native relay release preparation');
      }
      phase = 'prediction stall';
      // Arming on each local frame can strand a slower peer before its own
      // gate. Let every endpoint confirm the warmup while routes are open.
      armed = Array(players).fill(null);
      const allReady = Promise.all(pages.map(async (page, index) => {
        const receipt = await boundedRoom(() => armAndWaitForInput(page, route), 45000, `native peer ${index} prediction stall`);
        holdReadyReceived[index] = { controller_ms: performance.now(), page: receipt.ready };
        armed[index] = receipt.armed;
      }));
      await (relayRelease ? Promise.race([allReady, relayRelease]) : allReady);
      assert.ok(holdReadyReceived.every(Boolean), 'native relay release completed before hold readiness');
      if (errors.length) throw new Error(JSON.stringify(errors));
      phase = 'input release';
      const correctionBudgetMs = 45000;
      const releaseDispatchedAt = performance.now();
      correctionDeadline = releaseDispatchedAt + correctionBudgetMs;
      if (releaseSignal) {
        for (const peer of postRelease) peer.release_dispatched_ms = releaseDispatchedAt;
        releaseSignal.release(correctionDeadline);
        await boundedRoom(() => relayRelease, correctionBudgetMs, 'native relay input release');
      } else {
        await Promise.all(pages.map(async (page, index) => {
          stalled[index] = await boundedRoom(() => captureAndReleaseInput(page, index), correctionBudgetMs, `native peer ${index} input release`);
        }));
      }
      comparedFrames = historyThrough(stalled);
      phase = 'corrected history';
      const correctionRemainingMs = Math.floor(correctionDeadline - performance.now());
      assert.ok(correctionRemainingMs > 0, 'native input release exhausted the correction deadline');
      await boundedRoom(() => waitForCorrectedHistory(pages, comparedFrames, holdReadyReceived, wait, correctionRemainingMs),
        correctionRemainingMs, 'native corrected history');
      assert.ok(performance.now() < correctionDeadline, 'native corrected history exceeded the correction deadline');
    } else {
      phase = 'mixed confirmed history';
      await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= frame, comparedFrames)));
    }
    // A waiting step can publish confirmation before dispatching a correction.
    phase = 'post-confirmation engine turn';
    const engineTurnFailures = await waitForEngineTurn(pages, engineTurns);
    if (engineTurnFailures.length) {
      const lastFailure = engineTurnFailures.pop();
      failures.push(...engineTurnFailures);
      throw lastFailure;
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    phase = 'confirmed history capture';
    const history = await Promise.all(pages.map(async (page, index) => {
      const receipt = await boundedRoom(() => readConfirmedHistory(page, comparedFrames, ++sequence, players), PAGE_WAIT_MS,
        `native peer ${index} confirmed history capture`);
      if (postRelease) postRelease[index].history_received = { frames: receipt.frames, controller_ms: performance.now() };
      return receipt;
    }));
    phase = 'post-capture status';
    const peers = (await boundedRoom(observe, PAGE_WAIT_MS, 'native post-capture status'))
      .map((peer, index) => ({ ...peer, rows: history[index].rows, snapshots: history[index].snapshots }));
    compareHistory(peers, comparedFrames);
    if (recovery) assertRecoveredRoom(direct, restored, peers, recoveryEvidence);
    phase = 'route validation';
    const other = route === 'mesh' ? 'relay' : 'mesh';
    for (const peer of peers) {
      assert.equal(peer.movement_errors, 0, 'game must respond to every observed input');
      assert.equal(peer.game_frame, peer.frame, 'driver and game frame must agree');
      if (recovery) {
        assert.deepEqual(peer.relay_peers, []);
        continue;
      }
      if (mixed) {
        const affected = peer.index < 2;
        const expectedCloseState = startup && affected ? 0 : liveClose && peer.index === 0 ? 1 : -1;
        assert.equal(peer.closed_channel_state, expectedCloseState, 'the target channel must close at the specified lifecycle boundary');
        assert.deepEqual(peer.relay_peers, affected ? [joined[1 - peer.index].uuid] : [], 'fallback must target only the closed pair');
        assert.deepEqual(peer.sdk_roster.sort(), roster, 'the original SDK roster must stay in the room');
        if (startup && affected) {
          assert.ok(peer.previous_transport_delay < 3000000 && peer.transport_start_delay >= 3000000, 'fallback must start on the first tick after grace');
        } else {
          assert.ok(peer.open_mesh_wait_ticks <= 2, 'a complete direct mesh must start once the engine observes its channels');
        }
        const recipient = affected ? joined[1 - peer.index].uuid.replaceAll('-', '') : null;
        assert.deepEqual(Object.keys(peer.wire.relayRecipients), recipient ? [recipient] : [], 'relay must send only to the closed pair');
        assert.deepEqual(Object.keys(peer.wire.relaySenders), recipient ? [recipient] : [], 'only the closed pair must receive addressed relay');
        const open = peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open');
        assert.equal(open.length, players - (affected ? 2 : 1));
        assert.ok(open.every(([, , sent, received]) => sent > 0 && received > 0), 'every healthy channel must carry direct gameplay both ways');
        if (liveClose) {
          assert.ok(peer.wire.rtc.every(([id, state, sent, received], index) => id !== 3 || state !== 'open'
            || (sent > afterClose[peer.index].wire.rtc[index][2] && received > afterClose[peer.index].wire.rtc[index][3])),
          'each unaffected channel must exchange gameplay after the close');
          if (peer.index === 0) assert.ok(peer.closed_channel_frame < comparedFrames, 'physical close must precede confirmed history');
        }
        continue;
      }
      const before = stalled[peer.index];
      const ready = holdReadyReceived[peer.index].page;
      if (route === 'mesh') {
        assert.ok(peer.started_on_full_mesh, 'the direct-only room must start with every physical channel connected');
        assert.ok(peer.open_mesh_wait_ticks <= 2, 'a complete direct mesh must start when the engine sees its channels');
      }
      assert.ok(peer.saves > 0 && peer.advances > peer.frame && peer.restores > ready.restores, 'save, load and re-advance must run');
      assert.ok(ready.frame > GATE_FRAME && ready.confirmed < ready.frame - 1, 'gate must force prediction beyond confirmation');
      assert.ok(before.wire.holding && before.wire.held[route] > 0, 'native bytes must be held on the selected physical route');
      assert.ok(before.wire.control_round_trips[route] > 0, 'native control must make a round trip on the selected route during the input hold');
      assert.ok(!peer.wire.holding && peer.wire.totalBytes > 0 && peer.wire.released === peer.wire.held[route]
        && peer.wire.released >= before.wire.held[route], 'held originals must be released');
      assert.equal(peer.wire.counts[other], 0, 'native traffic must use the selected physical route');
      if (route === 'mesh') assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      else assert.deepEqual(peer.wire.rtc, [], 'initial relay must avoid WebRTC channel creation');
    }
    const survivors = liveClose ? pages : pages.slice(0, -1);
    let interruption;
    if (liveClose) {
      phase = 'native interruption';
      await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.holdTerminal())));
      interruption = await boundedRoom(() => Promise.all(pages.map(async (page, index) => {
        const handle = await page.waitForFunction(index => {
          const status = window.fortressNative;
          if (!status.interrupted.length || status.state !== 'playing' || status.terminal_endpoint !== 0) return null;
          return structuredClone({ index, ...status, wire: window.fortressNativeWire.status() });
        }, index, { timeout: PAGE_WAIT_MS });
        try {
          return await handle.jsonValue();
        } finally {
          await handle.dispose();
        }
      })), PAGE_WAIT_MS, 'native interruption snapshots');
      if (errors.length) throw new Error(JSON.stringify(errors));
      for (const peer of interruption) {
        assert.deepEqual(peer.sdk_roster.sort(), roster);
        assert.deepEqual(peer.wire.sockets, [1], 'SDK signaling must remain connected during the outage');
        assert.ok(peer.wire.holding && peer.wire.held.mesh > 0, 'direct gameplay must be held');
        assert.equal(peer.wire.held.relay > 0, peer.index < 2, 'relay gameplay for the closed pair must also be held');
      }
    } else {
      if (route === 'mesh' && browserPair.includes('webkit')) {
        phase = 'departure clock calibration';
        await calibrateDepartureClocks(pages, closeReport);
      }
      phase = 'departure';
      await leave(pages.at(-1), players - 1);
    }
    await Promise.all(survivors.map(page => wait(page, () => window.fortressNative.state === 'failed' && window.fortressNative.terminated)));
    const terminal = await observe(survivors);
    await Promise.all(survivors.map((page, index) => wait(page, turns => window.fortressNative.turns >= turns + 8, terminal[index].turns)));
    const after = await observe(survivors);
    for (const [index, peer] of after.entries()) {
      const before = terminal[index];
      assert.equal(peer.state, 'failed');
      assert.ok(peer.terminated && peer.reason !== 0 && peer.message);
      if (liveClose) {
        assert.equal(peer.terminal_detail, 'disconnected', 'the native protocol must report expiry');
        assert.deepEqual(peer.frozen_roster, roster, 'expiry must use the original frozen endpoint mapping');
        assert.equal(peer.frozen_roster[peer.slot], peer.uuid, 'the local slot must match the frozen roster');
        const endpoint = peer.terminal_endpoint;
        assert.ok(Number.isInteger(endpoint) && endpoint > 0 && endpoint <= players && endpoint !== peer.slot + 1,
          'native expiry must identify a remote endpoint');
        assert.deepEqual(peer.sdk_roster.sort(), roster, 'the original SDK roster must survive until native expiry');
        assert.deepEqual(peer.wire.sockets, [1], 'SDK room must survive the outage until native expiry');
        assert.ok(peer.wire.deferredClose, 'the app must initiate native terminal cleanup');
        assert.deepEqual([peer.saves, peer.restores, peer.advances], peer.failure_tick_callbacks, 'no callback may run on or after native expiry');
      } else {
        assert.equal(peer.terminal_endpoint, 0, 'SDK departure must not report a native expiry endpoint');
      }
      for (const key of ['frame', 'confirmed', 'reason', 'terminal_detail', 'terminal_endpoint', 'message', 'game_frame', 'saves', 'restores', 'advances'])
        assert.equal(peer[key], before[key], `terminal ${key} changed for survivor ${index}`);
    }
    phase = 'teardown';
    if (!liveClose) closeLinks = await waitForCloseProofs(pages, peers, departureErrors, closeReport) ?? closeLinks;
    if (liveClose) await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.releaseTerminal())));
    const teardown = await Promise.allSettled(survivors.map(leave));
    const leaveErrors = teardown.filter(outcome => outcome.status === 'rejected').map(outcome => outcome.reason);
    if (leaveErrors.length) throw new AggregateError(leaveErrors, 'native teardown leave failed');
    await Promise.all(pages.map(page => wait(page, () => {
      const { sockets, rtc } = window.fortressNativeWire.status();
      return window.fortressNative.state === 'offline' && sockets.every(state => state === WebSocket.CLOSED)
        && rtc.every(([, state]) => state === 'closed');
    })));
    let relayWire;
    let relayServer;
    let relayJoined;
    if (traceRelayWire) {
      phase = 'relay wire receipt';
      relayWire = (await collectRelayWire()).map(({ status, value, reason }, index) => {
        if (status === 'rejected') throw reason;
        assert.equal(value.local, roomIdentities.uuids[index].replaceAll('-', ''), 'relay wire receipt has the wrong local UUID');
        for (const [stage, streams] of Object.entries(value.streams)) {
          for (const [family, { count }] of Object.entries(streams)) assert.ok(count > 0, `missing relay ${stage} ${family}`);
        }
        return value;
      });
      assert.equal(new Set(relayWire.map(trace => trace.room)).size, 1, 'relay wire receipts disagree on the frozen room');
      if (readRelayServer) {
        relayServer = await readRelayServer();
        relayJoined = joinRelayReceipts(relayServer, relayWire);
        if (relayControl) assertJoinedRelayControl(relayJoined);
      }
    }
    result = { passed: true, route: mode, players, compared_frames: comparedFrames, browser_peers: browserPeers, bootstrap_ms, armed, stalled,
      holdReadyReceived: mixed ? undefined : holdReadyReceived, postRelease, correctionDeadline, engineTurns, relayWire, relayControl,
      relayServer, relayJoined, relayRetention, sameLinkRetention,
      releaseEvidence: postRelease && relayReleaseEvidence(postRelease, roomIdentities?.uuids, false), departureCommands, roomIdentities,
      direct, atClose, afterClose, restored, recoveryEvidence, peers, interruption, terminal, after, closeErrors: [...physicalCloseErrors, ...departureErrors], closeLinks,
      departureClocks: closeReport.clocks, departureClockSamples: closeReport.clockSamples,
      closeProofs: [...(physicalCloseReport.proofs ?? []), ...(closeReport.proofs ?? [])],
      warmup: warmupBarrier?.checkpoints, warmupCheckpointErrors: warmupBarrier?.errors,
      warmupGateReceived: warmupBarrier?.received, warmupFrontier: warmupBarrier?.frontier() };
  } catch (error) {
    failures.push(error);
    const correctionDeadlineReached = missedCorrectionDeadline(phase, error, correctionDeadline, performance.now());
    const expiryLinks = roomIdentities?.uuids.flatMap((uuid, index) => {
      const sender = postRelease?.[index].native_expiry?.uuid ?? warmupBarrier?.checkpoints[index]?.cutoff?.terminal_uuid;
      return sender ? [`${sender.replaceAll('-', '')}/${uuid.replaceAll('-', '')}`] : [];
    }) ?? [];
    const relayWireFailure = traceRelayWire ? collectRelayWire(expiryLinks) : null;
    const relayServerFailure = readRelayServer && roomIdentities ? Promise.allSettled([readRelayServer(undefined, DIAGNOSTIC_MS, expiryLinks)]) : null;
    const states = await Promise.allSettled(pages.map((page, index) => boundedRoom(() => page.evaluate(() => ({
      ...window.fortressNative, wire: window.fortressNativeWire?.status(), warmup: window.fortressNativeWire?.warmupStatus(),
      stalled: window.fortressNativeStalled,
    })), DIAGNOSTIC_MS, `native peer ${index} diagnostics`)));
    const diagnostics = states.map((state, index) => {
      if (state.status === 'rejected') return { status: state.status, reason: String(state.reason) };
      const { stalled: saved, ...current } = state.value;
      if (stalled && !stalled[index] && saved) stalled[index] = saved;
      return { status: state.status, value: current };
    });
    const relayWire = relayWireFailure && (await relayWireFailure).map(({ status, value, reason }) =>
      status === 'fulfilled' ? value ?? null : { error: String(reason) });
    let relayJoined;
    let relayJoinError;
    if (relayServerFailure) {
      try {
        const [serverReceipt] = await relayServerFailure;
        if (serverReceipt.status === 'rejected') throw serverReceipt.reason;
        relayJoined = joinRelayReceipts(serverReceipt.value, relayWire);
      } catch (joinError) {
        relayJoinError = String(joinError);
      }
    }
    console.error(JSON.stringify({
      phase, compared_frames: comparedFrames, browser_peers: browserPeers, bootstrap_ms, errors, closeErrors: [...physicalCloseErrors, ...departureErrors],
      departureClocks: closeReport.clocks, departureCommands, roomIdentities,
      closeProofs: [...(physicalCloseReport.proofs ?? []), ...(closeReport.proofs ?? [])],
      departureClockSamples: closeReport.clockSamples, departureClockErrors: closeReport.calibrationErrors,
      physicalClosePartialSnapshots: physicalCloseReport.partialSnapshots,
      closePartialSnapshots: closeReport.partialSnapshots, physicalCloseSnapshotErrors: physicalCloseReport.snapshotErrors,
      closeSnapshotErrors: closeReport.snapshotErrors, armed, holdReadyReceived: mixed ? undefined : holdReadyReceived, stalled,
      states: diagnostics, warmup: warmupBarrier?.checkpoints, warmupCheckpointErrors: warmupBarrier?.errors,
      warmupGateReceived: warmupBarrier?.received, warmupFrontier: warmupBarrier?.frontier(), postRelease, correctionDeadline, engineTurns,
      relayControl, relayRetention, sameLinkRetention, expiryLinks, relayWire: relayWire ?? undefined, relayJoined, relayJoinError,
      releaseEvidence: postRelease && relayReleaseEvidence(postRelease, roomIdentities?.uuids, correctionDeadlineReached),
    }));
  } finally {
    releaseSignal?.cancel();
    failures.push(...await closeAll(contexts, context => context.close(), 'context'));
    failures.push(...await closeAll(browsers, owner => owner.close(), 'browser'));
    for (const { socket, upstream } of proxyPairs) {
      socket.destroy();
      upstream.destroy();
    }
    failures.push(...await closeAll([server], owner => new Promise((resolve, reject) =>
      owner.close(error => error ? reject(error) : resolve())), 'host'));
  }
  await flush();
  if (errors.length) failures.push(new Error(JSON.stringify(errors)));
  if (failures.length) throw new AggregateError(failures, `native online witness failed in ${phase}`);
  return result;
}

if (require.main === module) {
  const [root, endpoint, route, size, profile = 'chromium', control] = process.argv.slice(2);
  const browserPair = profile.split('-');
  const validPair = browserPair.length <= 2 && new Set(browserPair).size === browserPair.length
    && browserPair.every(name => ['chromium', 'firefox', 'webkit'].includes(name));
  const overlap = route === 'mesh-recovery-overlap';
  const validOverlap = overlap && ['chromium', 'chromium-firefox'].includes(profile) && (!control || control === '--omit-second-replacement');
  const validFault = size === '4' && (validOverlap || (!control && ['mesh-startup', 'mesh-close', 'mesh-recovery'].includes(route)));
  const relayControl = !control || control === '--trace-relay-wire'
    || (size === '8' && ['--relay-retention-control', '--relay-same-link-control'].includes(control));
  const validPlain = ['2', '4', '8'].includes(size) && (route === 'relay' ? relayControl : route === 'mesh' && !control);
  if (!(validFault || validPlain) || !validPair) {
    console.error('usage: native_online.cjs EXPORT ENDPOINT MODE SIZE [BROWSER_PROFILE] [CONTROL]');
    process.exitCode = 1;
  } else run(root, endpoint, route, Number(size), browserPair, control).then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = { armAndWaitForInput, bindDepartureCheckpoints, calibrateDepartureClocks, captureAndReleaseInput, closeEvidence, compareHistory, createReleaseSignal,
  createWarmupBarrier, instrumentNativeWire, instrumentPostRelease, leaveWithReceipt, missedCorrectionDeadline,
  postReleaseCheckpoint, readConfirmedHistory, relayReleaseEvidence, reportedChannel, waitForCloseProofs, waitForCorrectedHistory, WARMUP_CHECKPOINT };
