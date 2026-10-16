// Development hosting only; installed Godot projects need no Node.js dependency.
const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const net = require('node:net');

async function createHost(root, endpoint, certificate, privateKey, port = 0) {
  root = path.resolve(root);
  const backend = new URL(endpoint);
  if (backend.protocol !== 'ws:' || backend.hostname !== '127.0.0.1' || !backend.port)
    throw new Error('upstream must be ws://127.0.0.1:PORT/v3/ws');
  const server = https.createServer({ cert: fs.readFileSync(certificate),
    key: fs.readFileSync(privateKey) }, (request, response) => {
    let filename;
    try { filename = path.resolve(root, '.' + decodeURIComponent(new URL(request.url, 'http://localhost').pathname)); }
    catch { response.writeHead(400); response.end(); return; }
    if (!filename.startsWith(root + path.sep)) { response.writeHead(403); response.end(); return; }
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    response.setHeader('Content-Type', { '.wasm': 'application/wasm', '.js': 'application/javascript', '.html': 'text/html' }[path.extname(filename)]
      || 'application/octet-stream');
    fs.readFile(filename, (error, bytes) => { response.writeHead(error ? 404 : 200); response.end(error ? '' : bytes); });
  });
  const proxyPairs = new Set();
  const proxy = { refuseUpgrades: false, refusedUpgrades: 0 };
  server.on('upgrade', (request, socket, head) => {
    if (proxy.refuseUpgrades) { proxy.refusedUpgrades++; socket.destroy(); return; }
    const backend = new URL(endpoint);
    const upstream = net.connect(Number(backend.port), '127.0.0.1', () => {
      let headers = `${request.method} ${backend.pathname} HTTP/${request.httpVersion}\r\n`;
      for (let index = 0; index < request.rawHeaders.length; index += 2)
        headers += `${request.rawHeaders[index]}: ${request.rawHeaders[index + 1]}\r\n`;
      upstream.write(headers + '\r\n');
      if (head.length) upstream.write(head);
      upstream.pipe(socket); socket.pipe(upstream);
    });
    const pair = { socket, upstream };
    proxyPairs.add(pair);
    upstream.on('close', () => { socket.destroy(); proxyPairs.delete(pair); });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return { server, proxyPairs, proxy };
}

module.exports = { createHost };
if (require.main === module) {
  const [root, endpoint, certificate, privateKey, port = '8443'] = process.argv.slice(2);
  if (!root || !endpoint || !certificate || !privateKey || !/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
    console.error('Usage: node online_host.cjs EXPORT_DIR ws://127.0.0.1:PORT/v3/ws CERT KEY [HTTPS_PORT]');
    process.exitCode = 1;
  } else {
    createHost(root, endpoint, certificate, privateKey, Number(port)).then(({ server }) => {
      console.log(`Open https://127.0.0.1:${server.address().port}/index.html`);
      console.log(`SignalFish endpoint: wss://127.0.0.1:${server.address().port}/v3/ws`);
    }).catch(error => { console.error(String(error)); process.exitCode = 1; });
  }
}
