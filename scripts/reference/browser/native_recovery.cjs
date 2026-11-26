'use strict';

const assert = require('node:assert/strict');

const PHYSICAL_PAIRS = [[0, 1], [2, 3]];

class OmittedReplacement extends Error {
  constructor(slots) {
    super('the selected replacement Offers were withheld');
    this.slots = slots;
  }
}

function reciprocalPair(peers, exclude = []) {
  const [left, right] = peers;
  const eligible = (record, index) => record.open && record.unreliable && record.local && record.remote
    && record.index !== exclude[index]?.index;
  const matches = left.wire.sctp.filter(record => eligible(record, 0)).flatMap(a => right.wire.sctp
    .filter(b => eligible(b, 1) && a.local === b.remote && a.remote === b.local).map(b => [a, b]));
  assert.equal(matches.length, 1, 'the two pages must have exactly one reciprocal open unreliable pair');
  return matches[0];
}

function assertStableRoom(direct, peers, targets = [1, 0]) {
  for (const [index, peer] of peers.entries()) {
    const before = direct[index];
    assert.equal(peer.state, 'playing', peer.message);
    assert.ok(peer.started_on_full_mesh);
    const counterpart = direct[targets[index]]?.uuid.replaceAll('-', '');
    for (const direction of ['relayRecipients', 'relaySenders'])
      assert.deepEqual(Object.keys(peer.wire[direction]), counterpart ? [counterpart] : [], 'relay must stay within the recovering pair');
    assert.equal(peer.plan_events, before.plan_events, 'no replacement plan was received');
    assert.deepEqual(peer.plan, before.plan, 'the accepted WebRTC plan must remain unchanged');
    for (const field of ['room_id', 'sdk_room_id', 'session_id', 'uuid', 'slot', 'sdk_epochs'])
      assert.deepEqual(peer[field], before[field], `recovery changed ${field}`);
    assert.deepEqual([...peer.sdk_roster].sort(), [...before.sdk_roster].sort());
    assert.deepEqual(peer.wire.sockets, [1], 'the original SDK socket must remain open');
  }
}

function makePair(direct, slots, drops) {
  const peers = slots.map(index => direct[index]);
  const initiators = peers.map((peer, index) => peer.plan.peers.find(plan => plan.player_id === peers[1 - index].uuid)?.initiate);
  assert.deepEqual([...initiators].sort(), [false, true]);
  const offerer = slots[initiators.indexOf(true)];
  const answerer = slots.find(index => index !== offerer);
  return { slots, old: reciprocalPair(peers), offerer, answerer, drops };
}

function addressCounts(peer, target) {
  const uuid = target.uuid.replaceAll('-', '');
  return [peer.wire.relayInputRecipients[uuid] ?? 0, peer.wire.relayInputSenders[uuid] ?? 0];
}

function assertHealthy(healthy, before, peers) {
  let progressed = true;
  for (const [index, peer] of peers.entries()) {
    for (const link of healthy[index]) {
      const now = peer.wire.sctp.find(record => record.index === link.index);
      const earlier = before[index].wire.sctp.find(record => record.index === link.index);
      assert.ok(now?.open && now.local === link.local && now.remote === link.remote && now.closeEvents === 0,
        `peer ${index} channel ${link.index} must stay open with its original ICE credentials`);
      if (now.inputsSent <= earlier.inputsSent || now.inputsReceived <= earlier.inputsReceived) progressed = false;
    }
  }
  return progressed;
}

function assertRecoveredRoom(direct, restored, peers, { pairs, targets }) {
  assertStableRoom(direct, peers, targets);
  const original = pairs.flatMap(pair => pair.old);
  const replacement = pairs.flatMap(pair => pair.replacement);
  const links = direct.map((peer, index) => {
    const healthy = peer.wire.sctp.filter(link => link.index !== original[index]?.index);
    return replacement[index] ? [...healthy, replacement[index]] : healthy;
  });
  assert.ok(assertHealthy(links, restored, peers), 'direct gameplay must advance through final history capture');
}

