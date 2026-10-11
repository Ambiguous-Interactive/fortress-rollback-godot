// Value: a slow advancing workload passes; independent stalled peers and unbounded work fail.
const assert = require('node:assert/strict');
const test = require('node:test');
const { ProgressWatchdog, ROOM_MS, LABEL_SECONDS } = require('./webrtc_watchdog.cjs');
const snapshot = (frame, received = 38, acked = 37) => ({ frame, done: false,
  progress: { confirmed: 37, received: [received], acked: [acked] } });

test('forty slow advancing frames exceed the old aggregate cutoff but finish inside bounded phases', () => {
  const watch = new ProgressWatchdog(2, 0);
  for (let frame = 0; frame < 40; frame++) {
    const now = frame * 4000;
    for (let peer = 0; peer < 2; peer++) assert.equal(watch.sample(peer, snapshot(frame), now), false);
  }
  assert.ok(39 * 4000 > 120000); // The previous whole-gameplay wait rejects this useful work.
  for (let peer = 0; peer < 2; peer++) {
    assert.equal(watch.sample(peer, snapshot(39, 39, 38), 180000), false);
    assert.equal(watch.sample(peer, { done: true }, 185000), true);
  }
});

test('frozen frames, tokens, stage changes and packet heartbeats do not extend gameplay', () => {
  const watch = new ProgressWatchdog(2, 0);
  watch.sample(0, snapshot(0), 0);
  for (let now = 1000; now < 20000; now += 1000)
    watch.sample(0, { ...snapshot(0), token: now, stage: `stage-${now}`, packets: now }, now);
  assert.throws(() => watch.sample(0, snapshot(0), 20000), /gameplay stalled/);
});

test('one advancing peer cannot shelter another stalled peer', () => {
  const watch = new ProgressWatchdog(2, 0);
  watch.sample(1, snapshot(0), 0);
  for (let frame = 0; frame < 20; frame++) watch.sample(0, snapshot(frame), frame * 1000);
  assert.throws(() => watch.sample(1, snapshot(0), 20000), /peer 1 gameplay stalled/);
});

test('only monotonic confirmed and endpoint frontiers extend final completion', () => {
  const watch = new ProgressWatchdog(2, 0);
  watch.sample(0, snapshot(39), 0);
  watch.sample(0, snapshot(39, 39), 25000);
  assert.throws(() => watch.sample(0, { ...snapshot(39, 39), token: 'fresh', heartbeat: 555 }, 55000), /final confirmation stalled/);
  assert.throws(() => watch.sample(0, snapshot(39, 38), 26000), /frontier regressed/);
});

test('absolute caps reject continual frame and final frontier progress', () => {
  const gameplay = new ProgressWatchdog(2, 0);
  for (let frame = 0; frame < 25; frame++) gameplay.sample(0, snapshot(frame), frame * 9000);
  assert.throws(() => gameplay.sample(0, snapshot(25), 240000), /absolute gameplay deadline/);
  const final = new ProgressWatchdog(2, 0);
  for (let acked = -1; acked < 8; acked++) final.sample(0, snapshot(39, 38, acked), (acked + 1) * 10000);
  assert.throws(() => final.sample(0, snapshot(39, 39, 8), 90000), /absolute final deadline/);
  assert.equal(LABEL_SECONDS * 1000, 3 * ROOM_MS + 60000);
});

test('invalid, missing and arbitrary dictionary frontiers cannot claim final progress', () => {
  const watch = new ProgressWatchdog(2, 0);
  watch.sample(0, { frame: 39, done: false, progress: null }, 0);
  assert.throws(() => watch.sample(0, { frame: 39, done: false, progress: null }, 30000), /final confirmation stalled/);
  assert.throws(() => watch.sample(0, { ...snapshot(39), progress: { heartbeat: 1 } }, 1), /frontier shape/);
  assert.throws(() => watch.sample(0, { ...snapshot(39), progress: { received: [NaN], acked: [38], confirmed: 38 } }, 1), /frontier value/);
});

test('exact expired boundaries reject late frame transitions, final completion and fresh progress', () => {
  const idle = new ProgressWatchdog(2, 0);
  idle.sample(0, snapshot(0), 0);
  assert.throws(() => idle.sample(0, snapshot(1), 20000), /gameplay stalled/);
  const game = new ProgressWatchdog(2, 0);
  for (let frame = 0; frame < 39; frame++) game.sample(0, snapshot(frame), frame * 6000);
  game.sample(0, snapshot(38), 239000);
  assert.throws(() => game.sample(0, snapshot(39), 240000), /absolute gameplay deadline/);
  const final = new ProgressWatchdog(2, 0);
  for (let acked = -1; acked < 8; acked++) final.sample(0, snapshot(39, 38, acked), (acked + 1) * 10000);
  assert.throws(() => final.sample(0, { done: true }, 90000), /absolute final deadline/);
  const finalIdle = new ProgressWatchdog(2, 0);
  finalIdle.sample(0, snapshot(39), 0);
  assert.throws(() => finalIdle.sample(0, { done: true }, 30000), /final confirmation stalled/);
});

test('an unresponsive page evaluation cannot suppress the independent progress deadline', async () => {
  const { waitGameplay } = require('./webrtc_watchdog.cjs');
  let readings = 0;
  const clock = () => readings++ === 0 ? 0 : 19999;
  const never = { evaluate: () => new Promise(() => {}) };
  await assert.rejects(waitGameplay([never, never], clock), /page evaluation exceeded active progress deadline/);
});
