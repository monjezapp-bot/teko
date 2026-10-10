(function(){
try{
var SS=sessionStorage,q=new URLSearchParams(location.search);
if(document.referrer.indexOf('android-app://')===0)SS.setItem('teko_twa','1');
if(q.get('apk'))SS.setItem('teko_apk',q.get('apk'));
if(SS.getItem('teko_twa')!=='1')return;
var cur=parseInt(SS.getItem('teko_apk')||'1',10);
fetch('version.json?t='+Date.now(),{cache:'no-store'})
.then(function(r){return r.json()})
.then(function(v){
 if(!v||!(v.latest>cur)||!v.url)return;
 if(!v.force&&SS.getItem('teko_later')==='1')return;
 show(v);
}).catch(function(){});
function show(v){
 var d=document.createElement('div');
 d.dir='rtl';
 d.style.cssText='position:fixed;top:0;left:0;right:0;z-index:99999;background:#1d2540;color:#fff;padding:calc(env(safe-area-inset-top,0px) + 10px) 14px 12px;font:15px/1.5 system-ui,sans-serif;box-shadow:0 2px 12px rgba(0,0,0,.3)';
 d.innerHTML='<div style="margin-bottom:8px">يتوفر إصدار جديد من التطبيق.'+(v.notes?' '+String(v.notes).replace(/</g,'&lt;'):'')+'</div>';
 var b=document.createElement('button');
 b.textContent='تحديث الآن';
 b.style.cssText='background:#00A8E1;color:#fff;border:0;border-radius:8px;padding:8px 16px;font:inherit;margin-inline-end:8px';
 b.onclick=function(){window.open(v.url,'_blank')};
 d.appendChild(b);
 if(!v.force){
  var l=document.createElement('button');
  l.textContent='لاحقاً';
  l.style.cssText='background:transparent;color:#cbd5e1;border:1px solid #475569;border-radius:8px;padding:8px 16px;font:inherit';
  l.onclick=function(){SS.setItem('teko_later','1');d.remove()};
  d.appendChild(l);
 }
 document.body.appendChild(d);
}
}catch(e){}
})();