function verifyReplacement(pair, direct, peers) {
  const { slots, offerer, answerer, old, drops, released } = pair;
  const send = peers[offerer].wire.recovery;
  const receive = peers[answerer].wire.recovery;
  assert.equal(receive.pending, 0, 'answerer signaling must pass through');
  assert.equal(send.pending, 0);
  assert.equal(send.droppedOffers, Number(Boolean(drops)));
  assert.equal(released, send.queuedKinds.Offer + send.queuedKinds.IceCandidate - send.droppedOffers);
  assert.ok(receive.receivedKinds.IceCandidate >= send.queuedKinds.IceCandidate);
  assert.equal(receive.receivedKinds.Offer, drops ? 0 : 1, 'first Offer delivery must match the selected fault');
  const replacement = reciprocalPair(slots.map(index => peers[index]), old);
  const ice = replacement[slots.indexOf(offerer)].local;
  const accepted = receive.delivered.find(offer => offer.body.match(/^a=ice-ufrag:([\w+/]+)\r?$/m)?.[1] === ice);
  assert.ok(accepted && (drops ? accepted.attempt > 1 : accepted.attempt === 1), 'fresh channel must use the expected delivered Offer');
  const { at_ms: deliveredAt, ...envelope } = accepted;
  const sent = send.observed.find(offer => offer.attempt === envelope.attempt);
  assert.ok(sent);
  const { at_ms: sentAt, ...sentEnvelope } = sent;
  assert.deepEqual(envelope, sentEnvelope, 'the real server delivered the exact replacement Offer');
  assert.ok(send.released >= send.observed[0].at_ms && sentAt >= send.observed[0].at_ms && deliveredAt > 0);
  if (!drops) assert.deepEqual(send.observed.map(event => event.attempt), [1]);
  for (const [offset, index] of slots.entries()) {
    const record = replacement[offset];
    assert.notEqual(record.local, old[offset].local, 'replacement uses a fresh local ICE credential');
    assert.notEqual(record.remote, old[offset].remote, 'replacement uses a fresh remote ICE credential');
    assert.ok(record.inputsSent > 0 && record.inputsReceived > 0);
    assert.ok(!direct[index].wire.sctp.some(link => link.index === record.index), 'replacement must be a new physical channel');
    const closed = peers[index].wire.sctp.find(link => link.index === old[offset].index);
    assert.ok(closed?.closed && closed.connectionClosed, 'old physical channel and connection must both retire');
  }
  return { ...pair, replacement, attempt: accepted.attempt };
}

