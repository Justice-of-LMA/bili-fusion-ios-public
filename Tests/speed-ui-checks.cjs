const assert=require('node:assert/strict');
module.exports=async function checkSpeed(page){
 const setup=await page.evaluate(()=>({saved:localStorage.getItem('fusion-mobile-v1'),rows:document.getElementById('maxRows').value,manual:window.__areaManual}));
 await page.evaluate(()=>{window.__areaManual=true;const e=document.getElementById('maxRows');e.value='1';e.dispatchEvent(new Event('input'));});
 const counters=()=>page.evaluate(()=>JSON.stringify((window.__calls||window.calls||[]).filter(c=>/^(resolve|startChat|stopChat|mediaOpen|mediaClose|mediaSeek)$/.test(c.op))));
 const before=await counters();
 for(const speed of [.5,1,2]){
  await page.evaluate(value=>{const e=document.getElementById('size');e.dispatchEvent(new Event('input'));const s=document.getElementById('chatSpeed');s.value=String(value);s.dispatchEvent(new Event('input'));window.__emitBlockingTest('B',{cmd:'DANMU_MSG',info:[[],'速度测量',[999,'速度测试']]});},speed);
  await page.waitForFunction(()=>[...document.querySelectorAll('.bullet')].some(e=>e.textContent.includes('速度测量')));
  const measured=await page.evaluate(async()=>{
   const b=[...document.querySelectorAll('.bullet')].find(e=>e.textContent.includes('速度测量'));
   const a=b.getBoundingClientRect().x,t=performance.now();await new Promise(r=>setTimeout(r,450));return (a-b.getBoundingClientRect().x)/((performance.now()-t)/1000);
  });
  assert.ok(Math.abs(measured-95*speed)<28,JSON.stringify({speed,measured}));
 }
 const continuous=await page.evaluate(()=>{
  const b=[...document.querySelectorAll('.bullet')].find(e=>e.textContent.includes('速度测量')),x=b.getBoundingClientRect().x,s=document.getElementById('chatSpeed');
  s.value='.5';s.dispatchEvent(new Event('input'));return {same:b.isConnected,delta:Math.abs(x-b.getBoundingClientRect().x),label:document.getElementById('chatSpeedValue').textContent,saved:JSON.parse(localStorage.getItem('fusion-mobile-v1')).chatSpeed};
 });
 assert.equal(continuous.same,true);assert.ok(continuous.delta<.1);assert.equal(continuous.label,'0.5 倍');assert.equal(continuous.saved,'0.5');
 assert.equal(await counters(),before,'Changing bullet speed must not reconnect or seek media');
 await page.evaluate(setup=>{for(const [id,value]of Object.entries({chatSpeed:'1',maxRows:setup.rows})){const e=document.getElementById(id);e.value=value;e.dispatchEvent(new Event('input'));}window.__areaManual=setup.manual;if(setup.saved===null)localStorage.removeItem('fusion-mobile-v1');else localStorage.setItem('fusion-mobile-v1',setup.saved);},setup);
 console.log('Actual moving bullets: 0.5x/1x/2x, no jumps or media restarts: PASS');
};

