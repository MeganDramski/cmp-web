//
//  LoadStore.swift
//  CMP Tracking
//
//  Persists loads using iCloud Key-Value Store (NSUbiquitousKeyValueStore).
//  ✅ Survives app reinstall
//  ✅ Syncs across all devices signed into the same iCloud account
//  ✅ Falls back to UserDefaults when iCloud is unavailable (e.g. simulator)
//

import Foundation

final class LoadStore {

    static let shared = LoadStore()
    private init() {
        // Start listening for iCloud remote changes pushed from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        // Kick off sync with iCloud on launch
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private let iCloudKey       = "cmp.loads"
    private let fallbackKey     = "cmp.loads.local"
    /// Persists IDs that have been explicitly deleted so that stale iCloud
    /// snapshots can never resurrect them.
    private let deletedIDsKey   = "cmp.loads.deletedIDs"

    // MARK: - Encoder / Decoder

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Save

    /// Persists loads to iCloud KV store (+ UserDefaults fallback).
    func save(_ loads: [Load]) {
        guard let data = try? encoder.encode(loads) else { return }

        // 1. iCloud KV (survives reinstall, syncs devices)
        NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
        NSUbiquitousKeyValueStore.default.synchronize()

        // 2. UserDefaults fallback (instant, offline)
        UserDefaults.standard.set(data, forKey: fallbackKey)

        // 3. Prune deleted-ID tombstones that are no longer needed
        //    (i.e. the ID was never in this save anyway — it's fully gone)
        let currentIDs = Set(loads.map { $0.id })
        var deleted = loadDeletedIDs()
        let before = deleted.count
        deleted = deleted.filter { currentIDs.contains($0) == false }
        // Only write back if something changed, to avoid spurious KV updates
        if deleted.count != before {
            saveDeletedIDs(deleted)
        }
    }

    // MARK: - Load

    /// Returns persisted loads — tries iCloud first, then UserDefaults.
    /// Deleted-ID tombstones are always filtered out.
    func load() -> [Load] {
        let deleted = loadDeletedIDs()

        // Try iCloud KV store first
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let loads = try? decoder.decode([Load].self, from: data) {
            // Keep UserDefaults in sync
            UserDefaults.standard.set(data, forKey: fallbackKey)
            return loads.filter { !deleted.contains($0.id) }
        }
        // Fallback to UserDefaults (simulator / no iCloud)
        if let data = UserDefaults.standard.data(forKey: fallbackKey),
           let loads = try? decoder.decode([Load].self, from: data) {
            return loads.filter { !deleted.contains($0.id) }
        }
        return []
    }

    // MARK: - Helpers

    func upsert(_ load: Load) {
        var loads = self.load()
        if let index = loads.firstIndex(where: { $0.id == load.id }) {
            loads[index] = load
        } else {
            loads.append(load)
        }
        save(loads)
    }

    func delete(id: String) {
        // 1. Record the tombstone FIRST so the load() call below already filters it
        var deleted = loadDeletedIDs()
        deleted.insert(id)
        saveDeletedIDs(deleted)

        // 2. Remove from the persisted list
        var loads = self.load()
        loads.removeAll { $0.id == id }
        save(loads)
    }

    // MARK: - Deleted-ID Tombstones (private)

    private func loadDeletedIDs() -> Set<String> {
        if let arr = NSUbiquitousKeyValueStore.default.array(forKey: deletedIDsKey) as? [String] {
            return Set(arr)
        }
        if let arr = UserDefaults.standard.stringArray(forKey: deletedIDsKey) {
            return Set(arr)
        }
        return []
    }

    private func saveDeletedIDs(_ ids: Set<String>) {
        let arr = Array(ids)
        NSUbiquitousKeyValueStore.default.set(arr, forKey: deletedIDsKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        UserDefaults.standard.set(arr, forKey: deletedIDsKey)
    }

    // MARK: - iCloud Remote Change

    /// Called when another device pushes a KV change to iCloud.
    @objc private func iCloudDidChange(_ notification: Notification) {
        // Post a notification so any open DispatcherViewModel can reload
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cmpLoadsDidChangeRemotely, object: nil)
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let cmpLoadsDidChangeRemotely = Notification.Name("cmpLoadsDidChangeRemotely")
}
