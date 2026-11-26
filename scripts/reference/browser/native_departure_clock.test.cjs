const assert = require('node:assert/strict');
const test = require('node:test');
const { setTimeout: pause } = require('node:timers/promises');
const { clockExchangeWindow, createDepartureClock } = require('./native_departure_clock.cjs');
const { closeEvidence, waitForCloseProofs } = require('./native_online.cjs');

test('a bounded HTTPS clock sample uses only matching, ordered micros', () => {
  const host = { receivedUs: 1300, writeUs: 1400 };
  const page = { nonce: 'current', status: 204, sentUs: 1000, receivedUs: 1140 };
  assert.deepEqual(clockExchangeWindow('current', host, page), { offsetMin: 219, offsetMax: 341 });
  for (const badPage of [
    { ...page, nonce: 'earlier' }, { ...page, status: 200 }, { ...page, sentUs: 1150 },
    { ...page, sentUs: -1 }, { ...page, receivedUs: '1140' }, { ...page, receivedUs: 1001 },
  ]) assert.equal(clockExchangeWindow('current', host, badPage), null);
  assert.equal(clockExchangeWindow('current', null, page), null);
  assert.equal(clockExchangeWindow('current', { ...host, writeUs: 1200 }, page), null);
  assert.deepEqual(clockExchangeWindow('current', host, { ...page, requestUs: 1020, responseUs: 1120 }), { offsetMin: 239, offsetMax: 321 });
  assert.deepEqual(clockExchangeWindow('current', host, { ...page, requestUs: 1120, responseUs: 1020 }), { offsetMin: 219, offsetMax: 341 });
});

test('the host serves each active clock URL once and retires failed or expired exchanges', async () => {
  let now = 1;
  const { handle, sample } = createDepartureClock(() => now);
  function request(method, url) {
    let status, headers;
    const accepted = handle({ method, url }, { writeHead(code, values) { status = code; headers = values; }, end() {} });
    return { accepted, status, headers };
  }
  assert.equal(request('GET', '/index.html').accepted, false);
  assert.equal(request('GET', '/native-departure-clock/unknown').status, 404);
  const page = { async evaluate(_fn, { path, nonce }) {
    assert.equal(request('POST', path).status, 404);
    assert.equal(request('GET', path + '?wrong').status, 404);
    const response = request('GET', path);
    assert.equal(response.status, 204);
    assert.equal(response.headers['X-Fortress-Clock-Nonce'], nonce);
    assert.equal(response.headers['Cache-Control'], 'no-store');
    assert.equal(request('GET', path).status, 404);
    now = 1.1;
    return { nonce, status: 204, sentUs: 700, receivedUs: 800 };
  }};
  assert.deepEqual((await sample(page, 100)).bound, { offsetMin: 159, offsetMax: 341 });

  let abandonedPath;
  const abandoned = { async evaluate(_fn, { path }) {
    abandonedPath = path;
    return new Promise(() => {});
  }};
  const missing = await sample(abandoned, 3);
  assert.equal(missing.bound, null);
  assert.match(missing.error, /deadline/);
  assert.equal(request('GET', abandonedPath).status, 404);
  const invalid = await sample({ async evaluate() { return { status: 204, nonce: 'wrong', sentUs: 700, receivedUs: 800 }; } }, 100);
  assert.equal(invalid.bound, null);
  assert.match(invalid.error, /invalid/);
});

test('an HTTPS sample cannot establish a WebKit close below the causal margin', async () => {
  const before = { index: 17, local: 'sender', remote: 'closer', closed: false, closeAborts: 0 };
  const reciprocal = { index: 4, local: 'closer', remote: 'sender', closed: true, connectionClosed: true, closedAt: 5000 };
  const warning = { index: 1, channel: 17, attempt: 3 };
  const receipt = { attempt: 3, channel: 17, sentAt: 7080 };
  const ambiguous = [{ offsetMin: -200, offsetMax: 200 }, { offsetMin: -200, offsetMax: 200 }];
  const tight = [{ offsetMin: 0, offsetMax: 40 }, { offsetMin: -40, offsetMax: 0 }];
  const snapshot = { links: [[reciprocal], [before]], sampled: [0, 0] };
  assert.equal(closeEvidence(warning, [before], snapshot.links, null, ambiguous, receipt).proof, null);
  assert.equal(closeEvidence(warning, [before], snapshot.links, null, tight, { ...receipt, sentAt: 6999 }).proof, null);
  const pages = snapshot.links.map((links, index) => ({ evaluate: async () => ({ links, sampledAt: snapshot.sampled[index], sends: { 3: receipt } }) }));
  const report = { clocks: ambiguous };
  const httpsClock = { sample: async (page) => ({ bound: tight[pages.indexOf(page)] }) };
  await waitForCloseProofs(pages, [{ wire: { sctp: [] } }, { wire: { sctp: [before] } }], [warning], report, {
    clock: () => 0, delay: () => pause(0), httpsClock,
  });
  assert.equal(report.proofs[0].proof, 'clock-order');
  assert.equal(report.proofs[0].minimumGapUs, 2000);
  assert.deepEqual(report.httpsClockSamples.map(sample => sample.after.length), [1, 1]);
});

