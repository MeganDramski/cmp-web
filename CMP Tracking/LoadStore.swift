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

    private let iCloudKey    = "cmp.loads"
    private let fallbackKey  = "cmp.loads.local"

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
    }

    // MARK: - Load

    /// Returns persisted loads — tries iCloud first, then UserDefaults.
    func load() -> [Load] {
        // Try iCloud KV store first
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let loads = try? decoder.decode([Load].self, from: data) {
            // Keep UserDefaults in sync
            UserDefaults.standard.set(data, forKey: fallbackKey)
            return loads
        }
        // Fallback to UserDefaults (simulator / no iCloud)
        if let data = UserDefaults.standard.data(forKey: fallbackKey),
           let loads = try? decoder.decode([Load].self, from: data) {
            return loads
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
        var loads = self.load()
        loads.removeAll { $0.id == id }
        save(loads)
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
