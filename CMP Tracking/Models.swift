//
//  Models.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import Foundation
import CoreLocation
import SwiftData

// MARK: - User Role

enum UserRole: String, Codable, CaseIterable {
    case driver = "driver"
    case dispatcher = "dispatcher"
}

// MARK: - Driver

struct Driver: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var phone: String
    var email: String
    var role: UserRole = .driver

    static let preview = Driver(id: "D001", name: "John Smith", phone: "555-0101", email: "john@cmpfreight.com")
}

// MARK: - Location Update

struct LocationUpdate: Codable {
    var loadId: String
    var driverId: String
    var latitude: Double
    var longitude: Double
    var speed: Double        // mph
    var heading: Double      // degrees
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static let preview = LocationUpdate(
        loadId: "L001",
        driverId: "D001",
        latitude: 41.8781,
        longitude: -87.6298,
        speed: 65.0,
        heading: 180.0,
        timestamp: Date()
    )
}

// MARK: - Load Status

enum LoadStatus: String, Codable, CaseIterable {
    case pending    = "Pending"
    case assigned   = "Assigned"
    case accepted   = "Accepted"
    case inTransit  = "In Transit"
    case delivered  = "Delivered"
    case cancelled  = "Cancelled"

    var color: String {
        switch self {
        case .pending:   return "gray"
        case .assigned:  return "blue"
        case .accepted:  return "purple"
        case .inTransit: return "orange"
        case .delivered: return "green"
        case .cancelled: return "red"
        }
    }

