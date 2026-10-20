// Execute the same ownership suite in a real release Web export.
const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

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
      // can be told apart from a run that was merely too slow.
      const detail = { stage: 'ownership-result', errors, reported: await page.evaluate(
        () => document.body.dataset.fortressOwnership !== undefined) };
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
