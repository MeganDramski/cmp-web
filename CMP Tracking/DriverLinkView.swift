// DriverLinkView.swift
// Shown when driver taps the SMS link — no sign-in required.
// Fetches load by token, shows details, lets driver start/stop tracking.

import SwiftUI
import CoreLocation
import MapKit

// MARK: - Model

struct DriverDeepLink: Equatable {
    let token:  String
    let loadId: String
}

// MARK: - View

struct DriverLinkView: View {
    let link: DriverDeepLink

    @StateObject private var vm = DriverLinkVM()
    @StateObject private var wallet = LoadWallet.shared

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.11)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ────────────────────────────────────────────────
                HStack(spacing: 12) {
                    RouteloLogo(size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Routelo").font(.headline).foregroundColor(.white)
                        Text("LIVE TRACKING")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .kerning(2)
                    }
                    Spacer()
                    if wallet.cards.count > 1 {
                        Text("\(wallet.cards.count) loads")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.08))

                ScrollView {
                    VStack(spacing: 16) {

                        if vm.isLoading {
                            ProgressView("Loading load…")
                                .foregroundColor(.secondary)
                                .padding(.top, 60)

                        } else if let err = vm.errorMessage, wallet.cards.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.orange)
                                Text(err)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry") { vm.fetchLoad(link: link) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 60)

                        } else if !wallet.cards.isEmpty {
                            // ── Wallet stack ─────────────────────────────────
                            WalletCardStack(
                                wallet: wallet,
                                onTrack: { entry in
                                    vm.handleTrackToggle(entry: entry)
                                },
                                onAccept: { entry in
                                    vm.acceptEntry(entry: entry)
                                }
                            )

                            // ── Map (follows active card) ─────────────────
                            mapCard

                            // ── Tracking stats (when tracking active entry) ─
                            if let active = wallet.activeCard,
                               active.status == "In Transit" {
                                trackingStatsCard
                            }
                        }
                    }
                    .padding(.horizontal, 0)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear { vm.fetchLoad(link: link) }
    }

    // MARK: - Map Card

    @ViewBuilder
    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .foregroundColor(.blue)
                Text("Map")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if vm.isTracking {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Live")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ZStack(alignment: .bottomTrailing) {
                Group {
                    if vm.isTracking || vm.lastLocation != nil {
                        LiveMapView(
                            region: vm.mapRegion,
                            userLocation: vm.lastLocation?.coordinate,
                            trail: vm.routeTrail
                        )
                    } else if vm.pickupPin != nil || vm.deliveryPin != nil {
                        RouteMapView(pickupCoord: vm.pickupPin, deliveryCoord: vm.deliveryPin)
                    } else {
                        LiveMapView(
                            region: MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
                            ),
                            userLocation: nil,
                            trail: []
                        )
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "location.slash.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.secondary)
                                Text("Waiting for GPS…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                    }
                }
                .frame(height: 220)
                .cornerRadius(12)
                .padding(.horizontal, 12)

                if vm.lastLocation != nil {
                    Button {
                        if let loc = vm.lastLocation {
                            vm.mapRegion = MKCoordinateRegion(
                                center: loc.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            )
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14))
                            .padding(10)
                            .background(Color(red: 0.145, green: 0.145, blue: 0.220))
                            .foregroundColor(.blue)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                    .padding(.trailing, 20).padding(.bottom, 10)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .padding(.horizontal, 16)
    }

    // MARK: - Tracking Stats Card (shown when In Transit)

    @ViewBuilder
    private var trackingStatsCard: some View {
        VStack(spacing: 10) {
            if vm.locationStatus == .denied || vm.locationStatus == .restricted {
                HStack(spacing: 10) {
                    Image(systemName: "location.slash.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Location Access Required")
                            .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                        Text("Go to Settings → Routelo → Location → Always")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption).foregroundColor(.accentColor)
                }
                .padding(14)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            }

            if let loc = vm.lastLocation {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill").foregroundColor(.green).font(.caption)
                    Text(String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude))
                        .font(.caption.monospaced()).foregroundColor(.secondary)
                    Spacer()
                    if let speed = vm.lastSpeed {
                        Text(String(format: "%.0f mph", speed))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }

            Text("GPS updates every 10 seconds • Works with screen locked")
                .font(.caption2).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .padding(.horizontal, 16)
    }
}

// MARK: - Simple Load Data (no auth needed)

struct LoadData {
    let id: String
    let loadNumber: String
    let description: String
    let pickupAddress: String
    let deliveryAddress: String
    let pickupDate: String
    let deliveryDate: String
    var status: String
    let trackingToken: String
    let companyName: String
    let notes: String
    let weight: String
}

// MARK: - ViewModel

@MainActor
class DriverLinkVM: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var load: LoadData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isTracking = false
    @Published var isAccepting = false
    @Published var lastLocation: CLLocation?
    @Published var lastSpeed: Double?
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined

    // Map state
    @Published var routeTrail: [CLLocationCoordinate2D] = []
    @Published var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
    )
    @Published var pickupPin: CLLocationCoordinate2D? = nil
    @Published var deliveryPin: CLLocationCoordinate2D? = nil

    // Which loadId is currently being GPS-tracked
    private var activeTrackingToken = ""
    private var activeTrackingLoadId = ""

    private let clm = CLLocationManager()
    private var token = ""
    private var loadId = ""
    private var updateInterval: TimeInterval = 10
    private var lastSentTime: Date = .distantPast

    private lazy var bgSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.routelo.driverlink")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg)
    }()

    var canTrack: Bool {
        locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse
    }

    override init() {
        super.init()
        clm.delegate = self
        clm.desiredAccuracy = kCLLocationAccuracyBest
        clm.distanceFilter = 20
        clm.pausesLocationUpdatesAutomatically = false
        clm.allowsBackgroundLocationUpdates = true
        locationStatus = clm.authorizationStatus
    }

    // MARK: - Fetch Load (adds to wallet on success)

    func fetchLoad(link: DriverDeepLink) {
        token  = link.token
        loadId = link.loadId
        isLoading = true
        errorMessage = nil

        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, !base.contains("REPLACE"),
              let url = URL(string: "\(base)/track/\(token)") else {
            errorMessage = "Invalid configuration."
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard let data, error == nil else {
                    // If we already have cards in wallet, just show those silently
                    if LoadWallet.shared.cards.isEmpty {
                        self.errorMessage = "Cannot reach server. Check your connection."
                    }
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if LoadWallet.shared.cards.isEmpty {
                        self.errorMessage = "Invalid response from server."
                    }
                    return
                }

                // Build wallet entry and add/upsert
                let entry = LoadWallet.entry(from: json, link: link)
                LoadWallet.shared.add(entry: entry)

                // Also populate legacy `load` for any remaining old code paths
                self.load = LoadData(
                    id:              entry.id,
                    loadNumber:      entry.loadNumber,
                    description:     entry.description,
                    pickupAddress:   entry.pickupAddress,
                    deliveryAddress: entry.deliveryAddress,
                    pickupDate:      entry.pickupDate,
                    deliveryDate:    entry.deliveryDate,
                    status:          entry.status,
                    trackingToken:   entry.token,
                    companyName:     entry.companyName,
                    notes:           entry.notes,
                    weight:          entry.weight
                )

                // Request location permission
                self.clm.requestAlwaysAuthorization()

                // Geocode for map pins (use newly fetched addresses)
                let pickup   = entry.pickupAddress
                let delivery = entry.deliveryAddress
                if !pickup.isEmpty {
                    CLGeocoder().geocodeAddressString(pickup) { [weak self] p, _ in
                        DispatchQueue.main.async { self?.pickupPin = p?.first?.location?.coordinate }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !delivery.isEmpty {
                        CLGeocoder().geocodeAddressString(delivery) { [weak self] p, _ in
                            DispatchQueue.main.async { self?.deliveryPin = p?.first?.location?.coordinate }
                        }
                    }
                }
            }
        }.resume()
    }

    // MARK: - Wallet-aware track toggle

    /// Called by WalletCardStack when driver taps Start/Stop on a card
    func handleTrackToggle(entry: WalletEntry) {
        if isTracking && activeTrackingToken == entry.token {
            // Stop tracking this load
            stopTracking()
            LoadWallet.shared.updateStatus(id: entry.id, status: "Accepted")
        } else {
            // Switch tracking to this entry
            if isTracking { stopTracking() }
            activeTrackingToken  = entry.token
            activeTrackingLoadId = entry.id
            token  = entry.token
            loadId = entry.id
            beginGPS()
            LoadWallet.shared.updateStatus(id: entry.id, status: "In Transit")
        }
    }

    /// Called by WalletCardStack when driver taps Accept on an assigned card
    func acceptEntry(entry: WalletEntry) {
        isAccepting = true
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/loads/\(entry.id)/accept") else {
            isAccepting = false
            LoadWallet.shared.updateStatus(id: entry.id, status: "Accepted")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": entry.token])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.isAccepting = false
                LoadWallet.shared.updateStatus(id: entry.id, status: "Accepted")
            }
        }.resume()
    }

    // MARK: - Start Tracking (legacy single-load path kept for compat)

    func startTracking(link: DriverDeepLink) {
        isAccepting = true
        token  = link.token
        loadId = link.loadId
        activeTrackingToken  = token
        activeTrackingLoadId = loadId
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/loads/\(loadId)/accept") else {
            beginGPS(); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.load?.status = "Accepted"
                LoadWallet.shared.updateStatus(id: self?.loadId ?? "", status: "Accepted")
                self?.beginGPS()
            }
        }.resume()
    }

    private func beginGPS() {
        isAccepting = false
        isTracking  = true
        routeTrail  = []
        clm.startUpdatingLocation()
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tok = activeTrackingToken.isEmpty ? token : activeTrackingToken
        let lid = activeTrackingLoadId.isEmpty ? loadId : activeTrackingLoadId
        guard let url = URL(string: "\(base)/track/\(tok)/start") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["loadId": lid])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.load?.status = "In Transit"
                LoadWallet.shared.updateStatus(id: lid, status: "In Transit")
            }
        }.resume()
    }

    // MARK: - Stop / Deliver

    func stopTracking() {
        isTracking = false
        clm.stopUpdatingLocation()
    }

    func markDelivered(link: DriverDeepLink) {
        let tok = activeTrackingToken.isEmpty ? link.token : activeTrackingToken
        let lid = activeTrackingLoadId.isEmpty ? link.loadId : activeTrackingLoadId
        stopTracking()
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/track/\(tok)/status") else { return }
        var req = URLRequest(url: url)
        req.httpMethod  = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["status": "Delivered", "loadId": lid])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.load?.status = "Delivered"
                LoadWallet.shared.updateStatus(id: lid, status: "Delivered")
            }
        }.resume()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.lastSpeed    = loc.speed > 0 ? loc.speed * 2.23694 : nil

            self.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )

            if self.isTracking {
                let coord = loc.coordinate
                if self.routeTrail.last.map({ $0.latitude != coord.latitude || $0.longitude != coord.longitude }) ?? true {
                    self.routeTrail.append(coord)
                }
            }

            guard self.isTracking else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastSentTime) >= self.updateInterval else { return }
            self.lastSentTime = now
            self.postLocation(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.locationStatus = manager.authorizationStatus }
    }

    private func postLocation(_ loc: CLLocation) {
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tok = activeTrackingToken.isEmpty ? token : activeTrackingToken
        let lid = activeTrackingLoadId.isEmpty ? loadId : activeTrackingLoadId
        guard let url = URL(string: "\(base)/track/\(tok)/location") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "latitude":  loc.coordinate.latitude,
            "longitude": loc.coordinate.longitude,
            "speed":     max(loc.speed, 0) * 2.23694,
            "heading":   loc.course >= 0 ? loc.course : 0,
            "timestamp": ISO8601DateFormatter().string(from: loc.timestamp),
            "loadId":    lid
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        bgSession.dataTask(with: req).resume()
    }

    // MARK: - Helpers

    /// Exposed as internal so LoadWallet can call it too
    static func fmtDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d 'at' h:mm a"
        return out.string(from: date)
    }
}
