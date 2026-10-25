// X8: service worker for the WebUI (browser/mobile). Enables notifications that
// persist in the OS notification center and can be shown while the tab is
// backgrounded, and handles server-sent Web Push when a push subscription +
// VAPID sender are configured (see /api/push/*). Foreground notifications also
// route through here via registration.showNotification.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

// Server-initiated Web Push: fires even when the tab is closed (once a push
// subscription is registered and the server sends with VAPID).
self.addEventListener("push", (event) => {
  let data = { title: "Glyph Studio", body: "You have an update." };
  try { if (event.data) data = { ...data, ...event.data.json() }; } catch { /* plain text fallback */ }
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/logo-512.png",
      badge: "/logo-512.png",
      tag: data.tag || "prevail",
    }),
  );
});

// Clicking a notification focuses an existing Prevail tab, or opens one.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const w of wins) { if ("focus" in w) return w.focus(); }
      if (self.clients.openWindow) return self.clients.openWindow("/");
    }),
  );
});
