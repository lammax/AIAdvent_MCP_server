self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = {};
  }
  const notification = payload.notification || payload;
  const title = notification.title || 'Remote';
  const options = {
    body: notification.body || 'A new approval is waiting.',
    tag: notification.tag || 'remote-approval',
    renotify: false,
    icon: '/assets/remote-icon-192.png',
    badge: '/assets/remote-icon-192.png',
    data: {
      destination: notification.destination || '/approvals'
    }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const destination = event.notification.data?.destination || '/approvals';
  const target = new URL(destination, self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('navigate' in client) await client.navigate(target);
      if ('focus' in client) return client.focus();
    }
    return self.clients.openWindow(target);
  })());
});
