// Execute a bounded ownership suite batch in a real release Web export.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

(async () => {
  if (![4, 5].includes(process.argv.length) || !process.argv[2]) throw new Error('expected export root, JSON suite batch and optional exact case');
  let suites;
  try { suites = JSON.parse(process.argv[3]); } catch { throw new Error('suite batch must be a JSON array'); }
  if (!Array.isArray(suites) || suites.length < 1 || suites.length > 4 ||
      suites.some(suite => typeof suite !== 'string' || !/^res:\/\/tests\/(unit|determinism)\/test_[a-z0-9_]+\.gd$/.test(suite)) ||
      new Set(suites).size !== suites.length) {
    throw new Error('suite batch must contain 1..4 unique canonical res://tests suite paths');
  }
  const caseName = process.argv.length === 5 ? process.argv[4] : null;
  if (caseName !== null && (suites.length !== 1 || !/^[a-z][a-z0-9_]*$/.test(caseName))) {
    throw new Error('exact case requires one suite and a canonical case name');
  }
  const root = path.resolve(process.argv[2]);
  if (!fs.statSync(root).isDirectory()) throw new Error('export root must be an existing directory');
  const selected = process.env.FORTRESS_OWNERSHIP_BROWSER || 'chromium';
  if (!['chromium', 'firefox'].includes(selected)) throw new Error('unsupported ownership browser');
  const executable = process.env[`FORTRESS_${selected.toUpperCase()}_EXECUTABLE`];
  if (!executable) throw new Error('ownership browser needs a verified executable');
  const engines = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const { placeFirefox } = require('./webrtc_display.cjs');
  const preferences = { 'webgl.force-enabled': true, 'webgl.disabled': false };
  const errors = [];
  const server = http.createServer((request, response) => {
    const relative = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const filename = path.resolve(root, '.' + relative);
    if (!filename.startsWith(root + path.sep)) { response.writeHead(403); response.end(); return; }
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    const mime = { '.wasm': 'application/wasm', '.js': 'application/javascript', '.html': 'text/html' };
    response.setHeader('Content-Type', mime[path.extname(filename)] || 'application/octet-stream');
    fs.readFile(filename, (error, data) => { response.writeHead(error ? 404 : 200); response.end(error ? '' : data); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await engines[selected].launch(selected === 'chromium' ? {
      headless: true, executablePath: executable,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    } : { headless: false, executablePath: executable, firefoxUserPrefs: preferences });
    const page = await browser.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    const url = new URL(`http://127.0.0.1:${server.address().port}/index.html`);
    for (const suite of suites) url.searchParams.append('suite', suite);
    if (caseName !== null) url.searchParams.append('case', caseName);
    await page.goto(url.toString());
    const display = selected === 'firefox' ? await placeFirefox(page, 0) : null;
    try {
      // Each batch keeps the existing page budget on bounded CI runners.
      await page.waitForFunction(() => document.body.dataset.fortressOwnership !== undefined, null, { timeout: 180000 });
    } catch (error) {
      // The watchdog rejected the run before the inventory could be
      // printed. Report what the page saw, so an engine or script failure
      // can be told apart from a run that was merely too slow. The
      // inventory is printed first: reading the page can fail when the
      // renderer is gone, and that failure must not hide this one.
      const detail = { stage: 'ownership-result', suites, errors };
      if (caseName !== null) detail.case = caseName;
      console.error(JSON.stringify(detail));
      try {
        detail.reported = await page.evaluate(() => document.body.dataset.fortressOwnership !== undefined);
      } catch (page_error) {
        detail.reported = null;
        detail.page_error = String(page_error).slice(0, 200);
      }
      // The page publishes the case that was executing, the number of
      // completed cases and the time the last completed case took, so a
      // rejected run names where it stopped and how long it took.
      try {
        const progress = await page.evaluate(() => document.body.dataset.fortressOwnershipProgress);
        detail.progress = progress === undefined ? null : JSON.parse(progress);
      } catch (progress_error) {
        detail.progress = null;
        detail.progress_error = String(progress_error).slice(0, 200);
      }
      console.error(JSON.stringify(detail));
      throw error;
    }
    if (errors.length) throw new Error(JSON.stringify(errors));
    const result = await page.evaluate(() => JSON.parse(document.body.dataset.fortressOwnership));
    const observation = { browser: selected === 'chromium' ? 'Chromium' : 'Firefox', version: browser.version(), result, errors };
    if (selected === 'firefox') Object.assign(observation, { firefox_preferences: preferences, display });
    console.log(JSON.stringify(observation));
  } finally {
    if (browser) await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
