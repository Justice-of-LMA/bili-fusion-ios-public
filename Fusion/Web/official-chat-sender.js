// Runs only inside the selected platform's official room. No privileged native bridge.
// A user send has one commit, one matching wire submission, and no automatic retry.
(function(){
 'use strict';if(window.FusionOfficialSender)return;
 const state={ready:false,armed:false,submitted:false,error:'',receipt:'',diagnostic:''};
 let platform='',message='',wire=false,installed=false,huyaReady=false,uid='',huyaRequest=null;
 const visible=e=>e&&!!(e.offsetWidth||e.offsetHeight)&&!e.disabled;
 const result=(ok,receipt,error='')=>{if(!state.armed||state.submitted||state.error)return;state.submitted=ok;state.receipt=receipt;state.error=error;};
 const fail=message=>result(false,'',message);
 const cookie=k=>document.cookie.split(';').map(x=>x.trim()).find(x=>x.startsWith(k+'='))?.slice(k.length+1)||'';
 function editor(p){return p==='huya'?document.querySelector('#pub_msg_input'):p==='douyu'?document.querySelector('.ChatSend-txt[contenteditable=true]'):document.querySelector('.editor-kit-container[contenteditable=true]');}
 function button(p){return document.querySelector(p==='huya'?'#msg_send_bt':p==='douyu'?'.ChatSend-button':'.webcast-chatroom___send-btn');}
 const httpChat=url=>{try{const u=new URL(url,location.href);return platform==='douyin'&&u.origin==='https://live.douyin.com'&&u.pathname==='/webcast/room/chat/';}catch{return false;}};
 function ackHttp(status,body){
  if(!state.armed)return;
  if(status!==200){fail('平台发送接口返回 HTTP '+status+'，没有自动重发');return;}
  try{
   const j=typeof body==='string'?JSON.parse(body):body;
   state.diagnostic='HTTP '+status+' / code '+String(j?.status_code)+' / data keys '+Object.keys(j?.data||{}).slice(0,15).join(',');
   if(!j||typeof j.status_code!=='number')return;
   if(j.status_code!==0){fail('抖音未接受弹幕（'+j.status_code+'）。请到官方房间查看登录、验证或发言限制');return;}
   // Empty HTTP success is not a message acknowledgment.
   if(j.data&&typeof j.data==='object'&&(j.data.id||j.data.id_str||j.data.message_id||j.data.msg_id))result(true,'douyin-chat-response');
  }catch{}
 }
 function installHttp(){
  const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;
  const urls=new WeakMap();
  XMLHttpRequest.prototype.open=function(method,url,...args){urls.set(this,String(url));return open.call(this,method,url,...args);};
  XMLHttpRequest.prototype.send=function(body){
   if(state.armed&&httpChat(urls.get(this))){
    if(wire)throw Error('本次消息已提交，禁止自动重发');wire=true;
    this.addEventListener('load',()=>ackHttp(this.status,this.responseType==='json'?this.response:this.responseText),{once:true});
   }
   return send.call(this,body);
  };
  const fetch=window.fetch;
  if(fetch)window.fetch=function(input,...args){
   const match=state.armed&&httpChat(typeof input==='string'?input:input?.url);
   // fetch may internally use the site's XHR signer. Track there if it does.
   if(match&&wire)return Promise.reject(Error('本次消息已提交，禁止自动重发'));
   if(match)wire=true;
   const promise=fetch.call(this,input,...args);
   if(match)promise.then(r=>r.clone().text().then(s=>ackHttp(r.status,s))).catch(()=>{});
   return promise;
  };
 }
 function stt(s){const r={};for(const part of s.split('/')){const i=part.indexOf('@=');if(i>0)r[part.slice(0,i)]=part.slice(i+2).replaceAll('@S','/').replaceAll('@A','@');}return r;}
 function douyuFrames(data){
  const b=data instanceof ArrayBuffer?new Uint8Array(data):ArrayBuffer.isView(data)?new Uint8Array(data.buffer,data.byteOffset,data.byteLength):null;if(!b||b.length>2097152)return [];
  const v=new DataView(b.buffer,b.byteOffset,b.byteLength),out=[];
  for(let p=0;p+12<=b.length;){const len=v.getUint32(p,true);if(len<9||len>1048576||p+len+4>b.length||v.getUint32(p+4,true)!==len)return out;out.push(stt(new TextDecoder().decode(b.subarray(p+12,p+len+3))));p+=len+4;}return out;
 }
 // Bounded reader for public Tars fields, used only to correlate official WebSocket replies.
 function tars(raw){
  const a=raw instanceof Uint8Array?raw:new Uint8Array(raw);if(a.length>2097152)throw Error('packet size');
  const b=new DataView(a.buffer,a.byteOffset,a.byteLength);let p=0;
  const take=n=>{if(n<0||p+n>a.length)throw Error('truncated');const r=a.slice(p,p+n);p+=n;return r;};
  const num=n=>{const q=p;take(n);return n===1?b.getInt8(q):n===2?b.getInt16(q):n===4?b.getInt32(q):Number(b.getBigInt64(q));};
  const head=()=>{const h=take(1)[0];return {tag:h>>>4===15?take(1)[0]:h>>>4,type:h&15};};
  const next=d=>value(head().type,d+1);
  const count=d=>{const n=next(d);if(!Number.isInteger(n)||n<0||n>100000)throw Error('count');return n;};
  const fields=d=>{const r=new Map();while(p<a.length){const h=head();if(h.type===11)break;r.set(h.tag,value(h.type,d+1));if(r.size>256)throw Error('fields');}return r;};
  function value(t,d){
   if(d>16)throw Error('depth');
   switch(t){
    case 0:return num(1);case 1:return num(2);case 2:return num(4);case 3:return num(8);case 12:return 0;
    case 6:return new TextDecoder().decode(take(take(1)[0]));case 7:return new TextDecoder().decode(take(num(4)));
    case 8:{const n=count(d),r=new Map();for(let i=0;i<n;i++)r.set(next(d),next(d));return r;}
    case 9:{const n=count(d),r=[];for(let i=0;i<n;i++)r.push(next(d));return r;}
    case 10:return fields(d);
    case 13:if((take(1)[0]&15)!==0)throw Error('bytes');return take(count(d));
    default:throw Error('unsupported');
   }
  }
  return fields(0);
 }
 function huyaPacket(raw){
  try{const cmd=tars(raw),op=cmd.get(0);if(op!==3&&op!==4)return null;
   const data=cmd.get(1);if(!(data instanceof Uint8Array)||data.length<4)return null;
   const env=tars(data.slice(4)),values=tars(env.get(7)).get(0);return {op,fn:env.get(6),id:env.get(4),values};
  }catch{return null;}
 }
 function installSocket(){
  const send=WebSocket.prototype.send,seen=new WeakSet();
  WebSocket.prototype.send=function(data){
   if(platform==='huya'&&state.armed){
    const out=huyaPacket(data);
    if(out?.op===3&&out.fn==='sendMessage'){
     const req=tars(out.values.get('tReq')).get(0);
     if(req?.get(3)===message){
      if(wire)throw Error('本次消息已提交，禁止自动重发');wire=true;huyaRequest={id:out.id,fn:out.fn};
      this.addEventListener('message',async e=>{
       const raw=e.data instanceof Blob?await e.data.arrayBuffer():e.data,r=huyaPacket(raw);
       if(r?.op!==4||r.id!==huyaRequest?.id||r.fn!==huyaRequest?.fn)return;
       state.diagnostic='Huya response keys: '+[...r.values.keys()].map(String).join(',');
       try{
        const ret=tars(r.values.get('')).get(0),rsp=tars(r.values.get('tRsp')).get(0),status=rsp.get(0)??0;
        state.diagnostic='Huya ret '+ret+' / status '+status;
        if(ret===0&&status===0)result(true,'huya-sendMessage-response');
        else if(typeof ret==='number'&&typeof status==='number')fail('虎牙未接受弹幕（'+ret+'/'+status+'）。请到官方房间查看发言限制');
       }catch{}
      });
     }
    }
   }
   if(platform==='douyu'&&state.armed){
    const frames=douyuFrames(data),out=frames.find(x=>x.type==='chatmessage'&&x.content===message);
    if(out){
     if(wire)throw Error('本次消息已提交，禁止自动重发');wire=true;uid=out.sender||uid;
     if(!seen.has(this)){
      seen.add(this);this.addEventListener('message',async e=>{
       const raw=e.data instanceof Blob?await e.data.arrayBuffer():e.data;
       for(const m of douyuFrames(raw)){
        if(m.type==='chatmsg'&&m.txt===message&&String(m.uid)===uid)result(true,'douyu-server-chatmsg');
        if(m.type==='chatres'){
         const code=m.res??m.code??m.error;
         state.diagnostic='Douyu chatres code '+String(code)+' / keys '+Object.keys(m).join(',');
         if(code==='0')result(true,'douyu-chatres');
         else if(code!==undefined)fail('斗鱼未接受弹幕（'+String(code).slice(0,12)+'）。请到官方房间查看发言限制');
        }
       }
      });
     }
    }
   }
   return send.call(this,data);
  };
 }
 function installHuya(){
  if(huyaReady||!window.TTP?.ready)return;
  window.TTP.ready(t=>{huyaReady=!!t.taf?.HUYA?.SendMessageRsp;});
 }
 function inspect(p){
  platform=p;
  if(!installed){installed=true;installSocket();
   // The worker must not become a second audible player.
   try{HTMLMediaElement.prototype.play=function(){this.muted=true;this.pause();return Promise.resolve();};}catch{}
  }
  document.querySelectorAll('video,audio').forEach(e=>{e.muted=true;e.pause();});
  if(p==='huya')installHuya();
  const e=editor(p);state.ready=visible(e)&&(p==='douyin'?!!button(p):visible(button(p)))&&(p!=='huya'||huyaReady);
  return {ready:state.ready,submitted:state.submitted,error:state.error,receipt:state.receipt,armed:state.armed,wire,diagnostic:state.diagnostic};
 }
 function commit(p,text){
  if(state.armed)return false;
  const e=editor(p);if(!inspect(p).ready||!text||[...text].length>40)return false;
  state.armed=true;message=text;uid=p==='douyu'?cookie('acf_uid'):'';
  try{
   if(p==='douyin')installHttp(); // Install after the official signing SDK, immediately before this one user send.
   e.focus();
   if(e.isContentEditable){
    const range=document.createRange();range.selectNodeContents(e);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
    // Let the official rich-text editor update its own state; no React/private-state injection.
    if(!document.execCommand('insertText',false,text)){fail('官方输入框未接受文本，本次未发送');return false;}
   }else{
    const setter=Object.getOwnPropertyDescriptor(e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype,'value').set;setter.call(e,text);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
   }
   const waitStart=performance.now();
   const submit=()=>{
    try{
     const b=button(p);
     if(p==='douyin'){
      if(!b||b.hasAttribute('disabled')||b.classList.contains('disable')){
       if(performance.now()-waitStart<2500){setTimeout(submit,100);return;}
       fail('抖音发送按钮仍未就绪，本次未发送。请到官方页面查看登录或验证提示');return;
      }
      // The official control is an SVG button, not an HTML button; synthetic Enter is ignored by its editor.
      b.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
     }else b.click();
    }catch{fail('官方发送入口发生错误，请核实结果；没有自动重发');}
   };setTimeout(submit,150);
   return true;
  }catch{fail('官方输入框暂不可用，请到“账号 / 登录”检查验证提示');return false;}
 }
 window.FusionOfficialSender={inspect,commit};
})();
