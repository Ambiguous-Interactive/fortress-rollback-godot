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

// Value: a timer firing fractionally early must rearm; a hung page still expires at the exact deadline.
test('an unresponsive page evaluation expires only after the real progress deadline', async () => {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  for (const early of [19999.75, 19999.999]) {
    let now = 0;
    let callback;
    let delay;
    let outcome;
    let failure;
    const loaded = { exports: {} };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc_watchdog.cjs'), 'utf8'), {
      module: loaded, require: () => ({ performance: { now: () => now } }),
      setTimeout(operation, milliseconds) { callback = operation; delay = milliseconds; return 1; }, clearTimeout() {},
    });
    const never = { evaluate: () => new Promise(() => {}) };
    const running = loaded.exports.waitGameplay([never, never], () => now).then(
      () => { outcome = 'fulfilled'; }, error => { outcome = 'rejected'; failure = error; });
    now = early;
    callback();
    for (let turn = 0; turn < 8; turn++) await Promise.resolve();
    assert.equal(outcome, undefined, 'a fractional early callback must not reject gameplay');
    assert.equal(delay, 1, 'the remaining fractional wait is rounded up');
    now = 20000;
    callback();
    await running;
    assert.equal(outcome, 'rejected');
    assert.match(failure.message, /page evaluation exceeded active progress deadline/);
    const diagnostic = JSON.parse(failure.message.slice(failure.message.indexOf('{')));
    assert.equal(diagnostic.deadline_ms, 20000);
    assert.equal(diagnostic.elapsed_ms, 20000);
    assert.deepEqual([...diagnostic.peers].map(peer => peer.frame), [-1, -1]);
    assert.deepEqual([...diagnostic.evaluations], [null, null]);
  }
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
    const window = { fortressRtc: {}, fortressResources: { channels: [], connections: [] }, fortressSockets: [] };
    const invoke = (operation, argument) => vm.runInNewContext(`(${operation.toString()})(argument)`, { document, window, argument, WebSocket: { CLOSED: 3 } });
    return {
      on() {}, async addInitScript() {}, async goto() {},
      async waitForFunction(operation, argument) {
        if (invoke(operation, argument)) return;
        // The real setup phase can require 25s, without any submitted gameplay frame.
        if (operation.toString().includes('fortressGameplayDone')) {
          terminalWaits++;
          now = 25000;
          document.body.dataset.fortressGameplayDone = 'true';
        }
        assert.equal(invoke(operation, argument), true, 'unexpected unmet browser barrier');
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


test('observation diagnostic retains only bounded current-round frontiers from completed siblings', async () => {
  await assert.rejects(scheduledGameplay((index, round, later) => {
    if (index === 1 || round > 1) return new Promise(() => {});
    return later({ frame: 39, done: false,
      progress: { confirmed: 37, received: [38], acked: [37], arbitrary_history: 'ignored' } }, 19999);
  }), error => {
    const diagnostic = JSON.parse(error.message.slice(error.message.indexOf('{')));
    assert.deepEqual(diagnostic.evaluations[0].progress, { confirmed: 37, received: [38], acked: [37] });
    assert.equal(diagnostic.evaluations[1], null);
    assert.deepEqual(diagnostic.peers.map(peer => peer.frame), [39, -1]);
    assert.deepEqual(diagnostic.peers[0].frontier, [37, 38, 37]);
    assert.equal(typeof diagnostic.round_started_ms, 'number');
    return true;
  });
});

// Value: protects=timely per-page progress; fails_when=batch sampling delays evidence; why_new=earlier controls test watchdog alone; seam=none.
async function scheduledGameplay(observe, pauseTimes = null) {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  let now = 0;
  let nextId = 0;
  let pumping = false;
  const timers = new Map();
  function pump() {
    pumping = false;
    const pending = [...timers].sort((left, right) => left[1].at - right[1].at);
    if (!pending.length) return;
    const [id, timer] = pending[0];
    timers.delete(id);
    now = timer.at;
    timer.callback();
    if (timers.size && !pumping) { pumping = true; setImmediate(pump); }
  }
  function schedule(callback, delay) {
    const id = ++nextId;
    timers.set(id, { callback, at: now + delay });
    if (!pumping) { pumping = true; setImmediate(pump); }
    return id;
  }
  const loaded = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc_watchdog.cjs'), 'utf8'), {
    module: loaded, require: () => ({ performance: { now: () => now } }),
    setTimeout: schedule, clearTimeout: id => timers.delete(id),
  });
  const rounds = [0, 0];
  const pages = rounds.map((unused, index) => ({ evaluate() {
    return observe(index, ++rounds[index], (value, delay) => new Promise(resolve => schedule(() => resolve(value), delay)), () => now);
  } }));
  try {
    const pause = pauseTimes === null ? undefined : index => new Promise(resolve => {
      const target = pauseTimes[rounds[index] - 1];
      if (target === undefined) return;
      schedule(resolve, Math.max(0, target - now));
    });
    await loaded.exports.waitGameplay(pages, () => now, pause);
    return { now, rounds };
  } finally { timers.clear(); }
}
const observed = (frame, done = false, progress = null) => ({ frame, done, progress });