test('optional HTTPS cannot spend the deadline for a fresh abort snapshot', async () => {
  let now = 0;
  let rounds = 0;
  const sender = { index: 17, local: 'sender', remote: 'closer', closed: false, closeAborts: 0 };
  const closer = { index: 4, local: 'closer', remote: 'sender', closed: true, connectionClosed: true, closedAt: 5000 };
  const before = [{ wire: { sctp: [] } }, { wire: { sctp: [sender] } }];
  const pages = [{ async evaluate() {
    if (++rounds === 1) now = 4900;
    return { links: [closer], sampledAt: null, sends: {} };
  } }, { async evaluate() {
    return { links: [{ ...sender, closeAborts: rounds > 1 ? 1 : 0 }], sampledAt: null,
      sends: { 3: { attempt: 3, channel: 17, sentAt: 7000 } } };
  } }];
  const report = {};
  const httpsClock = { async sample() { await pause(10); now = 5100; return { bound: null, error: 'unavailable' }; } };
  await waitForCloseProofs(pages, before, [{ index: 1, channel: 17, attempt: 3 }], report, {
    clock: () => now, delay: async ms => { now += ms; }, httpsClock,
  });
  assert.equal(rounds, 2);
  assert.equal(report.proofs[0].proof, 'sctp-abort');
});

test('only a room-issued exact HTTPS fetch belongs to its original page after timeout', async () => {
  const origin = 'https://127.0.0.1:8765';
  const clock = createDepartureClock();
  const other = {};
  const paths = [];
  const owner = { async evaluate(_fn, { path }) { paths.push(path); return new Promise(() => {}); } };
  const makeRequest = (url, method = 'GET', type = 'fetch') => ({ url: () => url, method: () => method, resourceType: () => type });
  for (let i = 0; i < 3; i++) assert.match((await clock.sample(owner, 1)).error, /deadline/);
  const url = origin + paths[0];
  assert.equal(clock.ownsRequest(owner, origin, makeRequest(url)), true);
  for (const [page, request] of [
    [other, makeRequest(url)], [owner, makeRequest(url + '?extra')], [owner, makeRequest(url + '#fragment')],
    [owner, makeRequest(url.replace('8765', '8766'))], [owner, makeRequest(url.replace('https:', 'http:'))],
    [owner, makeRequest(url, 'POST')], [owner, makeRequest(url, 'GET', 'document')],
    [owner, makeRequest(origin + '/native-departure-clock/not-issued')], [owner, makeRequest(origin + '/native-release/not-a-clock')],
  ]) assert.equal(clock.ownsRequest(page, origin, request), false);
  assert.match((await clock.sample(owner, 1)).error, /limit/);
  assert.equal(paths.length, 3);
  assert.equal(clock.ownsRequest(owner, origin, makeRequest(url)), true);
});

test('a rejecting mandatory snapshot retains already settled optional HTTPS diagnostics', async () => {
  const sender = { index: 17, local: 'sender', remote: 'closer', closed: false, closeAborts: 0 };
  const closer = { index: 4, local: 'closer', remote: 'sender', closed: true, connectionClosed: true, closedAt: 5000 };
  const before = [{ wire: { sctp: [] } }, { wire: { sctp: [sender] } }];
  const warnings = [3, 4].map(attempt => ({ index: 1, channel: 17, attempt }));
  const sends = { 3: { attempt: 3, channel: 17, sentAt: 8000 }, 4: { attempt: 4, channel: 17, sentAt: 7080 } };
  const tight = { offsetMin: 0, offsetMax: 0 };
  const late = Promise.withResolvers();
  let rounds = 0;
  const pages = [{ async evaluate() {
    if (++rounds > 1) throw new Error('mandatory close snapshot failed');
    return { links: [closer], sampledAt: 0, sends: {} };
  } }, { async evaluate() { return { links: [sender], sampledAt: 0, sends }; } }];
  const report = { clocks: [{ offsetMin: -200, offsetMax: 200 }, { offsetMin: -200, offsetMax: 200 }] };
  const httpsClock = { sample: async page => page === pages[0] ? { bound: tight } : late.promise };
  await assert.rejects(waitForCloseProofs(pages, before, warnings, report, {
    clock: () => 0, delay: () => pause(0), httpsClock,
  }), /WebKit close snapshots failed/);
  assert.equal(rounds, 2);
  assert.deepEqual(report.httpsClockSamples.map(page => page.after), [[{ bound: tight }], []]);
  assert.deepEqual(report.lastCompleteProofs.map(proof => [proof.attempt, proof.proof]), [[3, 'clock-order']]);
  assert.equal(report.proofs[1].proof, null);
  assert.deepEqual(report.clocks, [{ offsetMin: -41, offsetMax: 41 }, { offsetMin: -41, offsetMax: 41 }]);
  const frozen = structuredClone(report);
  late.resolve({ bound: tight });
  await pause(0);
  assert.deepEqual(report, frozen, 'late optional publication must leave the terminal report unchanged');
});
