//
//  DriverView.swift
//  CMP Tracking
//

import SwiftUI
import MapKit

// MARK: - Dark Theme Colors
private extension Color {
    static let dkBg       = Color(red: 0.059, green: 0.059, blue: 0.102)   // #0f0f1a
    static let dkSurface  = Color(red: 0.110, green: 0.110, blue: 0.180)   // #1c1c2e
    static let dkSurface2 = Color(red: 0.145, green: 0.145, blue: 0.220)   // #252538
    static let dkBorder   = Color(red: 0.173, green: 0.173, blue: 0.243)   // #2c2c3e
    static let dkMuted    = Color(red: 0.557, green: 0.557, blue: 0.627)   // #8e8ea0
    static let dkBlue     = Color(red: 0.000, green: 0.478, blue: 1.000)   // #007AFF
    static let dkGreen    = Color(red: 0.204, green: 0.780, blue: 0.349)   // #34C759
    static let dkOrange   = Color(red: 1.000, green: 0.584, blue: 0.000)   // #FF9500
    static let dkRed      = Color(red: 1.000, green: 0.231, blue: 0.188)   // #FF3B30
    static let dkPurple   = Color(red: 0.588, green: 0.329, blue: 0.969)   // #9654F7
}

struct DriverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var notifDelegate: AppNotificationDelegate
    @StateObject private var locationManager = LocationManager()
    @StateObject private var network = NetworkManager.shared

    @State private var assignedLoad: Load? = nil
    @State private var showLoadPicker = false
    @State private var statusMessage: String = ""
    @State private var showNotificationBanner = false
    @State private var notificationBannerMessage = ""
    @State private var isSendingNotification = false
    @State private var isAcceptingLoad = false
    @State private var isLoadingLoad = false
    @State private var showLocationPrePrompt = false
    @State private var showDeliveryReminderAlert = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var hasSetInitialRegion = false
    @State private var pickupPin: CLLocationCoordinate2D? = nil
    @State private var deliveryPin: CLLocationCoordinate2D? = nil

    var body: some View {
        NavigationView {
            ZStack {
                Color.dkBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        // ── Tracking status (prominent top card) ─────────────
                        trackingStatusCard

                        // ── Load card ────────────────────────────────────────
                        if let load = assignedLoad {
                            loadInfoCard(load: load)
                        } else {
                            noLoadCard
                        }

                        // ── Live section (accepted or in-transit) ────────────
                        let isActive = assignedLoad.map {
                            $0.status == .accepted || $0.status == .inTransit
                        } ?? false

                        if isActive {
                            liveLocationCard
                            mapPreviewCard
                            trackingButton

                            if let load = assignedLoad {
                                SendTrackingView(
                                    load: load,
                                    dispatcherEmail: appState.currentUser?.email ?? ""
                                ) { bannerMsg in
                                    notificationBannerMessage = bannerMsg
                                    showNotificationBanner = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                        showNotificationBanner = false
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .refreshable { await fetchAssignedLoadAsync() }
            .navigationTitle("Driver Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    RouteloLogo(showWordmark: false, size: 32)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button(action: { fetchAssignedLoad() }) {
                            if isLoadingLoad {
                                ProgressView().tint(.white).scaleEffect(0.75)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.dkMuted)
                            }
                        }
                        .disabled(isLoadingLoad)

                        Button(action: { authManager.signOut(); appState.logout() }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.dkMuted)
                        }
                    }
                }
            }
            .toolbarBackground(Color.dkBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                fetchAssignedLoad()
                NotificationCenter.default.addObserver(
                    forName: .cmpLoadsDidChangeRemotely, object: nil, queue: .main
                ) { _ in fetchAssignedLoad() }
                switch locationManager.authorizationStatus {
                case .notDetermined: showLocationPrePrompt = true
                case .authorizedWhenInUse:
                    locationManager.requestPermission()
                    locationManager.requestCurrentLocation()
                case .authorizedAlways:
                    locationManager.requestCurrentLocation()
                default: break
                }
            }
            .sheet(isPresented: $showLocationPrePrompt) {
                LocationPermissionView {
                    showLocationPrePrompt = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        locationManager.requestPermission()
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            .safeAreaInset(edge: .top) {
                if locationManager.authorizationStatus == .authorizedWhenInUse {
                    AlwaysAllowBanner {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .onReceive(locationManager.$currentLocation) { location in
                guard let loc = location else { return }
                if !hasSetInitialRegion {
                    mapRegion = MKCoordinateRegion(
                        center: loc.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    )
                    hasSetInitialRegion = true
                } else {
                    let latDiff = abs(loc.coordinate.latitude  - mapRegion.center.latitude)
                    let lngDiff = abs(loc.coordinate.longitude - mapRegion.center.longitude)
                    if latDiff > mapRegion.span.latitudeDelta * 0.4 ||
                       lngDiff > mapRegion.span.longitudeDelta * 0.4 {
                        withAnimation { mapRegion.center = loc.coordinate }
                    }
                }
            }
            .onReceive(locationManager.$deliveryReminderTriggered) { triggered in
                if triggered { showDeliveryReminderAlert = true }
            }
            .onChange(of: notifDelegate.shouldOpenDriverDashboard) {
                guard notifDelegate.shouldOpenDriverDashboard else { return }
                notifDelegate.shouldOpenDriverDashboard = false
                notificationBannerMessage = "🚛 It's pickup time! Tap Start Tracking to begin."
                showNotificationBanner = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    showNotificationBanner = false
                }
            }
            .alert("Delivery Reminder", isPresented: $showDeliveryReminderAlert) {
                Button("Mark as Delivered") {
                    locationManager.stopTracking()
                    network.disconnectWebSocket()
                    statusMessage = "Delivered at \(Date().formatted(date: .omitted, time: .shortened))"
                    if var load = assignedLoad {
                        load.status = .delivered
                        assignedLoad = load
                        LoadStore.shared.upsert(load)
                        network.updateLoadStatus(loadId: load.id, status: .delivered)
                        PickupReminderService.cancel(loadId: load.id)
                    }
                }
                Button("Not Yet", role: .cancel) {
                    locationManager.deliveryReminderTriggered = false
                }
            } message: {
                Text("You've been stopped near the delivery address for a while. Did you complete this delivery?")
            }
            .alert("Location Access Needed", isPresented: .constant(
                locationManager.authorizationStatus == .denied
            )) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please enable location access in Settings to track your deliveries.")
            }
        }
        .overlay(alignment: .top) {
            if showNotificationBanner {
                DarkNotificationBanner(message: notificationBannerMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showNotificationBanner)
    }

    // MARK: - Tracking Status Card

    private var trackingStatusCard: some View {
        HStack(spacing: 16) {
            // Pulsing circle indicator
            ZStack {
                if locationManager.isTracking {
                    Circle()
                        .stroke(Color.dkGreen.opacity(0.35), lineWidth: 10)
                        .frame(width: 46, height: 46)
                        .scaleEffect(locationManager.isTracking ? 1.35 : 1)
                        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                                   value: locationManager.isTracking)
                }
                Circle()
                    .fill(locationManager.isTracking ? Color.dkGreen : Color.dkMuted.opacity(0.35))
                    .frame(width: 22, height: 22)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(locationManager.isTracking ? "Tracking Active" : "Tracking Stopped")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(locationManager.isTracking ? .dkGreen : .dkMuted)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundColor(locationManager.isTracking ? Color.dkGreen.opacity(0.75) : .dkMuted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            locationManager.isTracking
                ? Color.dkGreen.opacity(0.10)
                : Color.dkSurface
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    locationManager.isTracking
                        ? Color.dkGreen.opacity(0.45)
                        : Color.dkBorder,
                    lineWidth: locationManager.isTracking ? 1.5 : 1
                )
        )
    }

    // MARK: - Load Info Card

    private func loadInfoCard(load: Load) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Dispatcher / company banner ───────────────────────────────────
            if let dispatcher = load.dispatcherEmail, !dispatcher.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.dkPurple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ASSIGNED BY")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dkPurple.opacity(0.8))
                            .kerning(0.8)
                        Text(dispatcher)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.dkPurple.opacity(0.12))
                .overlay(
                    Rectangle().frame(height: 1).foregroundColor(Color.dkPurple.opacity(0.3)),
                    alignment: .bottom
                )
            }

            // ── Header row ────────────────────────────────────────────────────
            HStack {
                Label(load.loadNumber, systemImage: "shippingbox.fill")
                    .font(.headline).fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
                DarkStatusBadge(status: load.status)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            Divider().background(Color.dkBorder).padding(.horizontal, 16)

            // ── Details ───────────────────────────────────────────────────────
            VStack(spacing: 0) {
                DarkInfoRow(icon: "arrow.up.circle",        label: "PICKUP",   value: load.pickupAddress)
                DarkInfoRow(icon: "arrow.down.circle.fill", label: "DELIVERY", value: load.deliveryAddress)
                DarkInfoRow(icon: "scalemass.fill",         label: "WEIGHT",   value: "\(Int(load.weight)) lbs")
                DarkInfoRow(icon: "person.fill",            label: "CUSTOMER", value: load.customerName)
                if !load.notes.isEmpty {
                    DarkInfoRow(icon: "note.text", label: "NOTES", value: load.notes)
                }
            }
            .padding(.vertical, 8)

            // ── Accept button (for assigned loads) ────────────────────────────
            if load.status == .assigned {
                Divider().background(Color.dkBorder).padding(.horizontal, 16)
                acceptLoadCard(load: load)
            }
        }
        .background(Color.dkSurface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dkBorder, lineWidth: 1))
        .onAppear { geocodeLoadAddresses(load) }
        .onChange(of: load.id) { geocodeLoadAddresses(load) }
    }

    // MARK: - No Load Card

    private var noLoadCard: some View {
        VStack(spacing: 14) {
            if isLoadingLoad {
                ProgressView()
                    .tint(.dkBlue)
                    .scaleEffect(1.2)
                Text("Checking for loads…")
                    .font(.subheadline)
                    .foregroundColor(.dkMuted)
            } else {
                ZStack {
                    Circle().fill(Color.dkSurface2).frame(width: 64, height: 64)
                    Image(systemName: "shippingbox")
                        .font(.system(size: 26))
                        .foregroundColor(.dkMuted)
                }
                Text("No Load Assigned")
                    .font(.headline).fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("Contact dispatch for your next assignment.")
                    .font(.subheadline)
                    .foregroundColor(.dkMuted)
                    .multilineTextAlignment(.center)
                Button(action: { fetchAssignedLoad() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.dkBlue)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color.dkBlue.opacity(0.12))
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.dkBlue.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(Color.dkSurface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dkBorder, lineWidth: 1))
    }

    // MARK: - Accept Load Card (inline, shown at bottom of loadInfoCard)

    private func acceptLoadCard(load: Load) -> some View {
        VStack(spacing: 10) {
            if let dispatcher = load.dispatcherEmail, !dispatcher.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.dkPurple)
                    Text("New load from \(dispatcher)")
                        .font(.caption).fontWeight(.medium)
                        .foregroundColor(.dkPurple)
                    Spacer()
                    Text(load.pickupDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.dkMuted)
                }
            }

            Button(action: { acceptLoad(load) }) {
                HStack(spacing: 8) {
                    if isAcceptingLoad {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Accepting…").fontWeight(.semibold)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept Load").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.dkPurple)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isAcceptingLoad)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Live Location Card

    private var liveLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill").foregroundColor(.dkBlue)
                Text("Current Location")
                    .font(.headline).fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            Divider().background(Color.dkBorder).padding(.horizontal, 16)

            if let loc = locationManager.currentLocation {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        coordLabel(label: "Lat", value: loc.coordinate.latitude)
                        coordLabel(label: "Lng", value: loc.coordinate.longitude)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "speedometer").foregroundColor(.dkMuted)
                            Text("\(Int(max(loc.speed, 0) * 2.23694)) mph")
                                .foregroundColor(.white)
                        }
                        .font(.subheadline)
                        HStack(spacing: 5) {
                            Image(systemName: "scope").foregroundColor(.dkMuted)
                            Text("±\(Int(loc.horizontalAccuracy))m")
                                .foregroundColor(.dkMuted)
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 16)

                if let update = locationManager.latestUpdate {
                    Text("Last sent \(update.timestamp, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.dkMuted)
                        .padding(.horizontal, 16)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(.dkMuted).scaleEffect(0.8)
                    Text("Waiting for GPS signal…")
                        .font(.subheadline)
                        .foregroundColor(.dkMuted)
                }
                .padding(.horizontal, 16)
            }

            Spacer(minLength: 14)
        }
        .background(Color.dkSurface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dkBorder, lineWidth: 1))
    }

    private func coordLabel(label: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.dkMuted)
            Text(String(format: "%.5f", value))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - Map Preview Card

    private var mapPreviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill").foregroundColor(.dkBlue)
                Text("Live Map")
                    .font(.headline).fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ZStack(alignment: .bottomTrailing) {
                LiveMapView(region: mapRegion, userLocation: locationManager.currentLocation?.coordinate, trail: locationManager.routeTrail)
                    .frame(height: 220)
                    .cornerRadius(12)
                    .padding(.horizontal, 12)

                Button(action: recenterDriverMap) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 14))
                        .padding(10)
                        .background(Color.dkSurface2)
                        .foregroundColor(.dkBlue)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.dkBorder, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
                .padding(.trailing, 20).padding(.bottom, 10)
            }
            .padding(.bottom, 12)
        }
        .background(Color.dkSurface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dkBorder, lineWidth: 1))
    }

    private func recenterDriverMap() {
        guard let loc = locationManager.currentLocation else { return }
        withAnimation {
            mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
    }

    // MARK: - Tracking Button

    private var trackingButton: some View {
        Button(action: toggleTracking) {
            HStack(spacing: 10) {
                if isSendingNotification {
                    ProgressView().tint(.white).scaleEffect(0.85)
                    Text("Notifying…").fontWeight(.semibold)
                } else {
                    Image(systemName: locationManager.isTracking ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(locationManager.isTracking ? "Stop Tracking" : "Start Tracking")
                        .font(.body).fontWeight(.bold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(locationManager.isTracking ? Color.dkRed : Color.dkGreen)
            .foregroundColor(.white)
            .cornerRadius(14)
            .shadow(color: (locationManager.isTracking ? Color.dkRed : Color.dkGreen).opacity(0.4),
                    radius: 8, x: 0, y: 4)
        }
    }

    // MARK: - Route Map Helpers

    private func geocodeLoadAddresses(_ load: Load) {
        pickupPin = nil
        deliveryPin = nil
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(load.pickupAddress) { placemarks, _ in
            guard let coord = placemarks?.first?.location?.coordinate else { return }
            DispatchQueue.main.async { self.pickupPin = coord }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            geocoder.geocodeAddressString(load.deliveryAddress) { placemarks, _ in
                guard let coord = placemarks?.first?.location?.coordinate else { return }
                DispatchQueue.main.async { self.deliveryPin = coord }
            }
        }
    }

    // MARK: - Actions (unchanged logic)

    private func fetchAssignedLoad() {
        guard let driver = appState.currentUser else { return }
        isLoadingLoad = true
        NSUbiquitousKeyValueStore.default.synchronize()
        matchLoadForDriver(driver)
        let phone = driver.phone.filter { $0.isNumber }
        let name  = driver.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let email = driver.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let base  = AWSConfig.baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        var query = "phone=\(phone)"
        if !name.isEmpty  { query += "&name=\(name)" }
        if !email.isEmpty { query += "&email=\(email)" }
        guard !base.contains("REPLACE_WITH"),
              let url = URL(string: "\(base)/loads/by-driver?\(query)") else {
            self.isLoadingLoad = false; return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                defer { self.isLoadingLoad = false }
                guard let data = data, error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let serverLoads = try? decoder.decode([Load].self, from: data),
                      !serverLoads.isEmpty else { return }
                for load in serverLoads { LoadStore.shared.upsert(load) }
                self.matchLoadForDriver(driver)
            }
        }.resume()
    }

    private func fetchAssignedLoadAsync() async {
        await withCheckedContinuation { cont in
            fetchAssignedLoad()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cont.resume() }
        }
    }

    private func matchLoadForDriver(_ driver: Driver) {
        let driverEmail = driver.email.lowercased()
        let driverPhone = driver.phone.filter { $0.isNumber }
        let driverName  = driver.name.lowercased().trimmingCharacters(in: .whitespaces)
        let allLoads = LoadStore.shared.load()
        let activeStatuses: Set<LoadStatus> = [.assigned, .accepted, .inTransit]
        let match = allLoads.first(where: {
            guard activeStatuses.contains($0.status) else { return false }
            let phoneMatch = !driverPhone.isEmpty &&
                ($0.assignedDriverPhone?.filter { $0.isNumber } == driverPhone ||
                 $0.assignedDriverId?.filter    { $0.isNumber } == driverPhone)
            let emailMatch = !driverEmail.isEmpty &&
                ($0.assignedDriverEmail?.lowercased() == driverEmail)
            let nameMatch = !driverName.isEmpty &&
                ($0.assignedDriverName?.lowercased().trimmingCharacters(in: .whitespaces) == driverName)
            return phoneMatch || emailMatch || nameMatch
        })
        assignedLoad = match
        if let load = match { PickupReminderService.schedule(load: load) }
    }

    private func acceptLoad(_ load: Load) {
        guard let driver = appState.currentUser else { return }
        isAcceptingLoad = true
        var updated = load; updated.status = .accepted
        assignedLoad = updated; LoadStore.shared.upsert(updated)
        network.updateLoadStatus(loadId: load.id, status: .accepted)
        network.notifyDispatcherLoadAccepted(load: updated, driverName: driver.name) { _ in
            isAcceptingLoad = false
        }
        PickupReminderService.schedule(load: updated)
        notificationBannerMessage = "✅ Load accepted — dispatcher has been notified!"
        showNotificationBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showNotificationBanner = false }
    }

    private func toggleTracking() {
        if locationManager.isTracking {
            locationManager.stopTracking()
            network.disconnectWebSocket()
            statusMessage = "Stopped at \(Date().formatted(date: .omitted, time: .shortened))"
        } else {
            guard let load = assignedLoad, let driver = appState.currentUser else {
                statusMessage = "No load assigned."; return
            }
            locationManager.requestPermission()
            var updatedLoad = load; updatedLoad.status = .inTransit
            assignedLoad = updatedLoad; LoadStore.shared.upsert(updatedLoad)
            AWSManager.shared.updateStatusByToken(token: load.trackingToken,
                                                  loadId: load.id, status: .inTransit)
            locationManager.startTracking(
                loadId: load.id, driverId: driver.id,
                trackingToken: load.trackingToken,
                deliveryAddress: load.deliveryAddress, interval: 10
            ) { update in
                DispatchQueue.main.async {
                    self.statusMessage = "Sent at \(update.timestamp.formatted(date: .omitted, time: .shortened))"
                }
            }
            statusMessage = "Tracking started"
            notificationBannerMessage = "🚛 Tracking started — dispatcher can see your location live"
            showNotificationBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showNotificationBanner = false }
        }
    }
}

