// Serialized into the browser init script. Keep its dependencies local.
function createRelayWireTrace() {
  const cap = 128;
  const archiveCap = 512;
  const families = ['sync', 'sync', 'input', 'input', 'quality', 'quality'];
  const streams = Object.fromEntries(['send', 'raw', 'sdk', 'native'].map(stage => [stage, Object.fromEntries(
    [...new Set(families)].map(family => [family, { count: 0, links: new Map() }]))]));
  let room, local, localBytes, roster;
  const hex = bytes => Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');

  function decodeDelivery(bytes) {
    // The pinned server writes a five-field named MessagePack map.
    if (bytes[0] !== 0x85) return null;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 1;
    function span(size) {
      if (size > bytes.length - offset) throw new RangeError('truncated GameData field');
      const value = bytes.subarray(offset, offset + size);
      offset += size;
      return value;
    }
    function integer(width) {
      const at = offset;
      span(width);
      if (width === 8) return view.getBigUint64(at);
      if (width === 4) return view.getUint32(at);
      if (width === 2) return view.getUint16(at);
      return view.getUint8(at);
    }
    function string() {
      const marker = integer(1);
      if (marker < 0xa0 || marker > 0xbf) throw new RangeError('expected short GameData string');
      return String.fromCharCode(...span(marker & 31));
    }
    function binary() {
      const marker = integer(1);
      if (marker < 0xc4 || marker > 0xc6) throw new RangeError('expected binary GameData field');
      return span(integer(1 << (marker - 0xc4)));
    }
    function unsigned() {
      const marker = integer(1);
      if (marker < 0x80) return BigInt(marker);
      if (marker < 0xcc || marker > 0xcf) throw new RangeError('expected unsigned GameData stamp');
      return BigInt(integer(1 << (marker - 0xcc)));
    }
    const readers = new Map([['from_player', binary], ['encoding', string], ['payload', binary], ['seq', unsigned], ['epoch', unsigned]]);
    const fields = new Map();
    try {
      for (let i = 0; i < 5; i++) {
        const key = string();
        if (!readers.has(key) || fields.has(key)) return null;
        fields.set(key, readers.get(key)());
      }
    } catch (error) {
      if (!(error instanceof RangeError)) throw error;
      return null;
    }
    const from = fields.get('from_player');
    const epoch = fields.get('epoch');
    const seq = fields.get('seq');
    if (offset !== bytes.length || from.length !== 16 || fields.get('encoding') !== 'message_pack' || !seq || !epoch || epoch > 0xffffffffn) return null;
    const envelope = fields.get('payload');
    // SignalFish also broadcasts every envelope addressed to another peer.
    if (!localBytes.every((byte, index) => envelope[37 + index] === byte)) return null;
    return { envelope, from: hex(from), epoch: Number(epoch), seq: seq.toString() };
  }

  function identify(envelope) {
    if (envelope.length < 85 || envelope.length > 1257) return null;
    const view = new DataView(envelope.buffer, envelope.byteOffset, envelope.byteLength);
    if (view.getUint32(0) !== 0x46535231 || envelope[4] !== 1 || view.getUint32(53, true) !== envelope.length - 57
        || view.getUint32(73, true) !== 0x000252f5 || view.getUint16(77, true) === 0
        || hex(envelope.subarray(5, 21)) !== room || hex(envelope.subarray(57, 73)) !== room) return null;
    const kind = view.getUint32(81, true);
    if (kind >= families.length) return null;
    if (kind === 2) {
      if (envelope.length < 109) return null;
      const statusCount = view.getBigUint64(85, true);
      if (statusCount > BigInt(Math.floor((envelope.length - 109) / 7))) return null;
      const afterStatus = 93 + Number(statusCount) * 7;
      for (let offset = 93; offset < afterStatus; offset += 7) if (envelope[offset] > 1) return null;
      if (view.getBigUint64(afterStatus + 8, true) !== BigInt(envelope.length - afterStatus - 16)) return null;
    } else if (envelope.length !== 85 + [31, 31, null, 4, 18, 16][kind]) return null;
    const sender = hex(envelope.subarray(21, 37));
    const recipient = hex(envelope.subarray(37, 53));
    if (sender === recipient || !roster.has(sender) || !roster.has(recipient)) return null;
    return { sender, recipient, kind };
  }

  function retain(stage, envelope, identity, metadata) {
    const stream = streams[stage][families[identity.kind]];
    const ordinal = ++stream.count;
    const peer = stage === 'send' ? identity.recipient : identity.sender;
    if (!stream.links.has(peer)) stream.links.set(peer, []);
    const events = stream.links.get(peer);
    if (events.length === (identity.kind < 2 ? cap : archiveCap)) events.shift();
    const packet = { ordinal, ...identity, ...metadata, bytes: Uint8Array.from(envelope) };
    events.push(packet);
    return packet;
  }

  const sha256 = async bytes => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
  const unhex = value => Uint8Array.from(value.match(/../g) ?? [], byte => parseInt(byte, 16));
  return {
    bind(session, uuid, members) {
      if (roster) throw new Error('relay wire trace already bound');
      const identities = new Set(members);
      if (members.length !== identities.size || identities.size < 2 || identities.size > 8 || !identities.has(uuid))
        throw new Error('invalid relay wire trace roster');
      room = session;
      local = uuid;
      localBytes = unhex(uuid);
      roster = identities;
    },
    record(stage, bytes, socket_ordinal = null) {
      if (!roster || !bytes) return;
      const at_ms = performance.now();
      const delivery = stage === 'raw' ? decodeDelivery(bytes) : null;
      if (stage === 'raw' && !delivery) return;
      const envelope = delivery?.envelope ?? bytes;
      const identity = identify(envelope);
      if (!identity || (stage === 'raw' ? delivery.from !== identity.sender || identity.recipient !== local : identity.sender !== local)) return;
      let protocol_reply;
      if (stage === 'send' && identity.kind === 5) {
        const token = hex(envelope.subarray(-16));
        // An echo proves processing of this token on the link. Identical reports can share it.
        const candidates = streams.native.quality.links.get(identity.recipient)?.slice(-cap).filter(event => event.kind === 4
          && event.code === 0 && event.report_token === token).map(({ epoch, seq }) => ({ epoch, seq }));
        if (candidates?.length) protocol_reply = { token, candidates };
      }
      return retain(stage, envelope, identity, { at_ms, socket_ordinal, epoch: delivery?.epoch ?? null, seq: delivery?.seq ?? null, protocol_reply });
    },
    recordEngine(stage, from, value, epoch, signedSeq, code) {
      if (!roster || !epoch || value.length > 2514) return;
      const at_ms = performance.now();
      const sender = from.replaceAll('-', '');
      if (!roster.has(sender) || sender === local) return;
      const bytes = unhex(value);
      let envelope = bytes;
      if (stage === 'native') {
        envelope = new Uint8Array(57 + bytes.length);
        envelope.set(unhex('4653523101' + room + sender + local));
        new DataView(envelope.buffer).setUint32(53, bytes.length, true);
        envelope.set(bytes, 57);
      }
      const identity = identify(envelope);
      if (!identity || identity.sender !== sender || identity.recipient !== local) return;
      const seq = BigInt.asUintN(64, BigInt(signedSeq));
      const report_token = stage === 'native' && identity.kind === 4 ? hex(envelope.subarray(-16)) : undefined;
      if (seq !== 0n) retain(stage, envelope, identity, { at_ms, epoch, seq: seq.toString(), code, report_token });
    },
    repeatQuality(recipient, other, send) {
      const original = streams.send.quality.links.get(recipient)?.slice(-cap).findLast(event => event.kind === 4);
      if (!original || !roster.has(other) || other === local || other === recipient) throw new Error('missing relay control packet or recipient');
      const addressed = original.bytes.slice();
      const readdressed = addressed.slice();
      readdressed.set(unhex(other), 37);
      return [send(addressed), send(addressed), send(readdressed)];
    },
    pressureLink(recipient, send) {
      const originals = [['input', 2], ['quality', 4]].map(([family, kind]) =>
        streams.send[family].links.get(recipient)?.findLast(event => event.kind === kind));
      if (originals.some(packet => !packet)) throw new Error('missing same-link pressure packets');
      const ordinals = [];
      for (let index = 0; index <= cap; index++) {
        for (const { bytes } of originals) ordinals.push(send(bytes));
      }
      return ordinals;
    },
    hasBlockedRelayStamps(sender, stamps) {
      const blocked = new Set(['input', 'quality'].flatMap(family => (streams.raw[family].links.get(sender) ?? [])
        .filter(event => event.delivery_blocked).map(({ epoch, seq }) => `${epoch}/${seq}`)));
      return stamps.length > 0 && stamps.every(({ epoch, seq }) => blocked.has(`${epoch}/${seq}`));
    },
    freezeEnqueued(stamps) {
      if (!stamps.every(stamp => streams.native.quality.links.get(stamp.sender)?.slice(-cap).some(event =>
        event.recipient === stamp.recipient && event.epoch === stamp.epoch && event.seq === stamp.seq && event.code === 0))) return null;
      return this.freeze();
    },
    retentionSample(sender) {
      const counts = Object.fromEntries(Object.entries(streams).map(([stage, groups]) =>
        [stage, { input: groups.input.count, quality: groups.quality.count }]));
      const frontier = [['input', 2], ['quality', 4]].map(([family, kind]) => {
        const match = streams.native[family].links.get(sender)?.findLast(event => event.kind === kind && event.code === 0);
        if (!match) return null;
        const { recipient, epoch, seq } = match;
        return { family, sender, recipient, epoch, seq };
      });
      return { counts, frontier };
    },
    async freeze(links = []) {
      if (!Array.isArray(links) || links.length > 8) throw new Error('invalid relay wire link selection');
      const selected = new Set(links);
      if (selected.size !== links.length || [...selected].some(link => {
        if (typeof link !== 'string') return true;
        const [sender, recipient, extra] = link.split('/');
        return extra !== undefined || sender === recipient || !roster?.has(sender) || !roster.has(recipient);
      })) throw new Error('invalid relay wire link selection');
      function retained(stage, family, peer, records) {
        const link = stage === 'send' ? `${local}/${peer}` : `${peer}/${local}`;
        if (selected.size && !selected.has(link)) return [];
        return selected.size && family !== 'sync' ? records : records.slice(-cap);
      }
      const entries = Object.entries(streams).flatMap(([stage, groups]) => Object.entries(groups).map(([family, stream]) =>
        ({ stage, family, count: stream.count, events: [...stream.links].flatMap(([peer, records]) =>
          retained(stage, family, peer, records)).sort((a, b) => a.ordinal - b.ordinal) })));
      const snapshot = { version: 1, clock: 'page.performance.now', room, local, streams: Object.fromEntries(Object.keys(streams).map(stage => [stage, {}])) };
      // Only retained events can add entries, and the cache lives for one freeze.
      const stamped = new Map();
      const hashPacket = async bytes => ({
        envelope_sha256: await sha256(bytes), payload_sha256: await sha256(bytes.subarray(57)),
      });
      function packetDigests({ sender, recipient, epoch, seq }, bytes) {
        if (seq === null) return hashPacket(bytes);
        // Each traced envelope is at most 1,257 bytes, so this key can include the exact bytes.
        const key = `${sender}/${recipient}/${epoch}/${seq}:${String.fromCharCode(...bytes)}`;
        const cached = stamped.get(key);
        if (cached) return cached;
        const digests = hashPacket(bytes);
        stamped.set(key, digests);
        return digests;
      }
      await Promise.all(entries.map(async ({ stage, family, count, events }) => {
        snapshot.streams[stage][family] = { count, omitted: count - events.length, events: await Promise.all(events.map(async ({ bytes, ...event }) =>
          ({ ...event, envelope_bytes: bytes.length, ...await packetDigests(event, bytes) }))) };
      }));
      return snapshot;
    },
  };
}

module.exports = { createRelayWireTrace };
