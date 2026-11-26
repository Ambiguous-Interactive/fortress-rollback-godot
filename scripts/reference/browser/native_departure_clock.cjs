const { randomUUID } = require('node:crypto');
const { boundedRoom } = require('./webrtc_watchdog.cjs');

const PATH_PREFIX = '/native-departure-clock/';
const NONCE_HEADER = 'X-Fortress-Clock-Nonce';
const CLOCK_PRECISION_US = 41;

function micros(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function clockExchangeWindow(nonce, host, page) {
  if (typeof nonce !== 'string' || !nonce || !page || page.nonce !== nonce || page.status !== 204
    || !micros(page.sentUs) || !micros(page.receivedUs) || page.receivedUs < page.sentUs
    || !micros(host?.receivedUs) || !micros(host.writeUs) || host.writeUs < host.receivedUs) return null;
  const { requestUs, responseUs } = page;
  // Prefer the network boundaries when the same nonce has a complete resource entry.
  const resource = micros(requestUs) && micros(responseUs) && page.sentUs <= requestUs && requestUs <= responseUs && responseUs <= page.receivedUs;
  const sent = resource ? requestUs : page.sentUs;
  const received = resource ? responseUs : page.receivedUs;
  // All transport delay is non-negative. Allow for two coarsened browser clock reads and integer rounding.
  const offsetMin = host.writeUs - received - CLOCK_PRECISION_US;
  const offsetMax = host.receivedUs - sent + CLOCK_PRECISION_US;
  return Number.isSafeInteger(offsetMin) && Number.isSafeInteger(offsetMax) && offsetMin <= offsetMax ? { offsetMin, offsetMax } : null;
}

async function fetchClock({ path, nonceHeader }) {
  if (!window.crossOriginIsolated) return null;
  const url = new URL(path, location.href).href;
  const sentUs = Math.round(performance.now() * 1000);
  const response = await fetch(url, { cache: 'no-store', redirect: 'error' });
  const receivedUs = Math.round(performance.now() * 1000);
  if (response.url !== url) return null;
  const entry = performance.getEntriesByName(url, 'resource').find(entry => entry.initiatorType === 'fetch');
  return { nonce: response.headers.get(nonceHeader), status: response.status, sentUs, receivedUs,
    requestUs: entry?.requestStart ? Math.round(entry.requestStart * 1000) : null,
    responseUs: entry?.responseEnd ? Math.round(entry.responseEnd * 1000) : null };
}

function createDepartureClock(clock = () => performance.now()) {
  const pending = new Map();
  return {
    handle(request, response) {
      if (!request.url.startsWith(PATH_PREFIX)) return false;
      const receivedUs = Math.round(clock() * 1000);
      const entry = pending.get(request.url);
      if (request.method !== 'GET' || !entry || entry.host) {
        response.writeHead(404);
        response.end();
        return true;
      }
      entry.host = { receivedUs, writeUs: Math.round(clock() * 1000) };
      response.writeHead(204, { 'Cache-Control': 'no-store', [NONCE_HEADER]: entry.nonce });
      response.end();
      return true;
    },
    async sample(page, timeout) {
      const nonce = randomUUID();
      const path = PATH_PREFIX + nonce;
      const entry = { nonce, host: null, page: null, bound: null };
      const deadline = clock() + timeout;
      pending.set(path, entry);
      try {
        entry.page = await boundedRoom(() => page.evaluate(fetchClock, { path, nonce, nonceHeader: NONCE_HEADER }), timeout, 'native HTTPS clock');
        if (clock() >= deadline) throw new Error('absolute native HTTPS clock deadline');
        entry.bound = clockExchangeWindow(nonce, entry.host, entry.page);
        if (!entry.bound) throw new Error('invalid native HTTPS clock exchange');
      } catch (error) {
        entry.error = String(error);
      } finally {
        pending.delete(path);
      }
      return entry;
    },
  };
}

module.exports = { clockExchangeWindow, createDepartureClock };
