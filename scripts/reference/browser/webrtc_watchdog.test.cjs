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

test('default factory terminal setup can take over 20s without entering the frame watchdog', async () => {
  const { waitDefaultSetup } = require('./webrtc_watchdog.cjs');
  const vm = require('node:vm');
  let now = 0;
  const page = { async waitForFunction(condition, argument, options) {
    assert.equal(argument, null);
    assert.equal(options.timeout, 120000);
    const document = { body: { dataset: {} } };
    const ready = () => vm.runInNewContext(`(${condition.toString()})()`, { document });
    assert.equal(ready(), false);
    now = 25000; // Authentication/mesh establishment is setup, with no gameplay frame yet.
    document.body.dataset.fortressGameplayDone = 'true';
    assert.equal(ready(), true);
  } };
  const oldPhase = new ProgressWatchdog(2, now);
  await waitDefaultSetup([page, page]);
  assert.throws(() => oldPhase.sample(0, { done: true }, now), /gameplay stalled/);
  const correctPhase = new ProgressWatchdog(2, now);
  assert.equal(correctPhase.sample(0, { done: true }, now), true);
});

test('actual default main orchestration waits for delayed terminal setup before starting gameplay', async () => {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  let now = 0;
  let terminalWaits = 0;
  const output = [];
  const timers = { setTimeout, clearTimeout };
  const watchdogModule = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc_watchdog.cjs'), 'utf8'), {
    module: watchdogModule, ...timers, require: name => {
      assert.equal(name, 'node:perf_hooks');
      return { performance: { now: () => now } };
    },
  });
  const fakeResult = JSON.stringify({ passed: false, failure: { stage: 'handshake', errors: ['direct_poll_3_peer_0'] } });
  const makePage = () => {
    const document = { body: { dataset: { fortressRoom: 'ROOM' } } };
    const window = { fortressRtc: {}, fortressResources: { channels: [], connections: [] } };
    const invoke = (operation, argument) => vm.runInNewContext(`(${operation.toString()})(argument)`, { document, window, argument });
    return {
      on() {}, async addInitScript() {}, async goto() {},
      async waitForFunction(operation) {
        if (invoke(operation)) return;
        // The real setup phase can require 25s, without any submitted gameplay frame.
        if (operation.toString().includes('fortressGameplayDone')) {
          terminalWaits++;
          now = 25000;
          document.body.dataset.fortressGameplayDone = 'true';
        }
        assert.equal(invoke(operation), true, 'unexpected unmet browser barrier');
      },
      async evaluate(operation, argument) {
        if (operation.toString().includes('progress:') && document.body.dataset.fortressGameplayDone !== 'true') {
          now = 25000;
          document.body.dataset.fortressGameplayDone = 'true';
        }
        const result = invoke(operation, argument);
        if (window.fortressTeardownArmed) document.body.dataset.fortressTeardownArmed = 'true';
        if (window.fortressTeardownReady) document.body.dataset.fortressWebrtc = fakeResult;
        return result;
      },
    };
  };
  const browser = { version: () => '141', async close() {}, async newContext() {
    return { async newPage() { return makePage(); }, async close() {} };
  } };
  const server = { on() {}, listen(port, host, ready) { ready(); }, address() { return { port: 123 }; }, close() {} };
  const mainModule = { exports: {} };
  const fakeRequire = name => {
    if (name === './webrtc_watchdog.cjs') return watchdogModule.exports;
    if (name === 'fake-playwright') return { chromium: { async launch() { return browser; } } };
    if (name === 'node:https') return { createServer() { return server; } };
    if (name === 'node:fs') return { readFileSync() { return ''; } };
    return require(name);
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc.cjs'), 'utf8') + '\nmodule.exports.main = main;', {
    module: mainModule, require: fakeRequire, ...timers,
    process: { argv: ['node', 'probe', '/export', 'ws://127.0.0.1:1/v3/ws', 'default'], env: { FORTRESS_PLAYWRIGHT_PACKAGE: 'fake-playwright' } },
    console: { log(value) { output.push(value); }, error() {} },
  });
  await mainModule.exports.main();
  assert.equal(terminalWaits, 2);
  assert.equal(JSON.parse(output.at(-1)).passed, true);
});
