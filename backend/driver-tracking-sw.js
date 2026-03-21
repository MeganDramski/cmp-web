/**
 * CMP Logistics — Driver Tracking Service Worker
 *
 * Responsibilities:
 *  1. Cache the page shell so the driver can open it even with no signal.
 *  2. Send a keep-alive ping to the app every 25 s (background periodic
 *     messaging) so the browser doesn't suspend the GPS watchPosition.
 *  3. Queue POST /location requests that fail while offline and replay them
 *     as soon as the network comes back (Background Sync where available).
 */

const CACHE_NAME   = 'cmp-driver-v1';
const ASSETS_CACHE = [
  'driver-tracking.html',
  'config.js',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
];

// ── Install: pre-cache app shell ──────────────────────────────────────────
self.addEventListener('install', function (evt) {
  evt.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      // Use individual requests so one failure doesn't abort the whole install
      return Promise.allSettled(
        ASSETS_CACHE.map(function (url) {
          return cache.add(url).catch(function (e) {
            console.warn('[SW] cache.add failed for', url, e);
          });
        })
      );
    })
  );
  self.skipWaiting();
});

// ── Activate: clean up old caches ────────────────────────────────────────
self.addEventListener('activate', function (evt) {
  evt.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys
          .filter(function (k) { return k !== CACHE_NAME; })
          .map(function (k) { return caches.delete(k); })
      );
    })
  );
  self.clients.claim();
});

// ── Fetch: network-first for API calls, cache-first for static assets ────
self.addEventListener('fetch', function (evt) {
  var url = evt.request.url;

  // Always go network-first for location POST/PATCH calls
  if (evt.request.method !== 'GET') {
    evt.respondWith(
      fetch(evt.request.clone()).catch(function () {
        // Let the page's own offline queue handle it; just return an error
        return new Response(JSON.stringify({ error: 'offline' }), {
          status: 503,
          headers: { 'Content-Type': 'application/json' },
        });
      })
    );
    return;
  }

  // Cache-first for known static assets, network-first + cache-update otherwise
  evt.respondWith(
    caches.match(evt.request).then(function (cached) {
      var networkFetch = fetch(evt.request).then(function (response) {
        if (response && response.status === 200 && response.type !== 'opaque') {
          var clone = response.clone();
          caches.open(CACHE_NAME).then(function (cache) { cache.put(evt.request, clone); });
        }
        return response;
      });
      return cached || networkFetch;
    })
  );
});

// ── Background Sync: replay queued location POSTs ────────────────────────
self.addEventListener('sync', function (evt) {
  if (evt.tag === 'cmp-location-sync') {
    evt.waitUntil(replayQueuedLocations());
  }
});

async function replayQueuedLocations() {
  // The page stores queued payloads in IndexedDB key 'cmp_location_queue'
  // This is a best-effort replay; the page JS also handles it via online event.
  try {
    var db = await openQueueDB();
    var items = await dbGetAll(db);
    for (var item of items) {
      try {
        var resp = await fetch(item.url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(item.payload),
        });
        if (resp.ok) {
          await dbDelete(db, item.id);
        }
      } catch (e) {
        // Still offline — leave in queue
        break;
      }
    }
    db.close();
  } catch (e) {
    console.warn('[SW] replayQueuedLocations error:', e);
  }
}

// ── Minimal IndexedDB helpers ─────────────────────────────────────────────
function openQueueDB() {
  return new Promise(function (resolve, reject) {
    var req = indexedDB.open('cmp_sw_queue', 1);
    req.onupgradeneeded = function (e) {
      e.target.result.createObjectStore('queue', { keyPath: 'id', autoIncrement: true });
    };
    req.onsuccess = function (e) { resolve(e.target.result); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

function dbGetAll(db) {
  return new Promise(function (resolve, reject) {
    var tx  = db.transaction('queue', 'readonly');
    var req = tx.objectStore('queue').getAll();
    req.onsuccess = function (e) { resolve(e.target.result); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

function dbDelete(db, id) {
  return new Promise(function (resolve, reject) {
    var tx  = db.transaction('queue', 'readwrite');
    var req = tx.objectStore('queue').delete(id);
    req.onsuccess = function () { resolve(); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

// ── Keep-alive ping to clients every 25 s ────────────────────────────────
// Prevents the browser from suspending the page's GPS watchPosition
// when the screen is on but the tab is backgrounded.
setInterval(function () {
  self.clients.matchAll({ type: 'window' }).then(function (clients) {
    clients.forEach(function (client) {
      client.postMessage({ type: 'SW_KEEPALIVE' });
    });
  });
}, 25000);
