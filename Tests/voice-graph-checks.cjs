/* Real browser WebAudio regression for the non-AudioWorklet WK fallback. No live stream or account. */
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 try{
  const page=await browser.newPage();
  await page.addScriptTag({content:fs.readFileSync(path.resolve(__dirname,'../Fusion/Web/voice-reducer.js'),'utf8')});
  const results=await page.evaluate(async()=>{
   const all=[];
   for(const mode of ['centre','side','mono','unknown','off']){
    const channels=mode==='mono'?1:2,c=new OfflineAudioContext(channels,48000,48000),buffer=c.createBuffer(channels,48000,48000);
    for(let k=0;k<channels;k++){const data=buffer.getChannelData(k);for(let i=0;i<data.length;i++)data[i]=.2*Math.sin(2*Math.PI*1000*i/48000)*(mode==='side'&&k===1?-1:1);}
    const source=c.createBufferSource();source.buffer=buffer;
    c.createMediaElementSource=()=>source;c.resume=async()=>{};
    const old=window.AudioContext;window.AudioContext=function(){return c;};
    const reducer=new FusionVoiceReducer({});reducer.setChannels(mode==='unknown'?0:channels);
    // about:blank is not a secure context: the production graph path is used.
    await reducer.set(true,1);if(mode==='off')await reducer.set(false,1);
    source.start();const audio=await c.startRendering();window.AudioContext=old;
    let input=0,output=0,error=0;for(let i=12000;i<audio.length;i++){const x=buffer.getChannelData(0)[i],y=audio.getChannelData(0)[i];input+=x*x;output+=y*y;error=Math.max(error,Math.abs(x-y));}
    all.push({mode,ratio:Math.sqrt(output/input),error,detail:reducer.detail(),graph:!!reducer.remove});
   }
   return all;
  });
  assert.ok(results.every(x=>x.graph),'Must exercise the standard graph, not the worklet');
  assert.ok(results.find(x=>x.mode==='centre').ratio<.3,JSON.stringify(results));
  for(const mode of ['side','mono','unknown','off'])assert.ok(results.find(x=>x.mode===mode).error<1e-6,JSON.stringify(results));
  assert.match(results.find(x=>x.mode==='mono').detail,/单声道/);
  assert.match(results.find(x=>x.mode==='unknown').detail,/暂保留/);
  console.log(JSON.stringify({passed:true,results},null,2));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
