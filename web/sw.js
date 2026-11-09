// herd's service worker: keeps the page's shell (HTML, CSS, JS, manifest, icons) so the PWA opens
// without a network, and shows "offline" instead of a browser error. It never caches /api: stream
// data, diffs and screens always come from the server or not at all.
//
// Served at /sw.js (not /static/) so its scope is the whole page.

const CACHE = "herd-shell-2";
const SHELL = [
  "/",
  "/static/app.css",
  "/static/app.js",
  "/static/manifest.webmanifest",
  "/static/icons/icon-192.png",
  "/static/icons/icon-512.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Network first, so a new page shows up at once; the cache only when the network fails. Only
// same-origin GETs of shell files are touched, and /api never is.
self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/") || url.pathname === "/healthz") return;
  const key = req.mode === "navigate" ? "/" : url.pathname;
  if (!SHELL.includes(key)) return;
  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(key, copy));
        }
        return res;
      })
      .catch(() => caches.match(key).then((hit) => hit || Response.error())),
  );
});