test('actual sampler applies timely frame progress before a slower sibling evaluation', async () => {
  const result = await scheduledGameplay((index, round, later) => {
    if (round === 1) return Promise.resolve(observed(0));
    if (round === 2) return Promise.resolve(observed(index));
    if (round === 3) return index === 0 ? Promise.resolve(observed(1)) : later(observed(2, true), 10000);
    return Promise.resolve(observed(index + 1, true));
  }, [10000, 15000, 25000]);
  assert.equal(result.now, 25000);
});

test('actual sampler extends final-frontier progress independently of a slower sibling', async () => {
  const result = await scheduledGameplay((index, round, later) => {
    if (round === 1) return Promise.resolve(snapshot(39, 37, 37));
    if (round === 2) return Promise.resolve(snapshot(39, 37 + index, 37));
    if (round === 3) return index === 0 ? Promise.resolve(snapshot(39, 38, 37)) : later(observed(39, true), 10000);
    return Promise.resolve(observed(39, true));
  }, [10000, 25000, 35000]);
  assert.equal(result.now, 35000);
});

test('actual sampler retires timely completed peer while a sibling keeps its later deadline', async () => {
  const result = await scheduledGameplay((index, round, later) => {
    if (round === 1) return Promise.resolve(observed(0));
    if (round === 2) return Promise.resolve(observed(index));
    return index === 0 ? Promise.resolve(observed(1, true)) : later(observed(2, true), 10000);
  }, [10000, 15000]);
  assert.equal(result.now, 25000);
});

test('actual sampler cannot extend a frozen sibling with another peer progress', async () => {
  await assert.rejects(scheduledGameplay((index, round) => {
    if (round === 1) return Promise.resolve(observed(0));
    if (round === 2) return Promise.resolve(observed(index));
    return index === 0 ? Promise.resolve(observed(1)) : new Promise(() => {});
  }, [10000, 15000]), error => {
    assert.match(error.message, /page evaluation exceeded active progress deadline/);
    const detail = JSON.parse(error.message.slice(error.message.indexOf('{')));
    assert.equal(detail.elapsed_ms, 30000);
    assert.equal(detail.deadline_ms, 30000);
    assert.equal(detail.peers[0].changed_ms, 15000);
    assert.equal(detail.peers[1].changed_ms, 10000);
    assert.equal(detail.evaluations[1], null);
    return true;
  });
});

test('actual sampler rejects exact expired per-page progress and completion before applying them', async () => {
  for (const final of [false, true]) for (const done of [false, true]) {
    const limit = final ? 30000 : 20000;
    await assert.rejects(scheduledGameplay((index, round) => {
      if (round === 1) return Promise.resolve(final ? snapshot(39, 37, 37) : observed(0));
      return Promise.resolve(final ? { ...snapshot(39, 38, 38), done } : observed(1, done));
    }, [limit]), error => {
      assert.match(error.message, final ? /final confirmation stalled/ : /gameplay stalled/);
      const detail = JSON.parse(error.message.slice(error.message.indexOf('{')));
      assert.equal(detail.deadline_ms, limit);
      assert.equal(detail.elapsed_ms, limit);
      assert.equal(detail.attempts[0].completed_ms, limit);
      assert.equal(detail.evaluations[0].elapsed_ms, limit);
      assert.equal(detail.last_samples[0].elapsed_ms, 0);
      assert.equal(detail.peers[0].done, false);
      assert.equal(detail.round_started_ms, limit);
      assert.equal(detail.evaluations.filter((value, index) => value !== null
        && JSON.stringify(value) !== JSON.stringify(detail.last_samples[index])).length, 1);
      return true;
    });
  }
});

