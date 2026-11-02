/* Add a third independent source while retaining the original controls and listeners. */
(()=>{'use strict';const $=id=>document.getElementById(id);
function clone(node){const c=node.cloneNode(true);for(const e of [c,...c.querySelectorAll('*')]){for(const a of ['id','for'])if(e.hasAttribute(a))e.setAttribute(a,e.getAttribute(a).replace(/B/g,'C'));if(e.classList.contains('badge')){e.classList.remove('b');e.classList.add('c');}if(e.hasAttribute('aria-label'))e.setAttribute('aria-label',e.getAttribute('aria-label').replace(/B|二路/g,'C'));}
 const walk=document.createTreeWalker(c,NodeFilter.SHOW_TEXT);while(walk.nextNode())walk.currentNode.textContent=walk.currentNode.textContent.replace(/\bB\b/g,'C').replace(/二路直播间/g,'第三路直播间');return c;}
const room=clone($('roomB').closest('.room-slot'));$('roomB').closest('.room-slot').after(room);$('roomC').value='';$('previewC').textContent='可选第三路';
$('roomCLabel')?.replaceChildren('第三路直播间');
for(const s of ['A','B','C']){const label=$('room'+s).closest('.room-slot').querySelector('label'),e=document.createElement('input');e.id='enabled'+s;e.type='checkbox';e.checked=s!=='C';e.setAttribute('aria-label','启用 '+s);label.prepend(e);}
$('viewB').after(clone($('viewB')));$('viewC').setAttribute('aria-hidden','true');
$('statusB').parentElement.after(clone($('statusB').parentElement));
for(const id of ['qualityB','audioOnlyB','volumeB','delayB','chatB','scB']){const node=$(id).closest('label');node.after(clone(node));}
for(const id of ['chatStatsB','qualityBState','refreshQualityB','verifyQualityB','refreshB'])if($(id))$(id).after(clone($(id)));
const onlyA=clone($('audioOnlyB').closest('label'));for(const e of [onlyA,...onlyA.querySelectorAll('*')])if(e.id==='audioOnlyC')e.id='audioOnlyA';onlyA.querySelector('input').checked=false;onlyA.childNodes.forEach(n=>{if(n.nodeType===3)n.textContent=n.textContent.replace(/\bC\b/g,'A');});onlyA.querySelectorAll('span').forEach(n=>n.textContent=n.textContent.replace(/\bC\b/g,'A'));$('audioOnlyB').closest('label').before(onlyA);
$('audioOnlyC').checked=true;
const target=new Option('发送 C','C');$('target').append(target);
const three=document.createElement('button');three.id='threeView';three.type='button';three.textContent='三画面';$('dual').after(three);
const audio=document.createElement('button');audio.id='audioBC';audio.type='button';audio.textContent='BC 仅音频';$('settings').querySelector('h3').before(audio);
const share=document.createElement('button');share.id='shareConfig';share.type='button';share.textContent='延迟分享';document.querySelector('header').append(share);
const sharePlay=share.cloneNode(true);sharePlay.id='shareFromPlayer';$('stageMenu').append(sharePlay);
for(const id of ['enabledA','enabledB','enabledC'])$(id).addEventListener('change',()=>{document.dispatchEvent(new Event('fusion-source-selection'));});
document.body.classList.add('fusion-triple');
})();

