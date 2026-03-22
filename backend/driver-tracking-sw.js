/**
 * CMP Logistics — Driver Tracking Service Worker  (v3)
 *
 * Responsibilities:
 *  1. Cache the page shell so the driver can open it even with no signal.
 *  2. Background Sync  — replay queued POST /location when back online.
 *  3. Periodic Background Sync (Android Chrome) — post last-known location
 *     from IndexedDB even when the page is fully closed / backgrounded.
 *  4. Keep-alive ping every 25 s to open pages so the browser doesn't
 *     suspend GPS watchPosition, AND request a fresh location from them.
 *  5. Store last-known location in IndexedDB so the SW can send it even
 *     when the page JS is suspended by the OS.
 */

const CACHE_NAME   = 'cmp-driver-v3';
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

// ── Periodic Background Sync ──────────────────────────────────────────────
// Fires even when the page is fully closed (Android Chrome on HTTPS only).
// We post the last-known location so the server doesn't think the driver
// has gone offline.
self.addEventListener('periodicsync', function (evt) {
  if (evt.tag === 'cmp-location-heartbeat') {
    evt.waitUntil(postLastKnownLocation());
  }
});

/**
 * Post the last location stored by the page JS into IndexedDB.
 * If the page is open, ask it to send a fresh fix first.
 * If not, use the stale cached location (still beats nothing).
 */
async function postLastKnownLocation() {
  try {
    // 1. Ask any open page clients to post a fresh reading first
    var clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (clients.length > 0) {
      clients.forEach(function (c) {
        c.postMessage({ type: 'SW_REQUEST_LOCATION' });
      });
      // Give the page 3 s to respond before we fall back to stored data
      await sleep(3000);
    }

    // 2. Read last-known location from IndexedDB
    var db      = await openLocationDB();
    var record  = await dbGet(db, 'last_location');
    db.close();

    if (!record || !record.apiBase || !record.token) return;

    // Don't re-post if we already sent this exact timestamp
    var sentDb   = await openLocationDB();
    var lastSent = await dbGet(sentDb, 'last_sent_ts');
    sentDb.close();
    if (lastSent && lastSent === record.ts) return;

    var payload = {
      latitude:  record.latitude,
      longitude: record.longitude,
      speed:     record.speed   || 0,
      heading:   record.heading || 0,
      timestamp: new Date(record.ts).toISOString(),
    };

    var resp = await fetch(record.apiBase + '/track/' + record.token + '/location', {
      method:    'POST',
      headers:   { 'Content-Type': 'application/json' },
      body:      JSON.stringify(payload),
      keepalive: true,
    });

    if (resp.ok) {
      var updateDb = await openLocationDB();
      await dbPut(updateDb, 'last_sent_ts', record.ts);
      updateDb.close();
      console.log('[SW] periodic heartbeat posted location', payload.latitude, payload.longitude);
    }
  } catch (e) {
    console.warn('[SW] postLastKnownLocation error:', e);
  }
}

async function replayQueuedLocations() {
  try {
    var db    = await openQueueDB();
    var items = await dbGetAll(db);
    for (var item of items) {
      try {
        var resp = await fetch(item.url, {
          method:    'POST',
          headers:   { 'Content-Type': 'application/json' },
          body:      JSON.stringify(item.payload),
          keepalive: true,
        });
        if (resp.ok) {
          await dbDelete(db, item.id);
        }
      } catch (e) {
        break; // Still offline — leave in queue
      }
    }
    db.close();
  } catch (e) {
    console.warn('[SW] replayQueuedLocations error:', e);
  }
}

// ── IndexedDB — location queue (offline replay) ───────────────────────────
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

// ── IndexedDB — last-known location store (for periodic heartbeat) ────────
// The page writes to 'cmp_location_state'; the SW reads from it.
function openLocationDB() {
  return new Promise(function (resolve, reject) {
    var req = indexedDB.open('cmp_location_state', 1);
    req.onupgradeneeded = function (e) {
      e.target.result.createObjectStore('kv', { keyPath: 'key' });
    };
    req.onsuccess = function (e) { resolve(e.target.result); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

function dbGet(db, key) {
  return new Promise(function (resolve, reject) {
    var tx  = db.transaction('kv', 'readonly');
    var req = tx.objectStore('kv').get(key);
    req.onsuccess = function (e) { resolve(e.target.result ? e.target.result.value : null); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

function dbPut(db, key, value) {
  return new Promise(function (resolve, reject) {
    var tx  = db.transaction('kv', 'readwrite');
    var req = tx.objectStore('kv').put({ key: key, value: value });
    req.onsuccess = function () { resolve(); };
    req.onerror   = function (e) { reject(e.target.error); };
  });
}

function sleep(ms) {
  return new Promise(function (resolve) { setTimeout(resolve, ms); });
}

// ── Keep-alive ping to all open page clients every 25 s ──────────────────
// Prevents the browser from suspending watchPosition when the tab is
// backgrounded but still open (screen on, app minimised).
// We also request a fresh location post at the same time.
setInterval(function () {
  self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clients) {
    clients.forEach(function (client) {
      // KEEPALIVE — tells the page to re-acquire wake lock & check GPS health
      client.postMessage({ type: 'SW_KEEPALIVE' });
      // REQUEST_LOCATION — tells the page to immediately call postLocation()
      client.postMessage({ type: 'SW_REQUEST_LOCATION' });
    });
  });
}, 25000);
