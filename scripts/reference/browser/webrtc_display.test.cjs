// Value: window placement must mutate only one uniquely titled owned page and reject ambiguous or unverifiable geometry.
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function placement(mutation = '', diagnostics = false) {
  const calls = [];
  const exported = { exports: {} };
  const context = {
    module: exported, process: { env: { FORTRESS_XDOTOOL_EXECUTABLE: '/owned/xdotool', DISPLAY: ':99', XAUTHORITY: '/owned/auth',
      ...(diagnostics ? { DEBUG: 'pw:browser', DEBUG_FILE: '/owned/browser.log' } : {}) } },
    require(name) {
      if (name === 'node:crypto') return { randomUUID: () => 'unique-owner' };
      assert.equal(name, 'node:child_process');
      return { execFileSync(executable, args, options) {
        assert.equal(executable, '/owned/xdotool');
        assert.equal(options.timeout, 2000);
        const environment = options.env || context.process.env;
        assert.equal(environment.DISPLAY, ':99');
        assert.equal(environment.XAUTHORITY, '/owned/auth');
        if (diagnostics) {
          assert.equal(environment.DEBUG, undefined, 'xdotool must not inherit Playwright diagnostics');
          assert.equal(environment.DEBUG_FILE, undefined);
          assert.equal(context.process.env.DEBUG, 'pw:browser', 'parent browser diagnostics remain enabled');
          assert.equal(context.process.env.DEBUG_FILE, '/owned/browser.log');
        }
        calls.push(Array.from(args));
        if (args[0] === 'search') return mutation === 'ambiguous' ? '123\n456\n' : '123\n';
        if (args[0] === 'getdisplaygeometry') {
          const screen = { small: '80 1024', screen_missing: '1280', screen_nonnumeric: 'garbage 1024',
            screen_fraction: '1280.5 1024', screen_large: '65536 1024' };
          return (screen[mutation] || '1280 1024') + '\n';
        }
        if (args[0] === 'getwindowgeometry') {
          const fields = { WINDOW: '123', X: mutation === 'position' ? '0' : '80', Y: '0', WIDTH: '1280', HEIGHT: '720', SCREEN: '0' };
          if (mutation === 'width_missing') delete fields.WIDTH;
          if (mutation === 'height_missing') delete fields.HEIGHT;
          if (mutation === 'width_nonnumeric') fields.WIDTH = 'garbage';
          if (mutation === 'height_nonnumeric') fields.HEIGHT = 'garbage';
          const afterMove = calls.some(call => call[0] === 'windowmove');
          if (mutation === 'post_width_nonnumeric' && afterMove) fields.WIDTH = 'garbage';
          if (mutation === 'post_height_missing' && afterMove) delete fields.HEIGHT;
          if (mutation === 'width_fraction') fields.WIDTH = '1280.5';
          if (mutation === 'height_large') fields.HEIGHT = '65536';
          let output = Object.entries(fields).map(([key, value]) => `${key}=${value}`).join('\n') + '\n';
          const malformed = mutation.startsWith('post_') ? (afterMove ? mutation.slice(5) : '') : mutation;
          if (malformed === 'extra_separator') output = output.replace('WIDTH=1280', 'WIDTH=1280=garbage');
          if (malformed === 'missing_separator') output += 'garbage\n';
          if (malformed === 'duplicate_key') output += 'WIDTH=1280\n';
          if (malformed === 'unknown_key') output += 'UNEXPECTED=1280\n';
          return output;
        }
        assert.deepEqual(Array.from(args), ['windowmove', '123', '80', '0']);
        return '';
      } };
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'webrtc_display.cjs'), 'utf8'), context);
  const page = { async evaluate(operation, title) {
    const document = {};
    vm.runInNewContext(`(${operation.toString()})(title)`, { document, title });
    assert.equal(document.title, 'fortress-owned-unique-owner');
  } };
  const result = exported.exports.placeFirefox(page, 1);
  if (mutation) {
    await assert.rejects(result, /window identity|display cannot|window placement/);
    if (mutation !== 'position' && !mutation.startsWith('post_')) assert.equal(calls.some(call => call[0] === 'windowmove'), false);
  } else {
    assert.equal((await result).x, 80);
    assert.deepEqual(calls[0], ['search', '--sync', '--onlyvisible', '--name', 'fortress-owned-unique-owner']);
  }
}

test('window arrangement identifies only the uniquely titled owned Firefox page', () => placement());
test('window arrangement isolates Playwright diagnostics from xdotool', () => placement('', true));
for (const mutation of ['ambiguous', 'small', 'position', 'screen_missing', 'screen_nonnumeric', 'screen_fraction', 'screen_large',
  'width_missing', 'height_missing', 'width_nonnumeric', 'height_nonnumeric', 'width_fraction', 'height_large', 'post_width_nonnumeric', 'post_height_missing',
  'extra_separator', 'missing_separator', 'duplicate_key', 'unknown_key',
  'post_extra_separator', 'post_missing_separator', 'post_duplicate_key', 'post_unknown_key'])
  test(`window arrangement rejects ${mutation} evidence`, () => placement(mutation));
