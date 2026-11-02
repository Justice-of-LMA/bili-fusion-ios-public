(()=>{'use strict';
window.FusionWebLayout={mount(hooks){
 const stage=document.getElementById('stage'),history=document.getElementById('normalHistory'),composer=document.getElementById('composer');
 if(!stage||!history||!composer)return null;
 const shell=document.createElement('div');shell.id='webLayoutShell';shell.hidden=true;document.body.append(shell);
 const head=document.createElement('div');head.className='web-layout-head';const title=document.createElement('strong');title.textContent='同屏弹幕';head.append(title);
 function button(text,action){const b=document.createElement('button');b.type='button';b.textContent=text;b.onclick=action;head.append(b);return b;}
 const pause=button('暂停',()=>{document.getElementById('pause').click();pause.textContent=document.getElementById('pause').textContent;});button('横竖',()=>hooks.rotate());button('设置',()=>{document.getElementById('settings').hidden=false;});button('退出',()=>api.exit());history.prepend(head);head.hidden=true;
 const entry=document.createElement('button');entry.id='webLayoutToggle';entry.type='button';entry.textContent='网页全屏布局';document.getElementById('stageMenu').append(entry);
 let active=false,snapshot=null,places=[];
 function mark(node){const marker=document.createComment('web-layout-return');node.before(marker);places.push([node,marker]);}
 const api={get active(){return active;},preserve(config){if(active&&snapshot){for(const source of ['B','C'])config['audioOnly'+source]=snapshot['audioOnly'+source];config.dual=snapshot.dual;}},
 enter(){if(active)return;if(!hooks.ready()){hooks.notice('请先开始主直播间播放');return;}
  snapshot={audioOnlyB:document.getElementById('audioOnlyB').checked,audioDisabled:document.getElementById('audioOnlyB').disabled,dual:document.body.classList.contains('dual')};for(const source of ['B','C']){snapshot['audioOnly'+source]=document.getElementById('audioOnly'+source).checked;snapshot['disabled'+source]=document.getElementById('audioOnly'+source).disabled;document.getElementById('audioOnly'+source).disabled=true;}active=true;pause.textContent=document.getElementById('pause').textContent;
  mark(stage);mark(history);mark(composer);shell.append(stage,history);history.append(composer);head.hidden=false;shell.hidden=false;document.body.classList.add('web-layout');document.getElementById('settings').hidden=true;
  hooks.audio(true,snapshot);hooks.clear();window.iosLayout?.();
 },
 exit(options={}){if(!active)return;active=false;document.body.classList.remove('web-layout');head.hidden=true;shell.hidden=true;document.getElementById('settings').hidden=true;
  for(const [node,marker] of places){marker.replaceWith(node);}places=[];for(const source of ['B','C'])document.getElementById('audioOnly'+source).disabled=snapshot['disabled'+source];hooks.audio(false,snapshot,options.restoreMedia!==false);snapshot=null;hooks.clear();window.iosLayout?.();
 }};
 entry.onclick=()=>api.enter();document.addEventListener('keydown',e=>{if(e.key==='Escape'&&active){api.exit();e.preventDefault();}});
 return api;
}};
})();
