// LoadWallet.swift
// Singleton ObservableObject that holds the driver's active load cards,
// persisted to UserDefaults so they survive backgrounding / relaunches.

import Foundation
import Combine

// MARK: - WalletEntry

/// A persisted snapshot of a load for the wallet.
struct WalletEntry: Identifiable, Codable, Equatable {
    let id: String          // loadId
    let token: String
    let loadNumber: String
    let description: String
    let pickupAddress: String
    let deliveryAddress: String
    let pickupDate: String
    let deliveryDate: String
    var status: String
    let companyName: String
    let notes: String
    let weight: String
    /// When this entry was added to the wallet
    let addedAt: Date

    var isComplete: Bool {
        status == "Delivered" || status == "Cancelled"
    }
}

// MARK: - LoadWallet

final class LoadWallet: ObservableObject {

    static let shared = LoadWallet()

    // All cards; index 0 is the front/active card
    @Published private(set) var cards: [WalletEntry] = []

    // The card the driver is currently viewing / acting on
    @Published var activeId: String? = nil

    private let key = "com.routelo.loadWallet.cards"

    private init() { load() }

    // MARK: - Active card helper

    var activeCard: WalletEntry? {
        guard let id = activeId else { return cards.first }
        return cards.first(where: { $0.id == id }) ?? cards.first
    }

    // MARK: - Add / upsert

    func add(entry: WalletEntry) {
        if let idx = cards.firstIndex(where: { $0.id == entry.id }) {
            // Already in wallet — refresh status but keep position
            cards[idx] = entry
        } else {
            // Insert at front (like adding a new card to the top of the stack)
            cards.insert(entry, at: 0)
        }
        activeId = entry.id
        persist()
    }

    // MARK: - Status update (called when tracking state changes)

    func updateStatus(id: String, status: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].status = status
        persist()
    }

    // MARK: - Remove (swipe-dismiss or after completion)

    func remove(id: String) {
        cards.removeAll { $0.id == id }
        // If we removed the active card, fall back to the new front
        if activeId == id { activeId = cards.first?.id }
        persist()
    }

    func removeCompleted() {
        cards.removeAll { $0.isComplete }
        if let id = activeId, !cards.contains(where: { $0.id == id }) {
            activeId = cards.first?.id
        }
        persist()
    }

    // MARK: - Activate (bring a card to front)

    func activate(id: String) {
        activeId = id
    }

    // MARK: - Build from DriverDeepLink + server JSON

    static func entry(from json: [String: Any], link: DriverDeepLink) -> WalletEntry {
        WalletEntry(
            id:              json["id"]              as? String ?? link.loadId,
            token:           json["trackingToken"]   as? String ?? link.token,
            loadNumber:      json["loadNumber"]      as? String ?? "—",
            description:     json["description"]     as? String ?? "",
            pickupAddress:   json["pickupAddress"]   as? String ?? "—",
            deliveryAddress: json["deliveryAddress"] as? String ?? "—",
            pickupDate:      formatDate(json["pickupDate"]   as? String),
            deliveryDate:    formatDate(json["deliveryDate"] as? String),
            status:          json["status"]          as? String ?? "Assigned",
            companyName:     json["companyName"]     as? String ?? json["dispatcherEmail"] as? String ?? "",
            notes:           json["notes"]           as? String ?? "",
            weight: {
                if let w = json["weight"] as? Double, w > 0 { return "\(Int(w)) lbs" }
                if let w = json["weight"] as? Int,    w > 0 { return "\(w) lbs" }
                if let w = json["weight"] as? String, !w.isEmpty { return "\(w) lbs" }
                return ""
            }(),
            addedAt: Date()
        )
    }

    // MARK: - Date Formatting

    private static func formatDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d 'at' h:mm a"
        return out.string(from: date)
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([WalletEntry].self, from: data) else { return }
        cards = saved
        activeId = cards.first?.id
    }
}
