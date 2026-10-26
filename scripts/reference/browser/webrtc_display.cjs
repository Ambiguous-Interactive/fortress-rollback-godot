// Keep owned Firefox windows partly visible so the X11 WebGL compositor can service each client.
const { execFileSync } = require('node:child_process');
const { randomUUID } = require('node:crypto');

async function placeFirefox(page, index) {
  const title = 'fortress-owned-' + randomUUID();
  await page.evaluate(value => { document.title = value; }, title);
  const environment = { ...process.env };
  delete environment.DEBUG;
  delete environment.DEBUG_FILE;
  const execute = args => execFileSync(process.env.FORTRESS_XDOTOOL_EXECUTABLE, args, { encoding: 'utf8', timeout: 2000, env: environment }).trim();
  const windows = execute(['search', '--sync', '--onlyvisible', '--name', title]).split('\n');
  if (windows.length !== 1 || !/^\d+$/.test(windows[0])) throw new Error('owned Firefox window identity is ambiguous');
  const integer = (value, minimum, maximum) => typeof value === 'string' && /^-?\d+$/.test(value)
    && Number.isSafeInteger(Number(value)) && Number(value) >= minimum && Number(value) <= maximum;
  const x = 80 * index;
  const screen = execute(['getdisplaygeometry']).split(/\s+/);
  if (!Number.isSafeInteger(index) || index < 0 || x > 32767 || screen.length !== 2
      || !screen.every(value => integer(value, 1, 65535)) || Number(screen[0]) <= x)
    throw new Error('display cannot show every Firefox client');
  const geometry = () => {
    // Accept exactly xdotool's six shell fields; reject unknown, duplicate or malformed rows.
    const fields = {};
    const keys = ['WINDOW', 'X', 'Y', 'WIDTH', 'HEIGHT', 'SCREEN'];
    for (const row of execute(['getwindowgeometry', '--shell', windows[0]]).split('\n')) {
      const parts = row.split('=');
      if (parts.length !== 2 || !keys.includes(parts[0]) || Object.hasOwn(fields, parts[0]))
        throw new Error('owned Firefox window placement failed: malformed geometry');
      fields[parts[0]] = parts[1];
    }
    if (Object.keys(fields).length !== keys.length || fields.WINDOW !== windows[0] || !integer(fields.SCREEN, 0, 65535)
        || !integer(fields.X, -32768, 32767) || !integer(fields.Y, -32768, 32767)
        || !integer(fields.WIDTH, 81, 65535) || !integer(fields.HEIGHT, 1, 65535))
      throw new Error('owned Firefox window placement failed: invalid geometry');
    return { x: Number(fields.X), y: Number(fields.Y), width: Number(fields.WIDTH), height: Number(fields.HEIGHT) };
  };
  geometry();
  execute(['windowmove', windows[0], String(x), '0']);
  const placed = geometry();
  if (placed.x !== x || placed.y !== 0) throw new Error('owned Firefox window placement failed');
  return { ...placed, screen_width: Number(screen[0]), screen_height: Number(screen[1]) };
}

module.exports = { placeFirefox };