    var icon: String {
        switch self {
        case .pending:   return "clock"
        case .assigned:  return "person.fill"
        case .accepted:  return "hand.thumbsup.fill"
        case .inTransit: return "truck.box.fill"
        case .delivered: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}

// MARK: - Load

struct Load: Identifiable, Codable {
    var id: String
    var loadNumber: String
    var description: String
    var weight: Double       // lbs
    var pickupAddress: String
    var deliveryAddress: String
    var pickupDate: Date
    var deliveryDate: Date
    var status: LoadStatus
    var assignedDriverId: String?
    var assignedDriverName: String?
    var assignedDriverEmail: String?    // kept for backwards compat
    var assignedDriverPhone: String?    // driver's cell — SMS tracking link target
    var trackingToken: String       // unique token for customer tracking link
    var customerName: String
    var customerEmail: String
    var customerPhone: String
    var dispatcherEmail: String?    // saved so startTracking Lambda can email them
    var notifyCustomer: Bool        // if true, email customer when driver starts
    var lastLocation: LocationUpdate?
    var notes: String
    /// Set automatically when status transitions to .delivered or .cancelled.
    var completedAt: Date?

    // Deep-link into the iOS app (kept for reference)
    var trackingURL: String {
        "cmptracking://track/\(trackingToken)"
    }

    // Browser-based driver tracking page — no app required
    var webTrackingURL: String {
        let base = AWSConfig.baseURL.isEmpty ? "https://YOUR_API_URL" : AWSConfig.baseURL
        return "\(base)/driver-tracking.html?token=\(trackingToken)&loadId=\(id)"
    }

    // Browser-based customer tracking page
    var customerTrackingURL: String {
        let base = AWSConfig.baseURL.isEmpty ? "https://YOUR_API_URL" : AWSConfig.baseURL
        return "\(base)/track-shipment.html?token=\(trackingToken)"
    }

    static let preview = Load(
        id: "L001",
        loadNumber: "CMP-2026-0001",
        description: "Electronics – 48 pallets",
        weight: 38000,
        pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
        deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
        pickupDate: Date(),
        deliveryDate: Date().addingTimeInterval(86400),
        status: .inTransit,
        assignedDriverId: "D001",
        assignedDriverName: "John Smith",
        assignedDriverEmail: nil,
        assignedDriverPhone: "+13125550101",
        trackingToken: UUID().uuidString,
        customerName: "Acme Corp",
        customerEmail: "logistics@acme.com",
        customerPhone: "+1-312-555-0101",
        dispatcherEmail: "dispatch@cmpfreight.com",
        notifyCustomer: true,
        lastLocation: LocationUpdate.preview,
        notes: "Handle with care. Temperature-sensitive."
    )

    static let sampleLoads: [Load] = [
        Load(
            id: "L001",
            loadNumber: "CMP-2026-0001",
            description: "Electronics – 48 pallets",
            weight: 38000,
            pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
            deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
            pickupDate: Date(),
            deliveryDate: Date().addingTimeInterval(86400),
            status: .inTransit,
            assignedDriverId: "D001",
            assignedDriverName: "John Smith",
            assignedDriverEmail: nil,
            assignedDriverPhone: "+13125550101",
            trackingToken: "abc123token",
            customerName: "Acme Corp",
            customerEmail: "logistics@acme.com",
            customerPhone: "+1-312-555-0101",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: true,
            lastLocation: LocationUpdate.preview,
            notes: "Handle with care."
        ),
        Load(
            id: "L002",
            loadNumber: "CMP-2026-0002",
            description: "Auto Parts – 20 pallets",
            weight: 22000,
            pickupAddress: "789 Parts St, Detroit, MI 48201",
            deliveryAddress: "321 Depot Rd, Nashville, TN 37201",
            pickupDate: Date().addingTimeInterval(3600),
            deliveryDate: Date().addingTimeInterval(172800),
            status: .assigned,
            assignedDriverId: "D002",
            assignedDriverName: "Maria Lopez",
            assignedDriverEmail: nil,
            assignedDriverPhone: "+13135550202",
            trackingToken: "def456token",
            customerName: "Motor World",
            customerEmail: "orders@motorworld.com",
            customerPhone: "+1-313-555-0202",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: true,
            lastLocation: nil,
            notes: ""
        ),
        Load(
            id: "L003",
            loadNumber: "CMP-2026-0003",
            description: "Frozen Foods – 36 pallets",
            weight: 41000,
            pickupAddress: "555 Cold Ave, Minneapolis, MN 55401",
            deliveryAddress: "900 Fresh Blvd, Kansas City, MO 64101",
            pickupDate: Date().addingTimeInterval(-7200),
            deliveryDate: Date().addingTimeInterval(43200),
            status: .pending,
            assignedDriverId: nil,
            assignedDriverName: nil,
            assignedDriverEmail: nil,
            assignedDriverPhone: nil,
            trackingToken: "ghi789token",
            customerName: "FreshMart",
            customerEmail: "supply@freshmart.com",
            customerPhone: "+1-612-555-0303",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: false,
            lastLocation: nil,
            notes: "Reefer required. Keep at -10°F."
        )
    ]
}

// MARK: - WebSocket Message

struct WSMessage: Codable {
    enum MessageType: String, Codable {
        case locationUpdate = "location_update"
        case ping = "ping"
        case pong = "pong"
        case subscribe = "subscribe"
        case error = "error"
    }
    var type: MessageType
    var payload: LocationUpdate?
    var loadId: String?
    var message: String?
}

// MARK: - User Account (SwiftData model – persisted locally, re-seeded from Keychain after reinstall)

@Model
final class UserAccount {
    @Attribute(.unique) var email: String
    var name: String
    var phone: String
    var role: String
    var passwordHash: String

    init(email: String, name: String, phone: String, role: String, passwordHash: String) {
        self.email        = email
        self.name         = name
        self.phone        = phone
        self.role         = role
        self.passwordHash = passwordHash
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var currentUser: Driver?
    @Published var userRole: UserRole = .dispatcher
    @Published var isLoggedIn: Bool = false

    static let shared = AppState()

    /// Called by AuthManager after a successful sign-in.
    func login(from account: UserAccount) {
        let role = UserRole(rawValue: account.role) ?? .driver
        self.currentUser = Driver(
            id: account.email,
            name: account.name,
            phone: account.phone,
            email: account.email,
            role: role
        )
        self.userRole  = role
        self.isLoggedIn = true
    }

    /// Legacy helper kept for demo buttons.
    func login(as driver: Driver) {
        self.currentUser = driver
        self.userRole    = driver.role
        self.isLoggedIn  = true
    }

    func logout() {
        self.currentUser = nil
        self.isLoggedIn  = false
    }
}
//
//  Models.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import Foundation
import CoreLocation
import SwiftData

// MARK: - User Role

enum UserRole: String, Codable, CaseIterable {
    case driver = "driver"
    case dispatcher = "dispatcher"
}

// MARK: - Driver

struct Driver: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var phone: String
    var email: String
    var role: UserRole = .driver

    static let preview = Driver(id: "D001", name: "John Smith", phone: "555-0101", email: "john@cmpfreight.com")
}

// MARK: - Location Update

struct LocationUpdate: Codable {
    var loadId: String
    var driverId: String
    var latitude: Double
    var longitude: Double
    var speed: Double        // mph
    var heading: Double      // degrees
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static let preview = LocationUpdate(
        loadId: "L001",
        driverId: "D001",
        latitude: 41.8781,
        longitude: -87.6298,
        speed: 65.0,
        heading: 180.0,
        timestamp: Date()
    )
}

// MARK: - Load Status

enum LoadStatus: String, Codable, CaseIterable {
    case pending    = "Pending"
    case assigned   = "Assigned"
    case inTransit  = "In Transit"
    case delivered  = "Delivered"
    case cancelled  = "Cancelled"

    var color: String {
        switch self {
        case .pending:   return "gray"
        case .assigned:  return "blue"
        case .inTransit: return "orange"
        case .delivered: return "green"
        case .cancelled: return "red"
        }
    }

    var icon: String {
        switch self {
        case .pending:   return "clock"
        case .assigned:  return "person.fill"
        case .inTransit: return "truck.box.fill"
        case .delivered: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}

// MARK: - Load

struct Load: Identifiable, Codable {
    var id: String
    var loadNumber: String
    var description: String
    var weight: Double       // lbs
    var pickupAddress: String
    var deliveryAddress: String
    var pickupDate: Date
    var deliveryDate: Date
    var status: LoadStatus
    var assignedDriverId: String?
    var assignedDriverName: String?
    var assignedDriverEmail: String?    // kept for backwards compat
    var assignedDriverPhone: String?    // driver's cell — SMS tracking link target
    var trackingToken: String       // unique token for customer tracking link
    var customerName: String
    var customerEmail: String
    var customerPhone: String
    var dispatcherEmail: String?    // saved so startTracking Lambda can email them
    var notifyCustomer: Bool        // if true, email customer when driver starts
    var lastLocation: LocationUpdate?
    var notes: String
    /// Set automatically when status transitions to .delivered or .cancelled.
    var completedAt: Date?

    // Deep-link into the iOS app (kept for reference)
    var trackingURL: String {
        "cmptracking://track/\(trackingToken)"
    }

    // Browser-based driver tracking page — no app required
    var webTrackingURL: String {
        let base = AWSConfig.baseURL.isEmpty ? "https://YOUR_API_URL" : AWSConfig.baseURL
        return "\(base)/driver-tracking.html?token=\(trackingToken)&loadId=\(id)"
    }

    // Browser-based customer tracking page
    var customerTrackingURL: String {
        let base = AWSConfig.baseURL.isEmpty ? "https://YOUR_API_URL" : AWSConfig.baseURL
        return "\(base)/track-shipment.html?token=\(trackingToken)"
    }

    static let preview = Load(
        id: "L001",
        loadNumber: "CMP-2026-0001",
        description: "Electronics – 48 pallets",
        weight: 38000,
        pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
        deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
        pickupDate: Date(),
        deliveryDate: Date().addingTimeInterval(86400),
        status: .inTransit,
        assignedDriverId: "D001",
        assignedDriverName: "John Smith",
        assignedDriverEmail: nil,
        assignedDriverPhone: "+13125550101",
        trackingToken: UUID().uuidString,
        customerName: "Acme Corp",
        customerEmail: "logistics@acme.com",
        customerPhone: "+1-312-555-0101",
        dispatcherEmail: "dispatch@cmpfreight.com",
        notifyCustomer: true,
        lastLocation: LocationUpdate.preview,
        notes: "Handle with care. Temperature-sensitive."
    )

    static let sampleLoads: [Load] = [
        Load(
            id: "L001",
            loadNumber: "CMP-2026-0001",
            description: "Electronics – 48 pallets",
            weight: 38000,
            pickupAddress: "123 Warehouse Blvd, Chicago, IL 60601",
            deliveryAddress: "456 Distribution Ave, Dallas, TX 75201",
            pickupDate: Date(),
            deliveryDate: Date().addingTimeInterval(86400),
            status: .inTransit,
            assignedDriverId: "D001",
            assignedDriverName: "John Smith",
            assignedDriverEmail: nil,
            assignedDriverPhone: "+13125550101",
            trackingToken: "abc123token",
            customerName: "Acme Corp",
            customerEmail: "logistics@acme.com",
            customerPhone: "+1-312-555-0101",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: true,
            lastLocation: LocationUpdate.preview,
            notes: "Handle with care."
        ),
        Load(
            id: "L002",
            loadNumber: "CMP-2026-0002",
            description: "Auto Parts – 20 pallets",
            weight: 22000,
            pickupAddress: "789 Parts St, Detroit, MI 48201",
            deliveryAddress: "321 Depot Rd, Nashville, TN 37201",
            pickupDate: Date().addingTimeInterval(3600),
            deliveryDate: Date().addingTimeInterval(172800),
            status: .assigned,
            assignedDriverId: "D002",
            assignedDriverName: "Maria Lopez",
            assignedDriverEmail: nil,
            assignedDriverPhone: "+13135550202",
            trackingToken: "def456token",
            customerName: "Motor World",
            customerEmail: "orders@motorworld.com",
            customerPhone: "+1-313-555-0202",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: true,
            lastLocation: nil,
            notes: ""
        ),
        Load(
            id: "L003",
            loadNumber: "CMP-2026-0003",
            description: "Frozen Foods – 36 pallets",
            weight: 41000,
            pickupAddress: "555 Cold Ave, Minneapolis, MN 55401",
            deliveryAddress: "900 Fresh Blvd, Kansas City, MO 64101",
            pickupDate: Date().addingTimeInterval(-7200),
            deliveryDate: Date().addingTimeInterval(43200),
            status: .pending,
            assignedDriverId: nil,
            assignedDriverName: nil,
            assignedDriverEmail: nil,
            assignedDriverPhone: nil,
            trackingToken: "ghi789token",
            customerName: "FreshMart",
            customerEmail: "supply@freshmart.com",
            customerPhone: "+1-612-555-0303",
            dispatcherEmail: "dispatch@cmpfreight.com",
            notifyCustomer: false,
            lastLocation: nil,
            notes: "Reefer required. Keep at -10°F."
        )
    ]
}

// MARK: - WebSocket Message

struct WSMessage: Codable {
    enum MessageType: String, Codable {
        case locationUpdate = "location_update"
        case ping = "ping"
        case pong = "pong"
        case subscribe = "subscribe"
        case error = "error"
    }
    var type: MessageType
    var payload: LocationUpdate?
    var loadId: String?
    var message: String?
}

// MARK: - User Account (SwiftData model – persisted locally, re-seeded from Keychain after reinstall)

@Model
final class UserAccount {
    @Attribute(.unique) var email: String
    var name: String
    var phone: String
    var role: String
    var passwordHash: String

    init(email: String, name: String, phone: String, role: String, passwordHash: String) {
        self.email        = email
        self.name         = name
        self.phone        = phone
        self.role         = role
        self.passwordHash = passwordHash
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var currentUser: Driver?
    @Published var userRole: UserRole = .dispatcher
    @Published var isLoggedIn: Bool = false

    static let shared = AppState()

    /// Called by AuthManager after a successful sign-in.
    func login(from account: UserAccount) {
        let role = UserRole(rawValue: account.role) ?? .driver
        self.currentUser = Driver(
            id: account.email,
            name: account.name,
            phone: account.phone,
            email: account.email,
            role: role
        )
        self.userRole  = role
        self.isLoggedIn = true
    }

    /// Legacy helper kept for demo buttons.
    func login(as driver: Driver) {
        self.currentUser = driver
        self.userRole    = driver.role
        self.isLoggedIn  = true
    }

    func logout() {
        self.currentUser = nil
        self.isLoggedIn  = false
    }
}
