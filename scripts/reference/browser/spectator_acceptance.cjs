// Hold the actual acceptance response while the host continues publishing.
const fs=require('node:fs');
const {chromium}=require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
const delay=Number(process.env.FORTRESS_ACCEPT_DELAY_MS);
if(!Number.isInteger(delay) || delay<1 || delay>5000) throw Error('invalid acceptance hold');
const launch=chromium.launch.bind(chromium);
chromium.launch=async options=>{
  const browser=await launch(options);
  const newContext=browser.newContext.bind(browser);
  browser.newContext=async options=>{
    const context=await newContext(options);
    const newPage=context.newPage.bind(context);
    context.newPage=async()=>{
      const page=await newPage();
      let requests=0,baselineFrame,releaseFrame,heldMs;
      await page.addInitScript(()=>{
        let ready=false,result;
        Object.defineProperty(window,'fortressSpectatorDepartureReady',{
          get:()=>ready,set:value=>{ready=value;if(value && window.fortressSpectatorAcceptAcknowledged!==true) window.fortressEarlyDeparture=true;}
        });
        Object.defineProperty(window,'fortressSpectatorResult',{
          get:()=>result,set:value=>{result=value;if(value?.passed && window.fortressSpectatorAcceptAcknowledged!==true) window.fortressEarlySuccess=true;}
        });
      });
      await page.route('**/accept',async route=>{
        requests++;
        baselineFrame=await page.evaluate(()=>window.fortressSpectatorFrame);
        const response=await route.fetch();
        const deadline=performance.now()+delay;
        while(performance.now()<deadline) await new Promise(resolve=>setTimeout(resolve,Math.max(1,deadline-performance.now())));
        if(page.isClosed()) return;
        releaseFrame=await page.evaluate(()=>window.fortressSpectatorFrame);
        heldMs=delay;
        await route.fulfill({response});
      });
      const evaluate=page.evaluate.bind(page);
      page.evaluate=async(...args)=>{
        const result=await evaluate(...args);
        if(result?.passed===true) {
          const order=await evaluate(()=>({acknowledged:window.fortressSpectatorAcceptAcknowledged===true,
            earlyDeparture:window.fortressEarlyDeparture===true,earlySuccess:window.fortressEarlySuccess===true}));
          if(process.env.FORTRESS_ORDER_OUTPUT) fs.writeFileSync(process.env.FORTRESS_ORDER_OUTPUT,JSON.stringify({...order,requests,baselineFrame,releaseFrame,heldMs}));
          if(requests!==1 || heldMs!==delay || !Number.isSafeInteger(baselineFrame) || !Number.isSafeInteger(releaseFrame)) {
            throw Error('acceptance response hold was not observed');
          }
          if(releaseFrame!==baselineFrame) throw Error('playback advanced while acceptance response was held');
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
require('./spectator.cjs').run().catch(error=>{console.error(error);process.exitCode=1;});
