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
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.08))

                ScrollView {
                    VStack(spacing: 16) {

                        if vm.isLoading {
                            ProgressView("Loading your load…")
                                .foregroundColor(.secondary)
                                .padding(.top, 60)

                        } else if let err = vm.errorMessage {
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

                        } else if let load = vm.load {
                            loadCard(load)
                            mapCard
                            trackingCard(load)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { vm.fetchLoad(link: link) }
    }

    // MARK: - Load Card

    @ViewBuilder
    private func loadCard(_ load: LoadData) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Company banner ────────────────────────────────────────────
            if !load.companyName.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ASSIGNED BY")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.purple.opacity(0.8))
                            .kerning(0.8)
                        Text(load.companyName)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color.purple.opacity(0.12))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.purple.opacity(0.25)), alignment: .bottom)
            }

            VStack(alignment: .leading, spacing: 0) {
                // ── Status row ────────────────────────────────────────────
                HStack {
                    Text("LOAD #\(load.loadNumber)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .kerning(1)
                    Spacer()
                    Text(load.status)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(statusColor(load.status).opacity(0.25))
                        .overlay(Capsule().stroke(statusColor(load.status).opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 14)

                if !load.description.isEmpty {
                    Text(load.description)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 14)
                }

                // ── Route ─────────────────────────────────────────────────
                VStack(spacing: 0) {
                    routeRow(icon: "circle.fill",        color: .green, label: "PICKUP",   address: load.pickupAddress,   date: "")
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 20).padding(.leading, 18)
                    routeRow(icon: "mappin.circle.fill", color: .red,   label: "DELIVERY", address: load.deliveryAddress, date: "")
                }

                // ── Extra details ──────────────────────────────────────────
                let hasExtras = !load.pickupDate.isEmpty || !load.deliveryDate.isEmpty || !load.weight.isEmpty
                if hasExtras {
                    Divider().background(Color.white.opacity(0.08)).padding(.top, 12)
                    VStack(spacing: 2) {
                        if !load.pickupDate.isEmpty {
                            detailRow(icon: "calendar",              iconColor: .green,  label: "PICKUP DATE",   value: load.pickupDate)
                        }
                        if !load.deliveryDate.isEmpty {
                            detailRow(icon: "calendar.badge.clock",  iconColor: .orange, label: "EST. DELIVERY", value: load.deliveryDate)
                        }
                        if !load.weight.isEmpty {
                            detailRow(icon: "scalemass.fill",        iconColor: .blue,   label: "WEIGHT",        value: load.weight)
                        }
                    }
                    .padding(.top, 6)
                }

                // ── Notes ─────────────────────────────────────────────────
                if !load.notes.isEmpty {
                    Divider().background(Color.white.opacity(0.08)).padding(.top, 12)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "note.text")
                            .font(.system(size: 13))
                            .foregroundColor(.yellow.opacity(0.8))
                            .frame(width: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NOTES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.yellow.opacity(0.7))
                                .kerning(0.8)
                            Text(load.notes)
                                .font(.subheadline).foregroundColor(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(18)
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .clipped()
    }

    @ViewBuilder
    private func routeRow(icon: String, color: Color, label: String, address: String, date: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary).kerning(1)
                Text(address)
                    .font(.subheadline).foregroundColor(.white)
                if !date.isEmpty {
                    Text(date)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(icon: String, iconColor: Color = .secondary, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .kerning(0.5)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
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

                // Re-center button
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
    }

    // MARK: - Tracking Card

    @ViewBuilder
    private func trackingCard(_ load: LoadData) -> some View {
        VStack(spacing: 14) {

            // Location permission warning
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

            // GPS coords when tracking
            if vm.isTracking, let loc = vm.lastLocation {
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

            // Main button
            if load.status == "Delivered" || load.status == "Cancelled" {
                Label("Trip Complete", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundColor(.green)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(14)
            } else if vm.isTracking {
                VStack(spacing: 10) {
                    Button(action: { vm.stopTracking() }) {
                        Label("Stop Tracking", systemImage: "pause.fill")
                            .font(.headline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    Button(action: { vm.markDelivered(link: link) }) {
                        Label("Mark as Delivered", systemImage: "checkmark.seal.fill")
                            .font(.subheadline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                }
            } else {
                Button(action: { vm.startTracking(link: link) }) {
                    Label(vm.isAccepting ? "Starting…" : "Start Tracking", systemImage: "location.fill")
                        .font(.headline).fontWeight(.bold)
                        .frame(maxWidth: .infinity).padding()
                        .background(vm.canTrack ? Color.accentColor : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .disabled(!vm.canTrack || vm.isAccepting)
            }

            Text("GPS updates every 10 seconds • Works with screen locked")
                .font(.caption2).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Assigned":   return .blue
        case "Accepted":   return .purple
        case "In Transit": return .orange
        case "Delivered":  return .green
        default:           return .gray
        }
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

    // MARK: - Fetch Load

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
                self?.isLoading = false
                guard let data = data, error == nil else {
                    self?.errorMessage = "Cannot reach server. Check your connection."
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self?.errorMessage = "Invalid response from server."
                    return
                }
                self?.load = LoadData(
                    id:              json["id"]              as? String ?? link.loadId,
                    loadNumber:      json["loadNumber"]      as? String ?? "—",
                    description:     json["description"]     as? String ?? "",
                    pickupAddress:   json["pickupAddress"]   as? String ?? "—",
                    deliveryAddress: json["deliveryAddress"] as? String ?? "—",
                    pickupDate:      Self.formatDate(json["pickupDate"] as? String),
                    deliveryDate:    Self.formatDate(json["deliveryDate"] as? String),
                    status:          json["status"]          as? String ?? "Assigned",
                    trackingToken:   json["trackingToken"]   as? String ?? link.token,
                    companyName:     json["companyName"]     as? String ?? json["dispatcherEmail"] as? String ?? "",
                    notes:           json["notes"]           as? String ?? "",
                    weight:          {
                        if let w = json["weight"] as? Double, w > 0 { return "\(Int(w)) lbs" }
                        if let w = json["weight"] as? Int, w > 0    { return "\(w) lbs" }
                        if let w = json["weight"] as? String, !w.isEmpty { return "\(w) lbs" }
                        return ""
                    }()
                )
                // Request Always location permission on load
                self?.clm.requestAlwaysAuthorization()
                // Geocode pickup + delivery for map pins
                if let pickup = json["pickupAddress"] as? String, !pickup.isEmpty {
                    CLGeocoder().geocodeAddressString(pickup) { [weak self] p, _ in
                        DispatchQueue.main.async { self?.pickupPin = p?.first?.location?.coordinate }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let delivery = json["deliveryAddress"] as? String, !delivery.isEmpty {
                        CLGeocoder().geocodeAddressString(delivery) { [weak self] p, _ in
                            DispatchQueue.main.async { self?.deliveryPin = p?.first?.location?.coordinate }
                        }
                    }
                }
            }
        }.resume()
    }

    // MARK: - Start Tracking

    func startTracking(link: DriverDeepLink) {
        isAccepting = true
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Accept the load first
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
                self?.beginGPS()
            }
        }.resume()
    }

    private func beginGPS() {
        isAccepting = false
        isTracking  = true
        routeTrail  = []   // fresh trail for each trip
        clm.startUpdatingLocation()
        // Also call startTracking endpoint so dispatcher sees In Transit
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/track/\(token)/start") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["loadId": loadId])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.load?.status = "In Transit" }
        }.resume()
    }

    // MARK: - Stop / Deliver

    func stopTracking() {
        isTracking = false
        clm.stopUpdatingLocation()
    }

    func markDelivered(link: DriverDeepLink) {
        stopTracking()
        let base = AWSConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/track/\(token)/status") else { return }
        var req = URLRequest(url: url)
        req.httpMethod  = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["status": "Delivered", "loadId": loadId])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.load?.status = "Delivered" }
        }.resume()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.lastSpeed    = loc.speed > 0 ? loc.speed * 2.23694 : nil // m/s → mph

            // Always update map region to follow driver
            self.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )

            // Append to route trail while tracking
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
        guard let url = URL(string: "\(base)/track/\(token)/location") else { return }
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
            "loadId":    loadId
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        bgSession.dataTask(with: req).resume()
    }

    // MARK: - Helpers

    private static func formatDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d 'at' h:mm a"
        return out.string(from: date)
    }
}
