// Execute the same ownership suite in a real release Web export.
const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

// Name the last completed case, its elapsed time and the case in flight.
function summarize(progress) {
  if (!progress) return null;
  const unit = progress.unit || 'unit';
  const parts = [`completed ${progress.completed}`];
  const last = progress.last_completed;
  if (last) parts.push(`last completed ${last.case} in ${last.elapsed}${unit}`);
  const executing = progress.executing;
  if (executing) parts.push(`executing ${executing.case}`);
  return parts.join('; ');
}

(async () => {
  const root = path.resolve(process.argv[2]);
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
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    try {
      await page.waitForFunction(() => document.body.dataset.fortressOwnership !== undefined, null, { timeout: 120000 });
    } catch (error) {
      // The watchdog rejected the run before the inventory could be
      // printed. Report what the page saw, so an engine or script failure
      // can be told apart from a run that was merely too slow. The
      // inventory is printed first: reading the page can fail when the
      // renderer is gone, and that failure must not hide this one.
      const detail = { stage: 'ownership-result', errors };
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
        detail.summary = summarize(detail.progress);
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
