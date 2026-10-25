// Read only the official rendered chat list. No sends, socket hooks, page reloads or account exports.
(()=>{
 'use strict';if(window.FusionHuyaList)return;
 let list=null,observer=null,closed=false,total=0;const queue=[],seen=new Set(),nodes=new WeakSet();
 const words=e=>{let text='';function visit(n){if(n.nodeType===3)text+=n.nodeValue;else if(n.nodeType===1){if(n.tagName==='IMG')text+=n.getAttribute('alt')||'[表情]';else for(const c of n.childNodes)visit(c);}}if(e)visit(e);return text.trim().slice(0,2000);};
 function uid(name,row){
  for(const e of [name,row])for(const k of ['data-uid','data-user-id','data-userid','data-yyuid']){const v=e?.getAttribute(k);if(/^[1-9]\d{0,19}$/.test(v||''))return v;}
  // Some official layouts attach the public sender id via jQuery rather than an HTML attribute.
  try{if(typeof window.jQuery==='function')for(const k of ['uid','yyuid','userId']){const v=window.jQuery(name).data(k);if(/^[1-9]\d{0,19}$/.test(String(v||'')))return String(v);}}catch{}
  return ''; // Never use a fan badge data-id (that identifies an anchor, not this sender).
 }
 function take(row,skip=false){
  if(!row||row.nodeType!==1||nodes.has(row))return;
  const normal=row.matches('.msg-normal')?row:row.querySelector('.msg-normal');
  const name=normal?.querySelector('.name.J_userMenu'),body=normal?.querySelector('.msg.J_msg');
  if(!name||!body)return; // Excludes gifts, system notices and shopping banners.
  const id=row.getAttribute('data-cmid'),user=words(name),text=words(body);if(!user||!text)return;
  nodes.add(row);if(id&&seen.has(id))return;if(id){seen.add(id);if(seen.size>2048)seen.delete(seen.values().next().value);}
  if(skip)return;
  let color=0xffffff;const rgb=getComputedStyle(body).color.match(/^rgb[a]?\((\d+),\s*(\d+),\s*(\d+)/);if(rgb){const c=(+rgb[1]<<16)|(+rgb[2]<<8)|+rgb[3];if(c>0x444444)color=c;}
  queue.push({user,uid:uid(name,row),text,color});total++;if(queue.length>200)queue.shift();
 }
 function bind(){
  const next=document.getElementById('chat-room__list');if(next===list)return;
  if(observer)observer.disconnect();list=next;if(!list)return;seen.clear();
  for(const row of list.children)take(row,true); // Do not replay the existing history on a manual refresh.
  observer=new MutationObserver(records=>{for(const m of records){for(const n of m.addedNodes){if(n.nodeType!==1)continue;const row=n.closest('[data-cmid]');if(row&&row.parentElement===list)take(row);else if(n.parentElement===list)take(n);}const row=m.target.nodeType===1?m.target.closest('[data-cmid]'):m.target.parentElement?.closest('[data-cmid]');if(row&&row.parentElement===list)take(row);}});
  observer.observe(list,{childList:true,subtree:true,characterData:true});
 }
 function silence(){for(const v of document.querySelectorAll('video,audio')){v.muted=true;if(!v.paused)v.pause();}}
 window.FusionHuyaList={drain(){if(closed)return {ready:false,items:[],total};bind();silence();return {ready:!!list,items:queue.splice(0,50),total};},close(){closed=true;observer?.disconnect();queue.length=0;}};
 bind();silence();
})()
