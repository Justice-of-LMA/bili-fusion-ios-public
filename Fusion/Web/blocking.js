/* Local-only user/keyword filtering; no platform moderation requests. */
((root)=>{
'use strict';
const platforms=['bilibili','huya','douyu','douyin'];
const text=v=>String(v??'').trim();
const uid=v=>{const s=text(v);return /^[A-Za-z0-9_-]{1,100}$/.test(s)&&!/^0+$/.test(s)?s:'';};
function identity(message={},platform='bilibili'){
 message=message&&typeof message==='object'?message:{};
 const p=platforms.includes(message.platform)?message.platform:platforms.includes(platform)?platform:'bilibili';
 return {platform:p,uid:uid(message.uid),name:text(message.user??message.name).slice(0,100)};
}
const key=u=>u.platform+':'+(u.uid?'id:'+u.uid:'name:'+u.name);
function normalize(value={}){
 const users=[],keywords=[],exactTexts=[],seen=new Set();value=value&&typeof value==='object'?value:{};
 for(const raw of (Array.isArray(value.users)?value.users:[]).slice(0,500)){const u=identity(raw,raw?.platform);if((u.uid||u.name)&&!seen.has(key(u))){users.push(u);seen.add(key(u));}}
 for(const raw of (Array.isArray(value.keywords)?value.keywords:[]).slice(0,200)){if(typeof raw!=='string')continue;const s=text(raw).slice(0,100);if(s&&!keywords.includes(s))keywords.push(s);}
 for(const s of (Array.isArray(value.exactTexts)?value.exactTexts:[]).slice(0,200))if(typeof s==='string'&&s.length>0&&s.length<=2000&&!exactTexts.includes(s))exactTexts.push(s);
 return {users,keywords,exactTexts};
}
function matches(rules,message,platform){
 if(!message||message.type==='delete')return false;
 const u=identity(message,platform);
 if(rules.users.some(b=>b.platform===u.platform&&(b.uid?!!u.uid&&b.uid===u.uid:!!u.name&&b.name===u.name)))return true;
 if((rules.exactTexts||[]).includes(String(message.text??'')))return true;
 const body=text(message.text).toLowerCase();return rules.keywords.some(k=>body.includes(k.toLowerCase()));
}
function addUser(rules,message,platform){const u=identity(message,platform);return normalize({...rules,users:[u,...rules.users]});}
const api={normalize,identity,key,matches,addUser,names:{bilibili:'B站',huya:'虎牙',douyu:'斗鱼',douyin:'抖音'}};
root.FusionBlocking=Object.freeze(api);if(typeof module!=='undefined')module.exports=api;
})(globalThis);
