/**
 * CMP Logistics — Driver Tracking Service Worker  (v7)
 *
 * v7 changes: fixed duplicate setInterval block, replaced ts-based dedup
 * with wall-clock check so stationary drivers get heartbeats every 20s,
 * postLastKnownLocation now includes loadId for faster Lambda lookup.
 */

const CACHE_NAME   = 'cmp-driver-v7';
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

// ── Message: allow page to trigger immediate SW takeover ─────────────────
self.addEventListener('message', function (evt) {
  if (evt.data && evt.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

// ── Fetch: network-first for API calls, cache-first for static assets ────
self.addEventListener('fetch', function (evt) {
  // Always go network-first for non-GET (location POST, status PATCH etc.)
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

// ── Keep-alive: every 20 s ping open pages AND post location directly ────
// Posting directly from IDB means location reaches the server even when
// the page JS is frozen by iOS/Android background throttling.
setInterval(function () {
  // 1. Ping all open page clients (keeps watchPosition alive if JS is running)
  self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    .then(function (clients) {
      clients.forEach(function (client) {
        client.postMessage({ type: 'SW_KEEPALIVE' });
        client.postMessage({ type: 'SW_REQUEST_LOCATION' });
      });
    });
  // 2. Also post the last-known location directly from IDB — this fires even
  //    when page JS is fully suspended (screen locked, app backgrounded).
  postLastKnownLocation();
}, 20000);

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function postLastKnownLocation() {
  try {
    var clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (clients.length > 0) {
      clients.forEach(function (c) { c.postMessage({ type: 'SW_REQUEST_LOCATION' }); });
      await sleep(3000);
    }

    var db     = await openLocationDB();
    var record = await dbGet(db, 'last_location');
    db.close();

    if (!record || !record.apiBase || !record.token) return;

    // Rate-limit: only skip if we successfully sent within the last 15 s.
    // This allows stationary drivers (same GPS coords) to still get heartbeats
    // every ~20 s instead of being silently blocked after the first send.
    var sentDb      = await openLocationDB();
    var lastSentAt  = await dbGet(sentDb, 'last_sent_wall');
    sentDb.close();
    if (lastSentAt && (Date.now() - lastSentAt) < 15000) return;

    var payload = {
      latitude:  record.latitude,
      longitude: record.longitude,
      speed:     record.speed   || 0,
      heading:   record.heading || 0,
      timestamp: new Date().toISOString(), // always use current time so dispatcher sees a fresh ping
      loadId:    record.loadId || undefined
      speed:     record.speed   || 0,
      heading:   record.heading || 0,
      timestamp: new Date().toISOString(), // always use current time so dispatcher sees a fresh ping
      loadId:    record.loadId || undefined,
    };

    var resp = await fetch(record.apiBase + '/track/' + record.token + '/location', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      keepalive: true,
    });

    if (resp.ok) {
      var updateDb = await openLocationDB();
      await dbPut(updateDb, 'last_sent_wall', Date.now());
      updateDb.close();
      console.log('[SW] heartbeat posted', payload.latitude, payload.longitude);
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
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(item.payload),
          keepalive: true,
        });
        if (resp.ok) await dbDelete(db, item.id);
      } catch (e) {
        break; // Still offline
      }
    }
    db.close();
  } catch (e) {
    console.warn('[SW] replayQueuedLocations error:', e);
  }
}

// ── IndexedDB — offline location queue ───────────────────────────────────
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

// ── IndexedDB — last-known location store ────────────────────────────────
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
