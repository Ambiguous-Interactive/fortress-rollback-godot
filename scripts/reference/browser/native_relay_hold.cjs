const { createHash } = require('node:crypto');

const RELAY_HOLD_PREFIX = 'fortress native relay hold ';
const RELAY_HOLD_CAP = 512;
const RELAY_HOLD_WINDOW_MS = 45000;
const STAGES = ['send', 'raw'];
const REASONS = ['release', 'terminal', 'cap', 'window'];
const ID = /^[0-9a-f]{32}$/;
const uint = (value, minimum = 1, maximum = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(value) && value >= minimum && value <= maximum;
const ms = value => Number.isFinite(value) && value >= 0;
const validLane = lane => lane === undefined || lane === 'addressed';
const stamp = ({ epoch, seq, lane } = {}) => validLane(lane) && uint(epoch, 1, 0xffffffff) && typeof seq === 'string' && /^[1-9][0-9]{0,19}$/.test(seq)
  && BigInt(seq) <= 0xffffffffffffffffn;
const direction = ({ sender, recipient }) => `${sender}/${recipient}`;
const stamped = event => `${direction(event)}/${event.lane ?? 'broadcast'}/${event.epoch}/${event.seq}/${event.envelope_sha256}`;
const socket = event => `${direction(event)}/${event.lane ?? 'broadcast'}/${event.socket_ordinal}/${event.envelope_sha256}`;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const samePacket = (a, b) => a.kind === b.kind && a.lane === b.lane && a.envelope_bytes === b.envelope_bytes && a.payload_sha256 === b.payload_sha256;

function parsePacket(stage, event, page, through) {
  const { envelope, ordinal, at_ms, epoch, seq, lane, socket_ordinal, hold_gate_match, protocol_reply } = event ?? {};
  const sender = stage === 'send' ? page.local : page.remote;
  const recipient = stage === 'send' ? page.remote : page.local;
  if (typeof envelope !== 'string' || !/^(?:[0-9a-f]{2}){101,103}$/.test(envelope)
      || !validLane(lane) || !uint(ordinal) || !ms(at_ms) || at_ms < page.started_ms || at_ms > through
      || (stage === 'send' ? epoch !== null || seq !== null || !uint(socket_ordinal) : socket_ordinal !== null || !stamp(event))) return null;
  const bytes = Buffer.from(envelope, 'hex');
  const payload = bytes.subarray(57);
  const kind = bytes.readUInt32LE(81);
  const token = envelope.slice(-32);
  if (![4, 5].includes(kind) || bytes.length !== (kind === 4 ? 103 : 101)
      || !envelope.startsWith('4653523101' + page.room + sender + recipient)
      || bytes.readUInt32LE(53) !== payload.length || payload.subarray(0, 16).toString('hex') !== page.room
      || payload.readUInt32LE(16) !== 0x000252f5 || payload.readUInt16LE(20) === 0
      || (hold_gate_match !== undefined && (stage !== 'raw' || kind !== 5 || hold_gate_match !== true))
      || (protocol_reply !== undefined && (stage !== 'send' || kind !== 5 || protocol_reply?.token !== token
        || !Array.isArray(protocol_reply.candidates) || protocol_reply.candidates.length > 128 || !protocol_reply.candidates.every(stamp)))) return null;
  return { ordinal, at_ms, sender, recipient, kind, token, epoch, seq, ...(lane === undefined ? {} : { lane }), socket_ordinal, envelope,
    envelope_bytes: bytes.length, envelope_sha256: digest(bytes), payload_sha256: digest(payload),
    hold_gate_match, protocol_reply: protocol_reply?.candidates.map(({ epoch, seq, lane }) => ({ epoch, seq, ...(lane === undefined ? {} : { lane }) })) };
}

function createRelayHold(room, uuids, cap = RELAY_HOLD_CAP) {
  const roster = uuids.map(uuid => uuid.replaceAll('-', '')).sort();
  if (!ID.test(room) || roster.length < 2 || roster.length > 8 || new Set(roster).size !== roster.length || roster.some(uuid => !ID.test(uuid)))
    throw new Error('invalid relay hold roster');
  const pair = roster.slice(0, 2);
  const links = [pair.join('/'), pair.slice().reverse().join('/')];
  const observations = uuids.map(() => null);
  const errors = uuids.map(() => null);

  function record(index, text, controller_ms) {
    if (!text.startsWith(RELAY_HOLD_PREFIX)) return;
    try {
      const sample = JSON.parse(text.slice(RELAY_HOLD_PREFIX.length));
      const local = uuids[index]?.replaceAll('-', '');
      const remote = pair.find(peer => peer !== local);
      const previous = observations[index];
      const { started_ms, through_ms, sockets, sequence, end_reason, streams } = sample;
      if (!ms(controller_ms) || !pair.includes(local) || sample.local !== local || sample.room !== room
        || !ms(started_ms) || !ms(through_ms) || through_ms < started_ms || through_ms > started_ms + RELAY_HOLD_WINDOW_MS || !uint(sockets)
        || (end_reason !== null && !REASONS.includes(end_reason)) || previous?.end_reason
        || !uint(sequence, (previous?.sequence ?? 0) + 1, RELAY_HOLD_WINDOW_MS / 1000 + 2)
        || (previous && (started_ms !== previous.started_ms || through_ms < previous.through_ms || sockets < previous.sockets
          || controller_ms < previous.controller_ms)))
        throw new Error('invalid relay hold checkpoint');

      const page = { room, local, remote, started_ms, through_ms, sockets, sequence, end_reason, controller_ms, streams: {} };
      for (const stage of STAGES) {
        const { count, events } = streams?.[stage] ?? {};
        const history = previous?.streams[stage];
        if (!uint(count, history?.count ?? 0) || !Array.isArray(events) || events.length > cap - (history?.events.length ?? 0)
            || (history?.events.length ?? 0) + events.length > count) throw new Error('invalid relay hold checkpoint packet count');
        const next = events.map(event => parsePacket(stage, event, page, through_ms));
        let last = history?.events.at(-1);
        for (const event of next) {
          if (!event || (last && (event.ordinal <= last.ordinal || event.at_ms < last.at_ms
              || (stage === 'send' && sockets === 1 && event.socket_ordinal <= last.socket_ordinal))))
            throw new Error('invalid relay hold checkpoint packet');
          last = event;
        }
        const retained = [...(history?.events ?? []), ...next];
        page.streams[stage] = { count, omitted: count - retained.length, events: retained };
      }
      observations[index] = page;
    } catch (error) {
      errors[index] ??= String(error);
    }
  }

  function snapshot(server) {
    const pages = pair.map(local => {
      const index = uuids.findIndex(uuid => uuid.replaceAll('-', '') === local);
      return observations[index] && { index, ...observations[index] };
    });
    if (server && (server.room !== room || server.roster.join('/') !== roster.join('/') || server.clock !== 'server.monotonic'))
      throw new Error('relay hold server receipt changed the frozen room');
    const serverStage = stage => (server?.streams[stage].quality.events ?? []).filter(event =>
      links.includes(direction(event)) && stamp(event) && (stage !== 'write' || event.actual_recipient === event.recipient));
    const ingress = serverStage('ingress');
    const write = serverStage('write');
    const packets = joinPackets(pages, ingress, write);
    return { room, links, window_ms: RELAY_HOLD_WINDOW_MS, page_clock: 'page.performance.now', controller_clock: 'controller.performance.now', page_stage_cap: cap, pages,
      errors: [...errors], server_clock: server?.clock ?? null, server: server ? { request: server.request, ingress, write } : null, packets };
  }

  return { links, get started() { return observations.some(Boolean); }, record, snapshot };
}

function indexBy(events, key) {
  const index = new Map();
  for (const event of events) {
    const id = key(event);
    if (!index.has(id)) index.set(id, []);
    index.get(id).push(event);
  }
  return index;
}

function joinPackets(pages, ingress, write) {
  const raw = indexBy(pages.flatMap(page => page?.streams.raw.events ?? []), stamped);
  const accepted = indexBy(ingress, stamped);
  const written = indexBy(write, stamped);
  const sockets = indexBy(ingress, socket);
  const packets = new Map();
  function attach(packet, row, send) {
    const { sender, recipient, kind, token } = packet;
    const { epoch, seq } = row ?? { epoch: null, seq: null };
    const { lane } = packet;
    const key = row ? stamped(row) : `${sender}/send/${send.ordinal}`;
    const ordinals = index => (index.get(key) ?? []).filter(event => samePacket(packet, event)).map(event => event.ordinal);
    const match = packets.get(key) ?? { sender, recipient, kind, token, epoch, seq, ...(lane === undefined ? {} : { lane }), stages: {
      send: null, ingress: ordinals(accepted), write: ordinals(written), raw: ordinals(raw),
    } };
    if (send) {
      match.stages.send = send.ordinal;
      match.report_candidates = send.protocol_reply ?? [];
    }
    packets.set(key, match);
  }
  for (const [packet] of raw.values()) attach(packet, packet, null);
  for (const page of pages.filter(Boolean)) {
    for (const send of page.streams.send.events) {
      const candidates = page.sockets === 1 ? (sockets.get(socket(send)) ?? []).filter(event => samePacket(send, event)) : [];
      const stamps = new Set(candidates.map(stamped));
      attach(send, stamps.size === 1 ? candidates[0] : null, send);
    }
  }
  const reports = indexBy([...packets.values()].filter(packet => packet.kind === 4 && packet.seq !== null),
    packet => `${direction(packet)}/${packet.lane ?? 'broadcast'}/${packet.epoch}/${packet.seq}/${packet.token}`);
  for (const packet of packets.values()) {
    if (packet.kind === 4) delete packet.report_candidates;
    else {
      packet.report_candidates = [...new Map((packet.report_candidates ?? []).map(candidate =>
        [`${candidate.lane ?? 'broadcast'}/${candidate.epoch}/${candidate.seq}`, candidate])).values()];
      packet.joined_report_candidates = packet.report_candidates.filter(({ epoch, seq, lane }) =>
        reports.get(`${packet.recipient}/${packet.sender}/${lane ?? 'broadcast'}/${epoch}/${seq}/${packet.token}`)?.length === 1);
    }
  }
  return [...packets.values()];
}

module.exports = { createRelayHold, RELAY_HOLD_CAP, RELAY_HOLD_PREFIX, RELAY_HOLD_WINDOW_MS };
