//
//  DriverView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI
import MapKit

struct DriverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var notifDelegate: AppNotificationDelegate
    @StateObject private var locationManager = LocationManager()
    @StateObject private var network = NetworkManager.shared

    // The load assigned to this driver — fetched from LoadStore by matching driver email
    @State private var assignedLoad: Load? = nil
    @State private var showLoadPicker = false
    @State private var statusMessage: String = ""
    @State private var showNotificationBanner = false
    @State private var notificationBannerMessage = ""
    @State private var isSendingNotification = false
    @State private var isAcceptingLoad = false
    @State private var isLoadingLoad = false
    /// Controls the pre-prompt sheet shown before the iOS system permission dialog
    @State private var showLocationPrePrompt = false
    /// Shown when driver appears to have stopped at the delivery address
    @State private var showDeliveryReminderAlert = false
    /// Start with a zero-span region; we snap to the real GPS on the first fix
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    /// Tracks whether we've received and applied the first real GPS fix
    @State private var hasSetInitialRegion = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Status Card ──────────────────────────────────────────
                    trackingStatusCard

                    // ── Assigned Load Card ───────────────────────────────────
                    if let load = assignedLoad {
                        loadInfoCard(load: load)

                        // ── Accept Load Card (only when still in Assigned state) ──
                        if load.status == .assigned {
                            acceptLoadCard(load: load)
                        }
                    } else {
                        noLoadCard
                    }

                    // ── Live Location / Tracking controls (only after accepted) ──
                    let isAccepted = assignedLoad.map { $0.status == .accepted || $0.status == .inTransit } ?? false
                    if isAccepted {
                        // ── Live Location Card ───────────────────────────────────
                        liveLocationCard

                        // ── Map Preview ──────────────────────────────────────────
                        mapPreviewCard

                        // ── Start / Stop Button ──────────────────────────────────
                        trackingButton

                        // ── Send Tracking Link ───────────────────────────────────
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
                .padding()
            }
            .refreshable { await fetchAssignedLoadAsync() }
            .navigationTitle("Driver Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ParceloLogo(showWordmark: false, size: 32)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // Refresh loads from server
                        Button(action: { fetchAssignedLoad() }) {
                            if isLoadingLoad {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isLoadingLoad)
                        Button(action: { authManager.signOut(); appState.logout() }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .onAppear {
                fetchAssignedLoad()
                switch locationManager.authorizationStatus {
                case .notDetermined:
                    // Show our explanation screen first, THEN trigger the system dialog
                    showLocationPrePrompt = true
                case .authorizedWhenInUse:
                    // Driver previously picked "While Using" — request upgrade to Always
                    locationManager.requestPermission()
                    locationManager.requestCurrentLocation()
                case .authorizedAlways:
                    locationManager.requestCurrentLocation()
                default:
                    break
                }
            }
            // Pre-prompt sheet — shown before the iOS system permission dialog
            .sheet(isPresented: $showLocationPrePrompt) {
                LocationPermissionView {
                    showLocationPrePrompt = false
                    // Small delay so sheet dismisses before system dialog appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        locationManager.requestPermission()
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            // "Upgrade to Always Allow" banner — shown when driver only granted WhenInUse
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
                    // First real GPS fix — snap directly to the user's position
                    mapRegion = MKCoordinateRegion(
                        center: loc.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    )
                    hasSetInitialRegion = true
                } else {
                    // Subsequent updates — only recenter if driver has drifted
                    // outside the visible area, preserving manual zoom/pan
                    let latDiff = abs(loc.coordinate.latitude  - mapRegion.center.latitude)
                    let lngDiff = abs(loc.coordinate.longitude - mapRegion.center.longitude)
                    if latDiff > mapRegion.span.latitudeDelta * 0.4 ||
                       lngDiff > mapRegion.span.longitudeDelta * 0.4 {
                        withAnimation {
                            mapRegion.center = loc.coordinate
                        }
                    }
                }
            }
            .onReceive(locationManager.$deliveryReminderTriggered) { triggered in
                if triggered {
                    showDeliveryReminderAlert = true
                }
            }
            // Pickup reminder notification was tapped — prompt driver to start
            .onChange(of: notifDelegate.shouldOpenDriverDashboard) { tapped in
                guard tapped else { return }
                notifDelegate.shouldOpenDriverDashboard = false
                // Surface a banner nudging the driver to press Start Tracking
                notificationBannerMessage = "🚛 It's pickup time! Tap Start Tracking to begin."
                showNotificationBanner = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    showNotificationBanner = false
                }
            }
            .alert("Delivery Reminder", isPresented: $showDeliveryReminderAlert) {
                Button("Mark as Delivered") {
                    // Stop tracking and update load status to delivered
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
                    // Dismiss — reset so it can fire again after another stillness period
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
        // ── Notification Banner Overlay ──────────────────────────────────────
        .overlay(alignment: .top) {
            if showNotificationBanner {
                NotificationBanner(message: notificationBannerMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showNotificationBanner)
    }

    // MARK: - Sub Views

    private var trackingStatusCard: some View {
        HStack {
            Circle()
                .fill(locationManager.isTracking ? Color.green : Color.gray)
                .frame(width: 14, height: 14)
                .overlay(
                    locationManager.isTracking ?
                    Circle().stroke(Color.green.opacity(0.4), lineWidth: 6).scaleEffect(1.5) : nil
                )
                .animation(.easeInOut(duration: 1).repeatForever(), value: locationManager.isTracking)

            VStack(alignment: .leading, spacing: 2) {
                Text(locationManager.isTracking ? "Tracking Active" : "Tracking Stopped")
                    .font(.headline)
                    .foregroundColor(locationManager.isTracking ? .green : .secondary)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if network.wsConnected {
                Label("Live", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private func loadInfoCard(load: Load) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(load.loadNumber, systemImage: "shippingbox.fill")
                    .font(.headline)
                Spacer()
                StatusBadge(status: load.status)
            }
            Divider()
            InfoRow(icon: "arrow.up.circle", label: "Pickup", value: load.pickupAddress)
            InfoRow(icon: "arrow.down.circle.fill", label: "Delivery", value: load.deliveryAddress)
            InfoRow(icon: "scalemass.fill", label: "Weight", value: "\(Int(load.weight)) lbs")
            InfoRow(icon: "person.fill", label: "Customer", value: load.customerName)
            if !load.notes.isEmpty {
                InfoRow(icon: "note.text", label: "Notes", value: load.notes)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var noLoadCard: some View {
        VStack(spacing: 12) {
            if isLoadingLoad {
                ProgressView("Checking for assigned loads…")
                    .padding(.vertical, 8)
            } else {
                Image(systemName: "shippingbox")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No Load Assigned")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Contact dispatch for your next assignment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: { fetchAssignedLoad() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private func acceptLoadCard(load: Load) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.title2)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Load Assigned")
                        .font(.headline)
                    Text("Pickup: \(load.pickupDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Button(action: { acceptLoad(load) }) {
                HStack {
                    if isAcceptingLoad {
                        ProgressView().tint(.white).scaleEffect(0.85)
                        Text("Accepting…").fontWeight(.semibold)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept Load").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isAcceptingLoad)
        }
        .padding()
        .background(Color.purple.opacity(0.08))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }

    private var liveLocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Current Location", systemImage: "location.fill")
                .font(.headline)
            Divider()
            if let loc = locationManager.currentLocation {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lat: \(loc.coordinate.latitude, specifier: "%.5f")")
                            .font(.system(.body, design: .monospaced))
                        Text("Lng: \(loc.coordinate.longitude, specifier: "%.5f")")
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("\(Int(max(loc.speed, 0) * 2.23694)) mph", systemImage: "speedometer")
                            .font(.body)
                        Label("±\(Int(loc.horizontalAccuracy))m", systemImage: "scope")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let update = locationManager.latestUpdate {
                    Text("Last sent: \(update.timestamp, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Waiting for GPS signal…")
                    .foregroundColor(.secondary)
                    .font(.body)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var mapPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live Map", systemImage: "map.fill")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)
            ZStack(alignment: .bottomTrailing) {
                // Free-scrolling map — pinch to zoom, drag to pan
                Map(coordinateRegion: $mapRegion, showsUserLocation: true)
                    .frame(height: 220)
                    .cornerRadius(12)

                // Re-center button
                Button(action: recenterDriverMap) {
                    Image(systemName: "location.fill")
                        .padding(10)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 3)
                }
                .padding(10)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
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

    private var trackingButton: some View {
        Button(action: toggleTracking) {
            HStack {
                if isSendingNotification {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                    Text("Notifying…")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: locationManager.isTracking ? "stop.fill" : "play.fill")
                    Text(locationManager.isTracking ? "Stop Tracking" : "Start Tracking")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(locationManager.isTracking ? Color.red : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
    }

    // MARK: - Actions

    /// Finds the load assigned to the currently logged-in driver.
    /// Fetches fresh loads from the server first, then falls back to local cache.
    private func fetchAssignedLoad() {
        guard let driver = appState.currentUser else { return }
        isLoadingLoad = true

        // Try server first so the driver always sees the latest assignment
        network.fetchLoads { serverLoads, _ in
            if let serverLoads = serverLoads, !serverLoads.isEmpty {
                // Merge into local store so offline use still works
                for load in serverLoads { LoadStore.shared.upsert(load) }
            }
            // Now match from the (now-updated) local store
            self.matchLoadForDriver(driver)
            self.isLoadingLoad = false
        }
    }

    /// Async wrapper used by pull-to-refresh (.refreshable).
    private func fetchAssignedLoadAsync() async {
        await withCheckedContinuation { cont in
            fetchAssignedLoad()
            // fetchAssignedLoad sets isLoadingLoad = false when done;
            // give it a tiny moment to finish before releasing the refresh spinner
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cont.resume() }
        }
    }

    private func matchLoadForDriver(_ driver: Driver) {
        let driverEmail = driver.email.lowercased()
        let driverPhone = driver.phone.filter { $0.isNumber }
        let allLoads = LoadStore.shared.load()

        let activeStatuses: Set<LoadStatus> = [.assigned, .accepted, .inTransit]

        // Primary match: email/phone AND active status
        let match = allLoads.first(where: {
            let emailMatch = !driverEmail.isEmpty &&
                ($0.assignedDriverEmail?.lowercased() == driverEmail)
            let phoneMatch = !driverPhone.isEmpty &&
                ($0.assignedDriverId?.filter { $0.isNumber } == driverPhone ||
                 $0.assignedDriverEmail?.filter { $0.isNumber } == driverPhone)
            return (emailMatch || phoneMatch) && activeStatuses.contains($0.status)
        }) ?? allLoads.first(where: {
            // Secondary match: email/phone only, but STILL require active status
            let emailMatch = !driverEmail.isEmpty &&
                ($0.assignedDriverEmail?.lowercased() == driverEmail)
            let phoneMatch = !driverPhone.isEmpty &&
                ($0.assignedDriverEmail?.filter { $0.isNumber } == driverPhone)
            return (emailMatch || phoneMatch) && activeStatuses.contains($0.status)
        })

        assignedLoad = match

        // Schedule (or cancel) pickup reminders based on the assigned load
        if let load = match {
            PickupReminderService.schedule(load: load)
        }
    }

    private func acceptLoad(_ load: Load) {
        guard let driver = appState.currentUser else { return }
        isAcceptingLoad = true

        // 1. Update status locally & persist
        var updated = load
        updated.status = .accepted
        assignedLoad = updated
        LoadStore.shared.upsert(updated)

        // 2. Push status to server
        network.updateLoadStatus(loadId: load.id, status: .accepted)

        // 3. Notify dispatcher via server (fire-and-forget — graceful fallback)
        network.notifyDispatcherLoadAccepted(load: updated, driverName: driver.name) { _ in
            isAcceptingLoad = false
        }

        // 4. Re-schedule pickup reminders now that load is accepted
        PickupReminderService.schedule(load: updated)

        // 5. Show confirmation banner
        notificationBannerMessage = "✅ Load accepted — dispatcher has been notified!"
        showNotificationBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            showNotificationBanner = false
        }
    }

    private func toggleTracking() {
        if locationManager.isTracking {
            locationManager.stopTracking()
            network.disconnectWebSocket()
            statusMessage = "Stopped at \(Date().formatted(date: .omitted, time: .shortened))"
        } else {
            guard let load = assignedLoad,
                  let driver = appState.currentUser else {
                statusMessage = "No load assigned."
                return
            }
            locationManager.requestPermission()

            // 1️⃣ Update load status → In Transit immediately (local + server)
            var updatedLoad = load
            updatedLoad.status = .inTransit
            assignedLoad = updatedLoad
            LoadStore.shared.upsert(updatedLoad)
            // PATCH /track/{token}/status — public endpoint, no auth needed
            AWSManager.shared.updateStatusByToken(token: load.trackingToken,
                                                  loadId: load.id,
                                                  status: .inTransit)

            // 2️⃣ Start GPS — posts to /track/{token}/location in the background
            //    The native OS keeps this running even when the screen is locked.
            locationManager.startTracking(
                loadId: load.id,
                driverId: driver.id,
                trackingToken: load.trackingToken,
                deliveryAddress: load.deliveryAddress,
                interval: 10
            ) { update in
                DispatchQueue.main.async {
                    self.statusMessage = "Sent at \(update.timestamp.formatted(date: .omitted, time: .shortened))"
                }
            }

            statusMessage = "Tracking started"
            notificationBannerMessage = "🚛 Tracking started — dispatcher can see your location live"
            showNotificationBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showNotificationBanner = false
            }
        }
    }
}

// MARK: - Reusable Sub-components

struct StatusBadge: View {
    let status: LoadStatus
    var body: some View {
        Label(status.rawValue, systemImage: status.icon)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundColor(statusColor)
            .cornerRadius(8)
    }
    private var statusColor: Color {
        switch status {
        case .pending:   return .gray
        case .assigned:  return .blue
        case .accepted:  return .purple
        case .inTransit: return .orange
        case .delivered: return .green
        case .cancelled: return .red
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.body)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Always Allow Banner

struct AlwaysAllowBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Background location needed")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Tap to change to \"Always Allow\" in Settings")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button(action: onOpenSettings) {
                Text("Fix")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .foregroundColor(.orange)
                    .cornerRadius(20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.gradient)
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Notification Banner

struct NotificationBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.accentColor.gradient)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}

#Preview {
    DriverView()
        .environmentObject(AppState.shared)
}
