// 990crm 출석 알림 (직원 폰). 서버가 보낸 알림을 화면에 띄우고, 누르면 CRM 출석부를 연다.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: '990crm', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || '990crm', {
    body: d.body || '', tag: d.tag || undefined, icon: '/crm-icon-192.png?v=6', badge: '/crm-icon-192.png?v=6', data: { url: d.url || (String(d.tag || '').startsWith('att-') ? '/crm.html#att' : '/crm.html'), att: String(d.tag || '').startsWith('att-') },
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/crm.html';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    const w = list.find((c) => c.url.includes('/crm.html'));
    if (w) { if (e.notification.data && e.notification.data.att) w.postMessage({ type: 'att' }); return w.focus(); } // 열려 있으면 출석부 띄우기
    return self.clients.openWindow(url); // 닫혀 있으면 출석부로 열기
  }));
});
