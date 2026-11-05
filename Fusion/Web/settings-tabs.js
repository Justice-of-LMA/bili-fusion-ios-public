/* Reparent existing controls so values, IDs and playback listeners stay intact. */
(()=>{'use strict';
const root=document.getElementById('settings');if(!root||root.dataset.categorized)return;
root.dataset.categorized='true';
const title=root.querySelector('.settings-title'),nav=document.createElement('div'),body=document.createElement('div');
nav.className='settings-tabs';nav.setAttribute('role','tablist');nav.setAttribute('aria-label','观看设置分类');body.className='settings-content';
const definitions=[['video','视频设置'],['audio','声音与同步'],['chat','弹幕设置'],['sc','SC 设置']],panels={},buttons={};
for(const [key,label] of definitions){const button=document.createElement('button'),panel=document.createElement('section');button.type='button';button.id='settings-tab-'+key;button.textContent=label;button.setAttribute('role','tab');button.setAttribute('aria-controls','settings-panel-'+key);panel.id='settings-panel-'+key;panel.className='settings-panel';panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',button.id);nav.append(button);body.append(panel);panels[key]=panel;buttons[key]=button;}
let section='chat',scHints=false;
for(const node of [...root.children]){if(node===title)continue;
 if(node.tagName==='H3'){const text=node.textContent;section=/清晰度|播放与后台|画中画/.test(text)?'video':/声音与同步/.test(text)?'audio':'chat';scHints=false;}
 if(node.classList.contains('toggles')){for(const label of [...node.children]){const id=label.querySelector('input')?.id||'';const key=/^sc[ABC]$/.test(id)?'sc':'chat';let group=panels[key].querySelector('.toggles');if(!group){group=document.createElement('div');group.className='toggles';panels[key].append(group);}group.append(label);}node.remove();scHints=false;section='chat';continue;}
 const ids=[node.id,...[...node.querySelectorAll('[id]')].map(e=>e.id)].join(' ');
 let key=section;
 if(/\b(scLifetimeSettings|scPosition|scCorner|scDrag|scDraggable)\b/.test(ids)){key='sc';scHints=true;}
 else if(node.tagName==='P'&&scHints)key='sc';
 else if(/\b(audioBC|audioOnly[ABC]|audioModeHint)\b/.test(ids)){key='video';scHints=false;}
 else if(/\b(volume[ABC]|delay[ABC]|voice\w*)\b/.test(ids)){key='audio';scHints=false;}
 else if(/\b(networkResolutionSettings|streamFormat[ABC]|quality[ABC]\w*|refreshQuality[ABC]|verifyQuality[ABC]|backgroundMode|screenOrientation|pip\w*)\b/.test(ids)){key='video';scHints=false;}
 else if(/\b(chat\w*|refresh[ABC]|reconnect|verify|blockingSettings|size|opacity|font|color|marker|maxRows|nonOverlap|mergeSame|user|original)\b/.test(ids)){key='chat';scHints=false;}
 panels[key].append(node);
}
root.append(nav,body);
function select(key){if(!panels[key])key='video';for(const [name] of definitions){panels[name].hidden=name!==key;buttons[name].setAttribute('aria-selected',String(name===key));buttons[name].tabIndex=name===key?0:-1;}body.scrollTop=0;try{localStorage.setItem('fusion-settings-category',key);}catch{}root.dispatchEvent(new CustomEvent('settingscategory',{detail:key}));}
for(const [key] of definitions){buttons[key].onclick=()=>select(key);buttons[key].onkeydown=e=>{const index=definitions.findIndex(d=>d[0]===key);let next;if(e.key==='ArrowRight')next=(index+1)%4;if(e.key==='ArrowLeft')next=(index+3)%4;if(e.key==='Home')next=0;if(e.key==='End')next=3;if(next!==undefined){e.preventDefault();select(definitions[next][0]);buttons[definitions[next][0]].focus();}};}
let saved;try{saved=localStorage.getItem('fusion-settings-category');}catch{}select(saved||'video');
window.FusionSettings={select};
})();
