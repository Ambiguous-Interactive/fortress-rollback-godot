// Run the exported viewer with only its own control capability in an isolated context.
const fs = require('node:fs');
const REQUEST_FAILURE_LIMIT=32;
const REQUEST_TEXT_LIMIT=256;
const PHASES=new Set(['startup','navigation','departure','result','state','socket-drain','final']);
function readRequest(request,name) {
  try {return request[name]();} catch {return undefined;}
}
function requestFailure(request,phase) {
  let origin='unknown',path='unknown',failure='unknown';
  const raw=readRequest(request,'url');
  if(typeof raw==='string' && raw.length<=4096) {
    try {
      const url=new URL(raw);
      if(['http:','https:','ws:','wss:'].includes(url.protocol)) {
        origin=url.origin.slice(0,REQUEST_TEXT_LIMIT);
        path=url.pathname.slice(0,REQUEST_TEXT_LIMIT);
      }
    } catch {}
  }
  const method=readRequest(request,'method'),resource=readRequest(request,'resourceType');
  try {
    const text=readRequest(request,'failure')?.errorText;
    if(typeof text==='string' && /^(?:net::ERR_[A-Z0-9_]{1,64}|NS_(?:BINDING|ERROR)_[A-Z0-9_]{1,64})$/.test(text)) failure=text;
  } catch {}
  let observedPhase='unknown';
  try {const value=phase();if(PHASES.has(value)) observedPhase=value;} catch {}
  return {origin,path,method:['GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','CONNECT','TRACE'].includes(method)?method:'unknown',
    resourceType:['document','stylesheet','image','media','font','script','texttrack','xhr','fetch','eventsource','websocket','manifest','other']
      .includes(resource)?resource:'unknown',
    failure,phase:observedPhase};
}
function observeErrors(page,errors,isTearingDown,diagnostics) {
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
  page.on('requestfailed', request => {
    if(isTearingDown()) return;
    errors.push('browser request failed');
    // Diagnostic access must never bypass the original fatal observation.
    try {
      if(Array.isArray(diagnostics?.requestFailures) && diagnostics.requestFailures.length<REQUEST_FAILURE_LIMIT) {
        diagnostics.requestFailures.push(requestFailure(request,diagnostics.phase));
      }
    } catch {}
  });
}
module.exports={observeErrors};
async function run() {
  const { chromium } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
  const runtime = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:process.env.FORTRESS_CHROMIUM_EXECUTABLE,
    args:['--no-sandbox','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  let tearingDown=false,phase='startup',result,state,departureClosed=false,published=false,version='unknown';
  let operationFailed=false,operationError;
  const errors=[],requestFailures=[];
  const publish=failedPhase=>{
    if(published) return;
    const report={browser:'Chromium',version,result,state,errors,requestFailures,departureClosed};
    if(failedPhase) report.runnerFailurePhase=failedPhase;
    const output=JSON.stringify(report);
    published=true;
    process.stdout.write(output);
  };
  const watchdog = setTimeout(async () => {try {tearingDown=true;await browser.close();} finally {process.exitCode=1;}},70000);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    observeErrors(page,errors,()=>tearingDown,{requestFailures,phase:()=>phase});
    await page.addInitScript(data => {
      window.fortressSpectatorRuntime=data;
      window.fortressSpectatorSockets=[];
      window.WebSocket=new Proxy(window.WebSocket,{construct(target,args,newTarget) {
        const socket=Reflect.construct(target,args,newTarget); window.fortressSpectatorSockets.push(socket); return socket;
      }});
    },
      {endpoint:runtime.endpoint, control:runtime.control, viewer_token:runtime.viewer_token,browser_fault:runtime.browser_fault});
    phase='navigation';
    await page.goto(process.argv[2] + '/index.html');
    if (runtime.browser_fault==='viewer-departure') {
      phase='departure';
      await page.waitForFunction(() => window.fortressSpectatorDepartureReady===true,null,{timeout:45000});
      departureClosed=await page.evaluate(() => {
        const sockets=window.fortressSpectatorSockets;
        if(sockets.length!==1 || sockets[0].readyState!==1) return false;
        sockets[0].close(1000,'physical viewer departure'); return true;
      });
      if(!departureClosed) throw new Error('no live viewer socket at buffered departure');
    }
    phase='result';
    await page.waitForFunction(() => window.fortressSpectatorResult !== undefined, null, {timeout:60000});
    result = await page.evaluate(() => window.fortressSpectatorResult);
    phase='state';
    state = await page.evaluate(() => window.fortressSpectatorState);
    phase='socket-drain';
    await page.waitForFunction(() => window.fortressSpectatorSockets.length>0 && window.fortressSpectatorSockets.every(socket => socket.readyState===3),null,{timeout:5000});
    phase='final';
    version=browser.version();
    publish();
    if (errors.length || result.passed !== true) process.exitCode=1;
  } catch(error) {
    operationFailed=true;
    operationError=error;
    process.exitCode=1;
    publish(phase);
    throw error;
  } finally {
    clearTimeout(watchdog);
    tearingDown=true;
    try {await browser.close();} catch(cleanupError) {
      if(operationFailed) throw new AggregateError([operationError,cleanupError],'browser operation and cleanup failed');
      throw cleanupError;
    }
  }
}
if (require.main===module) run().catch(error => {console.error(error);process.exitCode=1;});
