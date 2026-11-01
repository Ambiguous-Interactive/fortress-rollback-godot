// Receive actual trusted-click downloads and reopen their bytes through the production file picker.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const requireState = (condition, message) => { if (!condition) throw new Error(message); };

async function replayDownloads(page, url, output, errors, onLoaded = async () => null) {
  fs.mkdirSync(output, { recursive: true });
  const records = [];
  let total = 0;
  let forbidden = 0;
  let allowance = null;
  let received = null;
  page.on('download', download => {
    total++;
    if (allowance !== null && download.suggestedFilename() === allowance && received === null) {
      allowance = null;
      received = download;
    } else forbidden++;
  });
  const read = () => page.evaluate(() => window.fortressReplayDownload);
  const command = (name, value = 0) => page.evaluate(arg => window.fortressReplayDownloadCommand(arg.name, arg.value), { name, value });
  const wait = expression => page.waitForFunction(expression, null, { timeout: 30000 });
  const quiet = () => requireState(errors.length === 0 && forbidden === 0, 'replay download forbidden events observed');
  await page.goto(url);
  const display = await onLoaded();
  await wait(() => window.fortressReplayDownload?.case === 'interior' && !window.fortressReplayDownload.disabled);
  for (const [index, name, frame] of [[0, 'interior', 301], [1, 'terminal', 610], [2, 'initial', 0]]) {
    await command('select', index);
    await page.waitForFunction(value => window.fortressReplayDownload?.case === value && !window.fortressReplayDownload.disabled,
      name, { timeout: 30000 });
    const before = await read();
    requireState(before.frame === frame && before.frames === 610 && before.canonical === before.original && !before.failure,
      'replay download original boundary differs');
    quiet();
    received = null;
    allowance = before.filename;
    const event = page.waitForEvent('download', { timeout: 15000, predicate: download => download === received });
    await page.mouse.click(before.x, before.y, { delay: 100 });
    const download = await event;
    const destination = path.join(output, name + '.frrp');
    await download.saveAs(destination);
    const bytes = fs.readFileSync(destination);
    requireState(bytes.length > 0 && bytes.equals(Buffer.from(before.expected, 'base64')), 'received replay download bytes differ');
    const sha256 = digest(bytes);
    requireState(download.suggestedFilename() === before.filename, 'received replay download filename differs');
    // Keep the controls disabled across real pointer clicks; no allowance is armed here.
    await command('seek');
    await wait(() => window.fortressReplayDownload.seeking && window.fortressReplayDownload.disabled);
    const seeking = await read();
    await page.mouse.click(seeking.x, seeking.y, { delay: 100 });
    await page.waitForTimeout(100);
    quiet();
    await command('cancel');
    await command('hold');
    await wait(() => window.fortressReplayDownload.held && window.fortressReplayDownload.disabled);
    const held = await read();
    await page.mouse.click(held.x, held.y, { delay: 100 });
    await page.waitForTimeout(100);
    quiet();
    await command('release');
    // Always replace the original 610-frame source before observing the imported ending.
    // In the full-ending case the digest is equal, so the retained old player must also be retired.
    await command('select', index === 1 ? 0 : 1);
    await page.waitForFunction(value => window.fortressReplayDownload?.case === value,
      index === 1 ? 'interior' : 'terminal', { timeout: 30000 });
    await command('prepare_import');
    const original = await read();
    const chooser = page.waitForEvent('filechooser', { timeout: 15000 });
    await page.mouse.click(original.open_x, original.open_y, { delay: 100 });
    const picker = await chooser;
    const payload = process.env.FORTRESS_REPLAY_DOWNLOAD_CONTROL === 'reject-reimport' ? Buffer.from([0]) : bytes;
    await picker.setFiles({ name: before.filename, mimeType: 'application/octet-stream', buffer: payload });
    await page.waitForFunction(value => {
      const state = window.fortressReplayDownload;
      return state && (state.import_replaced || state.message.startsWith('Could not open replay'));
    }, sha256, { timeout: 15000 });
    const imported = await read();
    requireState(imported.import_replaced && imported.source_sha256 === sha256 && imported.frames === frame && imported.source_bytes === bytes.length,
      'received replay download replacement refused');
    // Successful import restarts at zero. The source identity gate above prevents old playback satisfying this check.
    requireState(imported.frame === 0 && !imported.failure, 'received replay download did not restart');
    await command('verify_import');
    await wait(() => window.fortressReplayDownload.statuses_checked);
    requireState((await read()).statuses_valid, 'received replay download statuses differ');
    await page.evaluate(value => window.fortressReplayDownloadCommand('navigate', value), frame);
    await page.waitForFunction(value => window.fortressReplayDownload.frame === value && !window.fortressReplayDownload.seeking,
      frame, { timeout: 15000 });
    const reopened = await read();
    requireState(reopened.statuses_valid && reopened.disconnected_rows === Math.max(0, frame - 17),
      'received replay download statuses differ');
    requireState(reopened.canonical === before.original && reopened.canonical.length > 0 && !reopened.failure,
      'received replay download canonical playback differs');
    await page.screenshot({ path: path.join(output, name + '.png') });
    records.push({ case: name, frame: reopened.frame, frames: reopened.frames, bytes: bytes.length, sha256,
      filename: before.filename, canonical: reopened.canonical, original: before.original,
      replaced: true, disconnected_rows: reopened.disconnected_rows, seek_disabled: seeking.disabled, held_disabled: held.disabled });
    quiet();
  }
  if (process.env.FORTRESS_REPLAY_DOWNLOAD_CONTROL === 'late-error') await page.evaluate(() => console.error('late replay download control'));
  if (process.env.FORTRESS_REPLAY_DOWNLOAD_CONTROL === 'late-download') {
    const event = page.waitForEvent('download', { timeout: 15000 });
    await page.evaluate(() => {
      const link = document.createElement('a');
      link.href = 'data:application/octet-stream;base64,AQ=='; link.download = 'forbidden.frrp';
      link.textContent = 'forbidden'; link.style = 'position:fixed;top:0;left:0;z-index:2147483647;background:white';
      document.body.appendChild(link);
    });
    await page.locator('a[download="forbidden.frrp"]').click({ force: true });
    await event;
  }
  await page.waitForTimeout(100);
  quiet();
  requireState(total === 3 && allowance === null && received !== null, 'replay download event inventory differs');
  return { display, result: { cases: records, download_events: total, forbidden_events: forbidden, errors },
    verify: () => { quiet(); requireState(total === 3, 'replay download late event observed'); } };
}

module.exports = { replayDownloads };