test('actual sampler rejects a completed peer regressing on a subsequent round', async () => {
  await assert.rejects(scheduledGameplay((index, round) => {
    if (round === 1) return Promise.resolve(observed(0, index === 0));
    return Promise.resolve(observed(1, index === 1));
  }, [1000]), /terminal completion regressed/);
});

test('actual sampler preserves gameplay and final absolute caps despite timely independent progress', async () => {
  for (const final of [false, true]) {
    const step = final ? 10000 : 6000;
    const count = final ? 9 : 40;
    await assert.rejects(scheduledGameplay((index, round) => Promise.resolve(
      final ? snapshot(39, 37, round - 2) : observed(round - 2)
    ), Array.from({ length: count }, (unused, index) => (index + 1) * step)),
    final ? /absolute final deadline/ : /absolute gameplay deadline/);
  }
});

// Value: protects=no sampling after failure; fails_when=rejection awaits finally to deactivate; why_new=earlier timers have no same-turn completions; seam=none.
test('actual sampler stops same-turn sibling callbacks at every rejection boundary', async () => {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  for (const boundary of ['timer', 'evaluation', 'validation', 'pause']) {
    let now = 0;
    let timer;
    let armed = 0;
    const loaded = { exports: {} };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc_watchdog.cjs'), 'utf8'), {
      module: loaded, require: () => ({ performance: { now: () => now } }),
      setTimeout(callback) { armed++; timer = callback; return armed; }, clearTimeout() {},
    });
    const samples = [];
    const original = loaded.exports.ProgressWatchdog.prototype.sample;
    loaded.exports.ProgressWatchdog.prototype.sample = function(index, value, at) {
      samples.push({ index, at });
      return original.call(this, index, value, at);
    };
    const controls = [];
    const rounds = [0, 0];
    const pages = [0, 1].map(index => ({ evaluate() {
      const round = ++rounds[index];
      if (round === 1) return Promise.resolve(observed(0));
      if (round === 2) return Promise.resolve(observed(index));
      return new Promise((resolve, reject) => { controls[index] = { resolve, reject }; });
    } }));
    let pauses = 0;
    const running = loaded.exports.waitGameplay(pages, () => now, index => {
      now = ++pauses === 1 ? 10000 : 15000;
      if (boundary === 'pause' && index === 0 && rounds[index] === 2)
        return new Promise((resolve, reject) => { controls[index] = { resolve, reject }; });
      return Promise.resolve();
    });
    for (let turn = 0; turn < 20 && !controls[1]; turn++) await Promise.resolve();
    assert.equal(rounds[1], 3);
    // Peer 0 changed at 0; peer 1 changed at 10000 and remains live until 30000.
    now = boundary === 'timer' ? 20000 : 15000;
    const before = armed;
    samples.length = 0;
    if (boundary === 'timer') timer();
    else if (boundary === 'evaluation' || boundary === 'pause') controls[0].reject(new Error(`${boundary} failed`));
    else controls[0].resolve(observed(999));
    // Queue its success immediately after the failing operation, before the async finally resumes.
    controls[1].resolve(observed(1));
    await assert.rejects(running, boundary === 'timer' ? /page evaluation exceeded active progress deadline/
      : boundary === 'evaluation' ? /evaluation failed/ : boundary === 'pause' ? /pause failed/ : /invalid frame frontier/);
    await Promise.resolve();
    assert.equal(armed, before, `${boundary} failure must not rearm timers`);
    assert.deepEqual(samples, boundary === 'validation' ? [{ index: 0, at: 15000 }] : [],
      `${boundary} failure must not sample its late sibling`);
  }
});

// Value: protects=independent repeated observations; fails_when=slow evaluation blocks healthy sibling polling; why_new=earlier controls advance once per batch; seam=none.
test('actual sampler keeps observing healthy progress while one sibling evaluation takes almost its full deadline', async () => {
  const inflight = [0, 0];
  const result = await scheduledGameplay((index, round, later, clock) => {
    assert.equal(inflight[index], 0, 'only one evaluation per page may be in flight');
    inflight[index]++;
    const value = index === 0 ? Promise.resolve(observed(Math.floor(clock() / 1000), clock() >= 19000))
      : round === 1 ? Promise.resolve(observed(0)) : later(observed(1, true), 19900 - clock());
    return value.finally(() => { inflight[index]--; });
  });
  assert.equal(result.now, 19900);
  assert.ok(result.rounds[0] > 70, 'fast peer must be repeatedly observed while its sibling is pending');
  assert.equal(result.rounds[1], 2);
});

