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
      await page.addInitScript(()=>{
        let ready=false,result;
        Object.defineProperty(window,'fortressSpectatorDepartureReady',{
          get:()=>ready,set:value=>{ready=value;if(value && !window.fortressAckReleased) window.fortressEarlyDeparture=true;}
        });
        Object.defineProperty(window,'fortressSpectatorResult',{
          get:()=>result,set:value=>{result=value;if(value?.passed && !window.fortressAckReleased) window.fortressEarlySuccess=true;}
        });
      });
      await page.route('**/accept',async route=>{
        const response=await route.fetch();
        await new Promise(resolve=>setTimeout(resolve,delay));
        if(page.isClosed()) return;
        await page.evaluate(()=>{window.fortressAckReleased=true;});
        await route.fulfill({response});
      });
      const evaluate=page.evaluate.bind(page);
      page.evaluate=async(...args)=>{
        const result=await evaluate(...args);
        if(result?.passed===true) {
          const order=await evaluate(()=>({released:window.fortressAckReleased===true,
            earlyDeparture:window.fortressEarlyDeparture===true,earlySuccess:window.fortressEarlySuccess===true}));
          if(process.env.FORTRESS_ORDER_OUTPUT) fs.writeFileSync(process.env.FORTRESS_ORDER_OUTPUT,JSON.stringify(order));
          if(!order.released || order.earlyDeparture || order.earlySuccess) throw Error('playback completed before acceptance acknowledgment');
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
