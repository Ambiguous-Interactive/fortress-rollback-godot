// Inspect the actual browser picker while production playback owns a partial cadence or selected rewind.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const requireState = (condition, message) => { if (!condition) throw new Error(message); };

async function inspectChooser(page, output, read, command, quiet) {
  const records = [];
  const initial = await read();
  requireState(initial.frame === 0 && initial.frames === 0 && !initial.failure, 'replay chooser initial control differs');
  let pickers = 0;
  const observedPicker = () => { pickers++; };
  page.on('filechooser', observedPicker);
  const choose = async () => {
    const state = await read();
    const [picker] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 15000 }),
      Promise.resolve().then(() => page.mouse.click(state.open_x, state.open_y, { delay: 100 })),
    ]);
    return picker;
  };
  for (const [mode, target] of [['ordinary', 2], ['repeat', 300]]) {
    await command('inspection_prepare', mode === 'repeat' ? 1 : 0);
    const running = await read();
    requireState(running.speed === 1 && (mode === 'repeat' ? running.seeking : running.playing),
      'replay chooser playback setup differs');
    const picker = await choose();
    // Firefox can emit the picker event before the fixture's next render publication.
    const opened = await command('observe');
    requireState(!opened.playing, 'replay chooser failed to pause playback');
    await command('service', 12);
    const inspected = await read();
    requireState(inspected.frame === target && !inspected.playing && !inspected.seeking && inspected.canonical === inspected.inspection_original,
      'replay chooser changed inspected history');
    // Empty selection closes the observed picker through the browser's file-input path.
    await picker.setFiles([]);
    await page.waitForFunction(() => window.fortressReplayImport.input === null, null, { timeout: 15000 });
    await command('service', 12);
    const canceled = await read();
    requireState(canceled.frame === target && !canceled.playing && canceled.canonical === inspected.canonical,
      'replay chooser cancellation resumed playback');
    const invalid = await choose();
    await invalid.setFiles({ name: 'invalid.frrp', mimeType: 'application/octet-stream', buffer: Buffer.from([0]) });
    await page.waitForFunction(() => window.fortressReplayDownload.message.startsWith('Could not open replay'), null, { timeout: 15000 });
    await command('service', 12);
    const rejected = await read();
    requireState(rejected.frame === target && !rejected.playing && rejected.canonical === inspected.canonical
      && rejected.source_sha256 === canceled.source_sha256, 'replay chooser rejection changed inspection');
    await command('play');
    await command('service', 3);
    const partial = await read();
    requireState(partial.frame === target && partial.playing && partial.speed === 1,
      'replay chooser resume retained fractional cadence');
    await command('service', 1);
    const resumed = await read();
    requireState(resumed.frame === target + 1 && resumed.playing && !resumed.failure,
      'replay chooser explicit resume failed');
    await command('prepare_import');
    const replacement = await choose();
    const bytes = fs.readFileSync(path.join(output, 'interior.frrp'));
    const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
    await replacement.setFiles({ name: 'interior.frrp', mimeType: 'application/octet-stream', buffer: bytes });
    await page.waitForFunction(() => window.fortressReplayDownload.import_replaced, null, { timeout: 15000 });
    await command('service', 12);
    const replaced = await read();
    requireState(replaced.frame === 0 && replaced.frames === 301 && !replaced.playing && replaced.old_retired && replaced.speed === 1 && !replaced.failure
      && replaced.source_sha256 === sha256 && replaced.source_bytes === bytes.length && replaced.canonical === initial.canonical,
      'replay chooser replacement lifetime differs');
    for (const owner of ['timeline', 'expert']) {
      await command(owner === 'timeline' ? 'hold' : 'expert');
      const held = await read();
      requireState(held.open_disabled && (owner === 'timeline' ? held.held : held.busy), 'replay chooser ownership setup differs');
      const before = pickers;
      await page.mouse.click(held.open_x, held.open_y, { delay: 100 });
      await page.waitForTimeout(100);
      requireState(pickers === before, 'replay chooser opened during owned playback');
      await command(owner === 'timeline' ? 'release' : 'retire_expert');
    }
    records.push({ mode, paused_frame: inspected.frame, resumed_frame: resumed.frame, speed: replaced.speed,
      canonical: inspected.canonical, original: inspected.inspection_original, canceled: true, rejected: true, replaced: true,
      old_retired: replaced.old_retired, held_refused: true, expert_refused: true });
    quiet();
  }
  page.off('filechooser', observedPicker);
  return records;
}

module.exports = { inspectChooser };
