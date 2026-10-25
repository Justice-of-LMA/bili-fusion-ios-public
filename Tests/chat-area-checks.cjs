const assert=require('node:assert/strict');
module.exports=async function checkChatArea(page){
 const states=[
  {width:1024,height:1366,full:false,dual:false},
  {width:1024,height:1366,full:false,dual:true},
  {width:1366,height:1024,full:true,dual:false},
  {width:1366,height:1024,full:true,dual:true},
  {width:844,height:390,full:true,dual:false},
  {width:844,height:390,full:true,dual:true}
 ];
 for(const state of states){
  await page.setViewportSize({width:state.width,height:state.height});
  await page.evaluate(state=>{
   if(document.body.classList.contains('full')!==state.full)document.getElementById('full').click();
   if(document.body.classList.contains('dual')!==state.dual)document.getElementById('dual').click();
  },state);
  for(const area of [25,50,75,100]){
   await page.evaluate(area=>{
    for(const [id,value] of Object.entries({chatArea:String(area),maxRows:'11',size:'20'})){const e=document.getElementById(id);e.value=value;e.dispatchEvent(new Event('input'));}
    for(const [id,value] of Object.entries({chatA:false,chatB:true})){const e=document.getElementById(id);e.checked=value;e.dispatchEvent(new Event('input'));}
   },area);
   await page.waitForTimeout(40);
   const geometry=await page.evaluate(()=>{
    const a=document.getElementById('viewA').getBoundingClientRect(),b=document.getElementById('bullets').getBoundingClientRect();
    return {a:{x:a.x,y:a.y,w:a.width,h:a.height},b:{x:b.x,y:b.y,w:b.width,h:b.height}};
   });
   const h=geometry.a.h*area/100;
   for(const key of ['x','y','w'])assert.ok(Math.abs(geometry.a[key]-geometry.b[key])<.06,JSON.stringify({state,area,geometry}));
   assert.ok(Math.abs(geometry.b.h-h)<.06,'Exact percentage, never applied twice after a layout switch');
   const expected=Math.max(0,Math.min(11,1+Math.floor((h-8-3-31)/34)));
   await page.evaluate(n=>window.__emitAreaTest('B',n),expected);
   await page.waitForFunction(n=>document.querySelectorAll('.bullet[data-source=B]').length>=n,expected);
   const rows=await page.evaluate(()=>{
    const nodes=[...document.querySelectorAll('.bullet[data-source=B]')];window.__areaExisting=nodes.map(e=>({e,top:e.style.top}));
    return nodes.map(e=>({top:parseFloat(e.style.top),height:e.getBoundingClientRect().height}));
   });
   assert.equal(new Set(rows.map(r=>r.top)).size,expected);
   for(const r of rows)assert.ok(r.top+r.height<=h+0.06,'Full glyph/emote box stays inside selected area');
   if(expected>1)assert.ok(Math.abs(Math.max(...rows.map(r=>r.top))-(h-3-31))<.06,'Rows span selected area even with a row cap');
   // A on/off must not move or discard already displayed B rows, nor resize the region.
   for(const enabled of [true,false]){
    const unchanged=await page.evaluate(enabled=>{
     const e=document.getElementById('chatA');e.checked=enabled;e.dispatchEvent(new Event('input'));
     return window.__areaExisting.every(x=>x.e.isConnected&&x.e.style.top===x.top);
    },enabled);
    assert.ok(unchanged,'A toggle must preserve B nodes and their Y coordinates');
   }
  }
 }
 await page.evaluate(()=>{delete window.__areaExisting;});
 console.log('PASS chat-area geometry: 24 layout/area combinations; 75% + 11 rows; A toggle preserves B; strict bottom clipping.');
};