async function recoverPairs(direct, { pages, observe, command, pause, setPhase, overlap, omitSecond }) {
  const [first, second] = PHYSICAL_PAIRS;
  const pairs = [makePair(direct, first, overlap ? 'drop-first-offer' : null)];
  if (overlap) pairs.push(makePair(direct, second, omitSecond ? 'drop-all-offers' : null));
  const targets = pairs.flatMap(({ slots: [a, b] }) => [b, a]);
  const old = pairs.flatMap(pair => pair.old);
  const healthy = direct.map((peer, index) => peer.wire.sctp.filter(record => record.index !== old[index]?.index));
  for (const peer of direct) {
    assert.equal(peer.plan_events, 1);
    assert.ok(peer.room_id && peer.room_id === peer.sdk_room_id);
    assert.ok(peer.plan.generation && peer.plan.generation === direct[0].plan.generation);
    assert.equal(Object.keys(peer.sdk_epochs).length, direct.length);
    assert.ok(Object.values(peer.sdk_epochs).every(epoch => Number.isSafeInteger(epoch) && epoch >= 0));
    assert.equal(peer.wire.sctp.length, direct.length - 1);
  }
  await Promise.all(pairs.flatMap(({ slots, offerer }) => slots.map(index => {
    const peer = direct[index], target = direct[targets[index]];
    return pages[index].evaluate(scope => window.fortressNativeWire.observeRecovery(scope), {
      room: peer.room_id, generation: peer.plan.generation, peer: target.uuid,
      localEpoch: peer.sdk_epochs[peer.uuid], peerEpoch: peer.sdk_epochs[target.uuid], holdsOffer: index === offerer,
    });
  })));
  setPhase('physical channel close');
  await Promise.all(pairs.map(({ slots: [a, b] }) => command(pages[a], 'close_link', { uuid: direct[b].uuid })));
  const atClose = await observe();
  for (const { slots: [a] } of pairs) assert.equal(atClose[a].closed_channel_state, 1, 'fault must close an open channel');
  let relayAtOffer;
  const afterClose = await (async () => {
    const deadline = performance.now() + 7000;
    while (performance.now() < deadline) {
      const peers = await observe();
      const held = pairs.every(({ offerer }) => {
        const { queuedKinds } = peers[offerer].wire.recovery;
        return queuedKinds.Offer === 1 && queuedKinds.IceCandidate > 0;
      });
      if (held && !relayAtOffer) {
        relayAtOffer = targets.map((target, index) => addressCounts(peers[index], direct[target]));
      } else if (relayAtOffer && peers.every((peer, index) => {
        const target = direct[targets[index]];
        return peer.confirmed > atClose[index].confirmed
          && (!target || (peer.relay_peers.includes(target.uuid) && peer.wire.sctp.find(link => link.index === old[index].index)?.closed
            && addressCounts(peer, target).every((count, direction) => count > relayAtOffer[index][direction])));
      }) && assertHealthy(healthy, atClose, peers)) {
        return peers;
      }
      await pause(25);
    }
    throw new Error('the held attempts did not leave enough time for addressed relay gameplay and healthy direct progress');
  })();
  assertStableRoom(direct, afterClose, targets);
  for (const { offerer, answerer } of pairs) {
    const send = afterClose[offerer].wire.recovery;
    const receive = afterClose[answerer].wire.recovery;
    assert.deepEqual(send.observed.map(event => event.attempt), [1]);
    assert.equal(send.released, 0);
    assert.equal(send.pending, send.queuedKinds.Offer + send.queuedKinds.IceCandidate);
    assert.deepEqual(receive.receivedKinds, { Offer: 0, IceCandidate: 0 });
    assert.deepEqual(receive.delivered, []);
  }
  for (const [index, peer] of afterClose.entries()) {
    const target = direct[targets[index]];
    assert.deepEqual(peer.relay_peers, target ? [target.uuid] : []);
    assert.equal(peer.wire.sctp.filter(record => record.open).length, direct.length - (target ? 2 : 1));
  }

  setPhase('replacement Offers');
  await Promise.all(pairs.map(async pair => {
    pair.released = await pages[pair.offerer].evaluate(drops => window.fortressNativeWire.releaseRecovery(drops), pair.drops);
  }));
  const hasReplacement = (pair, peers) => pair.slots.every(index => !peers[index].relay_peers.length && peers[index].wire.sctp
    .some(record => record.open && record.unreliable && record.inputsSent > 0 && record.inputsReceived > 0
      && !direct[index].wire.sctp.some(link => link.index === record.index)));
  const deadline = performance.now() + 10000;
  let restored;
  do {
    restored = await observe();
    assertStableRoom(direct, restored, targets);
    const healthyProgress = assertHealthy(healthy, afterClose, restored);
    if (healthyProgress && pairs.every(pair => hasReplacement(pair, restored))) {
      const proofs = pairs.map(pair => verifyReplacement(pair, direct, restored));
      for (const peer of restored) assert.equal(peer.wire.sctp.filter(record => record.open).length, direct.length - 1);
      return { atClose, afterClose, restored, recoveryEvidence: { pairs: proofs, relayAtOffer, targets } };
    }
    await pause(25);
  } while (performance.now() < deadline);
  const missing = pairs.filter(pair => !hasReplacement(pair, restored));
  for (const pair of pairs.filter(pair => !missing.includes(pair))) verifyReplacement(pair, direct, restored);
  if (omitSecond && missing.length === 1 && missing[0] === pairs[1]) {
    assert.ok(assertHealthy(healthy, afterClose, restored), 'healthy direct gameplay must advance during isolated replacement loss');
    const { offerer, answerer } = pairs[1];
    const sent = restored[offerer].wire.recovery;
    assert.ok(sent.observed.some(event => event.attempt > 1), 'second pair must attempt a retry');
    assert.equal(sent.droppedOffers, sent.observed.length, 'second pair must drop every Offer');
    assert.deepEqual(restored[answerer].wire.recovery.delivered, [], 'second pair must receive no Offer');
    throw new OmittedReplacement(missing[0].slots);
  }
  if (missing.length) throw new Error(`replacement absent for pair ${missing.map(pair => pair.slots.join('-')).join(', ')}`);
  throw new Error('healthy direct gameplay did not advance after replacement');
}

module.exports = { assertRecoveredRoom, assertStableRoom, OmittedReplacement, PHYSICAL_PAIRS, recoverPairs };
