const fs=require('node:fs');
const {chromium}=require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE);
(async()=>{
const browser=await chromium.launch({headless:true,executablePath:process.env.FORTRESS_CHROMIUM_EXECUTABLE,args:['--no-sandbox','--js-flags=--expose-gc']});
try {
 const page=await browser.newPage(),events=[];
 page.on('requestfailed',r=>events.push({kind:'requestfailed',path:new URL(r.url()).pathname,error:r.failure()?.errorText}));
 page.on('pageerror',e=>events.push({kind:'pageerror',message:e.message}));
 await page.goto(process.argv[2]);
 const harness='var IDHandler={objects:new Map(),next:1,add(o){const id=this.next++;this.objects.set(id,o);return id},get(id){return this.objects.get(id)},'+
   'remove(id){this.objects.delete(id)}};var GodotRuntime={error(e){window.fetchErrors.push(String(e))}};window.fetchErrors=[];';
 await page.addScriptTag({content:harness+fs.readFileSync(process.argv[3],'utf8')});
 const result=await page.evaluate(async()=>{
  const wait=()=>new Promise(resolve=>setTimeout(resolve,0));
  const open=async path=>{const id=GodotFetch.create('POST',path,[],new TextEncoder().encode('{}'));while(!IDHandler.get(id).response) await wait();return id;};
  const read=async id=>{GodotFetch.read(id);while(IDHandler.get(id)?.reading) await wait();};
  const drain=async id=>{while(!IDHandler.get(id).done){IDHandler.get(id).chunks=[];await read(id);}GodotFetch.read(id);};
  let completed=0;
  for(let i=0;i<300;i++) {const id=await open('/complete/'+i);await drain(id);GodotFetch.free(id);await wait();if(i%10===0)gc();completed++;}
  const unretained=await open('/held/unretained');await read(unretained);GodotFetch.free(unretained);await wait();gc();await new Promise(resolve=>setTimeout(resolve,700));
  const retained=await open('/held/retained');await read(retained);gc();await new Promise(resolve=>setTimeout(resolve,700));await drain(retained);GodotFetch.free(retained);gc();
  return {completed,objects:IDHandler.objects.size,fetchErrors};
 });
 await page.waitForTimeout(100);
 console.log(JSON.stringify({browser:browser.version(),result,events}));
 if(result.completed!==300 || result.objects!==0 || result.fetchErrors.length || events.length) process.exitCode=1;
} finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
