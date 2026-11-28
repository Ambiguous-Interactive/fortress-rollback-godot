// Real independent exported Godot instances, with faults at the browser data-channel boundary.
const { inspect } = require('node:util');
const fs = require('node:fs');
const https = require('node:https');
const net = require('node:net');
const path = require('node:path');
const { waitGameplay, waitDefaultSetup, boundedRoom } = require('./webrtc_watchdog.cjs');
const { placeFirefox } = require('./webrtc_display.cjs');
const FIREFOX_PREFS = { 'webgl.force-enabled': true, 'webgl.disabled': false, 'toolkit.shutdown.fastShutdownStage': 0 };

async function closeDepartingRtc(pages, now = () => performance.now(), relayOnly = false) {
  if (pages.length !== 3) throw new Error('physical departure requires three pages');
  const ready = await boundedRoom(() => Promise.all(pages.map(async page => {
    const pageMs = await page.evaluate(async () => {
      while (document.body.dataset.fortressDropReady !== 'true') await new Promise(resolve => requestAnimationFrame(resolve));
      return performance.now();
    });
    if (!Number.isFinite(pageMs) || pageMs < 0) throw new Error('invalid physical departure readiness clock');
    return { pageMs, receivedAt: now() };
  })), 30000, 'physical departure readiness');
  const deadline = now() + 3000;
  // Use the reply arrival as an upper bound and allow 2 ms of coarsening at each page clock read.
  const pageDeadlines = ready.map(({ pageMs, receivedAt }) => Math.floor(pageMs + deadline - receivedAt) - 4);
  let active = true;
  const checkDeadline = () => {
    if (!active || now() >= deadline) throw new Error('physical departure phase deadline');
  };
  const evaluateBeforeDeadline = async (index, operation, argument) => {
    checkDeadline();
    return pages[index].evaluate(operation, { cutoff: pageDeadlines[index], ...argument });
  };
  try {
    await boundedRoom(async () => {
      const held = await Promise.all(pages.map((_, index) => evaluateBeforeDeadline(index, async ({ cutoff }) => {
        if (performance.now() >= cutoff) throw new Error('physical departure arm deadline');
        window.fortressDropArm = true;
        while (document.body.dataset.fortressDropPaused !== 'true' && performance.now() < cutoff)
          await new Promise(resolve => requestAnimationFrame(resolve));
        if (performance.now() >= cutoff) throw new Error('physical departure pause deadline');
        return { frame: Number(document.body.dataset.fortressFrame), released: window.fortressDropGo === true };
      })));
      checkDeadline();
      if (held.some(value => value?.frame !== 6 || value.released !== false))
        throw new Error('peer-drop endpoint advanced before physical departure');
      const frames = held.slice(0, 2).map(value => value.frame);
      const closes = index => relayOnly || index === 2;
      const closed = await Promise.all(pages.map((_, index) => closes(index) ? evaluateBeforeDeadline(index, async ({ cutoff, frames }) => {
        if (performance.now() >= cutoff) throw new Error('physical departure close deadline');
        const { connections, channels } = window.fortressResources;
        const departure = { frame: Number(document.body.dataset.fortressFrame), survivor_frames: frames,
          connections_created: connections.length, channels_created: channels.length };
        for (const connection of connections) {
          if (performance.now() >= cutoff) throw new Error('physical departure close deadline');
          connection.close();
        }
        do {
          if (performance.now() >= cutoff) throw new Error('physical departure close deadline');
          departure.connections_closed = connections.filter(connection => connection.connectionState === 'closed').length;
          departure.channels_closed = channels.filter(channel => channel.readyState === 'closed').length;
          if (departure.connections_closed === connections.length && departure.channels_closed === channels.length) return departure;
          await new Promise(resolve => requestAnimationFrame(resolve));
        } while (true);
      }, { frames }) : null));
      checkDeadline();
      if (closed.some((value, index) => closes(index) && (value?.frame !== 6 || value.channels_created !== 6 || value.channels_closed !== 6
          || !Number.isInteger(value.connections_created) || value.connections_created < 2 || value.connections_closed !== value.connections_created)))
        throw new Error('peer-drop physical departure incomplete');
      await Promise.all(pages.map((_, index) => evaluateBeforeDeadline(index, ({ cutoff, departure }) => {
        if (performance.now() >= cutoff) throw new Error('physical departure release deadline');
        if (departure) window.fortressRtc.departure = departure;
        window.fortressDropGo = true;
      }, { departure: closed[index] })));
      checkDeadline();
    }, Math.ceil(deadline - now()), 'physical departure');
  } finally { active = false; }
}

async function resolveDonorHistory(pages, contexts, closeDonor) {
  const uuids = await Promise.all(pages.map(page => page.evaluate(() => document.body.dataset.fortressUuid)));
  if (uuids.length !== 3 || uuids.some(uuid => !uuid) || new Set(uuids).size !== 3)
    throw new Error('donor history room identities missing');
  const recipient = uuids[0] < uuids[1] ? 0 : 1;
  const donor = 1 - recipient;
  const heldHandle = await pages[recipient].waitForFunction(
    () => document.body.dataset.fortressDonorHistoryHeld, null, { timeout: 30000 });
  const held = JSON.parse(await heldHandle.jsonValue());
  await heldHandle.dispose();
  if (held.recipient !== uuids[recipient] || held.donor !== uuids[donor] || held.target !== uuids[2])
    throw new Error('selected history donor differs from its live browser identity');
  const observed = await pages[donor].evaluate(() => ({
    uuid: document.body.dataset.fortressUuid,
    ready: document.body.dataset.fortressDropReady === 'true',
    frame: Number(document.body.dataset.fortressFrame),
    room: document.body.dataset.fortressRoom,
    open_sockets: window.fortressSockets.filter(record => record.socket.readyState === WebSocket.OPEN).length,
    first_history: document.body.dataset.fortressDonorFirstHistory,
    rtc_sent: window.fortressRtc.sent,
    rtc_received: window.fortressRtc.received,
    outcome: document.body.dataset.fortressWebrtc ?? null,
  }));
  if (observed.uuid !== held.donor || !observed.ready || observed.frame !== 7 || !observed.room
    || observed.first_history !== held.packet || observed.open_sockets !== 1 || observed.rtc_sent < 1 || observed.rtc_received < 1 || observed.outcome !== null)
    throw new Error('selected donor stopped before the controller action: ' + JSON.stringify(observed));
  if (closeDonor) {
    await Promise.all([pages[recipient], pages[2]].map(page => page.evaluate(uuid => {
      window.fortressDonorActionReady = uuid;
    }, held.donor)));
    await contexts[donor].close();
    if (!pages[donor].isClosed()) throw new Error('selected donor browser context stayed open');
  } else {
    await pages[recipient].evaluate(() => { window.fortressReleaseDonorHistory = true; });
  }
  return { held, observed, action: closeDonor ? 'context_closed' : 'history_released', donor_index: donor, page_uuids: uuids };
}

