const C='teko-v1';
self.addEventListener('install',e=>{self.skipWaiting()});
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return;const u=new URL(e.request.url);if(u.origin!==location.origin)return;
e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(C).then(k=>k.put(e.request,c));return r}).catch(()=>caches.match(e.request)))});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>l.length?l[0].focus():clients.openWindow('./')))});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch(_){d={title:'Teko',body:e.data?e.data.text():''}}
e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{if(l.some(c=>c.visibilityState=='visible'))return;return self.registration.showNotification(d.title||'Teko',{body:d.body||'',tag:d.tag||'teko',renotify:true,vibrate:d.urgent?[400,150,400,150,400,150,400]:[200],icon:'icon-192.png',badge:'icon-192.png',requireInteraction:!!d.urgent})}))});
