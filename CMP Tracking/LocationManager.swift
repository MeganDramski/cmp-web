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
    private var onLocationUpdate: ((LocationUpdate) -> Void)?

    // How often to send updates to server (seconds)
    private var updateInterval: TimeInterval = 5.0
    private var lastSentTime: Date = .distantPast

    // MARK: - Geofence / Stillness Detection
    /// Geocoded coordinate of the current load's delivery address
    private var deliveryCoordinate: CLLocationCoordinate2D?
    /// How close (meters) the driver must be to the delivery address to start the timer
    private let deliveryRadiusMeters: CLLocationDistance = 300
    /// How long (seconds) the driver must be still near the delivery address
    private let stillnessThreshold: TimeInterval = 5 * 60   // 5 minutes
    /// Timer that fires the reminder after stillness threshold
    private var stillnessTimer: Timer?
    /// Last location used to detect movement
    private var lastMovementLocation: CLLocation?
    /// Minimum movement (meters) to reset the stillness timer
    private let movementResetDistance: CLLocationDistance = 50

    // MARK: - Init
    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 10  // meters — only update if moved 10m
        clManager.pausesLocationUpdatesAutomatically = false
        // allowsBackgroundLocationUpdates can only be set to true on a real device
        // with the background location capability active. Setting it on the simulator
        // without the entitlement causes a SIGABRT crash.
        #if !targetEnvironment(simulator)
        clManager.allowsBackgroundLocationUpdates = true
        #endif
        authorizationStatus = clManager.authorizationStatus
    }

    // MARK: - Public API

    /// Request "Always" authorization so background tracking works
    func requestPermission() {
        #if targetEnvironment(simulator)
        clManager.requestWhenInUseAuthorization()
        #else
        clManager.requestAlwaysAuthorization()
        #endif
    }

    /// One-shot location fetch — just centers the map on the user without
    /// starting continuous tracking or sending data to the server.
    func requestCurrentLocation() {
        guard authorizationStatus == .authorizedAlways ||
              authorizationStatus == .authorizedWhenInUse else {
            // Permission not granted yet — the delegate will call this again
            // after the user responds to the permission prompt
            return
        }
        clManager.requestLocation()
    }

    /// Start tracking for a given load & driver. Calls back on every interval.
    func startTracking(loadId: String, driverId: String, deliveryAddress: String = "", interval: TimeInterval = 5, onUpdate: @escaping (LocationUpdate) -> Void) {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            requestPermission()
            return
        }
        self.currentLoadId = loadId
        self.currentDriverId = driverId
        self.updateInterval = interval
        self.onLocationUpdate = onUpdate
        self.lastSentTime = .distantPast
        self.deliveryReminderTriggered = false
        self.deliveryCoordinate = nil
        self.lastMovementLocation = nil
        cancelStillnessTimer()

        // Geocode delivery address so we know when the driver is near it
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
        onLocationUpdate = nil
        cancelStillnessTimer()
        deliveryCoordinate = nil
        lastMovementLocation = nil
        deliveryReminderTriggered = false
    }

    // MARK: - Geofence / Stillness Helpers

    private func geocodeDeliveryAddress(_ address: String) {
        CLGeocoder().geocodeAddressString(address) { [weak self] placemarks, error in
            guard let self, let coord = placemarks?.first?.location?.coordinate else { return }
            DispatchQueue.main.async {
                self.deliveryCoordinate = coord
            }
        }
    }

    private func cancelStillnessTimer() {
        stillnessTimer?.invalidate()
        stillnessTimer = nil
    }

    /// Called on every location update to check if driver is near delivery and has stopped.
    private func checkDeliveryStillness(location: CLLocation) {
        guard !deliveryReminderTriggered,
              let deliveryCoord = deliveryCoordinate else { return }

        let deliveryLocation = CLLocation(latitude: deliveryCoord.latitude, longitude: deliveryCoord.longitude)
        let distanceToDelivery = location.distance(from: deliveryLocation)

        guard distanceToDelivery <= deliveryRadiusMeters else {
            // Driver is not near delivery — cancel any running timer
            cancelStillnessTimer()
            lastMovementLocation = nil
            return
        }

        // Driver IS near delivery address — check for movement
        if let lastLoc = lastMovementLocation {
            let moved = location.distance(from: lastLoc)
            if moved > movementResetDistance {
                // Driver moved significantly — reset the timer
                cancelStillnessTimer()
                lastMovementLocation = location
            } else if stillnessTimer == nil {
                // Driver near delivery and hasn't moved — start the stillness timer
                stillnessTimer = Timer.scheduledTimer(withTimeInterval: stillnessThreshold, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.deliveryReminderTriggered = true
                    }
                }
            }
        } else {
            // First time near delivery — record position and start timer
            lastMovementLocation = location
            stillnessTimer = Timer.scheduledTimer(withTimeInterval: stillnessThreshold, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.deliveryReminderTriggered = true
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            // As soon as permission is granted, grab current location
            // so the map centers on the real position immediately
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                self.requestCurrentLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        DispatchQueue.main.async {
            self.currentLocation = location
        }

        // Check geofence + stillness for delivery reminder
        checkDeliveryStillness(location: location)

        // Throttle: only send every `updateInterval` seconds
        let now = Date()
        guard now.timeIntervalSince(lastSentTime) >= updateInterval else { return }
        lastSentTime = now

        guard let loadId = currentLoadId, let driverId = currentDriverId else { return }

        let speedMph = max(location.speed, 0) * 2.23694   // m/s → mph
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

        DispatchQueue.main.async {
            self.latestUpdate = update
        }

        onLocationUpdate?(update)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
        }
    }
}
