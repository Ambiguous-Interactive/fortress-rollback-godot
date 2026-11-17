// Minimal real-browser launch witness for the devcontainer capability (#385).
//
// Launches the pinned browser named in argv[2] ("chromium" or "firefox")
// through the pinned Playwright package at FORTRESS_PLAYWRIGHT_PACKAGE, using
// the executable recorded by the post-create acquisition, drives one real
// page evaluation, and prints a JSON identity line. Chromium launches
// headless with the same software-GL arguments the reference smoke uses;
// Firefox launches headed because the caller runs it under xvfb-run. Any
// launch, evaluation or cleanup failure exits nonzero with the diagnostic.
const MARKER = 'fortress-browser-witness';

const kind = process.argv[2];
if (kind !== 'chromium' && kind !== 'firefox') {
  console.error(`unknown witness browser: ${kind === undefined ? '<none>' : kind} (expected chromium or firefox)`);
  process.exit(2);
}
const playwrightPackage = process.env.FORTRESS_PLAYWRIGHT_PACKAGE;
if (!playwrightPackage) {
  console.error('FORTRESS_PLAYWRIGHT_PACKAGE is not recorded; run the post-create acquisition');
  process.exit(2);
}
const executable = kind === 'firefox'
  ? process.env.FORTRESS_FIREFOX_EXECUTABLE
  : process.env.FORTRESS_CHROMIUM_EXECUTABLE;
if (!executable) {
  console.error(`${kind} executable is not recorded; run the post-create acquisition`);
  process.exit(2);
}
const { chromium, firefox } = require(playwrightPackage);
const { inspect } = require('node:util');

(async () => {
  const launcher = kind === 'firefox' ? firefox : chromium;
  const failures = [];
  let browser;
  let page;
  let identity;
  try {
    browser = await launcher.launch({
      headless: kind !== 'firefox',
      executablePath: executable,
      args: kind === 'chromium'
        ? ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']
        : [],
    });
    page = await browser.newPage();
    const evaluated = await page.evaluate(marker => {
      document.body.textContent = marker;
      return document.body.textContent;
    }, MARKER);
    if (evaluated !== MARKER) throw new Error(`page evaluation returned ${JSON.stringify(evaluated)}`);
    identity = JSON.stringify({ browser: kind, version: browser.version(), marker: evaluated });
  } catch (error) {
    failures.push(error);
  } finally {
    try { if (page) await page.close(); } catch (error) { failures.push(error); }
    try { if (browser) await browser.close(); } catch (error) { failures.push(error); }
  }
  if (failures.length) {
    throw failures.length === 1 ? failures[0] : new AggregateError(failures, 'browser witness and cleanup failed');
  }
  console.log(identity);
})().catch(error => {
  process.exitCode = 1;
  try { console.error(inspect(error, { customInspect: false, getters: false, depth: 8 })); } catch { console.error('Browser witness failed; diagnostic unavailable.'); }
});
