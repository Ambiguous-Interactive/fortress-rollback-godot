// Frame progress and final receipt frontiers have separate, bounded deadlines.
const { performance } = require('node:perf_hooks');
const GAME_MS = 240000;
const FINAL_MS = 90000;
const ROOM_MS = 480000;
const LABEL_SECONDS = 1500;

class ProgressWatchdog {
  constructor(players, started) {
    this.players = players;
    this.started = started;
    this.peers = Array.from({ length: players }, () => ({ frame: -1, changed: started, finalStarted: null, frontier: null, done: false }));
  }
  sample(index, value, now) {
    const peer = this.peers[index];
    if (!peer || !Number.isFinite(now) || now < this.started) throw new Error('invalid watchdog clock or peer');
    if (now - this.started >= GAME_MS + FINAL_MS) throw new Error('absolute gameplay/final deadline');
    if (peer.done) {
      if (value.done !== true) throw new Error('terminal completion regressed');
      return true;
    }
    if (peer.finalStarted === null) {
      if (now - this.started >= GAME_MS) throw new Error(`peer ${index} absolute gameplay deadline`);
      if (now - peer.changed >= 20000) throw new Error(`peer ${index} gameplay stalled`);
    } else {
      if (now - peer.finalStarted >= FINAL_MS) throw new Error(`peer ${index} absolute final deadline`);
      if (now - peer.changed >= 30000) throw new Error(`peer ${index} final confirmation stalled`);
    }
    if (value.done === true) { peer.done = true; return true; }
    const frame = value.frame;
    if (!Number.isInteger(frame) || frame < peer.frame || frame > 39 || frame < -1) throw new Error('invalid frame frontier');
    if (frame > peer.frame) { peer.frame = frame; peer.changed = now; }
    if (frame < 39) {
      return false;
    }
    if (peer.finalStarted === null) { peer.finalStarted = now; peer.changed = now; }
    if (value.progress !== null) {
      const progress = value.progress;
      if (!progress || !Array.isArray(progress.received) || !Array.isArray(progress.acked)
        || progress.received.length !== this.players - 1 || progress.acked.length !== this.players - 1)
        throw new Error('invalid endpoint frontier shape');
      const frontier = [progress.confirmed, ...progress.received, ...progress.acked];
      if (frontier.some(item => !Number.isInteger(item) || item < -1 || item > 39)) throw new Error('invalid endpoint frontier value');
      if (peer.frontier && frontier.some((item, slot) => item < peer.frontier[slot])) throw new Error('endpoint frontier regressed');
      if (peer.frontier && frontier.some((item, slot) => item > peer.frontier[slot])) peer.changed = now;
      peer.frontier = frontier;
    }
    return false;
  }
  deadline() {
    return Math.min(this.started + GAME_MS + FINAL_MS, ...this.peers.filter(peer => !peer.done).map(peer =>
      peer.finalStarted === null ? Math.min(this.started + GAME_MS, peer.changed + 20000)
        : Math.min(peer.finalStarted + FINAL_MS, peer.changed + 30000)));
  }
}

function boundedFrontier(progress, players) {
  if (!progress || !Array.isArray(progress.received) || !Array.isArray(progress.acked)
    || progress.received.length !== players - 1 || progress.acked.length !== players - 1) return null;
  if ([progress.confirmed, ...progress.received, ...progress.acked].some(value => !Number.isInteger(value) || value < -1 || value > 39)) return null;
  return { confirmed: progress.confirmed, received: [...progress.received], acked: [...progress.acked] };
}

async function waitGameplay(pages, clock = () => performance.now(), pause = () => new Promise(resolve => setTimeout(resolve, 250))) {
  const watchdog = new ProgressWatchdog(pages.length, clock());
  for (;;) {
    let timer;
    let snapshots;
    const evaluations = pages.map(() => null);
    const round_started_ms = clock() - watchdog.started;
    try {
      snapshots = await Promise.race([Promise.all(pages.map((page, index) => page.evaluate(() => ({
      done: document.body.dataset.fortressGameplayDone === 'true' || document.body.dataset.fortressWebrtc !== undefined,
      frame: document.body.dataset.fortressFrame === undefined ? -1 : Number(document.body.dataset.fortressFrame),
      progress: document.body.dataset.fortressProgress === undefined ? null : JSON.parse(document.body.dataset.fortressProgress),
      })).then(snapshot => {
        evaluations[index] = { elapsed_ms: clock() - watchdog.started, frame: snapshot.frame, done: snapshot.done,
          progress: boundedFrontier(snapshot.progress, pages.length) };
        return snapshot;
      }))), new Promise((resolve, reject) => {
        timer = setTimeout(() => {
          const diagnostic = { round_started_ms, elapsed_ms: clock() - watchdog.started, deadline_ms: watchdog.deadline() - watchdog.started,
            peers: watchdog.peers.map(peer => ({ frame: peer.frame, changed_ms: peer.changed - watchdog.started,
              final_ms: peer.finalStarted === null ? null : peer.finalStarted - watchdog.started, frontier: peer.frontier, done: peer.done })), evaluations };
          reject(new Error('page evaluation exceeded active progress deadline ' + JSON.stringify(diagnostic)));
        }, Math.max(0, watchdog.deadline() - clock()));
      })]);
    } finally { clearTimeout(timer); }
    const now = clock();
    const completed = snapshots.map((snapshot, index) => watchdog.sample(index, snapshot, now));
    if (completed.every(Boolean)) return;
    await pause();
  }
}

async function waitDefaultSetup(pages) {
  await Promise.all(pages.map(page => page.waitForFunction(() => document.body.dataset.fortressGameplayDone === 'true'
    || document.body.dataset.fortressWebrtc !== undefined, null, { timeout: 120000 })));
}

async function boundedRoom(operation, timeout = ROOM_MS, label = 'room') {
  let timer;
  try {
    return await Promise.race([operation(), new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`absolute ${label} deadline`)), timeout);
    })]);
  } finally { clearTimeout(timer); }
}
module.exports = { ProgressWatchdog, waitGameplay, waitDefaultSetup, boundedRoom, GAME_MS, FINAL_MS, ROOM_MS, LABEL_SECONDS };