async function releaseRecordingTail(pages) {
  await Promise.all(pages.map(page => page.waitForFunction(
    () => document.body.dataset.fortressRecordingTailReady === 'true', null, { timeout: 120000 })));
  await Promise.all(pages.map(page => page.evaluate(() => { window.fortressRecordingTailStep = true; })));
  await Promise.all(pages.map(page => page.waitForFunction(
    () => document.body.dataset.fortressRecordingTail === '257', null, { timeout: 10000 })));
  await Promise.all(pages.map(page => page.evaluate(() => { window.fortressRecordingTailReleased = true; })));
}

function instrument({ endpoint, count, index, faults, corrupt, defaultFactory, mixed, mixedDefault,
  disableFallback, physicalClose = false, peerDrop = false, dropCorrupt = false, dropClose = false,
  dropAnswer = false, dropRelay = false, dropMissing = false, dropHistoryLost = false, dropDonorProcess = false, dropCommit = false,
  dropSecond = false, dropRollback = false, dropForeign = false,
  dropRoom = false, dropRoomContinue = false, dropProcess = false, dropProcessMissing = false,
  dropRoomAfterDrop = false, dropRoomBeforeDrop = false, dropOverlap = false, recordingPressure = false, secondBoundary = '' }) {
  window.fortressRecordingPressure = recordingPressure;
  window.fortressEndpoint = endpoint;
  window.fortressPlayers = count;
  window.fortressLocal = index;
  window.fortressFaultActive = false;
  window.fortressCorrupt = corrupt;
  window.fortressDefaultFactory = defaultFactory;
  window.fortressMixed = mixed;
  window.fortressMixedDefault = mixedDefault;
  window.fortressDisableFallback = disableFallback;
  window.fortressPhysicalClose = physicalClose;
  window.fortressPeerDrop = peerDrop;
  window.fortressDropMissing = dropMissing;
  window.fortressDropHistoryLost = dropHistoryLost;
  window.fortressDropDonorProcess = dropDonorProcess;
  window.fortressDropCommit = dropCommit;
  window.fortressDropSecond = dropSecond;
  window.fortressSecondBoundary = secondBoundary;
  window.fortressDropOverlap = dropOverlap;
  window.fortressDropRollback = dropRollback;
  window.fortressDropForeign = dropForeign;
  window.fortressDropRoom = dropRoom || dropRoomContinue || dropProcess || dropProcessMissing
    || dropRoomAfterDrop || dropRoomBeforeDrop;
  window.fortressDropRoomContinue = dropRoomContinue;
  window.fortressDropRoomAfterDrop = dropRoomAfterDrop;
  window.fortressDropRoomBeforeDrop = dropRoomBeforeDrop;
  window.fortressDropProcess = dropProcess;
  window.fortressDropProcessMissing = dropProcessMissing;
  window.fortressDropCorrupt = dropCorrupt;
  window.fortressDropClose = dropClose || dropRelay;
  window.fortressDropRelay = dropRelay;
  window.fortressRtc = { channels: [], sent: 0, received: 0, dropped: 0, reordered: 0, pending: 0, active: 0 };
  const evidence = window.fortressRtc;
  evidence.answerLoss = { dropped: 0, retries: 0, packet: null };
  evidence.binarySent = 0;
  evidence.relayBlockedReads = 0;
  evidence.relayPostWrapBlockedReads = 0;
  evidence.recordingRelaySends = [];
  evidence.recordingFinalRelaySend = null;
  evidence.maximumRelayBuffered = 0;
  evidence.captureError = false;
  window.fortressScheduling = { frames: 0, first: performance.now(), last: null };
  if (typeof requestAnimationFrame === 'function') {
    const frame = now => { window.fortressScheduling.frames++; window.fortressScheduling.last = now; requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
  }
  window.fortressSockets = [];
  const nativeSocket = WebSocket;
  const nativeBuffered = recordingPressure ? Object.getOwnPropertyDescriptor(nativeSocket.prototype, 'bufferedAmount').get : null;
  const relaySends = new Set();
  window.fortressArmRecordingHead = envelope => {
    if (relaySends.has(envelope) || evidence.captureError) return false;
    window.fortressRecordingRefusedHead = envelope;
    return true;
  };
  window.WebSocket = new Proxy(nativeSocket, { construct(target, args, newTarget) {
    const socket = Reflect.construct(target, args, newTarget);
    const record = { socket, received: 0, opened: false, failed: false, close_code: null };
    window.fortressSockets.push(record);
    if (recordingPressure) {
      Object.defineProperty(socket, 'bufferedAmount', { get() {
        const frame = Number(document.body?.dataset.fortressFrame ?? -1);
        if (frame >= 4 && frame < 253 && window.fortressRelayRefused === true) {
          evidence.relayBlockedReads++;
          if (frame > 128) evidence.relayPostWrapBlockedReads++;
          return 262144;
        }
        return nativeBuffered.call(socket);
      } });
    }
    socket.addEventListener('message', () => { record.received++; });
    socket.addEventListener('open', () => { record.opened = true; });
    socket.addEventListener('error', () => { record.failed = true; });
    socket.addEventListener('close', event => { record.close_code = event.code; });
    return socket;
  } });
  const carriesRecordingTail = view => {
    const envelopeHeader = 57;
    if (view.length < 133 || view[0] !== 70 || view[1] !== 83 || view[2] !== 82 || view[3] !== 49 || view[envelopeHeader + 6] !== 3) return false;
    const packet = new DataView(view.buffer, view.byteOffset + envelopeHeader, view.byteLength - envelopeHeader);
    return packet.getInt32(44, true) + packet.getUint16(52, true) === 257;
  };
  const websocketSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function(bytes) {
    if (typeof bytes !== 'string') evidence.binarySent++;
    const track = recordingPressure && this.readyState === nativeSocket.OPEN && typeof bytes !== 'string';
    const trackRetry = track && evidence.recordingRelaySends.length < 2;
    const trackTail = track && evidence.recordingFinalRelaySend === null && Number(document.body?.dataset.fortressFrame) >= 255;
    const result = websocketSend.call(this, bytes);
    if (trackRetry || trackTail) {
      const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
        : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
      if (!view) evidence.captureError = true;
      else if (view.length <= 1081) {
        const finalInput = trackTail && carriesRecordingTail(view);
        if (trackRetry || finalInput) {
          const wire = Array.from(view, byte => byte.toString(16).padStart(2, '0')).join('');
          if (finalInput) evidence.recordingFinalRelaySend = { wire, turn: window.fortressRecordingTurn, released: window.fortressRecordingTailReleased === true };
          if (trackRetry && !relaySends.has(wire)) {
            if (relaySends.size >= 1024) evidence.captureError = true;
            else relaySends.add(wire);
            if (wire === window.fortressRecordingRefusedHead && !evidence.captureError) {
              evidence.recordingRelaySends.push({ turn: window.fortressRecordingTurn, wire, first: true });
              window.fortressRecordingRefusedHead = '';
            }
          }
        }
      }
    }
    const buffered = nativeBuffered ? nativeBuffered.call(this) : this.bufferedAmount;
    evidence.maximumRelayBuffered = Math.max(evidence.maximumRelayBuffered, buffered || 0);
    return result;
  };
  const remember = (list, bytes) => {
    const frame = Number(document.body?.dataset.fortressFrame ?? -1);
    if (!mixed || frame < 0 || frame >= 4) return;
    const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
      : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
    if (!view || view.length > 1024) { evidence.captureError = true; return; }
    const hex = Array.from(view, byte => byte.toString(16).padStart(2, '0')).join('');
    if (!list.includes(hex)) {
      if (list.length >= 128) evidence.captureError = true;
      else list.push(hex);
    }
  };
  window.fortressResources = { connections: [], channels: [] };
  const nativeConnection = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(nativeConnection, {
    construct(target, args, newTarget) {
      const connection = Reflect.construct(target, args, newTarget);
      window.fortressResources.connections.push(connection);
      return connection;
    },
  });
  const create = RTCPeerConnection.prototype.createDataChannel;
  RTCPeerConnection.prototype.createDataChannel = function(label, options) {
    const channel = create.call(this, label, options);
    window.fortressResources.channels.push(channel);
    const record = { options, label, id: channel.id, ordered: channel.ordered, maxPacketLifeTime: channel.maxPacketLifeTime,
      maxRetransmits: channel.maxRetransmits, negotiated: channel.negotiated, sent: 0, received: 0, closed: false };
    record.blockedReads = 0;
    record.closeInitiatedFrame = null;
    record.physicalCloseFrame = null;
    record.mixedSent = 0;
    record.restoredSent = 0;
    record.postDropReceived = 0;
    record.earlySent = [];
    record.earlyReceived = [];
    record.maximumBuffered = 0;
    const buffered = mixed ? Object.getOwnPropertyDescriptor(RTCDataChannel.prototype, 'bufferedAmount').get : null;
    const unreliableIndex = evidence.channels.filter(value => value.id === 3).length;
    record.blockedLink = Boolean(mixed && !peerDrop && !physicalClose && (recordingPressure || index === 0) && channel.id === 3 && unreliableIndex === 0);
    // Inject send pressure on one live channel; all bytes still use real sockets.
    if (record.blockedLink) {
      Object.defineProperty(channel, 'bufferedAmount', { get() {
        const frame = Number(document.body?.dataset.fortressFrame ?? -1);
        if (frame >= 4 && frame < (recordingPressure ? 257 : 16)) { record.blockedReads++; return 262144; }
        return buffered.call(channel);
      } });
    }
    record.connectionState = this.connectionState;
    record.iceConnectionState = this.iceConnectionState;
    this.addEventListener('connectionstatechange', () => { record.connectionState = this.connectionState;
      console.log('RTC_STATE', JSON.stringify({ id: channel.id, state: this.connectionState })); });
    this.addEventListener('iceconnectionstatechange', () => { record.iceConnectionState = this.iceConnectionState; });
    evidence.channels.push(record);
    channel.addEventListener('message', event => {
      record.received++; evidence.received++;
      if (peerDrop && Number(document.body?.dataset.fortressFrame ?? -1) >= 8) record.postDropReceived++;
      if (channel.id === 3) remember(record.earlyReceived, event.data);
    });
    if (physicalClose) {
      const close = channel.close.bind(channel);
      channel.close = () => {
        const frame = Number(document.body?.dataset.fortressFrame ?? -1);
        if (physicalClose && index === 0 && channel.id === 3 && frame === 4 && record.closeInitiatedFrame === null) {
          record.blockedLink = true;
          record.closeInitiatedFrame = frame;
        }
        close();
      };
    }
    channel.addEventListener('close', () => {
      record.closed = true;
      const frame = Number(document.body?.dataset.fortressFrame ?? -1);
      if (physicalClose && channel.id === 3 && document.body?.dataset.fortressGameplayDone !== 'true' && frame >= 0 && frame < 39)
        record.physicalCloseFrame = frame;
    });
    const send = channel.send.bind(channel);
    channel.send = bytes => {
      record.sent++;
      evidence.sent++;
      if (channel.id === 3) remember(record.earlySent, bytes);
      const frame = Number(document.body?.dataset.fortressFrame ?? -1);
      if (mixed && frame >= 4 && frame < 16) record.mixedSent++;
      if (mixed && frame >= 20) record.restoredSent++;
      if (dropAnswer && channel.id === 3) {
        const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes)
          : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
        // FRGP v3 DROP_BARRIER, REPORT phase, INVENTORY stage.
        if (view && view.length >= 100 && view.length <= 1024 && view[0] === 70 && view[1] === 82
          && view[2] === 71 && view[3] === 80 && view[4] === 3 && view[5] === 0 && view[6] === 12
          && view[44] === 2 && view[45] === 1) {
          const hex = Array.from(view, byte => byte.toString(16).padStart(2, '0')).join('');
          if (evidence.answerLoss.dropped === 0) {
            evidence.answerLoss = { dropped: 1, retries: 0, packet: hex };
            return;
          }
          if (evidence.answerLoss.packet === hex) evidence.answerLoss.retries++;
        }
      }
      if (!window.fortressFaultActive || !faults) {
        send(bytes);
        if (mixed) record.maximumBuffered = Math.max(record.maximumBuffered, buffered.call(channel));
        return;
      }
      evidence.active++;
      if (evidence.active % 17 === 0) { evidence.dropped++; return; }
      if (evidence.active % 23 === 0) {
        // Copy bytes: Godot's WASM heap can be reused before delayed delivery.
        const owned = bytes instanceof ArrayBuffer ? bytes.slice(0) : new Uint8Array(bytes).slice();
        evidence.reordered++;
        evidence.pending++;
        setTimeout(() => { if (channel.readyState === 'open') send(owned); evidence.pending--; }, 30);
        return;
      }
      send(bytes);
    };
    return channel;
  };
}

