//
//  FirebaseManager.swift
//  CMP Tracking
//
//  Syncs loads with Firebase Firestore using the REST API.
//  No Firebase SDK needed — only URLSession.
//
//  HOW TO CONFIGURE:
//  1. Go to https://console.firebase.google.com and create a project (free tier is fine).
//  2. Enable Firestore Database (Start in test mode during development).
//  3. Replace `projectId` below with your Firebase project ID (found in Project Settings).
//  4. Optionally set up Firebase Authentication and replace the auth token logic.
//
//  Firestore REST Base URL:
//  https://firestore.googleapis.com/v1/projects/{projectId}/databases/(default)/documents
//

import Foundation

final class FirebaseManager {

    static let shared = FirebaseManager()
    private init() {}

    // ─── CONFIGURE THIS ──────────────────────────────────────────────────────
    /// Your Firebase project ID (e.g. "cmp-tracking-12345")
    private let projectId = "YOUR_FIREBASE_PROJECT_ID"
    // ────────────────────────────────────────────────────────────────────────

    private var baseURL: String {
        "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/loads"
    }

    /// Set to true once you've configured a real projectId.
    var isConfigured: Bool {
        projectId != "YOUR_FIREBASE_PROJECT_ID"
    }

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

    // MARK: - Fetch All Loads

    /// Fetches all loads from Firestore.
    func fetchLoads(completion: @escaping ([Load]?, Error?) -> Void) {
        guard isConfigured else { completion(nil, nil); return }
        guard let url = URL(string: baseURL) else { completion(nil, nil); return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            let loads = self.parseDocuments(data)
            DispatchQueue.main.async { completion(loads, nil) }
        }.resume()
    }

    // MARK: - Save (Create / Update) a Load

    /// Creates or updates a load document in Firestore.
    func saveLoad(_ load: Load, completion: ((Error?) -> Void)? = nil) {
        guard isConfigured else { completion?(nil); return }
        // Use PATCH with the load's id as the document name so it acts as upsert
        let urlString = "\(baseURL)/\(load.id)"
        guard let url = URL(string: urlString) else { completion?(nil); return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let firestoreDoc = loadToFirestoreDoc(load)
        request.httpBody = try? JSONSerialization.data(withJSONObject: firestoreDoc)

        URLSession.shared.dataTask(with: request) { _, _, error in
            DispatchQueue.main.async { completion?(error) }
        }.resume()
    }

    // MARK: - Delete a Load

    /// Deletes a load document from Firestore.
    func deleteLoad(id: String, completion: ((Error?) -> Void)? = nil) {
        guard isConfigured else { completion?(nil); return }
        let urlString = "\(baseURL)/\(id)"
        guard let url = URL(string: urlString) else { completion?(nil); return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, _, error in
            DispatchQueue.main.async { completion?(error) }
        }.resume()
    }

    // MARK: - Update Load Status

    /// Patches only the status field of a load document.
    func updateLoadStatus(id: String, status: LoadStatus, completion: ((Error?) -> Void)? = nil) {
        guard isConfigured else { completion?(nil); return }
        let urlString = "\(baseURL)/\(id)?updateMask.fieldPaths=status"
        guard let url = URL(string: urlString) else { completion?(nil); return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "fields": [
                "status": ["stringValue": status.rawValue]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in
            DispatchQueue.main.async { completion?(error) }
        }.resume()
    }

    // MARK: - Firestore Document Conversion

    /// Converts a Load to a Firestore REST document (field-value map).
    private func loadToFirestoreDoc(_ load: Load) -> [String: Any] {
        var fields: [String: Any] = [
            "id":               ["stringValue": load.id],
            "loadNumber":       ["stringValue": load.loadNumber],
            "description":      ["stringValue": load.description],
            "weight":           ["doubleValue": load.weight],
            "pickupAddress":    ["stringValue": load.pickupAddress],
            "deliveryAddress":  ["stringValue": load.deliveryAddress],
            "pickupDate":       ["timestampValue": ISO8601DateFormatter().string(from: load.pickupDate)],
            "deliveryDate":     ["timestampValue": ISO8601DateFormatter().string(from: load.deliveryDate)],
            "status":           ["stringValue": load.status.rawValue],
            "trackingToken":    ["stringValue": load.trackingToken],
            "customerName":     ["stringValue": load.customerName],
            "customerEmail":    ["stringValue": load.customerEmail],
            "customerPhone":    ["stringValue": load.customerPhone],
            "notes":            ["stringValue": load.notes]
        ]
        fields["notifyCustomer"] = ["booleanValue": load.notifyCustomer]
        if let driverId = load.assignedDriverId {
            fields["assignedDriverId"] = ["stringValue": driverId]
        }
        if let driverName = load.assignedDriverName {
            fields["assignedDriverName"] = ["stringValue": driverName]
        }
        if let driverEmail = load.assignedDriverEmail {
            fields["assignedDriverEmail"] = ["stringValue": driverEmail]
        }
        if let driverPhone = load.assignedDriverPhone {
            fields["assignedDriverPhone"] = ["stringValue": driverPhone]
        }
        if let dispEmail = load.dispatcherEmail {
            fields["dispatcherEmail"] = ["stringValue": dispEmail]
        }
        return ["fields": fields]
    }

    /// Parses a Firestore list-documents response into [Load].
    private func parseDocuments(_ data: Data) -> [Load] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["documents"] as? [[String: Any]] else {
            return []
        }
        return docs.compactMap { parseDocument($0) }
    }

    private func parseDocument(_ doc: [String: Any]) -> Load? {
        guard let fields = doc["fields"] as? [String: Any] else { return nil }

        func str(_ key: String) -> String {
            (fields[key] as? [String: Any])?["stringValue"] as? String ?? ""
        }
        func dbl(_ key: String) -> Double {
            (fields[key] as? [String: Any])?["doubleValue"] as? Double ?? 0
        }
        func date(_ key: String) -> Date {
            let s = (fields[key] as? [String: Any])?["timestampValue"] as? String ?? ""
            return ISO8601DateFormatter().date(from: s) ?? Date()
        }

        func bool(_ key: String) -> Bool {
            (fields[key] as? [String: Any])?["booleanValue"] as? Bool ?? false
        }

        let id = str("id")
        guard !id.isEmpty else { return nil }

        return Load(
            id: id,
            loadNumber: str("loadNumber"),
            description: str("description"),
            weight: dbl("weight"),
            pickupAddress: str("pickupAddress"),
            deliveryAddress: str("deliveryAddress"),
            pickupDate: date("pickupDate"),
            deliveryDate: date("deliveryDate"),
            status: LoadStatus(rawValue: str("status")) ?? .pending,
            assignedDriverId: str("assignedDriverId").isEmpty ? nil : str("assignedDriverId"),
            assignedDriverName: str("assignedDriverName").isEmpty ? nil : str("assignedDriverName"),
            assignedDriverEmail: str("assignedDriverEmail").isEmpty ? nil : str("assignedDriverEmail"),
            assignedDriverPhone: str("assignedDriverPhone").isEmpty ? nil : str("assignedDriverPhone"),
            trackingToken: str("trackingToken"),
            customerName: str("customerName"),
            customerEmail: str("customerEmail"),
            customerPhone: str("customerPhone"),
            dispatcherEmail: str("dispatcherEmail").isEmpty ? nil : str("dispatcherEmail"),
            notifyCustomer: bool("notifyCustomer"),
            lastLocation: nil,
            notes: str("notes")
        )
    }
}
