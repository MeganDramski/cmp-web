// DriverLinkView.swift
// Shown when driver taps the SMS link — no sign-in required.
// Fetches load by token, shows details, lets driver start/stop tracking.

import SwiftUI
import CoreLocation

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
            // Status badge
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

            // Route
            VStack(spacing: 0) {
                routeRow(icon: "circle.fill", color: .green,  label: "PICKUP",   address: load.pickupAddress,   date: load.pickupDate)
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 20).padding(.leading, 18)
                routeRow(icon: "mappin.circle.fill", color: .red, label: "DELIVERY", address: load.deliveryAddress, date: load.deliveryDate)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
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
                    trackingToken:   json["trackingToken"]   as? String ?? link.token
                )
                // Request Always location permission on load
                self?.clm.requestAlwaysAuthorization()
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
