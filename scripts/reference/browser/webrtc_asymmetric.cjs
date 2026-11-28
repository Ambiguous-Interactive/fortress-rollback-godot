const { createFrameReader, traceProxyWrites } = require('./native_relay_proxy.cjs');
const { decodeRelayDelivery } = require('./native_relay_trace.cjs');

const PHASES = [{ base: 144, receiver: 0 }, { base: 192, receiver: 1 }];

function proxyRecordingSocket(upstream, socket) {
  const reader = createFrameReader();
  let held = null;
  function inlet(chunk) {
    const events = [];
    reader.push(chunk, (carrier, completion) => {
      if (!held || held.action) return;
      const delivery = decodeRelayDelivery(carrier);
      if (!delivery) return;
      const envelope = Buffer.from(delivery.envelope.buffer, delivery.envelope.byteOffset, delivery.envelope.byteLength);
      if (envelope.length < 133 || envelope.toString('ascii', 0, 4) !== 'FSR1' || envelope[63] !== 3
        || envelope.subarray(37, 53).toString('hex') !== held.recipient
        || delivery.from !== envelope.subarray(21, 37).toString('hex')
        || envelope.readInt32LE(101) + envelope.readUInt16LE(109) <= held.base) return;
      events.push({ envelope: envelope.toString('hex'), carrier: carrier.toString('hex'), ...completion });
    });
    return events;
  }
  // A blocked physical write fills this stream's budget and pauses its upstream socket.
  const beforeForward = (events, chunk) => {
    if (!held || held.action) return;
    if (held.events) throw new Error('second recording relay write began while the first was blocked');
    held.events = events;
    held.chunk = chunk.toString('hex');
    return new Promise((resolve, reject) => {
      const closed = () => reject(new Error('recording relay socket closed before release'));
      socket.once('close', closed);
      held.resume = () => {
        socket.off('close', closed);
        resolve();
      };
    });
  };
  const forwarding = traceProxyWrites(upstream, socket, inlet, beforeForward, 1);
  return {
    arm(base, recipient) {
      if (held && !held.action) throw new Error('recording relay hold already armed');
      held = { base, recipient: recipient.replaceAll('-', '') };
    },
    observed() {
      const status = reader.status();
      if (status.error || status.skipped) throw new Error('recording relay frame reader failed: ' + JSON.stringify(status));
      if (!held?.events || !upstream.isPaused() || !forwarding.writableNeedDrain) return null;
      return { paused: true, pending_bytes: forwarding.writableLength, chunk: held.chunk, events: held.events };
    },
    closeWithheld() {
      if (held?.action === 'withheld') socket.destroy();
    },
    end(action) {
      if (!held?.resume || held.action) throw new Error('recording relay hold is not pending');
      held.action = action;
      if (action === 'released') held.resume();
      // Keeping this write pending until browser teardown prevents delivery of its whole TCP chunk.
    },
  };
}

async function setPages(pages, key, base) {
  await Promise.all(pages.map(page => page.evaluate(([key, base]) => { window[key] = base; }, [key, base])));
}

async function waitPages(pages, key, base, timeout = 15000) {
  await Promise.all(pages.map(async page => {
    const ready = await page.waitForFunction(([key, base]) => document.body.dataset[key] === String(base)
      || (document.body.dataset.fortressWebrtc !== undefined && 'failed'), [key, base], { timeout });
    try {
      if (await ready.jsonValue() !== true) throw new Error('recording endpoint failed before ' + key);
    } finally { await ready.dispose(); }
  }));
}

async function runAsymmetric(pages, sockets, mode) {
  const phases = mode === 'withheld' ? PHASES.slice(0, 1) : PHASES;
  const receipts = [];
  for (const { base, receiver } of phases) {
    await waitPages(pages, 'fortressAsymmetricReady', base, 120000);
    const page = pages[receiver];
    const hold = sockets.get(receiver);
    if (!hold || sockets.size !== 2) throw new Error('recording hold lacks its two physical relay sockets');
    const uuid = await page.evaluate(() => document.body.dataset.fortressUuid);
    if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(uuid))
      throw new Error('recording hold lacks a frozen recipient identity');
    hold.arm(base, uuid);
    await setPages(pages, 'fortressAsymmetricStart', base);
    if (base === PHASES[0].base) await waitPages([page], 'fortressAsymmetricSpeculated', base);
    const deadline = performance.now() + 10000;
    let observed;
    while (performance.now() < deadline && !(observed = hold.observed()))
      await new Promise(resolve => setTimeout(resolve, 10));
    if (!observed) throw new Error('recording original inputs did not back up on the physical relay stream');
    if (base === PHASES[0].base) await setPages([page], 'fortressAsymmetricStall', base);
    await waitPages(pages, 'fortressAsymmetricHeld', base);
    const action = mode === 'withheld' ? 'withheld' : 'released';
    receipts.push({ base, receiver, action, ...observed });
    hold.end(action);
    await setPages(pages, 'fortressAsymmetricEnd', base);
    if (action === 'released') {
      await waitPages(pages, 'fortressAsymmetricRecovered', base);
      await setPages(pages, 'fortressAsymmetricContinue', base);
    }
  }
  return receipts;
}

module.exports = { proxyRecordingSocket, runAsymmetric };