function isDropCanonicalFailure(witness) {
  const failure = witness?.failure;
  return witness?.passed === false && failure?.stage === 'peer_drop_gameplay' && Array.isArray(failure.errors)
    && failure.errors.length === 1 && typeof failure.errors[0] === 'string'
    && /^peer_drop_canonical_(?:[89]|[12][0-9]|3[0-7])$/.test(failure.errors[0]);
}

function isRoomContinueFailure(witness) {
  const failure = witness?.failure;
  if (!(witness?.passed === false && failure?.stage === 'peer_drop_room' && Array.isArray(failure.errors)
    && JSON.stringify(failure.errors) === JSON.stringify(['peer_drop_room_continued'])
    && Array.isArray(failure.records) && failure.records.length === 1
    && failure.records[0] && typeof failure.records[0] === 'object')) return false;
  const row = failure.records[0];
  const integer = value => typeof value === 'number' && Number.isInteger(value);
  return row.departed === false && row.room_fenced === true && row.fence_frame === 7
    && row.frames_submitted === 8 && row.final_frame === 8
    && row.frames_after_fence === 1 && row.continue_code === 0
    && integer(row.fence_frame) && integer(row.frames_submitted) && integer(row.final_frame)
    && integer(row.frames_after_fence) && integer(row.continue_code);
}

