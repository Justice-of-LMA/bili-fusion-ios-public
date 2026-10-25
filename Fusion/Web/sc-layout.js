/* Shared, resolution-independent placement of the entire SC stack. */
(()=>{
 'use strict';
 const unit=n=>Number.isFinite(Number(n))?Math.max(0,Math.min(1,Number(n))):0;
 const corners={'top-left':[0,0],'top-right':[1,0],'bottom-left':[0,1],'bottom-right':[1,1]};
 function geometry(w,h,cw,ch,x,y,margin=8,bottom=8){
   w=Math.max(0,w);h=Math.max(0,h);const left=Math.min(margin,w/2),top=Math.min(margin,h/2);
   const right=Math.max(left,w-margin-cw),end=Math.max(top,h-bottom-ch);
   return {left:left+unit(x)*(right-left),top:top+unit(y)*(end-top),rangeX:right-left,rangeY:end-top};
 }
 function mount(node,host,{load=()=>null,save=()=>{},bottom=()=>8}={}){
   let value={x:0,y:1},drag=null,disposed=false,enabled=true;
   try{const stored=load();if(stored)value={x:unit(stored.x),y:unit(stored.y)};}catch{}
   function apply(){
     if(disposed)return;
     const w=host.clientWidth,h=host.clientHeight;
     node.style.width=Math.max(1,Math.min(280,w*.55,w-16))+'px';node.style.maxHeight=Math.max(1,Math.min(h*.5,h-16-bottom()))+'px';
     const r=geometry(w,h,node.offsetWidth,node.offsetHeight,value.x,value.y,8,bottom());
     node.style.right='auto';node.style.bottom='auto';node.style.left=r.left+'px';node.style.top=r.top+'px';
   }
   function set(v,persist=false){value={x:unit(v.x),y:unit(v.y)};apply();if(persist)save({...value});}
   node.addEventListener('pointerdown',e=>{const card=e.target.closest('.sc');if(!enabled||e.button!==0||!card||e.target.closest('button,a,input,select'))return;node.setPointerCapture(e.pointerId);e.stopPropagation();const r=geometry(host.clientWidth,host.clientHeight,node.offsetWidth,node.offsetHeight,value.x,value.y,8,bottom());drag={id:e.pointerId,x:e.clientX,y:e.clientY,start:{...value},rx:r.rangeX,ry:r.rangeY,moved:false};});
   node.addEventListener('pointermove',e=>{if(!drag||e.pointerId!==drag.id)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;if(Math.abs(dx)+Math.abs(dy)>5)drag.moved=true;if(drag.moved)set({x:drag.start.x+dx/Math.max(1,drag.rx),y:drag.start.y+dy/Math.max(1,drag.ry)});});
   const finish=e=>{if(!drag||e.pointerId!==drag.id)return;const moved=drag.moved;drag=null;if(moved)save({...value});};
   node.addEventListener('pointerup',finish);node.addEventListener('pointercancel',finish);
   const observer=new ResizeObserver(apply);observer.observe(host);observer.observe(node);const mutation=new MutationObserver(apply);mutation.observe(node,{childList:true});apply();
   return {set,setDraggable:on=>{enabled=!!on;if(!enabled)drag=null;node.classList.toggle('sc-pass-through',!enabled);},get:()=>({...value}),corner:name=>{const p=corners[name];if(p)set({x:p[0],y:p[1]},true);},destroy:()=>{disposed=true;observer.disconnect();mutation.disconnect();}};
 }
 const api={geometry,mount,corners};if(typeof module!=='undefined')module.exports=api;else window.SCLayout=api;
})();