// MARK: - Dark Sub-components

struct DarkStatusBadge: View {
    let status: LoadStatus
    var body: some View {
        Label(status.rawValue, systemImage: status.icon)
            .font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundColor(statusColor)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(statusColor.opacity(0.3), lineWidth: 1))
    }
    private var statusColor: Color {
        switch status {
        case .pending:   return Color(red: 0.557, green: 0.557, blue: 0.627)
        case .assigned:  return Color(red: 0.000, green: 0.478, blue: 1.000)
        case .accepted:  return Color(red: 0.588, green: 0.329, blue: 0.969)
        case .inTransit: return Color(red: 1.000, green: 0.584, blue: 0.000)
        case .delivered: return Color(red: 0.204, green: 0.780, blue: 0.349)
        case .cancelled: return Color(red: 1.000, green: 0.231, blue: 0.188)
        }
    }
}

struct DarkInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Color(red: 0.557, green: 0.557, blue: 0.627))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 0.557, green: 0.557, blue: 0.627))
                    .kerning(0.5)
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

struct DarkNotificationBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline).fontWeight(.medium)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(red: 0.000, green: 0.478, blue: 1.000).opacity(0.9))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}

// Keep old names available so other files that reference them don't break
typealias StatusBadge = DarkStatusBadge
typealias InfoRow = DarkInfoRow

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AlwaysAllowBanner: View {
    let onOpenSettings: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill").foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Background location needed")
                    .font(.caption).fontWeight(.bold).foregroundColor(.white)
                Text("Tap to change to \"Always Allow\" in Settings")
                    .font(.caption2).foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button(action: onOpenSettings) {
                Text("Fix")
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white)
                    .foregroundColor(.orange)
                    .cornerRadius(20)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.gradient)
        .cornerRadius(12)
        .padding(.horizontal, 12).padding(.top, 4)
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

struct NotificationBanner: View {
    let message: String
    var body: some View { DarkNotificationBanner(message: message) }
}

#Preview {
    DriverView()
        .environmentObject(AppState.shared)
}
