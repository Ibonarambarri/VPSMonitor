const CACHE_PREFIX = "vps-monitor-shell-";
const CACHE_NAME = `${CACHE_PREFIX}v2`;
const SHELL_FILES = [
  "/",
  "/index.html",
  "/styles.css",
  "/app.js",
  "/manifest.webmanifest",
  "/icons/favicon.svg"
];
const STATIC_PATHS = new Set(SHELL_FILES.map((path) => new URL(path, self.location.origin).pathname));

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_FILES))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys
        .filter((key) => key.startsWith(CACHE_PREFIX) && key !== CACHE_NAME)
        .map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname === "/api" || url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirstNavigation(request));
    return;
  }

  if (STATIC_PATHS.has(url.pathname)) {
    event.respondWith(networkFirstStatic(request));
  }
});

async function networkFirstNavigation(request) {
  try {
    const response = await fetch(request);
    const pathname = new URL(request.url).pathname;
    if (response.ok && (pathname === "/" || pathname === "/index.html")) {
      const cache = await caches.open(CACHE_NAME);
      await cache.put("/index.html", response.clone());
    }
    return response;
  } catch {
    return await caches.match("/index.html") || await caches.match("/");
  }
}

async function networkFirstStatic(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      await cache.put(request, response.clone());
    }
    return response;
  } catch {
    return await caches.match(request) || Response.error();
  }
}

self.addEventListener("push", (event) => {
  let kind = "alert";
  let count = 1;
  try {
    const payload = event.data?.json();
    if (payload?.kind === "resolved") kind = "resolved";
    if (Number.isSafeInteger(payload?.count) && payload.count > 0) count = payload.count;
  } catch {
    // Invalid payloads still produce a generic, non-sensitive notification.
  }
  const body = kind === "resolved"
    ? "Las incidencias se han resuelto."
    : count === 1
      ? "Hay una incidencia activa. Abre VPS Monitor para consultarla."
      : `Hay ${count} incidencias activas. Abre VPS Monitor para consultarlas.`;
  event.waitUntil(self.registration.showNotification("VPS Monitor", {
    body,
    icon: "/icons/icon-192.png",
    badge: "/icons/icon-192.png",
    tag: "vps-monitor-alert",
    renotify: true,
    data: { url: "/#/alerts" }
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetURL = new URL(event.notification.data?.url || "/#/alerts", self.location.origin).href;
  event.waitUntil(openOrFocus(targetURL));
});

async function openOrFocus(targetURL) {
  const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  for (const client of windows) {
    if ("navigate" in client) await client.navigate(targetURL);
    if ("focus" in client) return client.focus();
  }
  return self.clients.openWindow ? self.clients.openWindow(targetURL) : undefined;
}
