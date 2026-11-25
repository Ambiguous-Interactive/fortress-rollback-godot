const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { setTimeout: pause } = require('node:timers/promises');

function events(trace, stage, family) {
  return trace.streams[stage][family].events;
}

const stampKey = ({ sender, recipient, epoch, seq }) => `${sender}/${recipient}/${epoch}/${seq}`;
const sendKey = ({ sender, socket_ordinal }) => `${sender}/${socket_ordinal}`;
const sameEnvelope = (a, b) => a.envelope_bytes === b.envelope_bytes && a.envelope_sha256 === b.envelope_sha256;

async function readServerReceipt(path) {
  try {
    return JSON.parse(await fs.readFile(path, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function waitForServerReceipt(path, select, timeout) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    const result = select(await readServerReceipt(path));
    if (result && performance.now() < deadline) return result;
    await pause(10);
  }
  throw new Error('relay server receipt deadline');
}

async function bindRelayServer(ready, scopePath, receiptPath) {
  const { room_id, session_id: room } = ready[0];
  const roster = ready.map(peer => peer.uuid.replaceAll('-', '')).sort();
  assert.ok(ready.every(peer => peer.room_id === room_id && peer.session_id === room), 'relay scope must bind the same room in every browser');
  const scope = { room_id, room, roster };
  await fs.writeFile(scopePath + '.new', JSON.stringify(scope), { flag: 'wx', mode: 0o600 });
  await fs.rename(scopePath + '.new', scopePath);
  await waitForServerReceipt(receiptPath, receipt => {
    if (!receipt) return null;
    assert.equal(receipt.version, 1);
    assert.equal(receipt.clock, 'server.monotonic');
    assert.deepEqual({ room_id: receipt.room_id, room: receipt.room, roster: receipt.roster }, scope);
    return receipt;
  }, 3000);
}

async function exerciseRelayDelivery(pages, ready, receiptPath) {
  const [sender, recipient, other] = ready.slice(0, 3).map(peer => peer.uuid.replaceAll('-', ''));
  const [sourcePage, delayedPage, otherPage] = pages;
  const started = await delayedPage.evaluate(() => window.fortressNativeWire.holdRelayControl());
  const ordinals = await sourcePage.evaluate(([recipient, other]) => window.fortressNativeWire.repeatRelayControl(recipient, other), [recipient, other]);
  assert.ok(ordinals.every((ordinal, index) => Number.isSafeInteger(ordinal) && (!index || ordinal === ordinals[index - 1] + 1)));
  const matched = await waitForServerReceipt(receiptPath, receipt => {
    if (!receipt) return null;
    const accepted = ordinals.map(ordinal => events(receipt, 'ingress', 'quality').find(event => event.sender === sender && event.socket_ordinal === ordinal));
    if (accepted.some(event => !event)) return null;
    const written = accepted.map(event => events(receipt, 'write', 'quality').find(write => stampKey(write) === stampKey(event)));
    return written.every(Boolean) ? { accepted, written, seen_controller_ms: performance.now() } : null;
  }, 650);
  const { accepted, written } = matched;
  const release = await delayedPage.waitForFunction(stamps => window.fortressNativeWire.releaseRelayControl(stamps), accepted.slice(0, 2), { timeout: 1000 });
  const delay = await release.jsonValue();
  await release.dispose();
  assert.equal(delay?.reason, 'controller', 'relay control delivery was released before the controller saw server writes');
  assert.ok(delay.events >= 2 && delay.started_ms === started && delay.release_ms >= started && delay.release_ms - started < 750);
  assert.deepEqual(accepted.map(event => event.recipient), [recipient, recipient, other]);
  assert.ok(accepted.every((event, index) => stampKey(event) === stampKey(written[index])
    && sameEnvelope(event, written[index]) && written[index].actual_recipient === event.recipient && event.at_ns <= written[index].at_ns));
  assert.equal(new Set(accepted.map(event => `${event.epoch}/${event.seq}`)).size, 3);
  assert.ok(sameEnvelope(accepted[0], accepted[1]) && accepted[0].envelope_sha256 !== accepted[2].envelope_sha256);
  assert.equal(new Set(accepted.map(event => event.payload_sha256)).size, 1);
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
  assert.ok(sends.every((event, index) => event && sameEnvelope(event, accepted[index])), 'server did not stamp the exact original send bytes');
  for (const stage of ['raw', 'sdk', 'native']) {
    assert.ok(browser[0][0][stage].ordinal < browser[0][1][stage].ordinal, `relay control reordered ${stage} delivery`);
  }
  return { ...matched, delay, sends, browser: browser.flat() };
}

function joinRelayReceipts(server, pages) {
  if (!server?.streams) return null;
  const rows = new Map();
  const sends = new Map();
  const matchedSends = new Set();
  const families = ['sync', 'input', 'quality'];
  function attach(family, stage, packet) {
    const key = stampKey(packet);
    if (!rows.has(key)) rows.set(key, { family, kind: packet.kind, sender: packet.sender, recipient: packet.recipient,
      epoch: packet.epoch, seq: packet.seq, envelope_bytes: packet.envelope_bytes, envelope_sha256: packet.envelope_sha256,
      send: null, ingress: [], write: [], raw: [], sdk: [], native: [] });
    const row = rows.get(key);
    assert.ok(sameEnvelope(row, packet) && row.kind === packet.kind && row.family === family, `relay receipt disagrees for ${key}`);
    row[stage].push(packet.ordinal);
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
        assert.ok(source.recipient === packet.recipient && sameEnvelope(source, packet), `relay socket ordinal disagrees for ${key}`);
        row.send = source.ordinal;
        matchedSends.add(key);
      }
    }
  }
  return { rows: [...rows.values()], unjoined_sends: [...sends].filter(([key]) => !matchedSends.has(key)).flatMap(([, candidates]) =>
    candidates.map(({ family, packet }) => ({ family, sender: packet.sender, ordinal: packet.ordinal }))) };
}

function assertJoinedRelayControl(joined) {
  const complete = joined.rows.filter(row => row.send !== null && ['ingress', 'write', 'raw', 'sdk', 'native'].every(stage => row[stage].length));
  assert.ok(complete.length >= 40, 'relay control requires 40 complete packet joins');
  assert.equal(new Set(complete.map(row => row.family)).size, 3, 'relay control requires complete sync, input, and quality packet joins');
}

module.exports = { assertJoinedRelayControl, bindRelayServer, exerciseRelayDelivery, joinRelayReceipts, readServerReceipt };
