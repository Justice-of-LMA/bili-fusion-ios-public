/* Resize viewports, never the video transform or danmaku font. */
(()=>{'use strict';const stage=document.getElementById('stage'),body=document.body;let editing=false,scheduled=false,drag=null,preferences={};
try{preferences=JSON.parse(localStorage.getItem('fusion-layout-ratios-v1')||'{}')||{};}catch{}
const clamp=n=>Math.min(.8,Math.max(.2,n));
const toggle=document.createElement('button');toggle.id='adjustRatio';toggle.type='button';toggle.textContent='调节比例';toggle.setAttribute('aria-pressed','false');
const anchor=document.getElementById('threeView')||document.getElementById('dual');anchor.after(toggle);
const dividers=['主副画面比例','副画面上下比例'].map((label,index)=>{const e=document.createElement('div');e.className='ratio-divider';e.dataset.index=index;e.setAttribute('role','separator');e.setAttribute('aria-label',label);e.tabIndex=0;e.hidden=true;e.title='拖动分隔线调节比例，双击恢复默认';const grip=document.createElement('span');e.append(grip);stage.append(e);return e;});
function configuration(){const portrait=matchMedia('(orientation:portrait)').matches,views=[...stage.querySelectorAll(':scope>.video-view')].filter(v=>['main','side1','side2'].includes(v.dataset.role));const main=views.find(v=>v.dataset.role==='main'),side=views.filter(v=>v!==main).sort((a,b)=>a.dataset.role.localeCompare(b.dataset.role));return {portrait,views,main,side,key:(portrait?'portrait':'landscape')+'-'+views.length};}
function sizes(c){const saved=preferences[c.key]||{};return {main:Number.isFinite(saved.main)?clamp(saved.main):c.portrait?1/c.views.length:c.views.length===2?.5:2/3,side:Number.isFinite(saved.side)?clamp(saved.side):.5};}
function save(){try{localStorage.setItem('fusion-layout-ratios-v1',JSON.stringify(preferences));}catch{}}
function rect(e,x,y,w,h){for(const [key,value] of Object.entries({left:x,top:y,width:w,height:h}))e.style.setProperty(key,value+'px','important');}
function apply(){scheduled=false;const c=configuration(),active=body.classList.contains('dual')&&!body.classList.contains('web-layout')&&c.views.length>=2;
 for(const e of stage.querySelectorAll(':scope>.video-view'))for(const key of ['left','top','width','height'])e.style.removeProperty(key);
 dividers.forEach(e=>e.hidden=true);toggle.disabled=!active;toggle.title=active?'拖动主副画面及副画面之间的分隔线':'先开启双画面或三画面';if(!active){editing=false;toggle.textContent='调节比例';toggle.setAttribute('aria-pressed','false');return;}
 const w=stage.clientWidth,reserved=body.classList.contains('full')?0:parseFloat(getComputedStyle(stage).getPropertyValue('--reserved-controls'))||0,h=Math.max(1,stage.clientHeight-reserved),p=sizes(c),cut=(c.portrait?h:w)*p.main;
 for(const count of [2,3])for(const portrait of [false,true]){const t={...c,portrait,key:(portrait?'portrait':'landscape')+'-'+count,views:Array(count)},v=sizes(t);stage.style.setProperty('--ratio-'+t.key,Math.round(v.main*100000)/1000+'%');stage.style.setProperty('--side-'+t.key,Math.round(v.side*100000)/1000+'%');stage.style.setProperty('--main-factor-'+t.key,String(v.main));stage.style.setProperty('--side-factor-'+t.key,String(v.side));}

 if(editing){const first=dividers[0];first.hidden=false;first.dataset.axis=c.portrait?'y':'x';first.setAttribute('aria-orientation',c.portrait?'horizontal':'vertical');first.setAttribute('aria-valuenow',String(Math.round(p.main*100)));rect(first,c.portrait?0:cut-10,c.portrait?cut-10:0,c.portrait?w:20,c.portrait?20:h);
 if(c.side.length>1){const second=dividers[1];second.hidden=false;second.dataset.axis='y';second.setAttribute('aria-orientation','horizontal');second.setAttribute('aria-valuenow',String(Math.round(p.side*100)));rect(second,c.portrait?0:cut,c.portrait?cut+(h-cut)*p.side-10:h*p.side-10,c.portrait?w:w-cut,20);}}
 window.iosLayout?.();window.AndroidAIMedia?.layout();stage.dispatchEvent(new CustomEvent('viewportratio'));
}
function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(apply);}}
function update(index,value){const c=configuration(),p=sizes(c);p[index===0?'main':'side']=clamp(value);preferences[c.key]=p;apply();}
for(const [index,e]of dividers.entries()){
 e.onpointerdown=event=>{if(event.button!==0||drag)return;event.preventDefault();event.stopPropagation();drag={pointer:event.pointerId,index};e.setPointerCapture(event.pointerId);};
 e.onpointermove=event=>{if(drag?.pointer!==event.pointerId||drag.index!==index)return;event.preventDefault();event.stopPropagation();const c=configuration(),r=stage.getBoundingClientRect(),reserved=body.classList.contains('full')?0:parseFloat(getComputedStyle(stage).getPropertyValue('--reserved-controls'))||0,h=r.height-reserved,p=sizes(c),v=index===0?(c.portrait?(event.clientY-r.y)/h:(event.clientX-r.x)/r.width):c.portrait?(event.clientY-r.y-h*p.main)/(h*(1-p.main)):(event.clientY-r.y)/h;update(index,v);};
 e.onpointerup=e.onpointercancel=event=>{if(drag?.pointer!==event.pointerId)return;event.stopPropagation();drag=null;save();};e.onlostpointercapture=()=>{drag=null;save();};e.onclick=event=>event.stopPropagation();
 e.ondblclick=event=>{event.stopPropagation();delete preferences[configuration().key];save();apply();};
 e.onkeydown=event=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(event.key))return;event.preventDefault();const c=configuration(),p=sizes(c);if(event.key==='Home')delete preferences[c.key];else update(index,p[index===0?'main':'side']+(['ArrowLeft','ArrowUp'].includes(event.key)?-.02:.02));save();apply();};
}
toggle.onclick=event=>{event.stopPropagation();editing=!editing;toggle.textContent=editing?'完成调节':'调节比例';toggle.setAttribute('aria-pressed',String(editing));apply();};
new ResizeObserver(schedule).observe(stage);new MutationObserver(schedule).observe(body,{attributes:true,attributeFilter:['class','data-visible-count','data-main-source']});for(const e of stage.querySelectorAll(':scope>.video-view'))new MutationObserver(schedule).observe(e,{attributes:true,attributeFilter:['data-role']});window.addEventListener('resize',schedule);schedule();
})();
