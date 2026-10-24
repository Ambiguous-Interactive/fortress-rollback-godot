// Execute a bounded ownership suite batch in a real release Web export.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

(async () => {
  if (process.argv.length !== 4 || !process.argv[2]) throw new Error('expected export root and JSON suite batch');
  let suites;
  try { suites = JSON.parse(process.argv[3]); } catch { throw new Error('suite batch must be a JSON array'); }
  if (!Array.isArray(suites) || suites.length < 1 || suites.length > 4 ||
      suites.some(suite => typeof suite !== 'string' || !/^res:\/\/tests\/(unit|determinism)\/test_[a-z0-9_]+\.gd$/.test(suite)) ||
      new Set(suites).size !== suites.length) {
    throw new Error('suite batch must contain 1..4 unique canonical res://tests suite paths');
  }
  const root = path.resolve(process.argv[2]);
  if (!fs.statSync(root).isDirectory()) throw new Error('export root must be an existing directory');
  const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
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
    browser = await chromium.launch({
      headless: true, executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    });
    const page = await browser.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    const url = new URL(`http://127.0.0.1:${server.address().port}/index.html`);
    for (const suite of suites) url.searchParams.append('suite', suite);
    await page.goto(url.toString());
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
    console.log(JSON.stringify({ browser: 'Chromium', version: browser.version(), result, errors }));
  } finally {
    if (browser) await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
