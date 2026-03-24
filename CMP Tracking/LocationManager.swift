//
//  LocationManager.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import Foundation
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Published State
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var errorMessage: String?
    @Published var latestUpdate: LocationUpdate?

    /// Fires true when driver appears to have stopped near the delivery address
    @Published var deliveryReminderTriggered: Bool = false

    // MARK: - Private
    private let clManager = CLLocationManager()
    private var currentLoadId: String?
    private var currentDriverId: String?
    private var currentTrackingToken: String?          // ← NEW: public endpoint token
    private var onLocationUpdate: ((LocationUpdate) -> Void)?

    // How often to send updates to server (seconds)
    private var updateInterval: TimeInterval = 10.0    // 10 s is enough for a truck
    private var lastSentTime: Date = .distantPast

    // Background URLSession — iOS keeps in-flight requests alive even when
    // the app is backgrounded or the screen is locked.
    private lazy var bgSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.cmptracking.location")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }()

    // MARK: - Geofence / Stillness Detection
    /// Geocoded coordinate of the current load's delivery address
    private var deliveryCoordinate: CLLocationCoordinate2D?
    /// How close (meters) the driver must be to the delivery address to start the timer
    /// ~100 ft = 30 meters
    private let deliveryRadiusMeters: CLLocationDistance = 30
    /// How long (seconds) the driver must be still near the delivery address
    private let stillnessThreshold: TimeInterval = 3 * 60   // 3 minutes
    /// Timer that fires the reminder after stillness threshold
    private var stillnessTimer: Timer?
    /// Last location used to detect movement
    private var lastMovementLocation: CLLocation?
    /// Minimum movement (meters) to reset the stillness timer
    private let movementResetDistance: CLLocationDistance = 15

    // MARK: - Init
    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 10  // meters — only wake for meaningful movement
        clManager.pausesLocationUpdatesAutomatically = false
        // allowsBackgroundLocationUpdates can only be set to true on a real device
        // with the background location capability active. Setting it on the simulator
        // without the entitlement causes a SIGABRT crash.
        #if !targetEnvironment(simulator)
        clManager.allowsBackgroundLocationUpdates = true
        clManager.showsBackgroundLocationIndicator = true  // blue bar so driver knows it's running
        #endif
        authorizationStatus = clManager.authorizationStatus
    }

    // MARK: - Public API

    /// Request "Always" authorization so background tracking works.
    /// iOS requires a two-step upgrade: WhenInUse first, then Always.
    /// Calling requestAlwaysAuthorization() before WhenInUse is granted causes
    /// iOS to silently downgrade the prompt — hiding the "Always Allow" option.
    func requestPermission() {
        switch clManager.authorizationStatus {
        case .notDetermined:
            // Step 1: request WhenInUse — iOS shows the full dialog with "Always Allow"
            clManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Step 2: upgrade to Always — shows the "Change to Always Allow" banner
            clManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// One-shot location fetch — just centers the map on the user without
    /// starting continuous tracking or sending data to the server.
    func requestCurrentLocation() {
        guard authorizationStatus == .authorizedAlways ||
              authorizationStatus == .authorizedWhenInUse else { return }
        clManager.requestLocation()
    }

    /// Start tracking for a given load & driver.
    /// - Parameters:
    ///   - trackingToken: The load's public tracking token — used to POST to
    ///                    `/track/{token}/location` without requiring JWT auth.
    ///                    This is the same token the browser driver page uses.
    func startTracking(loadId: String,
                       driverId: String,
                       trackingToken: String,
                       deliveryAddress: String = "",
                       interval: TimeInterval = 10,
                       onUpdate: ((LocationUpdate) -> Void)? = nil) {
        guard authorizationStatus == .authorizedAlways ||
              authorizationStatus == .authorizedWhenInUse else {
            requestPermission()
            return
        }
        self.currentLoadId = loadId
        self.currentDriverId = driverId
        self.currentTrackingToken = trackingToken
        self.updateInterval = interval
        self.onLocationUpdate = onUpdate
        self.lastSentTime = .distantPast
        self.deliveryReminderTriggered = false
        self.deliveryCoordinate = nil
        self.lastMovementLocation = nil
        cancelStillnessTimer()

        if !deliveryAddress.isEmpty {
            geocodeDeliveryAddress(deliveryAddress)
        }

        clManager.startUpdatingLocation()
        isTracking = true
    }

    func stopTracking() {
        clManager.stopUpdatingLocation()
        isTracking = false
        currentLoadId = nil
        currentDriverId = nil
        currentTrackingToken = nil
        onLocationUpdate = nil
        cancelStillnessTimer()
        deliveryCoordinate = nil
        lastMovementLocation = nil
        deliveryReminderTriggered = false
    }

    // MARK: - Post location to public endpoint (no auth, works in background)

    private func postLocationToServer(_ update: LocationUpdate, token: String) {
        let urlString = AWSConfig.baseURL + "/track/\(token)/location"
        guard let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        let body: [String: Any] = [
            "latitude":  update.latitude,
            "longitude": update.longitude,
            "speed":     update.speed,
            "heading":   update.heading,
            "timestamp": ISO8601DateFormatter().string(from: update.timestamp)
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Use background session so iOS delivers the request even when screen is locked
        bgSession.dataTask(with: req) { _, _, error in
            if let error = error {
                print("📍 Location post failed: \(error.localizedDescription)")
            } else {
                print("📍 Location posted → \(update.latitude), \(update.longitude)")
            }
        }.resume()
    }

    // MARK: - Geofence / Stillness Helpers

    private func geocodeDeliveryAddress(_ address: String) {
        CLGeocoder().geocodeAddressString(address) { [weak self] placemarks, error in
            guard let self, let coord = placemarks?.first?.location?.coordinate else { return }
            DispatchQueue.main.async { self.deliveryCoordinate = coord }
        }
    }

    private func cancelStillnessTimer() {
        stillnessTimer?.invalidate()
        stillnessTimer = nil
    }

    private func checkDeliveryStillness(location: CLLocation) {
        guard !deliveryReminderTriggered,
              let deliveryCoord = deliveryCoordinate else { return }
        let deliveryLocation = CLLocation(latitude: deliveryCoord.latitude, longitude: deliveryCoord.longitude)
        guard location.distance(from: deliveryLocation) <= deliveryRadiusMeters else {
            cancelStillnessTimer(); lastMovementLocation = nil; return
        }
        if let lastLoc = lastMovementLocation {
            if location.distance(from: lastLoc) > movementResetDistance {
                cancelStillnessTimer(); lastMovementLocation = location
            } else if stillnessTimer == nil {
                let t = Timer(timeInterval: stillnessThreshold, repeats: false) { [weak self] _ in
                    self?.deliveryReminderTriggered = true
                }
                RunLoop.main.add(t, forMode: .common); stillnessTimer = t
            }
        } else {
            lastMovementLocation = location
            let t = Timer(timeInterval: stillnessThreshold, repeats: false) { [weak self] _ in
                self?.deliveryReminderTriggered = true
            }
            RunLoop.main.add(t, forMode: .common); stillnessTimer = t
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            // Two-step iOS flow: once WhenInUse is granted, immediately request Always
            // so iOS presents the "Change to Always Allow" prompt/banner.
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            // As soon as any permission is granted, grab current location
            // so the map centers on the real position immediately.
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                self.requestCurrentLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        DispatchQueue.main.async { self.currentLocation = location }

        let captured = location
        DispatchQueue.main.async { self.checkDeliveryStillness(location: captured) }

        // Throttle
        let now = Date()
        guard now.timeIntervalSince(lastSentTime) >= updateInterval else { return }
        lastSentTime = now

        guard let loadId = currentLoadId, let driverId = currentDriverId else { return }

        let speedMph = max(location.speed, 0) * 2.23694
        let heading = location.course >= 0 ? location.course : 0

        let update = LocationUpdate(
            loadId: loadId,
            driverId: driverId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: speedMph,
            heading: heading,
            timestamp: location.timestamp
        )

        DispatchQueue.main.async { self.latestUpdate = update }

        // ── Post to public token endpoint (no auth, survives background) ──
        if let token = currentTrackingToken {
            postLocationToServer(update, token: token)
        }

        // Also fire the optional callback (used for UI updates / WebSocket)
        onLocationUpdate?(update)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
    }
}
