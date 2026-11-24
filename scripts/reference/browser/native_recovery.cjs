'use strict';

const assert = require('node:assert/strict');

function reciprocalPair(peers, exclude = []) {
  const [left, right] = peers;
  const eligible = (record, index) => record.open && record.unreliable && record.local && record.remote
    && record.index !== exclude[index]?.index;
  const matches = left.wire.sctp.filter(record => eligible(record, 0)).flatMap(a => right.wire.sctp
    .filter(b => eligible(b, 1) && a.local === b.remote && a.remote === b.local).map(b => [a, b]));
  assert.equal(matches.length, 1, 'the two pages must have exactly one reciprocal open unreliable pair');
  return matches[0];
}

function assertStableRoom(direct, peers) {
  for (const [index, peer] of peers.entries()) {
    const before = direct[index];
    assert.equal(peer.state, 'playing', peer.message);
    assert.ok(peer.started_on_full_mesh);
    const counterpart = index < 2 ? direct[1 - index].uuid.replaceAll('-', '') : null;
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

async function recoverPair(direct, { pages, wait, observe, command, pause, setPhase }) {
  const pair = direct.slice(0, 2);
  const old = reciprocalPair(pair);
  const allHealthy = direct.map((peer, index) => peer.wire.sctp.filter(record => record.index !== old[index]?.index));
  for (const peer of direct) {
    assert.equal(peer.plan_events, 1);
    assert.ok(peer.room_id && peer.room_id === peer.sdk_room_id);
    assert.ok(peer.plan.generation && peer.plan.generation === pair[0].plan.generation);
    assert.equal(Object.keys(peer.sdk_epochs).length, direct.length);
    assert.ok(Object.values(peer.sdk_epochs).every(epoch => Number.isSafeInteger(epoch) && epoch >= 0));
    assert.equal(peer.wire.sctp.length, direct.length - 1);
  }
  const initiators = pair.map((peer, index) => peer.plan.peers.find(plan => plan.player_id === pair[1 - index].uuid)?.initiate);
  assert.deepEqual([...initiators].sort(), [false, true]);
  const offerer = initiators.indexOf(true);
  const answerer = 1 - offerer;
  await Promise.all(pair.map((peer, index) => pages[index].evaluate(scope => window.fortressNativeWire.observeRecovery(scope), {
    room: peer.room_id, generation: peer.plan.generation, peer: pair[1 - index].uuid,
    localEpoch: peer.sdk_epochs[peer.uuid], peerEpoch: peer.sdk_epochs[pair[1 - index].uuid], holdsOffer: index === offerer,
  })));
  setPhase('physical channel close');
  await command(pages[0], 'close_link', { uuid: pair[1].uuid });
  const atClose = await observe();
  assert.equal(atClose[0].closed_channel_state, 1, 'fault must close an open channel');
  const addressedInputs = (peer, index) => {
    const counterparty = pair[1 - index].uuid.replaceAll('-', '');
    return [peer.wire.relayInputRecipients[counterparty] ?? 0, peer.wire.relayInputSenders[counterparty] ?? 0];
  };
  let relayAtOffer;
  const afterClose = await (async () => {
    const deadline = performance.now() + 7000;
    while (performance.now() < deadline) {
      const peers = await observe();
      const offer = peers[offerer].wire.recovery;
      if (offer.held && !relayAtOffer) {
        // Observe the hold first, then sample every affected page while it is still held.
        const duringHold = await observe(pages.slice(0, 2));
        relayAtOffer = duringHold.map(addressedInputs);
        continue;
      }
      if (!relayAtOffer || offer.queuedKinds.IceCandidate === 0) {
        await pause(25);
        continue;
      }
      const fallbackObserved = peers.every((peer, index) => {
        const target = pair[1 - index]?.uuid;
        const mid = peer.wire.sctp;
        return (index >= 2 || (peer.relay_peers.includes(target) && mid.find(record => record.index === old[index].index)?.closed
          && addressedInputs(peer, index).every((count, direction) => count > relayAtOffer[index][direction])))
          && peer.confirmed > atClose[index].confirmed
          && allHealthy[index].every(record => {
            const now = mid.find(link => link.index === record.index);
            const atFault = atClose[index].wire.sctp.find(link => link.index === record.index);
            return now?.open && now.inputsSent > atFault.inputsSent && now.inputsReceived > atFault.inputsReceived;
          });
      });
      if (fallbackObserved) return peers;
      await pause(25);
    }
    throw new Error('the held attempt did not leave enough time for addressed relay gameplay and healthy direct progress');
  })();
  assertStableRoom(direct, afterClose);
  const send = afterClose[offerer].wire.recovery;
  assert.deepEqual(send.observed.map(event => event.attempt), [1]);
  assert.equal(send.held.attempt, 1);
  assert.equal(send.queuedKinds.Offer, 1);
  assert.ok(send.queuedKinds.IceCandidate > 0 && !send.released);
  assert.equal(send.pending, send.queuedKinds.Offer + send.queuedKinds.IceCandidate);
  assert.deepEqual(afterClose[answerer].wire.recovery.receivedKinds, { Offer: 0, IceCandidate: 0 });
  assert.deepEqual(afterClose[answerer].wire.recovery.delivered, []);
  for (const [index, peer] of afterClose.entries()) {
    const affected = index < 2;
    const target = affected ? pair[1 - index].uuid : null;
    assert.deepEqual(peer.relay_peers, affected ? [target] : []);
    assert.equal(peer.wire.sctp.filter(record => record.open).length, direct.length - (affected ? 2 : 1));
  }
  setPhase('replacement Offer release');
  const released = await pages[offerer].evaluate(() => window.fortressNativeWire.releaseRecovery());
  assert.ok(released >= send.pending);
  await Promise.all(pair.map((_, index) => wait(pages[index], oldIndex => {
    const { relay_peers, state } = window.fortressNative;
    return state === 'playing' && !relay_peers.length && window.fortressNativeWire.status().sctp
      .some(channel => channel.index > oldIndex && channel.open && channel.unreliable && channel.inputsSent > 0 && channel.inputsReceived > 0);
  }, Math.max(...direct[index].wire.sctp.map(record => record.index)), 10000)));
  const restored = await observe();
  assertStableRoom(direct, restored);
  const replacement = reciprocalPair(restored.slice(0, 2), old);
  const held = restored[offerer].wire.recovery.held;
  assert.deepEqual(restored[offerer].wire.recovery.observed.map(event => event.attempt), [1]);
  const received = restored[answerer].wire.recovery;
  assert.equal(received.pending, 0, 'answerer signaling must pass through');
  const queued = restored[offerer].wire.recovery.queuedKinds;
  assert.equal(released, queued.Offer + queued.IceCandidate);
  assert.equal(received.receivedKinds.Offer, 1);
  assert.ok(received.receivedKinds.IceCandidate >= queued.IceCandidate);
  const offers = received.delivered;
  assert.equal(offers.length, 1);
  const { at_ms: delivered_at, ...receivedOffer } = offers[0];
  const { at_ms: held_at, ...sentOffer } = held;
  assert.deepEqual(receivedOffer, sentOffer, 'the real server delivered the exact held envelope');
  assert.ok(restored[offerer].wire.recovery.released > held_at && delivered_at > 0);
  assert.equal(replacement[offerer].local, held.body.match(/^a=ice-ufrag:([\w+/]+)\r?$/m)?.[1]);
  for (const [index, record] of replacement.entries()) {
    assert.notEqual(record.local, old[index].local, 'replacement uses a fresh local ICE credential');
    assert.notEqual(record.remote, old[index].remote, 'replacement uses a fresh remote ICE credential');
    assert.ok(record.inputsSent > 0 && record.inputsReceived > 0);
    const closed = restored[index].wire.sctp.find(link => link.index === old[index].index);
    assert.ok(closed?.closed && closed.connectionClosed, 'old physical channel and connection must both retire');
  }
  for (const [index, peer] of restored.entries()) {
    assert.equal(peer.wire.sctp.length, direct[index].wire.sctp.length + (index < 2 ? 1 : 0));
    assert.equal(peer.wire.sctp.filter(record => record.open).length, direct.length - 1);
    assert.deepEqual(peer.relay_peers, []);
    for (const link of allHealthy[index]) {
      const now = peer.wire.sctp.find(record => record.index === link.index);
      const during = afterClose[index].wire.sctp.find(record => record.index === link.index);
      assert.equal(now.local, link.local);
      assert.equal(now.remote, link.remote);
      assert.equal(now.closeEvents, 0, 'the original unaffected channel must never emit a close event');
      assert.ok(now.open && now.inputsSent > during.inputsSent && now.inputsReceived > during.inputsReceived);
    }
  }
  return { atClose, afterClose, restored, recoveryEvidence: { offerer, answerer, old, replacement, released, relayAtOffer } };
}

module.exports = { assertStableRoom, recoverPair };