test('continuous observation deadline remains armed while all peers are between attempts', async () => {
  await assert.rejects(scheduledGameplay((index, round) => Promise.resolve(observed(0)), [19900, 20150]), error => {
    assert.match(error.message, /page evaluation exceeded active progress deadline/);
    const detail = JSON.parse(error.message.slice(error.message.indexOf('{')));
    assert.equal(detail.elapsed_ms, 20000);
    assert.equal(detail.deadline_ms, 20000);
    assert.deepEqual(detail.attempts, [{ started_ms: 19900, completed_ms: 19900 }, { started_ms: 19900, completed_ms: 19900 }]);
    assert.equal(detail.round_started_ms, detail.elapsed_ms);
    assert.deepEqual(detail.last_samples.map(sample => sample.elapsed_ms), [19900, 19900]);
    return true;
  });
});

test('diagnostic keeps bounded gameplay frontiers and completed clocks when a later observation hangs', async () => {
  await assert.rejects(scheduledGameplay((index, round) => round === 1 ? Promise.resolve({ ...snapshot(0), arbitrary_history: 'ignored' })
    : new Promise(() => {}), [1000]), error => {
    const detail = JSON.parse(error.message.slice(error.message.indexOf('{')));
    assert.equal(detail.elapsed_ms, 20000);
    assert.deepEqual(detail.evaluations, [null, null]);
    assert.deepEqual(detail.attempts, [{ started_ms: 1000, completed_ms: null }, { started_ms: 1000, completed_ms: null }]);
    assert.deepEqual(detail.last_samples, [0, 1].map(() => ({ elapsed_ms: 0, frame: 0, done: false,
      progress: { confirmed: 37, received: [38], acked: [37] } })));
    assert.deepEqual(detail.peers.map(peer => peer.frontier), [null, null], 'gameplay gossip must not become accepted progress');
    return true;
  });
});

// Value: protects=failure wins over queued terminal success; fails_when=pause rejection waits for outer catch; why_new=other boundaries never complete all peers; seam=none.
test('a rejected completed-peer pause prevents same-turn sibling success from accepting the room', async () => {
  const { waitGameplay } = require('./webrtc_watchdog.cjs');
  let rejectPause;
  let resolveSibling;
  let siblingCalls = 0;
  const pages = [{ evaluate: async () => observed(0, true) }, { evaluate() {
    return ++siblingCalls === 1 ? Promise.resolve(observed(0)) : new Promise(resolve => { resolveSibling = resolve; });
  } }];
  const running = waitGameplay(pages, () => 0, index => index === 0
    ? new Promise((resolve, reject) => { rejectPause = reject; }) : Promise.resolve());
  for (let turn = 0; turn < 20 && !resolveSibling; turn++) await Promise.resolve();
  assert.equal(typeof resolveSibling, 'function');
  rejectPause(new Error('completed-peer pause failed'));
  resolveSibling(observed(1, true));
  await assert.rejects(running, /completed-peer pause failed/);
});

// Value: queue-wrap recording uses the existing deadlines without treating frame39 as final.
test('long recording frame frontier preserves the same absolute gameplay deadline', () => {
  const watchdog = new ProgressWatchdog(2, 0, 256);
  watchdog.sample(0, { done: false, frame: 39, progress: null }, 1);
  assert.equal(watchdog.peers[0].finalStarted, null);
  watchdog.sample(0, { done: false, frame: 255, progress: null }, 2);
  assert.equal(watchdog.peers[0].finalStarted, null);
  watchdog.sample(0, { done: false, frame: 256, progress: { confirmed: 255, received: [256], acked: [255] } }, 3);
  assert.equal(watchdog.peers[0].finalStarted, 3);
  assert.throws(() => watchdog.sample(0, { done: false, frame: 257, progress: null }, 4), /frame frontier/);
  assert.throws(() => new ProgressWatchdog(2, 0, 1000), /final frame/);
});
