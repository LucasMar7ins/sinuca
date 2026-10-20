// Sinuca de Bar: service worker simples. Sempre busca a versão nova na rede (nada fica velho em cache).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(fetch(e.request).catch(() => new Response('<meta charset="utf-8"><body style="background:#0f0f0f;color:#f5f3ee;font:20px sans-serif;display:grid;place-items:center;height:100vh;margin:0;text-align:center">Sem internet.<br>O Seu Zé espera você voltar.</body>', {headers: {'content-type': 'text/html; charset=utf-8'}})));
});
