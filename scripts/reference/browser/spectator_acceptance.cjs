// Hold the actual acceptance response while the host continues publishing.
const fs=require('node:fs');
const {chromium}=require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const runner=require('./spectator.cjs');
let rejectRoute,canAct=()=>false;
const failureSignal=new Promise((_resolve,reject)=>{rejectRoute=reject;});
failureSignal.catch(()=>{});
const delay=Number(process.env.FORTRESS_ACCEPT_DELAY_MS);
if(!Number.isInteger(delay) || delay<1 || delay>5000) throw Error('invalid acceptance hold');
const launch=chromium.launch.bind(chromium);
chromium.launch=async options=>{
  const browser=await launch(options);
  const routeTasks=new Set(),routeErrors=[];
  const close=browser.close.bind(browser);
  browser.close=async()=>{
    const failures=[];
    try {await close();} catch(error){failures.push(error);}
    let timer;
    try {
      await Promise.race([Promise.allSettled(Array.from(routeTasks)),
        new Promise((_resolve,reject)=>{timer=setTimeout(()=>reject(Error('Acceptance route cleanup deadline exceeded.')),5000);})]);
    } catch(error){failures.push(error);}
    finally {clearTimeout(timer);}
    failures.push(...routeErrors.slice(1));
    if(failures.length) throw failures.length===1?failures[0]:new AggregateError(failures,'browser close and acceptance route cleanup failed');
  };
  const newContext=browser.newContext.bind(browser);
  browser.newContext=async options=>{
    if(!canAct())return;
    const context=await newContext(options);
    if(!canAct())return context;
    const newPage=context.newPage.bind(context);
    context.newPage=async()=>{
      if(!canAct())return;
      const page=await newPage();
      if(!canAct())return page;
      let requests=0,baselineFrame,releaseFrame,heldMs;
      await page.addInitScript(()=>{
        let ready=false,result,frame=0;
        Object.defineProperty(window,'fortressSpectatorFrame',{
          get:()=>frame,set:value=>{
            if(value>frame && window.fortressSpectatorAcceptAcknowledged!==true) window.fortressEarlyPlayback=true;
            frame=value;
          }
        });
        Object.defineProperty(window,'fortressSpectatorDepartureReady',{
          get:()=>ready,set:value=>{ready=value;if(value && window.fortressSpectatorAcceptAcknowledged!==true) window.fortressEarlyDeparture=true;}
        });
        Object.defineProperty(window,'fortressSpectatorResult',{
          get:()=>result,set:value=>{result=value;if(value?.passed && window.fortressSpectatorAcceptAcknowledged!==true) window.fortressEarlySuccess=true;}
        });
      });
      if(!canAct())return page;
      await page.route('**/accept',route=>{
        const task=(async()=>{
        if(!canAct())return;
        requests++;
        baselineFrame=await page.evaluate(()=>window.fortressSpectatorFrame);
        if(!canAct())return;
        const response=await route.fetch();
        if(!canAct())return;
        const deadline=performance.now()+delay;
        while(performance.now()<deadline) {
          if(!canAct())return;
          await new Promise(resolve=>setTimeout(resolve,Math.max(1,deadline-performance.now())));
        }
        if(!canAct() || page.isClosed()) return;
        releaseFrame=await page.evaluate(()=>window.fortressSpectatorFrame);
        if(!canAct())return;
        heldMs=delay;
        await route.fulfill({response});
        })().catch(error=>{routeErrors.push(error);if(routeErrors.length===1) rejectRoute(error);});
        routeTasks.add(task);
        task.then(()=>routeTasks.delete(task));
        return task;
      });
      if(!canAct())return page;
      const evaluate=page.evaluate.bind(page);
      page.evaluate=async(...args)=>{
        if(!canAct())return;
        const result=await evaluate(...args);
        if(!canAct())return result;
        if(result?.passed===true) {
          const order=await evaluate(()=>({acknowledged:window.fortressSpectatorAcceptAcknowledged===true,
            earlyPlayback:window.fortressEarlyPlayback===true,
            earlyDeparture:window.fortressEarlyDeparture===true,earlySuccess:window.fortressEarlySuccess===true}));
          if(!canAct())return result;
          if(process.env.FORTRESS_ORDER_OUTPUT) fs.writeFileSync(process.env.FORTRESS_ORDER_OUTPUT,JSON.stringify({...order,requests,baselineFrame,releaseFrame,heldMs}));
          if(requests!==1 || heldMs!==delay || !Number.isSafeInteger(baselineFrame) || !Number.isSafeInteger(releaseFrame)) {
            throw Error('acceptance response hold was not observed');
          }
          if(releaseFrame!==baselineFrame || order.earlyPlayback) throw Error('playback advanced before acceptance acknowledgment');
          if(!order.acknowledged || order.earlyDeparture || order.earlySuccess) {
            throw Error('playback completed before acceptance acknowledgment');
          }
        }
        return result;
      };
      return page;
    };
    return context;
  };
  return browser;
};
runner.run(failureSignal,guard=>{canAct=guard;}).catch(runner.reportFailure);
