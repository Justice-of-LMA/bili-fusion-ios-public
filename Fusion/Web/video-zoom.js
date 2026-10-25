/* Dual-view video-only pinch zoom. Layout, messages, audio and clocks are untouched. */
(()=>{'use strict';
 if(window.FusionVideoZoom)return;
 const states=new Map(),clamp=(v,a,c)=>Math.max(a,Math.min(c,v));
 function apply(s){
  s.video=document.getElementById('video'+s.source)||s.video;
  const r=s.view.getBoundingClientRect();s.x=clamp(s.x,-r.width*(s.scale-1)/2,r.width*(s.scale-1)/2);s.y=clamp(s.y,-r.height*(s.scale-1)/2,r.height*(s.scale-1)/2);
  s.video.style.transformOrigin='50% 50%';s.video.style.transform=`translate(${s.x}px,${s.y}px) scale(${s.scale})`;
  s.button.hidden=s.scale<=1.01;s.button.textContent='恢复画面';
  window.iosVideoZoom?.(s.source,{scale:s.scale,x:s.x,y:s.y});
 }
 function reset(source){const s=states.get(source);if(!s)return;s.scale=1;s.x=s.y=0;s.gesture=null;apply(s);}
 function resetAll(){for(const source of states.keys())reset(source);}
 function mount(){for(const source of ['A','B']){
  const view=document.getElementById('view'+source),video=document.getElementById('video'+source);if(!view||!video||states.has(source))continue;
  const button=document.createElement('button');button.type='button';button.className='video-zoom-reset';button.dataset.source=source;button.setAttribute('aria-label','恢复 '+source+' 画面');button.hidden=true;
  button.style.cssText='position:absolute;right:8px;bottom:8px;z-index:35;padding:6px 10px;font:12px system-ui;color:white;background:#142438dd;border:1px solid #82b8cc;border-radius:8px;pointer-events:auto;touch-action:manipulation';
  view.append(button);const s={source,view,video,button,scale:1,x:0,y:0,gesture:null,suppress:0};states.set(source,s);
  button.onclick=e=>{e.preventDefault();e.stopPropagation();reset(source);};
  const point=e=>{const a=e.touches[0],c=e.touches[1],r=view.getBoundingClientRect();return{x:(a.clientX+c.clientX)/2-r.left-r.width/2,y:(a.clientY+c.clientY)/2-r.top-r.height/2,d:Math.max(1,Math.hypot(a.clientX-c.clientX,a.clientY-c.clientY))};};
  view.addEventListener('touchstart',e=>{
   if(!document.body.classList.contains('dual')||e.touches.length!==2||e.target.closest('button,input,select,textarea,[data-sc-id],.sc-card'))return;
   e.preventDefault();e.stopPropagation();const p=point(e);s.gesture={distance:p.d,scale:s.scale,ax:(p.x-s.x)/s.scale,ay:(p.y-s.y)/s.scale};s.suppress=performance.now()+500;
  },{passive:false,capture:true});
  view.addEventListener('touchmove',e=>{
   if(!s.gesture||e.touches.length!==2)return;e.preventDefault();e.stopPropagation();const p=point(e),g=s.gesture;s.scale=clamp(g.scale*p.d/g.distance,1,4);s.x=p.x-g.ax*s.scale;s.y=p.y-g.ay*s.scale;s.suppress=performance.now()+500;apply(s);
  },{passive:false,capture:true});
  const end=e=>{if(s.gesture){e.stopPropagation();s.suppress=performance.now()+400;}if(e.touches.length<2)s.gesture=null;};
  view.addEventListener('touchend',end,true);view.addEventListener('touchcancel',end,true);
  view.addEventListener('click',e=>{if(e.target!==button&&performance.now()<s.suppress){e.preventDefault();e.stopImmediatePropagation();}},true);
  let width=null,height=null;new ResizeObserver(entries=>{const r=entries[0].contentRect;const changed=width!==null&&(width!==r.width||height!==r.height);width=r.width;height=r.height;if(changed)reset(source);}).observe(view);
  new MutationObserver(()=>reset(source)).observe(video,{attributes:true,attributeFilter:['src']});
 }
 let dual=document.body.classList.contains('dual');new MutationObserver(()=>{const next=document.body.classList.contains('dual');if(next!==dual){dual=next;resetAll();}for(const s of states.values())s.view.style.touchAction=next?'none':'';}).observe(document.body,{attributes:true,attributeFilter:['class']});
 }
 window.FusionVideoZoom={reset,resetAll};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
