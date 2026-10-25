/* Bounded exact-text grouping and compact local-only message actions. */
((root)=>{
'use strict';
const raw=m=>String(m?.text??'');
class Group{
 constructor(message,context={}){this.text=raw(message);this.members=[];this.add(message,context);}
 add(message,context={}){
  if(raw(message)!==this.text)return false;
  const id=FusionBlocking.identity(message,context.platform),key=JSON.stringify([context.source,context.platform,context.room,context.epoch,FusionBlocking.key(id)]);
  let item=this.members.find(x=>x.key===key);
  if(item)item.count++;else if(this.members.length<60)this.members.push({key,message,context:{...context},count:1});
  else return false;
  return true;
 }
 filter(predicate){this.members=this.members.filter(x=>predicate(x.message,x.context));return this.members.length>0;}
 get count(){return this.members.reduce((n,x)=>n+x.count,0);}
}
function badge(el,group){el.textContent=group.count>1?'×'+(group.count>999?'999+':group.count):'';el.hidden=false;el.style.visibility=group.count<2?'hidden':'visible';}
function menu({parent=document.body,blockUser,blockText,send,active=()=>true}){
 const d=parent.ownerDocument||document,style=d.createElement('style'),box=d.createElement('div');
 style.textContent='.fusion-message-menu{position:fixed;box-sizing:border-box;width:min(320px,calc(100vw - 16px));max-height:min(420px,70vh);overflow:auto;padding:10px;background:#132235f5;color:#eef6ff;border:1px solid #55738c;border-radius:12px;box-shadow:0 6px 28px #0008;z-index:2147483647;font:14px system-ui;pointer-events:auto}.fusion-message-menu[hidden]{display:none!important}.fusion-message-menu button,.fusion-message-menu select{box-sizing:border-box;font:inherit;color:inherit;background:#29445b;border:1px solid #597588;border-radius:7px;padding:8px;margin:3px 0;width:100%;cursor:pointer}.fusion-message-menu button:disabled{opacity:.5;cursor:default}.fusion-message-menu .msg-head{display:flex;gap:8px;align-items:center}.fusion-message-menu .msg-head span{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.fusion-message-menu .msg-head button{width:32px}.fusion-message-menu .msg-body{white-space:pre-wrap;overflow-wrap:anywhere;max-height:4.5em;overflow:auto;color:#aecdde;margin:6px 0}.fusion-message-menu .msg-status{font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere}.fusion-merge-count{display:inline-block;box-sizing:border-box;min-width:3.4em;max-width:3.4em;font-size:.72em;padding-left:.25em;font-variant-numeric:tabular-nums;vertical-align:middle;pointer-events:none}';
 box.className='fusion-message-menu';box.hidden=true;box.setAttribute('role','menu');box.setAttribute('aria-label','弹幕操作');parent.append(style,box);
 let opened=false,busy=false,serial=0;
 const close=()=>{opened=false;serial++;box.hidden=true;box.replaceChildren();return true;};
 function open(group,event){
  const members=(group?.members||[]).map(x=>({...x,context:{...x.context}}));
  if(!members.length)return;
  if(opened)close();opened=true;busy=false;const ticket=++serial;box.replaceChildren();
  const head=d.createElement('div'),title=d.createElement('span'),x=d.createElement('button');head.className='msg-head';
  title.textContent='弹幕操作'+(group.count>1?' · '+group.count+' 条合并':'');x.textContent='×';x.setAttribute('aria-label','关闭弹幕操作');x.onclick=close;head.append(title,x);box.append(head);
  const body=d.createElement('div');body.className='msg-body';body.textContent=group.text;box.append(body);
  const status=d.createElement('div');status.className='msg-status';status.setAttribute('role','status');
  const action=(label,fn,enabled=true)=>{
   const button=d.createElement('button');button.textContent=label;button.disabled=!enabled;button.setAttribute('role','menuitem');
   button.onclick=async e=>{e.preventDefault();e.stopPropagation();if(busy||!opened)return;busy=true;
    const buttons=[...box.querySelectorAll('button')];buttons.forEach(b=>{if(b!==x)b.disabled=true;});
    status.textContent='处理中…';try{const text=await fn();if(opened&&ticket===serial)status.textContent=text||'已完成';}
    catch(error){if(opened&&ticket===serial)status.textContent=error?.message||String(error);}
    finally{busy=false;if(opened&&ticket===serial)buttons.forEach(b=>{if(b!==x)b.disabled=b.dataset.unavailable==='true';});}
   };button.dataset.unavailable=String(!enabled);box.append(button);return button;
  };
  const users=[];for(const item of members){const u=FusionBlocking.identity(item.message,item.context.platform);if((u.uid||u.name)&&!users.some(x=>FusionBlocking.key(x.u)===FusionBlocking.key(u)))users.push({u,item});}
  let selected=0;
  if(users.length>1){const select=d.createElement('select');select.setAttribute('aria-label','选择要屏蔽的发送者');users.forEach(({u},i)=>{const o=d.createElement('option');o.value=String(i);o.textContent=FusionBlocking.names[u.platform]+' · '+(u.name||u.uid);select.append(o);});select.onchange=()=>{selected=Number(select.value);};box.append(select);}
  action('屏蔽发送者'+(users.length===1?' · '+(users[0].u.name||users[0].u.uid):''),()=>blockUser(users[selected].item.message,users[selected].u.platform),users.length>0);
  action('屏蔽整句（每个字完全相同）',()=>blockText(group.text));
  const targets=[];for(const item of members){const c=item.context;const index=targets.findIndex(t=>t.platform===c.platform&&String(t.room)===String(c.room));if(index<0)targets.push(c);else if(!active(targets[index])&&active(c))targets[index]=c;}
  for(const target of targets){const okay=!!send&&active(target)&&[...group.text].length<=40&&group.text.length>0;
   action('+1 → '+target.source+' · '+(FusionBlocking.names[target.platform]||'直播间'),()=>{if(!active(target))throw Error('房间已改变，请点击当前房间的新弹幕');return send(group.text,target);},okay);
  }
  if([...group.text].length>40)status.textContent='原文超过 40 字，不能原样跟发；不会截断或自动发送。';
  box.append(status);box.hidden=false;box.style.left='8px';box.style.top='8px';
  const rect=box.getBoundingClientRect(),view=d.defaultView,left=Number(event?.clientX)||8,top=Number(event?.clientY)||8;
  box.style.left=Math.max(8,Math.min(view.innerWidth-rect.width-8,left))+'px';box.style.top=Math.max(8,Math.min(view.innerHeight-rect.height-8,top))+'px';
 }
 box.addEventListener('pointerdown',e=>e.stopPropagation());box.addEventListener('click',e=>e.stopPropagation());
 d.addEventListener('pointerdown',e=>{if(opened&&!e.composedPath().includes(box))close();},true);
 d.addEventListener('keydown',e=>{if(opened&&e.key==='Escape'){e.preventDefault();e.stopPropagation();close();}},true);
 d.defaultView?.addEventListener('resize',()=>{if(opened)close();});
 return {open,close:()=>opened?close():false,isOpen:()=>opened,element:box};
}
const api={Group,badge,menu};root.FusionDanmaku=api;if(typeof module!=='undefined')module.exports=api;
})(globalThis);