function isProcessMissingFailure(witness, role) {
  const failure = witness?.failure;
  const departing = role === 'departing';
  const expected = departing ? 'peer_drop_room_gate' : 'peer_drop_room_fence';
  const index = failure?.local_index;
  return witness?.passed === false && Array.isArray(failure?.errors)
    && JSON.stringify(failure.errors) === JSON.stringify([expected])
    && Array.isArray(failure.records) && failure.records.length === 0
    && (departing ? index === 2 : (index === 0 || index === 1))
    && typeof failure.uuid === 'string' && failure.uuid.length > 0
    && (departing
      ? Number.isInteger(failure.hold_ms) && failure.hold_ms >= 0 && failure.stage === 'handshake'
      : failure.stage === 'peer_drop_room_fence');
}

function resourcesClosed(requireSockets) {
  return window.fortressResources.channels.every(channel => channel.readyState === 'closed')
    && window.fortressResources.connections.every(connection => connection.connectionState === 'closed')
    && (!requireSockets || (window.fortressSockets.length > 0
      && window.fortressSockets.every(record => record.socket.readyState === WebSocket.CLOSED)));
}

async function captureFailure(pages, players) {
  return Promise.all(pages.slice(0, 8).map(async (page, index) => {
    let timer;
    try {
      return await Promise.race([page.evaluate(limit => {
        const evidence = window.fortressRtc;
        const resources = window.fortressResources;
        const candidates = (connection, field) => {
          if (connection.connectionState === 'closed') return null;
          return (connection[field]?.sdp || '').split('\r\n').filter(row => row.startsWith('a=candidate:')).slice(0, 16).map(row => row.slice(0, 512));
        };
        return { index: limit.index, captured_ms: performance.now(), frame: document.body.dataset.fortressFrame,
          witness: document.body.dataset.fortressWebrtc ?? null,
          markers: { drop_ready: document.body.dataset.fortressDropReady ?? null,
            room_fenced: document.body.dataset.fortressRoomFenced ?? null,
            room_left: document.body.dataset.fortressRoomLeft ?? null,
            gameplay_done: document.body.dataset.fortressGameplayDone ?? null },
          scheduling: { ...window.fortressScheduling, hidden: document.hidden, focused: document.hasFocus?.() },
          sockets: (window.fortressSockets || []).slice(0, 4).map(record => ({ opened: record.opened, failed: record.failed,
            close_code: record.close_code, received: record.received, state: record.socket.readyState, buffered: record.socket.bufferedAmount })),
          rtc: { sent: evidence.sent, received: evidence.received, dropped: evidence.dropped, reordered: evidence.reordered,
            pending: evidence.pending, active: evidence.active,
            channels: resources.channels.slice(0, 3 * (limit.players - 1)).map((channel, slot) => ({
              id: channel.id, label: channel.label, ready_state: channel.readyState, buffered_amount: channel.bufferedAmount,
              ordered: channel.ordered, max_packet_life_time: channel.maxPacketLifeTime, max_retransmits: channel.maxRetransmits,
              sent: evidence.channels[slot]?.sent, received: evidence.channels[slot]?.received,
              blocked_reads: evidence.channels[slot]?.blockedReads,
            })),
            connections: resources.connections.slice(0, 2 * (limit.players - 1)).map(connection => ({
              state: connection.connectionState, ice: connection.iceConnectionState, signaling: connection.signalingState,
              local_candidates: candidates(connection, 'localDescription'),
              remote_candidates: candidates(connection, 'remoteDescription'),
            })),
          } };
      }, { index, players }), new Promise(resolve => {
        timer = setTimeout(() => resolve({ index, failure: 'diagnostic_timeout' }), 1000);
      })]);
    } catch {
      return { index, failure: 'diagnostic_evaluation_failed' };
    } finally { clearTimeout(timer); }
  }));
}

function describeFailure(value,failures,descriptions) {
  if(descriptions.has(value))return descriptions.get(value);
  let text;
  try {text=String(value);} catch(error) {
    text='unprintable failure';
    if(!failures.includes(error))failures.push(error);
  }
  descriptions.set(value,text);
  return text;
}

