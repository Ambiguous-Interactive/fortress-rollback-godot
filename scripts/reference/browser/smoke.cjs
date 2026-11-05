// Run an actual exported Godot page; a HTTP 200 alone cannot satisfy this smoke.
const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const { inspect } = require('node:util');
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
  const failures=[];
  try {
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.FORTRESS_CHROMIUM_EXECUTABLE,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    });
    const page = await browser.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await page.waitForFunction(() => document.body.dataset.fortressBaseline === '78563412', null, { timeout: 60000 });
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({ browser: 'Chromium', version: browser.version(), marker: '78563412', errors }));
  } catch(error) {failures.push(error);} finally {
    try {if(browser) await browser.close();} catch(error) {failures.push(error);}
    try {await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));} catch(error) {failures.push(error);}
  }
  if(failures.length) throw failures.length===1?failures[0]:new AggregateError(failures,'browser smoke and cleanup failed');
})().catch(error => {
  process.exitCode=1;
  try {console.error(inspect(error,{customInspect:false,getters:false,depth:8}));} catch {console.error('Browser probe failed; diagnostic unavailable.');}
});
