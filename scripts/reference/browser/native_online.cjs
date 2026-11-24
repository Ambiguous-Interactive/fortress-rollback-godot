const { assertStableRoom, recoverPair } = require('./native_recovery.cjs');
const assert = require('node:assert/strict');
const { setImmediate: flush, setTimeout: pause } = require('node:timers/promises');
const { createHost } = require('./online_host.cjs');
const { placeFirefox } = require('./webrtc_display.cjs');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const INPUTS = [[1, ['KeyA']], [2, ['KeyD']], [4, ['KeyW']], [8, ['KeyS']],
  [5, ['KeyA', 'KeyW']], [6, ['KeyD', 'KeyW']], [9, ['KeyA', 'KeyS']], [10, ['KeyD', 'KeyS']]];
const GATE_FRAME = 12;
const HISTORY_FRAMES = 40;
const PAGE_BOOT_MS = 60000;
const DIAGNOSTIC_MS = 5000;
const CLOSE_MS = 10000;
const CLOSE_CLOCK_POST_SAMPLES = 4;
const WEBKIT_CLOSED_STREAM = 'Error sending binary data through RTCDataChannel.';
const WARMUP_CHECKPOINT = 'fortress native relay warmup ';

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

function instrumentNativeWire(tagWebKitSends, warmupPrefix) {
  const active = [];
  const resources = { rtc: [], sockets: [] };
  const ice = new Map();
  let session, localUuid;
  let observingDeparture = false;
  let holding = false;
  let releasingRelay = false;
  let releaseEnded = null;
  let holdFailure;
  let holdAll = false;
  let armed = false;
  let holdStarted = null;
  let holdEnded = null;
  let totalBytes = 0;
  let released = 0;
  const counts = { mesh: 0, relay: 0 };
  const relayRecipients = new Map();
  const relaySenders = new Map();
  const relayInputRecipients = new Map();
  const relayInputSenders = new Map();
  let blockRecovery = false;
  const recovery = { scope: null, held: null, released: 0, delivered: [], pending: [], observed: [],
    queuedKinds: { Offer: 0, IceCandidate: 0 }, receivedKinds: { Offer: 0, IceCandidate: 0 } };
  const qualityEvents = { send: [], receive: [] };
  const qualityEventCounts = { send: 0, receive: 0 };
  const qualityEventLimit = 256;
  let qualityEventCount = 0;
  let bufferedBytesPeak = 0;
  let relayBroadcasts = 0;
  const held = { mesh: 0, relay: 0 };
  const controlRoundTrips = { mesh: 0, relay: 0 };
  // The pinned protocol sends one report per peer at intervals above 200 ms.
  // Keep enough relay tokens for the 45-second stall witness despite FIFO delay.
  const pendingReportLimit = { mesh: 16, relay: 256 };
  const channelReports = new Map();
  const socketReports = new WeakMap();
  const warmupLinks = new Map();
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
      links: Array.from(warmupLinks, ([sender, { packets, evicted, unretained }]) => ({
        sender, evicted, unretained, packets: Array.from(packets, ([payload, stages]) => ({ payload, ...stages })),
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
        return;
      }
      link.packets.delete([...link.packets.keys()][8]);
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
        packet.native.acceptances++;
      }
    } else {
      packet[stage] ??= { first_ms: at, last_ms: at, count: 0 };
      packet[stage].last_ms = at;
      packet[stage].count++;
    }
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
    qualityEvents[direction][index] = { sequence: qualityEventCount++, direction, peer, kind, token, at_ms: performance.now() };
  }
  const increment = (counts, uuid) => counts.set(uuid, (counts.get(uuid) ?? 0) + 1);
  const ufrag = description => description?.sdp.match(/^a=ice-ufrag:([\w+/]+)\r?$/m)?.[1];
  function receive(route, reports, peer, packet) {
    if (packet.kind !== 5) return;
    const tokens = reports.get(peer);
    if (tokens?.get(packet.token)) {
      tokens.set(packet.token, false);
      controlRoundTrips[route]++;
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
      holdFailure ??= new Error('native packet hold exceeded bounds');
      throw holdFailure;
    }
    const owned = nativeBytes(data).slice();
    active.push(() => emit(owned));
    totalBytes += owned.byteLength;
    held[route]++;
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
    const tagged = name => new Function('send', 'channel', `return function ${name}(bytes) { send.call(channel, bytes); }`)(nativeSend, channel);
    const emit = tagWebKitSends ? tagged(`fortressNativeSend_${index}`) : bytes => nativeSend.call(channel, bytes);
    channel.send = data => {
      const view = nativeBytes(data);
      const packet = channel.id === 3 && view && matches(view, 0) ? nativePacket(view) : null;
      return send('mesh', channelReports, channel, bytes => {
        if (tagWebKitSends && observingDeparture) tagged(`fortressNativeSend_${index}_${instant()}`)(bytes);
        else emit(bytes);
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
    resources.sockets.push(socket);
    socket.addEventListener('message', ({ data }) => {
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
  nativeSocket.prototype.send = function(data) {
    const outgoing = readRecovery(data, 'send');
    if (blockRecovery && outgoing) return;
    if (outgoing?.kind === 'Offer') {
      if (recovery.observed.length === 8) throw new Error('recovery sent too many scoped offers');
      recovery.observed.push({ attempt: outgoing.attempt, at_ms: performance.now() });
      if (!recovery.held && outgoing.attempt === 1) recovery.held = { ...outgoing, at_ms: performance.now() };
    }
    if (recovery.scope?.holdsOffer && isFirstRecoveryOfferTraffic(outgoing) && !recovery.released) {
      if (recovery.pending.length === 32) throw new Error('scoped SDP and ICE queue exceeded its bound');
      recovery.queuedKinds[outgoing.kind]++;
      recovery.pending.push(() => {
        if (this.readyState !== nativeSocket.OPEN) throw new Error('recovery signaling socket closed before release');
        socketSend.call(this, data);
      });
      return;
    }
    const packet = relayAddresses(data);
    return send('relay', socketReports.get(this), packet?.recipient, bytes => {
      if (releasingRelay && packet && this.readyState !== nativeSocket.OPEN) throw new Error('native relay socket closed before release send');
      socketSend.call(this, bytes);
      if (releasingRelay && packet && this.readyState !== nativeSocket.OPEN) throw new Error('native relay socket closed during release send');
      if (packet && packet.sender === localUuid) {
        increment(relayRecipients, packet.recipient);
        if (packet.kind === inputKind) increment(relayInputRecipients, packet.recipient);
        bufferedBytesPeak = Math.max(bufferedBytesPeak, this.bufferedAmount);
        traceRelayQuality('send', packet.recipient, packet);
      }
    }, data, packet?.sender === localUuid ? packet : null);
  };
  window.fortressNativeWire = {
    bind(hash, uuid, warmupRoster = []) {
      if (session || !/^[0-9a-f]{32}$/.test(hash)) throw new Error('invalid native room session');
      localUuid = uuid.replaceAll('-', '');
      session = hash.match(/../g).map(value => parseInt(value, 16));
      if (warmupPrefix) for (const member of warmupRoster.slice(0, 8)) {
        const sender = member.replaceAll('-', '');
        if (sender !== localUuid) warmupLinks.set(sender, { packets: new Map(), evicted: 0, unretained: { sdk: 0, native: 0 } });
      }
      if (warmupLinks.size) warmupStarted = performance.now();
    },
    recordWarmup,
    warmupStatus,
    recordWarmupTick(before, after, budget, elapsed_us, failed) {
      if (!warmupLinks.size || warmupCutoff) return;
      const at = performance.now();
      if (warmupTicks.length === 24) warmupTicks.shift();
      warmupTicks.push({ at_ms: at, before, after, budget, elapsed_us, failed });
      warmupTickCount++;
      scheduleWarmupCheckpoint(at);
    },
    finishWarmup(reason) {
      if (warmupLinks.size && !warmupCutoff) {
        warmupCutoff = { at_ms: performance.now(), reason };
        checkpointWarmup(warmupCutoff.at_ms);
      }
    },
    blockRecovery() { blockRecovery = true; },
    observeRecovery(scope) {
      if (recovery.scope) throw new Error('recovery scope already set');
      recovery.scope = scope;
    },
    releaseRecovery() {
      if (!recovery.held || !recovery.pending.length || recovery.released) throw new Error('recovery SDP was not held');
      recovery.released = performance.now();
      const pending = recovery.pending.splice(0);
      for (const emit of pending) emit();
      return pending.length;
    },
    meshOpen(peers) {
      return resources.rtc.filter(({channel, connection}) => channel.readyState === 'open' && connection.connectionState === 'connected').length === peers * 3;
    },
    observeDeparture() { observingDeparture = true; return window.crossOriginIsolated ? instant() : null; },
    arm(all = false) {
      if (!armed) {
        armed = true;
        holdAll = all;
        holding = true;
        holdStarted = performance.now();
      }
    },
    async release() {
      if (!holding || !active.length) throw new Error('native packet hold did not take effect');
      holding = false;
      releasingRelay = held.relay > 0;
      holdEnded = performance.now();
      // Each relay send fans out to the room. Keep originals ahead of newly sampled inputs.
      const batchSize = releasingRelay ? 16 : active.length;
      while (active.length > 0 && !holdFailure) {
        for (const emit of active.splice(0, batchSize)) {
          emit();
          released++;
        }
        if (active.length > 0) await new Promise(resolve => requestAnimationFrame(resolve));
      }
      if (holdFailure) throw holdFailure;
      releasingRelay = false;
      releaseEnded = performance.now();
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
    hasHeldInputAndControl(route) {
      return held[route] > 0 && controlRoundTrips[route] > 0;
    },
    status() {
      const holdMs = holdStarted === null ? null : Math.round((holdEnded ?? performance.now()) - holdStarted);
      const sctp = resources.rtc.filter(({channel}) => channel.id === 3).map(record => {
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
      const events = [...qualityEvents.send, ...qualityEvents.receive].sort((a, b) => a.sequence - b.sequence)
        .map(({ direction, peer, kind, token, at_ms }) => ({ direction, peer, kind, token, at_ms }));
      const releaseMs = holdEnded === null ? null : Math.round((releaseEnded ?? performance.now()) - holdEnded);
      return { armed, holding, hold_ms: holdMs, release_ms: releaseMs, deferredClose: Boolean(deferredClose), counts: { ...counts }, held: { ...held }, released, totalBytes,
        control_round_trips: { ...controlRoundTrips },
        relayRecipients: Object.fromEntries(relayRecipients), relaySenders: Object.fromEntries(relaySenders),
        relayInputRecipients: Object.fromEntries(relayInputRecipients), relayInputSenders: Object.fromEntries(relayInputSenders),
        recovery: { held: recovery.held, released: recovery.released, pending: recovery.pending.length,
          queuedKinds: { ...recovery.queuedKinds }, receivedKinds: { ...recovery.receivedKinds },
          delivered: [...recovery.delivered], observed: [...recovery.observed] },
        relay_trace: { buffered_bytes_peak: bufferedBytesPeak, broadcasts: relayBroadcasts, events,
          event_count: qualityEventCount, direction_counts: { ...qualityEventCounts } },
        ice: [...ice.values()], sctp,
        rtc: resources.rtc.map(({channel, sent, received}) => [channel.id, channel.readyState, sent, received]),
        sockets: resources.sockets.map(socket => socket.readyState) };
    },
  };
}

function reportedChannel(stack) {
  const frames = [...(stack ?? '').matchAll(/^\s*at (?:Object\.)?fortressNativeSend_(\d+)(?:_(\d+))? \(/gm)];
  if (frames.length !== 1) return { channel: null, sentAt: null };
  const [, channel, sentAt] = frames[0];
  return { channel: Number(channel), sentAt: sentAt === undefined ? null : Number(sentAt) };
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

function closeEvidence({ index, channel, sentAt }, linksBefore, closedByPage, closer = null, clocks) {
  const before = linksBefore.find(peer => peer.index === channel) ?? null;
  const evidence = { index, channel, sentAt, closer, before, sender: null, counterparts: [], minimumGapUs: null, proof: null };
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
  }
  if (closer !== null) {
    if (counterpart.owner === closer && counterpart.closed && evidence.sender?.closed) evidence.proof = 'stream-close';
  } else if (counterpart.connectionClosed && evidence.sender) {
    if (evidence.sender.closeAborts > before.closeAborts) evidence.proof = 'sctp-abort';
    else if (evidence.minimumGapUs >= 2000) evidence.proof = 'clock-order';
  }
  return evidence;
}

async function waitForCloseProofs(pages, before, errors, report, { closer = null, clocks, clock = () => performance.now(), delay = pause } = {}) {
  if (!errors.length) return undefined;
  report.proofs = [];
  report.clocks = clocks;
  let rounds = 0;
  const deadline = clock() + DIAGNOSTIC_MS;
  while (clock() < deadline) {
    const sampleClock = Boolean(report.clocks) && rounds++ < CLOSE_CLOCK_POST_SAMPLES;
    const snapshots = await Promise.allSettled(pages.map((page, index) =>
      boundedRoom(async () => {
        const start = Math.floor(clock() * 1000);
        const { links, sampledAt } = await page.evaluate(timed => ({
          sampledAt: timed && window.crossOriginIsolated ? Math.round(performance.now() * 1000) : null,
          links: window.fortressNativeWire.status().sctp,
        }), sampleClock);
        const end = Math.ceil(clock() * 1000);
        return { links, bound: sampleClock ? clockWindow(start, end, sampledAt) : null };
      }, Math.max(0, Math.ceil(deadline - clock())), `native peer ${index} close snapshot`)));
    const failed = snapshots.flatMap((entry, index) => entry.status === 'rejected' ? [{ index, reason: entry.reason }] : []);
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
    report.proofs = errors.map(error => closeEvidence(error, before[error.index].wire.sctp, links, closer, report.clocks));
    for (const proof of report.proofs) assert.ok(proof.before, `WebKit send failure for peer ${proof.index} lacked a sending channel`);
    const remaining = deadline - clock();
    if (remaining <= 0) break;
    if (report.proofs.every(proof => proof.proof)) return links;
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

async function readConfirmedHistory(page, frames, wait) {
  await page.evaluate(frameCount => {
    window.fortressNativeHistory = null;
    window.fortressNativeCapture = frameCount;
  }, frames);
  await wait(page, frameCount => window.fortressNativeHistory?.frames === frameCount, frames);
  return page.evaluate(frameCount => {
    const history = window.fortressNativeHistory;
    if (history?.frames !== frameCount) throw new Error('native history receipt changed');
    return history;
  }, frames);
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
      assert.match(peer.snapshots[frame + 1], /^(?:[0-9a-f]{2})+$/);
      assert.equal(peer.snapshots[frame + 1], peers[0].snapshots[frame + 1], `canonical state at frame ${frame + 1}, slot ${peer.slot}`);
    }
  }
}

async function closeAll(items, close, kind) {
  const settled = await Promise.allSettled(items.map((item, index) =>
    boundedRoom(() => close(item), CLOSE_MS, `native ${kind} ${index} close`)));
  return settled.filter(result => result.status === 'rejected').map(result => result.reason);
}

async function run(root, endpoint, mode, players, browserPair) {
  const startup = mode === 'mesh-startup';
  const liveClose = mode === 'mesh-close';
  const recovery = mode === 'mesh-recovery';
  const mixed = startup || liveClose || recovery;
  const route = mixed ? 'mesh' : mode;
  const traceWarmup = route === 'relay' && players === 8;
  const warmup = traceWarmup ? Array(players).fill(null) : undefined;
  const warmupCheckpointErrors = traceWarmup ? Array(players).fill(null) : undefined;
  const playwright = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const { server, proxyPairs } = await createHost(root, endpoint, process.env.FORTRESS_TLS_CERT, process.env.FORTRESS_TLS_KEY);
  const origin = `https://127.0.0.1:${server.address().port}`;
  const socketEndpoint = `wss://127.0.0.1:${server.address().port}/v3/ws`;
  const pages = [];
  const bootstrap_ms = [];
  const contexts = [];
  const errors = [];
  const physicalCloseErrors = [];
  const departureErrors = [];
  const failures = [];
  const browsers = [];
  const browserPeers = [];
  let result;
  let phase = 'launch';
  let sequence = 0;
  let departureClocks;
  let stalled;
  const physicalCloseReport = {};
  const closeReport = {};
  const wait = async (page, condition, argument = null, timeout = 30000) => {
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
  };
  const observe = (group = pages) => Promise.all(group.map((page, index) => page.evaluate(index => ({
    index, ...window.fortressNative, wire: window.fortressNativeWire.status()
  }), index)));
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
        const physicalClose = (liveClose || recovery) && phase === 'physical channel close' && index === 1;
        const departure = route === 'mesh' && phase === 'departure' && index < players - 1;
        const webkitSend = name === 'webkit' && error.name === '' && error.message === WEBKIT_CLOSED_STREAM;
        const errorList = !webkitSend ? errors : physicalClose ? physicalCloseErrors : departure ? departureErrors : errors;
        errorList.push({ index, phase, text: String(error), ...(webkitSend ? reportedChannel(error.stack) : {}) });
      });
      page.on('crash', () => errors.push({ index, phase, text: 'Renderer crashed' }));
      page.on('console', message => {
        const text = message.text();
        if (traceWarmup && text.startsWith(WARMUP_CHECKPOINT)) {
          try {
            warmup[index] = JSON.parse(text.slice(WARMUP_CHECKPOINT.length));
          } catch (error) {
            warmupCheckpointErrors[index] = String(error);
          }
        }
        if (text.includes('SCRIPT ERROR:') || text.startsWith('ERROR:')) errors.push({ index, phase, text });
      });
      page.on('requestfailed', request => {
        const url = new URL(request.url());
        errors.push({ index, phase, host: url.host, path: url.pathname, method: request.method(), resource: request.resourceType(),
          code: request.failure()?.errorText });
      });
      // Register the socket and warmup hooks in a single init script.
      await page.addInitScript(`(${instrumentNativeWire})(${name === 'webkit'}, ${JSON.stringify(traceWarmup ? WARMUP_CHECKPOINT : '')})`);
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
    await Promise.all(pages.map(page => command(page, 'ready')));
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
    await command(pages[0], 'start');
    await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
      && window.fortressNative.confirmed >= frame, GATE_FRAME, 45000)));
    let armed, direct, atClose, afterClose, restored, recoveryEvidence, closeLinks;
    let comparedFrames = HISTORY_FRAMES;
    if (liveClose || recovery) {
      direct = await observe();
      for (const peer of direct) {
        assert.deepEqual(peer.relay_peers, [], 'the room must begin on direct links');
        assert.ok(peer.wire.counts.mesh > 0 && peer.wire.counts.relay === 0);
        assert.equal(peer.wire.rtc.filter(([id, state]) => id === 3 && state === 'open').length, players - 1);
      }
    }
    if (recovery) {
      ({ atClose, afterClose, restored, recoveryEvidence } = await recoverPair(direct, {
        pages, wait, observe, command, pause, setPhase: value => { phase = value; },
      }));
      comparedFrames = historyThrough(restored);
      closeLinks = await waitForCloseProofs(pages, direct, physicalCloseErrors, physicalCloseReport, { closer: 0 });
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
      phase = 'prediction stall';
      // Arming on each local frame can strand a slower peer before its own
      // gate. Let every endpoint confirm the warmup while routes are open.
      armed = await Promise.all(pages.map(page => page.evaluate(() => {
        const { frame, stalls, confirmed } = window.fortressNative;
        window.fortressNativeWire.arm();
        return { frame, stalls, confirmed };
      })));
      await Promise.all(pages.map((page, index) => wait(page, threshold => {
        const { state, stalls, prediction } = window.fortressNative;
        if (state === 'failed') return true;
        if (state !== 'playing' || stalls <= threshold.stalls || prediction < threshold.frame) return false;
        return window.fortressNativeWire.hasHeldInputAndControl(threshold.route);
      },
      { route, stalls: armed[index].stalls, frame: GATE_FRAME }, 45000)));
      stalled = await observe();
      for (const peer of stalled) {
        assert.equal(peer.state, 'playing', peer.message);
      }
      comparedFrames = historyThrough(stalled);
      phase = 'input release';
      const correctionBudgetMs = 45000;
      const correctionDeadline = performance.now() + correctionBudgetMs;
      await Promise.all(pages.map((page, index) => boundedRoom(() => page.evaluate(() => window.fortressNativeWire.release()),
        correctionBudgetMs, `native peer ${index} input release`)));
      phase = 'corrected history';
      const correctionRemainingMs = Math.floor(correctionDeadline - performance.now());
      assert.ok(correctionRemainingMs > 0, 'native input release exhausted the correction deadline');
      await Promise.all(pages.map((page, index) => wait(page, target => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= target.frame && window.fortressNative.restores > target.restores,
      { frame: comparedFrames, restores: stalled[index].restores }, correctionRemainingMs)));
      assert.ok(performance.now() < correctionDeadline, 'native corrected history exceeded the correction deadline');
    } else {
      phase = 'mixed confirmed history';
      await Promise.all(pages.map(page => wait(page, frame => window.fortressNative.state === 'playing'
        && window.fortressNative.confirmed >= frame, comparedFrames)));
    }
    // A waiting step can publish confirmation before dispatching a correction.
    const confirmedHistory = await observe();
    await Promise.all(pages.map((page, index) => wait(page, frame => window.fortressNative.state === 'playing'
      && window.fortressNative.frame > frame, confirmedHistory[index].frame)));
    phase = 'confirmed history capture';
    const history = await Promise.all(pages.map(page => readConfirmedHistory(page, comparedFrames, wait)));
    const peers = (await observe()).map((peer, index) => ({ ...peer, rows: history[index].rows, snapshots: history[index].snapshots }));
    compareHistory(peers, comparedFrames);
    if (recovery) assertStableRoom(direct, peers);
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
      if (route === 'mesh') {
        assert.ok(peer.started_on_full_mesh, 'the direct-only room must start with every physical channel connected');
        assert.ok(peer.open_mesh_wait_ticks <= 2, 'a complete direct mesh must start when the engine sees its channels');
      }
      assert.ok(peer.saves > 0 && peer.advances > peer.frame && peer.restores > before.restores, 'save, load and re-advance must run');
      assert.ok(before.frame > GATE_FRAME && before.confirmed < before.frame - 1, 'gate must force prediction beyond confirmation');
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
      await Promise.all(pages.map(page => wait(page, () => window.fortressNative.interrupted.length > 0 && window.fortressNative.state === 'playing')));
      interruption = await observe();
      for (const peer of interruption) {
        assert.deepEqual(peer.sdk_roster.sort(), roster);
        assert.deepEqual(peer.wire.sockets, [1], 'SDK signaling must remain connected during the outage');
        assert.ok(peer.wire.holding && peer.wire.held.mesh > 0, 'direct gameplay must be held');
        assert.equal(peer.wire.held.relay > 0, peer.index < 2, 'relay gameplay for the closed pair must also be held');
      }
    } else {
      if (route === 'mesh' && browserPair.includes('webkit')) {
        departureClocks = await Promise.all(pages.map(async page => {
          let bound;
          // Every round trip brackets the same page offset on the controller's clock.
          for (let attempt = 0; attempt < 3; attempt++) {
            const start = Math.floor(performance.now() * 1000);
            const sample = await page.evaluate(() => window.fortressNativeWire.observeDeparture());
            const end = Math.ceil(performance.now() * 1000);
            const measured = clockWindow(start, end, sample);
            bound = attempt === 0 ? measured : intersectClock(bound, measured);
          }
          return bound;
        }));
      }
      phase = 'departure';
      const departing = pages.at(-1);
      await command(departing, 'leave');
      await wait(departing, () => window.fortressNative.state === 'offline');
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
        assert.deepEqual(peer.sdk_roster.sort(), roster, 'the original SDK roster must survive until native expiry');
        assert.deepEqual(peer.wire.sockets, [1], 'SDK room must survive the outage until native expiry');
        assert.ok(peer.wire.deferredClose, 'the app must initiate native terminal cleanup');
        assert.deepEqual([peer.saves, peer.restores, peer.advances], peer.failure_tick_callbacks, 'no callback may run on or after native expiry');
      }
      for (const key of ['frame', 'confirmed', 'reason', 'terminal_detail', 'message', 'game_frame', 'saves', 'restores', 'advances'])
        assert.equal(peer[key], before[key], `terminal ${key} changed for survivor ${index}`);
    }
    phase = 'teardown';
    if (!liveClose) closeLinks = await waitForCloseProofs(pages, peers, departureErrors, closeReport, { clocks: departureClocks }) ?? closeLinks;
    if (liveClose) await Promise.all(pages.map(page => page.evaluate(() => window.fortressNativeWire.releaseTerminal())));
    await Promise.all(survivors.map(page => command(page, 'leave')));
    await Promise.all(pages.map(page => wait(page, () => {
      const { sockets, rtc } = window.fortressNativeWire.status();
      return window.fortressNative.state === 'offline' && sockets.every(state => state === WebSocket.CLOSED)
        && rtc.every(([, state]) => state === 'closed');
    })));
    result = { passed: true, route: mode, players, compared_frames: comparedFrames, browser_peers: browserPeers, bootstrap_ms, armed, stalled,
      direct, atClose, afterClose, restored, recoveryEvidence, peers, interruption, terminal, after, closeErrors: [...physicalCloseErrors, ...departureErrors], closeLinks,
      departureClocks: closeReport.clocks ?? departureClocks, closeProofs: [...(physicalCloseReport.proofs ?? []), ...(closeReport.proofs ?? [])], warmup, warmupCheckpointErrors };
  } catch (error) {
    failures.push(error);
    const states = await Promise.allSettled(pages.map((page, index) => boundedRoom(() => page.evaluate(() => ({
      ...window.fortressNative, wire: window.fortressNativeWire?.status(), warmup: window.fortressNativeWire?.warmupStatus()
    })), DIAGNOSTIC_MS, `native peer ${index} diagnostics`)));
    const diagnostics = states.map(state => state.status === 'fulfilled' ? state : { status: state.status, reason: String(state.reason) });
    console.error(JSON.stringify({
      phase, browser_peers: browserPeers, bootstrap_ms, errors, closeErrors: [...physicalCloseErrors, ...departureErrors],
      departureClocks: closeReport.clocks ?? departureClocks,
      closeProofs: [...(physicalCloseReport.proofs ?? []), ...(closeReport.proofs ?? [])],
      physicalCloseSnapshotErrors: physicalCloseReport.snapshotErrors,
      closeSnapshotErrors: closeReport.snapshotErrors, stalled, states: diagnostics, warmup, warmupCheckpointErrors
    }));
  } finally {
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
  const [root, endpoint, route, size, profile = 'chromium'] = process.argv.slice(2);
  const browserPair = profile.split('-');
  const validPair = browserPair.length <= 2 && new Set(browserPair).size === browserPair.length
    && browserPair.every(name => ['chromium', 'firefox', 'webkit'].includes(name));
  const validRoom = (['mesh-startup', 'mesh-close', 'mesh-recovery'].includes(route) && size === '4') || (['mesh', 'relay'].includes(route) && ['2', '4', '8'].includes(size));
  if (!validRoom || !validPair) {
    console.error('usage: native_online.cjs EXPORT ENDPOINT mesh|relay 2|4|8, or mesh-startup|mesh-close|mesh-recovery 4, with optional browser pair');
    process.exitCode = 1;
  } else run(root, endpoint, route, Number(size), browserPair).then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = { closeEvidence, compareHistory, instrumentNativeWire, readConfirmedHistory, reportedChannel, waitForCloseProofs };