async function main() {
  const engines = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const browserPair = JSON.parse(process.env.FORTRESS_BROWSER_PAIR || '["chromium","chromium"]');
  if (!Array.isArray(browserPair) || browserPair.length !== 2 || browserPair.some(name => !['chromium', 'firefox'].includes(name)))
    throw new Error('invalid browser pair');
  const root = path.resolve(process.argv[2]);
  const endpoint = process.argv[3];
  const faults = process.argv[4] === 'faults';
  const corrupt = process.argv[4] === 'corrupt';
  const defaultFactory = process.argv[4] === 'default';
  const secondBoundary = {
    'peer-drop-second-after-ack': 'after-ack',
    'peer-drop-second-last-turn': 'last-turn',
  }[process.argv[4]] || '';
  const peerDrop = ['peer-drop', 'peer-drop-corrupt', 'peer-drop-close', 'peer-drop-answer', 'peer-drop-relay',
    'peer-drop-missing', 'peer-drop-missing-lost', 'peer-drop-donor-process', 'peer-drop-commit', 'peer-drop-second', 'peer-drop-second-after-ack', 'peer-drop-second-last-turn',
    'peer-drop-rollback', 'peer-drop-foreign',
    'peer-drop-room', 'peer-drop-room-continue', 'peer-drop-process', 'peer-drop-process-missing',
    'peer-drop-room-after-drop', 'peer-drop-room-before-drop', 'peer-drop-overlap'].includes(process.argv[4]);
  const dropRoom = process.argv[4] === 'peer-drop-room';
  const dropRoomContinue = process.argv[4] === 'peer-drop-room-continue';
  const dropProcess = process.argv[4] === 'peer-drop-process';
  const dropProcessMissing = process.argv[4] === 'peer-drop-process-missing';
  const dropRoomAfterDrop = process.argv[4] === 'peer-drop-room-after-drop';
  const dropRoomBeforeDrop = process.argv[4] === 'peer-drop-room-before-drop';
  const dropHistoryLost = process.argv[4] === 'peer-drop-missing-lost';
  const dropDonorProcess = process.argv[4] === 'peer-drop-donor-process';
  const dropMissing = process.argv[4] === 'peer-drop-missing' || dropHistoryLost || dropDonorProcess;
  const dropCommit = process.argv[4] === 'peer-drop-commit';
  const dropSecond = Boolean(secondBoundary) || process.argv[4] === 'peer-drop-second';
  const dropOverlap = process.argv[4] === 'peer-drop-overlap';
  const dropRollback = process.argv[4] === 'peer-drop-rollback';
  const dropForeign = process.argv[4] === 'peer-drop-foreign';
  const dropCorrupt = process.argv[4] === 'peer-drop-corrupt';
  const dropClose = process.argv[4] === 'peer-drop-close';
  const dropAnswer = process.argv[4] === 'peer-drop-answer';
  const dropRelay = process.argv[4] === 'peer-drop-relay';
  const physicalClose = process.argv[4] === 'mixed-close';
  const mixed = ['mixed', 'mixed-default', 'mixed-disabled', 'mixed-close', 'peer-drop-close', 'peer-drop-relay', 'recording-pressure'].includes(process.argv[4]);
  const recordingPressure = process.argv[4] === 'recording-pressure';
  const mixedDefault = process.argv[4] === 'mixed-default';
  const disableFallback = process.argv[4] === 'mixed-disabled';
  const errors = [];
  const logs = [];
  const diagnostic = process.argv[5];
  const server = https.createServer({ cert: fs.readFileSync(process.env.FORTRESS_TLS_CERT),
    key: fs.readFileSync(process.env.FORTRESS_TLS_KEY) }, (request, response) => {
    const filename = path.resolve(root, '.' + decodeURIComponent(new URL(request.url, 'http://localhost').pathname));
    if (!filename.startsWith(root + path.sep)) { response.writeHead(403); response.end(); return; }
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    const mime = { '.wasm': 'application/wasm', '.js': 'application/javascript', '.html': 'text/html' };
    response.setHeader('Content-Type', mime[path.extname(filename)] || 'application/octet-stream');
    fs.readFile(filename, (error, bytes) => { response.writeHead(error ? 404 : 200); response.end(error ? '' : bytes); });
  });
  server.on('upgrade', (request, socket, head) => {
    const backend = new URL(endpoint);
    const upstream = net.connect(Number(backend.port), '127.0.0.1', () => {
      let headers = `${request.method} ${backend.pathname} HTTP/${request.httpVersion}\r\n`;
      for (let index = 0; index < request.rawHeaders.length; index += 2)
        headers += `${request.rawHeaders[index]}: ${request.rawHeaders[index + 1]}\r\n`;
      upstream.write(headers + '\r\n');
      if (head.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browsers = [];
  const records = [];
  const failed_rooms = [];
  const failures=[];
  const descriptions=new Map();
  try {
    for (const name of browserPair) browsers.push(await engines[name].launch(name === 'chromium' ? {
      headless: true, timeout: 30000, executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-background-timer-throttling', '--ignore-certificate-errors'],
    } : { headless: false, timeout: 30000, executablePath: process.env.FORTRESS_FIREFOX_EXECUTABLE,
      firefoxUserPrefs: FIREFOX_PREFS,
    }));
    for (const count of (recordingPressure ? [2] : dropOverlap ? [4] : peerDrop ? [3] : (corrupt || defaultFactory || disableFallback) ? [2] : [2, 4, 8])) {
      const contexts = [];
      const pages = [];
      const displays = [];
      const roomFailures=[];
      let evidencePages = pages;
      let departedUuid = null;
      let processClosed = null;
      let processHeld = null;
      let survivorUuids = null;
      let teardown;
      let serialDispatch;
      let donorHistory;
      try {
        await boundedRoom(async () => {
        await boundedRoom(async () => {
        for (let index = 0; index < count; index++) {
          const context = await browsers[index % 2].newContext({ ignoreHTTPSErrors: true });
          contexts.push(context);
          const page = await context.newPage();
          pages.push(page);
          displays.push(browserPair[index % 2] === 'firefox' ? await placeFirefox(page, index) : null);
          page.on('pageerror', error => errors.push({ count, index, error: error.message }));
          page.on('console', message => {
            const entry = { count, index, type: message.type(), text: message.text() };
            logs.push(entry);
            if(diagnostic)try {fs.appendFileSync(diagnostic,JSON.stringify(entry)+'\n');} catch(error) {
              failures.push(error);errors.push({count,index,error:'browser diagnostic log write failed'});
            }
            if (message.type() === 'error') errors.push({ count, index, error: message.text() });
          });
          await page.addInitScript(instrument, { endpoint: `wss://127.0.0.1:${server.address().port}/v3/ws`, count, index,
            faults, corrupt, defaultFactory, mixed, mixedDefault, disableFallback, physicalClose, peerDrop,
            dropCorrupt, dropClose, dropAnswer, dropRelay, dropMissing, dropHistoryLost, dropDonorProcess, dropCommit, dropSecond, dropRollback, dropForeign,
            dropRoom, dropRoomContinue, dropProcess, dropProcessMissing, dropRoomAfterDrop, dropRoomBeforeDrop, dropOverlap, recordingPressure, secondBoundary });
          await page.goto(`https://127.0.0.1:${server.address().port}/index.html`);
        }
        await pages[0].waitForFunction(() => document.body.dataset.fortressRoom !== undefined, null, { timeout: 60000 });
        const room = await pages[0].evaluate(() => document.body.dataset.fortressRoom);
        await Promise.all(pages.slice(1).map(page => page.evaluate(value => { window.fortressRoom = value; }, room)));
        if (!defaultFactory) {
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressHandshakeReady === 'true'
            || document.body.dataset.fortressGameplayDone === 'true' || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 120000 })));
          if (peerDrop) {
            const uuid = await pages[2].evaluate(() => document.body.dataset.fortressUuid);
            await Promise.all(pages.map(page => page.evaluate(value => { window.fortressDepartingUuid = value; }, uuid)));
            if (dropSecond) {
              const second = await pages[1].evaluate(() => document.body.dataset.fortressUuid);
              await Promise.all(pages.map(page => page.evaluate(value => { window.fortressSecondUuid = value; }, second)));
            }
          }
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstStepReady = true; })));
          await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressFrame === '0' || document.body.dataset.fortressGameplayDone === 'true'
            || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 10000 })));
          await Promise.all(pages.map(page => page.evaluate(() => { window.fortressFirstDeliveryReady = true; })));
        } else await waitDefaultSetup(pages);
        }, 120000, 'setup');
        {
          if (peerDrop) {
            if (dropRoom || dropRoomContinue) {
              await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
              await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropGo = true; })));
              await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(
                () => document.body.dataset.fortressRoomFenced === 'true', null, { timeout: 30000 })));
              await pages[2].waitForFunction(() => document.body.dataset.fortressRoomLeft === 'true', null, { timeout: 30000 });
              if (dropRoom) {
                const before = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
                if (before.length !== 2 || before.some(frame => frame !== '7'))
                  throw new Error(JSON.stringify({ control: 'room_survivor_frame', before }));
                await new Promise(resolve => setTimeout(resolve, 500));
                const after = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
                if (after.length !== 2 || after.some(frame => frame !== '7'))
                  throw new Error(JSON.stringify({ control: 'room_survivor_continued', before, after }));
              }
            } else if (dropRoomAfterDrop || dropRoomBeforeDrop) {
              await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
              await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropGo = true; })));
              const marker = dropRoomAfterDrop ? 'fortressDropComplete' : 'fortressDropPending';
              await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(
                name => document.body.dataset[name] === 'true' || document.body.dataset.fortressWebrtc !== undefined,
                marker, { timeout: 30000 })));
              const marked = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(
                name => document.body.dataset[name] === 'true', marker)));
              if (marked.some(value => !value))
                throw new Error(JSON.stringify({ control: 'room_marker_missing', marker, marked }));
              await pages[2].evaluate(() => { window.fortressDropRoomAfter = true; });
              await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(
                () => document.body.dataset.fortressRoomFenced === 'true', null, { timeout: 30000 })));
              await pages[2].waitForFunction(() => document.body.dataset.fortressRoomLeft === 'true', null, { timeout: 30000 });
              const expected = dropRoomAfterDrop ? '40' : '7';
              const before = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
              if (before.length !== 2 || before.some(frame => frame !== expected))
                throw new Error(JSON.stringify({ control: 'room_survivor_frame', before, expected }));
              await new Promise(resolve => setTimeout(resolve, 500));
              const after = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
              if (after.length !== 2 || after.some(frame => frame !== expected))
                throw new Error(JSON.stringify({ control: 'room_survivor_continued', before, after, expected }));
            } else if (dropProcess || dropProcessMissing) {
              await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
              departedUuid = await pages[2].evaluate(() => document.body.dataset.fortressUuid);
              if (typeof departedUuid !== 'string' || !departedUuid)
                throw new Error(JSON.stringify({ control: 'process_identity_missing', departedUuid }));
              survivorUuids = await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => document.body.dataset.fortressUuid)));
              if (survivorUuids.some(uuid => typeof uuid !== 'string' || !uuid || uuid === departedUuid)
                || new Set(survivorUuids).size !== 2)
                throw new Error(JSON.stringify({ control: 'process_survivor_identity', departedUuid, survivorUuids }));
              await Promise.all(pages.slice(0, 2).map(page => page.evaluate(value => {
                window.fortressDepartingUuid = value; window.fortressDropGo = true;
              }, departedUuid)));
              if (dropProcess) {
                await pages[2].waitForFunction(() => document.body.dataset.fortressHoldHealthy !== undefined,
                  null, { timeout: 5000 });
                processHeld = await pages[2].evaluate(() => ({
                  witness: document.body.dataset.fortressWebrtc ?? null,
                  teardown: document.body.dataset.fortressTeardownArmed ?? null,
                  go: window.fortressDropGo === true,
                  frame: document.body.dataset.fortressFrame ?? null,
                  healthy: document.body.dataset.fortressHoldHealthy === 'true',
                  connected: document.body.dataset.fortressHoldConnected === 'true',
                  authenticated: document.body.dataset.fortressHoldAuthenticated === 'true',
                  room: document.body.dataset.fortressHoldRoom ?? '',
                  errors: Number(document.body.dataset.fortressHoldErrors ?? -1),
                }));
                if (processHeld.witness !== null || processHeld.teardown !== null || processHeld.go
                  || processHeld.frame !== '6' || !processHeld.healthy || !processHeld.connected
                  || !processHeld.authenticated || !processHeld.room || processHeld.errors !== 0)
                  throw new Error(JSON.stringify({ control: 'process_departure_not_held', processHeld }));
                await contexts[2].close();
                processClosed = true;
                evidencePages = pages.slice(0, 2);
                await Promise.all(evidencePages.map(page => page.waitForFunction(
                  () => document.body.dataset.fortressRoomFenced === 'true', null, { timeout: 30000 })));
                const before = await Promise.all(evidencePages.map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
                if (before.length !== 2 || before.some(frame => frame !== '7'))
                  throw new Error(JSON.stringify({ control: 'room_survivor_frame', before }));
                await new Promise(resolve => setTimeout(resolve, 500));
                const after = await Promise.all(evidencePages.map(page => page.evaluate(() => document.body.dataset.fortressFrame)));
                if (after.length !== 2 || after.some(frame => frame !== '7'))
                  throw new Error(JSON.stringify({ control: 'room_survivor_continued', before, after }));
              } else {
                await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(
                  () => document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 30000 })));
                await pages[2].evaluate(() => { window.fortressDropRoomGiveUp = true; });
                await pages[2].waitForFunction(() => document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 30000 });
                const results = await Promise.all(pages.map(page => page.evaluate(() => JSON.parse(document.body.dataset.fortressWebrtc))));
                const ids = results.map(result => result.failure?.uuid);
                if (!isProcessMissingFailure(results[0], 'survivor') || !isProcessMissingFailure(results[1], 'survivor')
                  || !isProcessMissingFailure(results[2], 'departing')
                  || ids[2] !== departedUuid || ids[0] !== survivorUuids[0] || ids[1] !== survivorUuids[1])
                  throw new Error(JSON.stringify({ control: 'wrong_process_missing_boundary', results }));
              }
            } else if (dropClose || dropRelay) await closeDepartingRtc(pages, undefined, dropRelay);
            else {
              await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressDropReady === 'true', null, { timeout: 30000 })));
              if (dropRollback) {
                await pages[2].evaluate(() => { window.fortressDropGo = true; });
                await pages[2].waitForFunction(() => document.body.dataset.fortressFrame === '7'
                  && document.body.dataset.fortressDropPrepared === '7', null, { timeout: 30000 });
                await Promise.all(pages.slice(0, 2).map(page => page.evaluate(() => { window.fortressDropGo = true; })));
                await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(() => document.body.dataset.fortressFrame === '7',
                  null, { timeout: 30000 })));
                await pages[2].evaluate(() => { window.fortressDropSend = true; });
                await pages[2].waitForFunction(() => document.body.dataset.fortressDropSubmitted === '7', null, { timeout: 30000 });
                await Promise.all(pages.slice(0, 2).map(page => page.waitForFunction(
                  () => document.body.dataset.fortressPendingRollback === '7', null, { timeout: 30000 })));
                await pages[2].evaluate(() => { window.fortressDropRelease = true; });
              } else await Promise.all(pages.map(page => page.evaluate(() => { window.fortressDropGo = true; })));
            }
          }
          if (dropMissing && !dropHistoryLost) {
            donorHistory = await resolveDonorHistory(pages, contexts, dropDonorProcess);
            if (dropDonorProcess) evidencePages = pages.filter((_, index) => index !== donorHistory.donor_index);
          }
          if (secondBoundary) {
            const ready = await Promise.all(pages.slice(0, 2).map(async page => {
              const handle = await page.waitForFunction(() => document.body.dataset.fortressSerialReady
                || (document.body.dataset.fortressWebrtc && 'failed'), null, { timeout: 30000 });
              const raw = await handle.jsonValue();
              await handle.dispose();
              if (raw === 'failed') throw new Error('serial drop ended before its departure boundary');
              return { ...JSON.parse(raw), observed_us: Math.floor(performance.now() * 1000) };
            }));
            serialDispatch = { ready, dispatched_us: Math.floor(performance.now() * 1000) };
            await pages[1].evaluate(release => {
              if (window.fortressSecondRelease !== undefined) throw new Error('serial drop release already exists');
              window.fortressSecondRelease = JSON.stringify(release);
            }, serialDispatch);
          }
          if (!dropRoom && !dropRoomContinue && !dropRoomAfterDrop && !dropRoomBeforeDrop && !dropProcess && !dropProcessMissing && !dropDonorProcess) {
            const gameplay = waitGameplay(pages, undefined, undefined, recordingPressure ? 256 : secondBoundary ? 43 : 39);
            if (recordingPressure) await Promise.all([gameplay, releaseRecordingTail(pages)]);
            else await gameplay;
          }
          if (dropDonorProcess) await Promise.all(evidencePages.map(page => page.waitForFunction(
            () => document.body.dataset.fortressGameplayDone === 'true' || document.body.dataset.fortressWebrtc !== undefined,
            null, { timeout: 30000 })));
          await Promise.all(evidencePages.map(page => page.evaluate(() => { window.fortressTeardownArmed = true; })));
          await Promise.all(evidencePages.map(page => page.waitForFunction(() => document.body.dataset.fortressTeardownArmed === 'true',
            null, { timeout: 10000 })));
          await Promise.all(evidencePages.map(page => page.evaluate(() => { window.fortressTeardownReady = true; })));
        }
        await Promise.all(evidencePages.map(page => page.waitForFunction(() => document.body.dataset.fortressWebrtc !== undefined,
          null, { timeout: 10000 })));
        try {
          await Promise.all(evidencePages.map(page => page.waitForFunction(resourcesClosed, peerDrop || recordingPressure, { timeout: 10000 })));
        } catch (error) {
          const causes=[error];
          teardown={resources:null};
          try {
            const observed=await Promise.allSettled(evidencePages.map(async page=>page.evaluate(()=>({
              result: document.body.dataset.fortressWebrtc,
              connections: window.fortressResources.connections.map(connection=>({state:connection.connectionState,
                ice:connection.iceConnectionState,signaling:connection.signalingState})),
              channels: window.fortressResources.channels.map(channel=>({id:channel.id,state:channel.readyState})),
              websockets: window.fortressSockets.map(record=>record.socket.readyState),
            }))));
            teardown.resources=observed.map(result=>result.status==='fulfilled'?result.value:null);
            for(const result of observed)if(result.status==='rejected')causes.push(result.reason);
          } catch(diagnosticError) {causes.push(diagnosticError);}
          throw causes.length===1?error:new AggregateError(causes,'resource closure and diagnostics failed');
        }
        const peers = await Promise.all(evidencePages.map(page => page.evaluate(() => ({
          result: JSON.parse(document.body.dataset.fortressWebrtc), rtc: { ...window.fortressRtc, teardown: {
            channels: window.fortressResources.channels.filter(channel => channel.readyState === 'closed').length,
            connections_created: window.fortressResources.connections.length,
            connections: window.fortressResources.connections.filter(connection => connection.connectionState === 'closed').length,
            websockets_created: window.fortressSockets.length,
            websockets: window.fortressSockets.filter(record => record.socket.readyState === WebSocket.CLOSED).length } },
        }))));
        if (dropProcess && (peers.length !== 2 || peers.some(peer => peer.result?.passed !== true)))
          throw new Error(JSON.stringify({ control: 'wrong_process_fence_boundary', peers }));
        if (errors.length) throw new Error(JSON.stringify({ errors, peers }));
        for (const [index, peer] of peers.entries()) {
          if (dropCorrupt && index < 2 && !isDropCanonicalFailure(peer.result))
            throw new Error(JSON.stringify({ control: 'wrong_drop_canonical_boundary', peers }));
          if (!corrupt && !defaultFactory && !dropCorrupt && !dropRoomContinue && !dropProcessMissing && peer.result.passed !== true) throw new Error(JSON.stringify(peers));
          if (corrupt && (peer.result.passed !== false || peer.result.failure.stage !== 'gameplay'
            || peer.result.failure.errors.length !== 1 || !/^canonical_prefix_frame_[1-9][0-9]*$/.test(peer.result.failure.errors[0])))
            throw new Error(JSON.stringify({ control: 'wrong_failure_boundary', peers }));
          if (defaultFactory && (peer.result.passed !== false || peer.result.failure.stage !== 'handshake'
            || JSON.stringify(peer.result.failure.errors) !== JSON.stringify(['direct_poll_3_peer_0'])))
            throw new Error(JSON.stringify({ control: 'wrong_channel_policy_boundary', peers }));
        }
        if (dropRoomContinue) {
          const failed = peers.filter(peer => peer.result?.passed === false);
          const passed = peers.filter(peer => peer.result?.passed === true);
          if (failed.length !== 2 || passed.length !== 1 || !failed.every(peer => isRoomContinueFailure(peer.result)))
            throw new Error(JSON.stringify({ control: 'wrong_room_fence_boundary', peers }));
        }
        peers.forEach((peer, index) => {
          const pageIndex = pages.indexOf(evidencePages[index]);
          peer.browser = browserPair[pageIndex % 2];
          peer.display = displays[pageIndex];
          if (donorHistory) peer.page_index = pageIndex;
        });
        records.push({ players: count, peers, departedUuid, processClosed, processHeld, survivorUuids, serialDispatch, donorHistory });
        });
      } catch (error) {
        roomFailures.push(error);
        // Preserve live socket evidence before context.close destroys the failed room.
        try {
          const record={players:count,peers:await captureFailure(pages,count)};
          if(teardown!==undefined)record.teardown=teardown;
          failed_rooms.push(record);
        } catch(diagnosticError) {roomFailures.push(diagnosticError);}
      } finally {
        const closed=await Promise.allSettled(contexts.map(context=>Promise.resolve().then(()=>context.close())));
        for(const result of closed) if(result.status==='rejected') roomFailures.push(result.reason);
      }
      if(roomFailures.length) {
        if(roomFailures.length===1)throw roomFailures[0];
        const messages=roomFailures.slice().map(value=>describeFailure(value,roomFailures,descriptions));
        throw new AggregateError(roomFailures,'room operation and cleanup failed: '+messages.join('; '));
      }
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ passed: true, browser: browserPair.join('/'),
      browsers: browsers.map((browser, index) => ({ name: browserPair[index], version: browser.version() })),
      version: browsers[0].version(), browser_instances: 2, firefox_preferences: browserPair.includes('firefox') ? FIREFOX_PREFS : null,
      faults, corrupt, defaultFactory, mixed, mixedDefault, disableFallback, physicalClose, peerDrop, dropCorrupt, dropClose,
      dropAnswer, dropRelay, dropMissing, dropHistoryLost, dropDonorProcess, dropCommit, dropSecond, dropRollback, dropForeign, dropRoom, dropRoomContinue,
      dropProcess, dropProcessMissing, dropRoomAfterDrop, dropRoomBeforeDrop, dropOverlap, recordingPressure, secondBoundary, records, errors }));
  } catch (error) {
    failures.push(error);
    try {
      console.error(JSON.stringify({ failure: describeFailure(error,failures,descriptions), errors, records, failed_rooms, logs, browser: browserPair.join('/'),
        version: browsers[0]?.version(), firefox_preferences: browserPair.includes('firefox') ? FIREFOX_PREFS : null,
        browsers: browsers.map((browser, index) => ({ name: browserPair[index], version: browser.version() })) }));
    } catch(diagnosticError) {failures.push(diagnosticError);}
  } finally {
    const closed=await Promise.allSettled(browsers.map(browser=>Promise.resolve().then(()=>browser.close())));
    for(const result of closed) if(result.status==='rejected') failures.push(result.reason);
    try {await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));} catch(error) {failures.push(error);}
  }
  if(failures.length) {
    if(failures.length===1)throw failures[0];
    const messages=failures.slice().map(value=>describeFailure(value,failures,descriptions));
    throw new AggregateError(failures,'browser operation and cleanup failed: '+messages.join('; '));
  }
}

module.exports = { instrument, isDropCanonicalFailure, isRoomContinueFailure, isProcessMissingFailure, resourcesClosed, closeDepartingRtc,
  releaseRecordingTail };
if (require.main === module) main().catch(error => {
  process.exitCode=1;
  try {console.error(inspect(error,{customInspect:false,getters:false,depth:8}));} catch {console.error('Browser probe failed; diagnostic unavailable.');}
});
