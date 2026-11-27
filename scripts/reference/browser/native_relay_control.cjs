const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { createHash } = require('node:crypto');
const { setTimeout: pause } = require('node:timers/promises');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

function events(trace, stage, family) {
  return trace.streams[stage][family].events;
}

function stampKey({ sender, recipient, epoch, seq, lane }) {
  assert.ok(lane === undefined || lane === 'addressed', 'invalid relay stamp lane');
  return `${sender}/${recipient}/${lane === undefined ? '' : lane + '/'}${epoch}/${seq}`;
}
const sendKey = ({ sender, socket_ordinal }) => `${sender}/${socket_ordinal}`;
const sameEnvelope = (a, b) => a.envelope_bytes === b.envelope_bytes && a.envelope_sha256 === b.envelope_sha256;

async function readRelayWireReceipt(page, links = []) {
  // Send one string through Playwright instead of encoding each field as a remote value.
  const text = await page.evaluate(selected => JSON.stringify(window.fortressNativeWire?.relayWireTrace(selected)), links);
  if (text === undefined) return undefined;
  const receipt = JSON.parse(text);
  const digest = bytes => createHash('sha256').update(bytes).digest('hex');
  const exactEnvelopes = new Map();
  for (const groups of Object.values(receipt.streams)) {
    for (const { events } of Object.values(groups)) {
      for (const event of events) {
        let digests = exactEnvelopes.get(event.bytes);
        if (!digests) {
          const bytes = Buffer.from(event.bytes, 'base64');
          digests = { envelope_bytes: bytes.length, envelope_sha256: digest(bytes), payload_sha256: digest(bytes.subarray(57)) };
          exactEnvelopes.set(event.bytes, digests);
        }
        delete event.bytes;
        Object.assign(event, digests);
      }
    }
  }
  for (const event of receipt.carriers?.events ?? []) {
    event.carrier_sha256 = digest(Buffer.from(event.bytes, 'base64'));
    delete event.bytes;
  }
  return receipt;
}

async function readRelayWireDiagnostic(page, links, timeout, label) {
  const started = performance.now();
  const receipt = await boundedRoom(() => readRelayWireReceipt(page, links), timeout, label);
  if (performance.now() >= started + timeout) throw new Error(`absolute ${label} deadline`);
  if (receipt?.carriers) receipt.carrier_capture_started_ms = started;
  return receipt;
}

