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

    /// Accumulates GPS breadcrumbs while isTracking is true — used to draw route polyline on map.
    @Published var routeTrail: [CLLocationCoordinate2D] = []

    /// Fires true when driver appears to have stopped near the delivery address
    @Published var deliveryReminderTriggered: Bool = false

    // MARK: - Private
    private let clManager = CLLocationManager()
    private var currentLoadId: String?
    private var currentDriverId: String?
    private var currentTrackingToken: String?
    private var onLocationUpdate: ((LocationUpdate) -> Void)?

    // How often to send updates to server (seconds)
    private var updateInterval: TimeInterval = 10.0
    private var lastSentTime: Date = .distantPast

    // Background URLSession
    private lazy var bgSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.cmptracking.location")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }()

    // MARK: - Geofence / Stillness Detection
    private var deliveryCoordinate: CLLocationCoordinate2D?
    private let deliveryRadiusMeters: CLLocationDistance = 30
    private let stillnessThreshold: TimeInterval = 3 * 60
    private var stillnessTimer: Timer?
    private var lastMovementLocation: CLLocation?
    private let movementResetDistance: CLLocationDistance = 15

    // MARK: - Init
    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 10
        clManager.pausesLocationUpdatesAutomatically = false
        #if !targetEnvironment(simulator)
        clManager.allowsBackgroundLocationUpdates = true
        clManager.showsBackgroundLocationIndicator = true
        #endif
        authorizationStatus = clManager.authorizationStatus
    }

    // MARK: - Public API

    func requestPermission() {
        switch clManager.authorizationStatus {
        case .notDetermined:
            clManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            clManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func requestCurrentLocation() {
        guard authorizationStatus == .authorizedAlways ||
              authorizationStatus == .authorizedWhenInUse else { return }
        clManager.requestLocation()
    }

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
        self.routeTrail = []   // clear trail at start of each new trip
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
        // routeTrail kept intentionally so the last route stays visible on the map
    }

    // MARK: - Post location to public endpoint

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

        // Append every raw GPS point to the route trail while tracking
        // (independent of the server throttle so the polyline is smooth)
        if isTracking {
            let coord = location.coordinate
            DispatchQueue.main.async {
                if self.routeTrail.last.map({ $0.latitude != coord.latitude || $0.longitude != coord.longitude }) ?? true {
                    self.routeTrail.append(coord)
                }
            }
        }

        // Throttle server posts
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

        if let token = currentTrackingToken {
            postLocationToServer(update, token: token)
        }

        onLocationUpdate?(update)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
    }
}
