 self.addEventListener("push", (event) => {
  const data = event.data ? event.data.json() : {};
  event.waitUntil(self.registration.showNotification(data.title || "DrugXOne", {
    body: data.body || "You have a new notification.",
    icon: "/favicon.ico",
    badge: "/favicon.ico",
    tag: data.tag || "drugxone-notification",
    renotify: true,
    requireInteraction: true,
    data: { link: data.link || "/notifications" },
  }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data?.link || "/notifications"));
});
