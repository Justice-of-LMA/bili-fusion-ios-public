(function(root){
'use strict';
const clamp=(x,a,b)=>Math.min(b,Math.max(a,Number(x)||0));
const object=x=>{if(x&&typeof x==='object'&&!Array.isArray(x))return x;if(typeof x==='string'&&x.length<100000){try{return object(JSON.parse(x));}catch{}}return {};};
function imageUrl(value){
  if(typeof value!=='string'||value.length>2048)return '';
  try{const u=new URL(value.startsWith('//')?'https:'+value:value);
    if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.port)return '';
    if(!['hdslb.com','biliimg.com','bilibili.com','bilivideo.com','douyinpic.com','byteimg.com'].some(d=>u.hostname===d||u.hostname.endsWith('.'+d)))return '';
    u.protocol='https:';return u.href;
  }catch{return '';}
}
function roomImageUrl(value){
  if(imageUrl(value))return imageUrl(value);
  if(typeof value!=='string'||value.length>2048)return '';
  try{const u=new URL(value.startsWith('//')?'https:'+value:value);
    if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.port)return '';
    if(!['msstatic.com','douyucdn.cn','douyucdn2.cn','byteimg.com'].some(d=>u.hostname===d||u.hostname.endsWith('.'+d)))return '';
    u.protocol='https:';return u.href;
  }catch{return '';}
}
const string=x=>String(x??'').slice(0,2000);
// Only complete platform tokens are textual replacements, never bare words.
const emojiToken=x=>/^(?:\[[^\[\]【】\r\n]{1,98}\]|【[^\[\]【】\r\n]{1,98}】)$/.test(x);
class EmojiBook{
  constructor(){this.items=new Map();}
  add(label,data){
    const url=imageUrl(data?.url),name=string(label).trim();
    const key=emojiToken(name)?'['+name.slice(1,-1)+']':(/^[^\[\]【】\r\n]{1,98}$/.test(name)&&name!=='表情'?'['+name+']':'');
    if(!url||!key)return;
    this.items.set(key,{type:'emoji',url,alt:key,ratio:clamp(Number(data.width)/Number(data.height)||data.ratio||1,.5,3)});
    if(this.items.size>2000)this.items.delete(this.items.keys().next().value);
    if(key.startsWith('[')&&key.endsWith(']'))this.items.set('【'+key.slice(1,-1)+'】',this.items.get(key));
  }
  learn(data,depth=0,budget={n:0}){
    if(depth>8||++budget.n>8000||!data||typeof data!=='object')return;
    const url=imageUrl(data.url||data.emoticon_url);
    if(url)for(const label of [data.emoji,data.emoticon_unique,data.alt,data.text,...(Array.isArray(data.aliases)?data.aliases:[])])this.add(label,{...data,url});
    if(Array.isArray(data))for(const value of data.slice(0,1000))this.learn(value,depth+1,budget);
    else for(const [key,value] of Object.entries(data).slice(0,300)){
      if(value&&typeof value==='object'&&imageUrl(value.url))this.add(key,value);
      if(key!=='aliases')this.learn(value,depth+1,budget);
    }
  }
  segments(text,direct,inline){
    text=string(text);for(const [label,data] of Object.entries(object(inline)))this.add(label,object(data));
    if(imageUrl(direct?.url))return [{type:'emoji',url:imageUrl(direct.url),alt:text||'[表情]',ratio:clamp(Number(direct.width)/Number(direct.height)||1,.5,3)}];
    const keys=[...this.items.keys()].filter(k=>text.includes(k)).sort((a,b)=>b.length-a.length);
    if(!keys.length)return [{type:'text',value:text}];
    const out=[];let pos=0,count=0,run='';
    while(pos<text.length){
      const key=count<24?keys.find(k=>text.startsWith(k,pos)):null;
      if(key){if(run){out.push({type:'text',value:run});run='';}out.push({...this.items.get(key),alt:key});pos+=key.length;count++;}
      else run+=text[pos++];
    }
    if(run)out.push({type:'text',value:run});return out;
  }
}
function cleanSegments(input){
  const result=[];
  for(const s of (Array.isArray(input)?input:[]).slice(0,48)){
    if(s.type==='emoji'&&imageUrl(s.url)){
      result.push({type:'emoji',url:imageUrl(s.url),alt:string(s.alt)||'[表情]',ratio:clamp(s.ratio||1,.5,3)});
    }else if(s.type==='text'){
      let value=string(s.value),previous=result[result.length-1];
      // A crawler may provide IMG plus its immediately adjacent exact fallback label.
      // Never delete unrelated / unknown emoji tokens elsewhere in the sentence.
      if(previous?.type==='emoji'){
        for(const alias of [previous.alt,previous.alt.replace(/^\[/,'【').replace(/\]$/,'】')]){
          if(emojiToken(alias)&&value.startsWith(alias)){value=value.slice(alias.length);break;}
        }
      }
      if(value)result.push({type:'text',value});
    }
  }
  return result;
}
function normalize(packet,book=new EmojiBook(),now=Date.now()){
  const cmd=String(packet?.cmd||'').split(':')[0],d=object(packet?.data);
  if(cmd==='DANMU_MSG'){
    const info=packet.info;if(!Array.isArray(info))return null;
    const meta=info[0]||[],extra=object(object(meta[15]).extra),text=string(info[1]);
    return {type:'chat',user:string(info[2]?.[1]),uid:string(info[2]?.[0]),text,color:clamp(meta[3]||16777215,0,16777215),
      segments:book.segments(text,object(meta[13]),extra.emots),received:now};
  }
  if(cmd==='SUPER_CHAT_MESSAGE'||cmd==='SUPER_CHAT_MESSAGE_JPN'){
    const id=string(d.id);if(!id)return null;
    const total=clamp(d.time||Number(d.end_time)-Number(d.start_time)||60,1,7200);
    const expiry=Number(d.end_time)*1000,remaining=expiry>0?clamp((expiry-now)/1000,0,total):total;
    if(remaining<=0)return null;
    return {type:'sc',id,text:string(d.message),user:string(d.user_info?.uname||d.uname),uid:string(d.uid),
      avatar:imageUrl(d.user_info?.face),price:clamp(d.price,0,10000000),duration:remaining,totalDuration:total,
      segments:book.segments(string(d.message)),received:now};
  }
  if(cmd==='SUPER_CHAT_MESSAGE_DELETE')return {type:'delete',ids:(Array.isArray(d.ids)?d.ids:[]).slice(0,1000).map(String)};
  return null;
}
class Timeline{
  constructor(){this.items=[];this.sc=new Map();this.deleted=new Set();this.serial=0;this.closed=new Set();this.cursor=0;}
  add(event,at){
    if(!event||!Number.isFinite(at))return;
    if(event.type==='delete'){for(const id of event.ids){this.deleted.add(id);this.sc.delete(id);}while(this.deleted.size>2000)this.deleted.delete(this.deleted.values().next().value);return;}
    if(event.type==='sc'){
      if(this.deleted.has(event.id)||this.sc.has(event.id))return;
      this.sc.set(event.id,{...event,at});while(this.sc.size>200)this.sc.delete(this.sc.keys().next().value);return;
    }
    this.items.push({...event,at,serial:++this.serial});
    if(this.items.length>1200)this.items.splice(0,this.items.length-1200);
  }
  drain(time,maxAge=2){
    const output=[];
    for(const m of this.items)if(m.serial>this.cursor&&m.at<=time){this.cursor=m.serial;if(time-m.at<=maxAge)output.push(m);}
    return output.slice(-16);
  }
  seek(time){this.cursor=0;for(const m of this.items)if(m.at<time)this.cursor=m.serial;}
  cards(time){
    const out=[];
    for(const [id,m] of this.sc){
      if(time-m.at>m.duration+45){this.sc.delete(id);this.closed.delete(id);continue;}
      if(!this.closed.has(id)&&time>=m.at&&time<m.at+m.duration)out.push({...m,left:m.at+m.duration-time,fraction:clamp((m.at+m.duration-time)/m.totalDuration,0,1)});
    }
    return out;
  }
  dismiss(id){this.closed.add(id);}
}
// One shared lane scheduler for both rooms, using identical pixels/second.
class Lanes{
  constructor(count=6,speed=95){this.baseSpeed=speed;this.speed=speed;this.reset(count);}
  setSpeed(value,bullets=[],stageWidth=0){
    const n=Number(value),next=this.baseSpeed*(Number.isFinite(n)?clamp(n,.5,2):1),ratio=this.speed/next;
    if(next===this.speed)return;
    for(const b of bullets){b.age*=ratio;b.duration=(Math.max(0,stageWidth)+b.width+4)/next;}
    this.speed=next;this.tail.fill(-Infinity);
  }
  reset(count=this.count){this.count=count;this.tail=Array(count).fill(-Infinity);this.next=0;}
  enter(width,stageWidth,now,nonOverlap=true){
    let lane=-1;
    // Fair rotation: sparse B-only messages should still use the selected vertical area.
    for(let i=0;i<this.count;i++){const candidate=(this.next+i)%this.count;if(!nonOverlap||this.tail[candidate]<=now){lane=candidate;break;}}
    if(lane<0)return null;
    this.next=(lane+1)%this.count;
    this.tail[lane]=now+(width+32)/this.speed;
    return {lane,duration:(stageWidth+width+4)/this.speed};
  }
}
function delayAction(current,previous,next,ranges){
  previous=clamp(previous,0,20);next=clamp(next,0,20);
  const delta=next-previous;
  if(Math.abs(delta)<.001)return {seek:null,hold:0};
  const containing=ranges.find(([a,b])=>current>=a&&current<=b);
  if(!containing)return {seek:null,hold:Math.max(0,delta)};
  if(delta>0){const back=Math.min(delta,Math.max(0,current-containing[0]-.1));return {seek:back>.05?current-back:null,hold:Math.max(0,delta-back)};}
  const target=Math.max(current,Math.min(containing[1]-.15,current-delta));
  return {seek:target>current+.001?target:null,hold:0};
}
// A download endpoint is not a presentation clock. Only the delay chosen by the
// viewer should put new messages ahead of the current playhead. During a deliberate
// accumulation pause, subtract the remaining hold so each arrival still waits D seconds.
function messageTime(current,delay=0,holdRemaining=0){
  if(!Number.isFinite(current)||current<0)return null;
  return current+Math.max(0,clamp(delay,0,20)-Math.max(0,Number(holdRemaining)||0));
}
function laneLayout(height,size,area,limit){
  size=clamp(size,14,32);
  const regionHeight=Math.max(0,Number(height)||0)*clamp(area,25,100)/100;
  const top=8,bottom=3,rowHeight=size*1.55,usable=regionHeight-top-bottom;
  const count=usable<rowHeight?0:Math.min(Math.floor(clamp(limit,1,20)),1+Math.floor((usable-rowHeight)/(size*1.7)));
  // Row count controls density, not the area's boundary. Spread the rows across the area.
  const step=count>1?(usable-rowHeight)/(count-1):0;
  return {height:regionHeight,count,rowHeight,tops:Array.from({length:count},(_,i)=>top+i*step)};
}
function laneCount(height,size,area,limit){return laneLayout(height,size,area,limit).count;}
// One explicit action, at most two distinct rooms. Never retry an uncertain result.
async function sendBatch(targets,send,{active=()=>true,wait=ms=>new Promise(r=>setTimeout(r,ms)),progress=()=>{}}={}){
  if(!Array.isArray(targets)||targets.length<1||targets.length>2)throw Error('仅支持 A / B 两个发送目标');
  const rooms=new Map();
  for(const t of targets){
    const platform=t.platform||'bilibili',room=String(t.room);
    if(!/^[AB]$/.test(t.source)||!['bilibili','huya','douyu','douyin'].includes(platform)||
      !(platform==='huya'?/^[A-Za-z0-9_-]{1,40}$/.test(room):/^[1-9][0-9]{0,15}$/.test(room)&&Number.isSafeInteger(Number(room))))throw Error('发送目标无效');
    const key=platform+':'+room;if(rooms.has(key))rooms.get(key).sources.push(t.source);else rooms.set(key,{room,platform,sources:[t.source]});
  }
  const results=[];let index=0;
  for(const item of rooms.values()){
    // Retain the native five-second throttle; dual-send is not a fast-send bypass.
    if(index++&&active()){progress('wait',results);await wait(5100);}
    if(!active()){results.push({...item,submitted:false,error:'已取消：房间、账号或观看状态已改变'});continue;}
    progress('sending',results,item);
    try{
      const reply=await send(item.room,item.platform);
      if(reply?.submitted!==true)throw Error('未收到明确的提交确认，请到房间核实；没有自动重发');
      results.push({...item,submitted:true});
    }catch(e){results.push({...item,submitted:false,error:e.message||'发送结果未知，没有自动重发'});}
    progress('result',results);
  }
  return results;
}
const api={clamp,imageUrl,roomImageUrl,EmojiBook,cleanSegments,normalize,Timeline,Lanes,delayAction,messageTime,laneCount,laneLayout,sendBatch};
if(typeof module!=='undefined')module.exports=api;else root.FusionCore=api;
})(globalThis);
