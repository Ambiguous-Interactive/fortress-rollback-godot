// Run the exported viewer with only its own control capability in an isolated context.
const fs = require('node:fs');
const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
(async () => {
  const runtime = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:process.env.FORTRESS_CHROMIUM_EXECUTABLE,
    args:['--no-sandbox','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  const watchdog = setTimeout(async () => {try {await browser.close();} finally {process.exitCode=1;}},70000);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
    await page.addInitScript(data => {
      window.fortressSpectatorRuntime=data;
      window.fortressSpectatorSockets=[];
      window.WebSocket=new Proxy(window.WebSocket,{construct(target,args,newTarget) {
        const socket=Reflect.construct(target,args,newTarget); window.fortressSpectatorSockets.push(socket); return socket;
      }});
    },
      {endpoint:runtime.endpoint, control:runtime.control, viewer_token:runtime.viewer_token});
    await page.goto(process.argv[2] + '/index.html');
    await page.waitForFunction(() => window.fortressSpectatorResult !== undefined, null, {timeout:60000});
    const result = await page.evaluate(() => window.fortressSpectatorResult);
    const state = await page.evaluate(() => window.fortressSpectatorState);
    await page.waitForFunction(() => window.fortressSpectatorSockets.length>0 && window.fortressSpectatorSockets.every(socket => socket.readyState===3),null,{timeout:5000});
    process.stdout.write(JSON.stringify({browser:'Chromium',version:browser.version(),result,state,errors}));
    if (errors.length || result.passed !== true) process.exitCode=1;
  } finally {clearTimeout(watchdog);await browser.close();}
})().catch(error => {console.error(error);process.exitCode=1;});