async function readServerReceipt(path, timing) {
  timing.open_started_ms = performance.now();
  let file;
  try {
    file = await fs.open(path);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  // A successful open pins the atomically renamed file through the read and parse.
  timing.opened_ms = performance.now();
  let text;
  try {
    text = await file.readFile('utf8');
    timing.read_ms = performance.now();
  } finally {
    await file.close();
  }
  timing.parse_started_ms = performance.now();
  const receipt = JSON.parse(text);
  timing.parsed_ms = performance.now();
  timing.observed_generation = receipt?.request;
  return receipt;
}

function createRelayServerReader(path) {
  const requestPath = path + '.request';
  let completed = 0;
  let pending = null;
  let reading = false;
  async function poll(select, timeout, links) {
    const deadline = performance.now() + timeout;
    let timing = { clock: 'controller.performance', deadline_ms: deadline };
    try {
      while (performance.now() < deadline) {
        if (pending === null) {
          const generation = completed + 1;
          timing = { clock: timing.clock, deadline_ms: deadline, generation, links, request_started_ms: performance.now() };
          await fs.writeFile(requestPath + '.next', [generation, ...links].join('\n'), { flag: 'wx', mode: 0o600 });
          await fs.rename(requestPath + '.next', requestPath);
          pending = { generation, links, request_started_ms: timing.request_started_ms, request_published_ms: performance.now() };
        }
        timing = { clock: timing.clock, deadline_ms: deadline, ...pending };
        const receipt = await readServerReceipt(path, timing);
        timing.outcome = 'generation_not_observed';
        if (receipt) {
          assert.equal(receipt.version, 2, 'unexpected relay server receipt version');
          if (receipt.request === pending.generation) {
            if (performance.now() >= deadline) {
              if (timing.opened_ms >= deadline) timing.outcome = 'late_open';
              else if (timing.read_ms >= deadline) timing.outcome = 'late_read';
              else if (timing.parse_started_ms >= deadline) timing.outcome = 'late_before_parse';
              else timing.outcome = timing.parsed_ms >= deadline ? 'late_parse' : 'late_check';
              break;
            }
            const requested = pending.links;
            completed = pending.generation;
            pending = null;
            timing.outcome = 'scope_error';
            assert.deepEqual(receipt.links, requested, 'relay server receipt selected different links');
            const matches = requested.length === links.length && requested.every((link, index) => link === links[index]);
            let result;
            if (matches) {
              receipt.controller_timing = timing;
              timing.outcome = 'predicate_error';
              try {
                result = select(receipt);
              } finally {
                timing.selection_finished_ms = performance.now();
              }
            }
            timing.outcome = result ? 'selected' : matches ? 'predicate_not_met' : 'superseded_selection';
            if (result) return result;
          }
        }
        if (performance.now() < deadline) await pause(10);
      }
      throw new Error('relay server receipt deadline');
    } catch (error) {
      if (error instanceof Error) error.receiptTiming = timing;
      throw error;
    }
  }
  return async (select = receipt => receipt, timeout = 3000, links = []) => {
    assert.ok(!reading, 'relay server reader already has a caller');
    assert.ok(Array.isArray(links) && links.length <= 8 && new Set(links).size === links.length && [...links].every(link => {
      if (typeof link !== 'string' || !/^[0-9a-f]{32}\/[0-9a-f]{32}$/.test(link)) return false;
      return link.slice(0, 32) !== link.slice(33);
    }), 'invalid relay server link selection');
    reading = true;
    try {
      return await poll(select, timeout, [...links].sort());
    } finally {
      reading = false;
    }
  };
}

async function bindRelayServer(ready, scopePath, readReceipt, sourceRevision, wireVersion) {
  const { room_id, session_id: room } = ready[0];
  const roster = ready.map(peer => peer.uuid.replaceAll('-', '')).sort();
  assert.ok(ready.every(peer => peer.room_id === room_id && peer.session_id === room), 'relay scope must bind the same room in every browser');
  const scope = { room_id, room, roster, source_revision: sourceRevision };
  await fs.writeFile(scopePath + '.new', JSON.stringify(scope), { flag: 'wx', mode: 0o600 });
  await fs.rename(scopePath + '.new', scopePath);
  await readReceipt(receipt => {
    assert.equal(receipt.clock, 'server.monotonic');
    assert.deepEqual({ room_id: receipt.room_id, room: receipt.room, roster: receipt.roster, source_revision: receipt.source_revision }, scope);
    assert.equal(receipt.wire_version, wireVersion, 'relay receipt wire version differs from source revision');
    return receipt;
  });
}

async function exerciseRelayDelivery(pages, ready, readReceipt) {
  const [sender, recipient, other] = ready.slice(0, 3).map(peer => peer.uuid.replaceAll('-', ''));
  const [sourcePage, delayedPage, otherPage] = pages;
  const started = await delayedPage.evaluate(() => window.fortressNativeWire.holdRelayControl());
  const ordinals = await sourcePage.evaluate(([recipient, other]) => window.fortressNativeWire.repeatRelayControl(recipient, other), [recipient, other]);
  assert.ok(ordinals.every((ordinal, index) => Number.isSafeInteger(ordinal) && (!index || ordinal === ordinals[index - 1] + 1)));
  const matched = await readReceipt(receipt => {
    const accepted = ordinals.map(ordinal => events(receipt, 'ingress', 'quality').find(event => event.sender === sender && event.socket_ordinal === ordinal));
    if (accepted.some(event => !event)) return null;
    const written = accepted.map(event => events(receipt, 'write', 'quality').find(write => stampKey(write) === stampKey(event)));
    return written.every(Boolean) ? { accepted, written, seen_controller_ms: performance.now() } : null;
  }, 650);
  const { accepted, written } = matched;
  assert.deepEqual(accepted.map(event => event.recipient), [recipient, recipient, other]);
  assert.ok(accepted.every((event, index) => stampKey(event) === stampKey(written[index])
    && sameEnvelope(event, written[index]) && written[index].actual_recipient === event.recipient && event.at_ns <= written[index].at_ns));
  assert.equal(new Set(accepted.map(({ lane, epoch, seq }) => `${lane ?? 'broadcast'}/${epoch}/${seq}`)).size, 3);
  assert.ok(sameEnvelope(accepted[0], accepted[1]) && accepted[0].envelope_sha256 !== accepted[2].envelope_sha256);
  assert.equal(new Set(accepted.map(event => event.payload_sha256)).size, 1);
  const release = await delayedPage.waitForFunction(stamps => window.fortressNativeWire.releaseRelayControl(stamps), accepted.slice(0, 2), { timeout: 1000 });
  const delay = await release.jsonValue();
  await release.dispose();
  assert.equal(delay?.reason, 'controller', 'relay control delivery was released before the controller saw server writes');
  assert.ok(delay.events >= 2 && delay.started_ms === started && delay.release_ms >= started && delay.release_ms - started < 750);
  const browser = await Promise.all([[delayedPage, accepted.slice(0, 2)], [otherPage, accepted.slice(2)]].map(async ([page, stamps]) => {
    const handle = await page.waitForFunction(stamps => window.fortressNativeRelayTrace.freezeEnqueued(stamps), stamps, { timeout: 1000 });
    const receipt = await handle.jsonValue();
    await handle.dispose();
    return stamps.map(expected => {
      const observations = Object.fromEntries(['raw', 'sdk', 'native'].map(stage => [stage,
        events(receipt, stage, 'quality').find(event => stampKey(event) === stampKey(expected) && (stage !== 'native' || event.code === 0))]));
      const { raw, sdk, native } = observations;
      assert.ok(raw && sdk && native && [raw, sdk, native].every(event => sameEnvelope(event, expected)), 'relay control lost a stamped packet');
      assert.ok(raw.at_ms <= sdk.at_ms && sdk.at_ms <= native.at_ms);
      if (expected.recipient === recipient) assert.ok(raw.at_ms <= delay.release_ms && delay.release_ms <= sdk.at_ms, 'SDK escaped the FIFO hold');
      return observations;
    });
  }));
  const sent = await sourcePage.evaluate(() => window.fortressNativeRelayTrace.freeze());
  const sends = accepted.map(expected => events(sent, 'send', 'quality').find(event => sendKey(event) === sendKey(expected)));
  assert.ok(sends.every((event, index) => event && event.lane === accepted[index].lane && sameEnvelope(event, accepted[index])),
    'server did not stamp the exact original send bytes');
  for (const stage of ['raw', 'sdk', 'native']) {
    assert.ok(browser[0][0][stage].ordinal < browser[0][1][stage].ordinal, `relay control reordered ${stage} delivery`);
  }
  return { ...matched, delay, sends, browser: browser.flat() };
}

async function exerciseRelayRetention(pages, ready, readReceipt) {
  const [sender, recipient] = ready.slice(0, 2).map(peer => peer.uuid.replaceAll('-', ''));
  const [source, reporter] = pages;
  const families = ['input', 'quality'];
  const targets = (receipt, stage, family) => events(receipt, stage, family).filter(event => event.sender === sender && event.recipient === recipient);
  await source.evaluate(peer => window.fortressNativeWire.muteRelayLink(peer), recipient);
  let baseline, pauseReceipt;
  try {
    baseline = await Promise.all([source, reporter].map(page => page.evaluate(
      sender => window.fortressNativeRelayTrace.retentionSample(sender), sender)));
    assert.ok(baseline[1].frontier.every(Boolean), 'retention control requires an accepted input and quality report before pressure');
    await pause(950);
  } finally {
    pauseReceipt = await source.evaluate(() => window.fortressNativeWire.resumeRelayLink());
  }
  assert.ok(pauseReceipt.inputs > 0 && pauseReceipt.reports > 0, 'retention control did not mute input and quality');
  const receiptAtPressure = receipt => {
    const pressure = {};
    const { first_quiet_ordinal: first, last_quiet_ordinal: last } = pauseReceipt;
    for (const family of families) {
      const ingress = targets(receipt, 'ingress', family);
      const index = ingress.findLastIndex(event => event.socket_ordinal <= first);
      const [left, right] = index < 0 ? [] : ingress.slice(index, index + 2);
      if (!left || !right) return null;
      assert.ok(right.socket_ordinal > last, `muted link sent ${family} during pressure`);
      const writes = targets(receipt, 'write', family);
      const writerIndex = writes.findIndex(event => stampKey(event) === stampKey(left));
      if (writerIndex < 0 || !writes[writerIndex + 1]) return null;
      const [writtenLeft, writtenRight] = writes.slice(writerIndex, writerIndex + 2);
      assert.equal(stampKey(writtenRight), stampKey(right), `muted link wrote ${family} during pressure`);
      pressure[family] = { ingress: right.ordinal - left.ordinal - 1, write: writtenRight.ordinal - writtenLeft.ordinal - 1,
        before: stampKey(left), after: stampKey(right) };
    }
    return { receipt, pressure };
  };
  const [{ receipt: after, pressure }, pagesAtPressure] = await Promise.all([
    readReceipt(receiptAtPressure, 5000),
    Promise.all([source, reporter].map(page => readRelayWireReceipt(page))),
  ]);
  assert.ok(Object.values(pressure).every(family => family.ingress > 128 && family.write > 128), `insufficient healthy relay traffic: ${JSON.stringify(pressure)}`);
  const joined = joinRelayReceipts(after, pagesAtPressure);
  const frontier = baseline[1].frontier.map(stamp => {
    const row = joined.rows.find(row => stampKey(row) === stampKey(stamp));
    assert.ok(row && completeRelayRow(row), `retention control lost a stage of the original ${stamp.family} packet`);
    return row;
  });
  const browserTraffic = Object.fromEntries([['send', 0], ['raw', 1], ['sdk', 1], ['native', 1]].map(([stage, page]) =>
    [stage, Object.fromEntries(families.map(family => [family, pagesAtPressure[page].streams[stage][family].count - baseline[page].counts[stage][family]]))]));
  return { sender, recipient, pause: pauseReceipt, request: after.request, pressure, browserTraffic, frontier };
}

async function exerciseSameLinkRetention(pages, ready, readReceipt) {
  const [sender, recipient] = ready.slice(0, 2).map(peer => peer.uuid.replaceAll('-', ''));
  const [source, reporter] = pages;
  const links = [`${sender}/${recipient}`];
  const before = await reporter.evaluate(sender => window.fortressNativeWire.blockRelayLink(sender), sender);
  const deadline = performance.now() + 1250;
  const timeLeft = () => Math.max(1, Math.ceil(deadline - performance.now()));
  let ordinals, resumed, server;
  try {
    ordinals = await source.evaluate(recipient => window.fortressNativeWire.pressureRelayLink(recipient), recipient);
    const pending = new Set(ordinals);
    assert.ok(pending.size === ordinals.length && ordinals.every(Number.isSafeInteger), 'invalid same-link send ordinals');
    const observed = await readReceipt(receipt => {
      const streams = ['input', 'quality'];
      const received = streams.flatMap(family => events(receipt, 'ingress', family).filter(event =>
        event.sender === sender && event.recipient === recipient && pending.has(event.socket_ordinal)));
      if (received.length !== pending.size || new Set(received.map(event => event.socket_ordinal)).size !== pending.size
          || new Set(received.map(stampKey)).size !== pending.size) return null;
      const writes = new Map();
      for (const write of streams.flatMap(family => events(receipt, 'write', family))) {
        const key = stampKey(write);
        writes.set(key, writes.has(key) ? null : write);
      }
      return received.every(event => {
        const write = writes.get(stampKey(event));
        return write && write.actual_recipient === recipient && write.kind === event.kind && sameEnvelope(write, event);
      }) ? { receipt, received } : null;
    }, timeLeft(), links);
    server = observed.receipt;
    const stamps = observed.received.map(({ kind, epoch, seq, lane }) => ({ kind, epoch, seq, lane }));
    const handle = await reporter.waitForFunction(expected => window.fortressNativeWire.resumeBlockedRelay(expected), stamps, { timeout: timeLeft() });
    resumed = await handle.jsonValue();
    await handle.dispose();
  } catch (error) {
    try {
      await reporter.evaluate(() => window.fortressNativeWire.resumeBlockedRelay());
    } catch (cleanupError) {
      throw new AggregateError([error, cleanupError], 'same-link pressure and gate cleanup failed');
    }
    throw error;
  }
  assert.ok(resumed.resumed_ms < resumed.deadline_ms, 'same-link pressure exhausted its delivery gate');
  const browsers = await Promise.all([source, reporter].map(page => readRelayWireReceipt(page, links)));
  return checkSameLinkRetention(server, browsers, before, resumed, ordinals);
}

function checkSameLinkRetention(server, browsers, before, resumed, ordinals) {
  const [source, reporter] = browsers;
  const [sender, recipient] = [source.local, reporter.local];
  const expected = new Set(ordinals);
  assert.ok(expected.size === ordinals.length && ordinals.every(Number.isSafeInteger), 'invalid same-link send ordinals');
  const pinned = validateRelayExpiryFrontier(resumed.frontier, sender, recipient, resumed.resumed_ms);
  const joined = joinRelayReceipts(server, browsers, [{ frontier: pinned }]);
  const rows = new Map(joined.rows.map(row => [stampKey(row), row]));
  const frontier = [];
  const pressure = {};
  for (const [family, kind] of [['input', 2], ['quality', 4]]) {
    const rawWatermark = before.raw_watermark?.[family];
    assert.ok(Number.isSafeInteger(rawWatermark) && rawWatermark >= 0, `invalid raw ordinal watermark for ${family}`);
    const raw = new Map(events(reporter, 'raw', family).map(event => [stampKey(event), event]));
    const packet = pinned.packets.find(packet => packet.kind === kind);
    const originalKey = packet && stampKey(packet);
    const row = rows.get(originalKey);
    assert.ok(row && packet.stages.raw && packet.stages.raw.at_ms <= before.started_ms && packet.stages.raw.ordinal <= rawWatermark
      && packet.stages.sdk && completeRelayRow(row),
      `same-link control lost the original ${family} packet stage`);
    const matches = event => stampKey(event) === originalKey;
    const ingress = events(server, 'ingress', family);
    const original = ingress.find(matches);
    frontier.push({ ...row, observations: {
      send: events(source, 'send', family).find(event => event.ordinal === row.send),
      ingress: original, write: events(server, 'write', family).find(matches), ...packet.stages,
    } });
    const injected = ingress.filter(event => event.sender === sender && event.recipient === recipient && expected.has(event.socket_ordinal));
    assert.ok(injected.length > 512, `same-link control needs over 512 new ${family} arrivals`);
    for (const event of injected) {
      const key = stampKey(event);
      const row = rows.get(key);
      const arrival = raw.get(key);
      assert.ok(event.kind === kind && event.socket_ordinal > original.socket_ordinal && expected.delete(event.socket_ordinal)
        && row.send !== null && row.write.length && arrival?.delivery_blocked === true
        && arrival.delivery_gate === resumed.delivery_gate
        && arrival.at_ms >= before.started_ms && arrival.at_ms <= resumed.resumed_ms
        && !row.sdk.length && !row.native.length, `same-link pressure did not stop at raw arrival for ${key}`);
    }
    pressure[family] = { count: injected.length, first: raw.get(stampKey(injected[0])), last: raw.get(stampKey(injected.at(-1))) };
  }
  assert.equal(expected.size, 0, 'same-link control lost an injected send');
  return { request: server.request, before, resumed, pressure, frontier };
}

function validateRelayExpiryFrontier(frontier, uuid, local, at_ms) {
  const { room, sender, recipient, packets } = frontier ?? {};
  const requireValid = (condition, field) => assert.ok(condition, `invalid native expiry frontier ${field}`);
  requireValid(typeof room === 'string' && /^[0-9a-f]{32}$/.test(room)
    && local && sender === uuid.replaceAll('-', '') && recipient === local.replaceAll('-', '')
    && Array.isArray(packets) && packets.length <= 2, 'scope');
  const uint = (value, max = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value > 0 && value <= max;
  const mark = (value, ceiling, stage) => {
    requireValid(uint(value?.ordinal) && Number.isFinite(value.at_ms) && value.at_ms >= 0 && value.at_ms <= ceiling, stage);
    return { ordinal: value.ordinal, at_ms: value.at_ms };
  };
  const seen = new Set();
  return { room, sender, recipient, packets: packets.map(packet => {
    const { kind, epoch, seq, lane, envelope, stages } = packet ?? {};
    requireValid((kind === 2 || kind === 4) && !seen.has(kind) && uint(epoch, 0xffffffff)
      && (lane === undefined || lane === 'addressed') && typeof seq === 'string' && /^[1-9][0-9]{0,19}$/.test(seq) && BigInt(seq) <= 0xffffffffffffffffn
      && typeof envelope === 'string' && /^(?:[0-9a-f]{2}){85,1257}$/.test(envelope)
      && envelope.startsWith('4653523101' + room + sender + recipient), 'stamp and envelope');
    seen.add(kind);
    const bytes = Buffer.from(envelope, 'hex');
    const payload = bytes.subarray(57);
    requireValid(bytes.readUInt32LE(53) === payload.length && payload.subarray(0, 16).toString('hex') === room
      && payload.readUInt32LE(16) === 0x000252f5 && payload.readUInt16LE(20) !== 0 && payload.readUInt32LE(24) === kind, 'native header');
    if (kind === 4) requireValid(bytes.length === 103, 'quality report length');
    else {
      requireValid(bytes.length >= 109, 'input length');
      const count = bytes.readBigUInt64LE(85);
      requireValid(count <= BigInt(Math.floor((bytes.length - 109) / 7)), 'input status count');
      const statusesEnd = 93 + Number(count) * 7;
      requireValid(bytes.readBigUInt64LE(statusesEnd + 8) === BigInt(bytes.length - statusesEnd - 16), 'input body size');
      for (let offset = 93; offset < statusesEnd; offset += 7) requireValid(bytes[offset] <= 1, 'input status value');
    }
    const native = mark(stages?.native, at_ms, 'native stage');
    const sdk = stages.sdk === undefined ? null : mark(stages.sdk, native.at_ms, 'SDK stage');
    const raw = stages.raw === undefined ? null : mark(stages.raw, sdk?.at_ms ?? native.at_ms, 'raw stage');
    const hash = data => createHash('sha256').update(data).digest('hex');
    return { sender, recipient, kind, epoch, seq, ...(lane === undefined ? {} : { lane }), envelope_bytes: bytes.length,
      envelope_sha256: hash(bytes), payload_sha256: hash(payload), stages: { raw, sdk, native } };
  }) };
}

function relayExpiryRows(expiries, joined, selectedLinks) {
  const byStamp = new Map((joined?.rows ?? []).map(row => [stampKey(row), row]));
  return expiries.flatMap(({ frontier }) => (frontier?.packets ?? []).map(({ stages, ...packet }) => {
    const link = `${packet.sender}/${packet.recipient}`;
    const upstream_scope = !selectedLinks.length ? 'room' : selectedLinks.includes(link) ? 'focused' : 'outside-focus';
    const candidate = byStamp.get(stampKey(packet));
    const row = candidate && sameEnvelope(packet, candidate) ? candidate : null;
    const missing = ['send', 'ingress', 'write'].filter(stage => stage === 'send' ? row?.send == null : !row?.[stage].length);
    for (const stage of ['raw', 'sdk']) if (!stages[stage]) missing.push(stage);
    return { ...packet, upstream_scope, missing };
  }));
}

function joinRelayReceipts(server, pages, expiries = []) {
  if (!server?.streams) return null;
  const rows = new Map();
  const sends = new Map();
  const matchedSends = new Set();
  const families = ['sync', 'input', 'quality'];
  function attach(family, stage, packet) {
    const key = stampKey(packet);
    if (!rows.has(key)) rows.set(key, { family, kind: packet.kind, sender: packet.sender, recipient: packet.recipient,
      epoch: packet.epoch, seq: packet.seq, ...(packet.lane === undefined ? {} : { lane: packet.lane }),
      envelope_bytes: packet.envelope_bytes, envelope_sha256: packet.envelope_sha256,
      send: null, ingress: [], write: [], raw: [], sdk: [], native: [], native_accepted: [] });
    const row = rows.get(key);
    assert.ok(sameEnvelope(row, packet) && row.kind === packet.kind && row.family === family, `relay receipt disagrees for ${key}`);
    if (!row[stage].includes(packet.ordinal)) row[stage].push(packet.ordinal);
    if (stage === 'native' && packet.code === 0 && !row.native_accepted.includes(packet.ordinal)) row.native_accepted.push(packet.ordinal);
    return row;
  }
  for (const page of pages) {
    if (!page?.streams) continue;
    assert.equal(page.room, server.room, 'relay trace receipt changed the match');
    assert.ok(server.roster.includes(page.local), 'relay trace receipt changed the roster');
    for (const family of families) {
      for (const stage of ['raw', 'sdk', 'native']) {
        for (const packet of events(page, stage, family)) attach(family, stage, packet);
      }
      for (const packet of events(page, 'send', family)) {
        const key = sendKey(packet);
        if (!sends.has(key)) sends.set(key, []);
        sends.get(key).push({ family, packet, sockets: page.sockets });
      }
    }
  }
  for (const { frontier } of expiries) {
    if (!frontier) continue;
    assert.ok(frontier.room === server.room && server.roster.includes(frontier.sender) && server.roster.includes(frontier.recipient),
      'native expiry frontier changed the relay scope');
    for (const { stages, ...packet } of frontier.packets) {
      const family = packet.kind === 2 ? 'input' : 'quality';
      for (const [stage, observation] of Object.entries(stages)) {
        if (observation) attach(family, stage, { ...packet, ...observation, code: stage === 'native' ? 0 : null });
      }
    }
  }
  for (const family of families) {
    for (const packet of events(server, 'write', family)) {
      assert.equal(packet.actual_recipient, packet.recipient, 'relay write did not reach the addressed socket');
      attach(family, 'write', packet);
    }
    for (const packet of events(server, 'ingress', family)) {
      const row = attach(family, 'ingress', packet);
      const key = sendKey(packet);
      const candidates = sends.get(key);
      if (candidates?.length === 1 && candidates[0].sockets === 1) {
        const source = candidates[0].packet;
        assert.ok(source.recipient === packet.recipient && source.lane === packet.lane && sameEnvelope(source, packet), `relay socket ordinal disagrees for ${key}`);
        row.send = source.ordinal;
        matchedSends.add(key);
      }
    }
  }
  return { rows: [...rows.values()], unjoined_sends: [...sends].filter(([key]) => !matchedSends.has(key)).flatMap(([, candidates]) =>
    candidates.map(({ family, packet }) => ({ family, sender: packet.sender, ordinal: packet.ordinal }))) };
}

function assertJoinedRelayControl(joined) {
  const complete = joined.rows.filter(completeRelayRow);
  assert.ok(complete.length >= 40, 'relay control requires 40 complete packet joins');
  assert.equal(new Set(complete.map(row => row.family)).size, 3, 'relay control requires complete sync, input, and quality packet joins');
}

function completeRelayRow(row) {
  return row.send !== null && ['ingress', 'write', 'raw', 'sdk', 'native_accepted'].every(stage => row[stage].length);
}

module.exports = { assertJoinedRelayControl, bindRelayServer, checkSameLinkRetention, createRelayServerReader, exerciseRelayDelivery,
  exerciseRelayRetention, exerciseSameLinkRetention, joinRelayReceipts, readRelayWireDiagnostic, readRelayWireReceipt, relayExpiryRows, validateRelayExpiryFrontier };
