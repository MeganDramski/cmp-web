//
//  DispatcherView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI
import MapKit

struct DispatcherView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var viewModel = DispatcherViewModel()

    var body: some View {
        TabView {
            ActiveLoadsTab(viewModel: viewModel)
                .tabItem {
                    Label("Loads", systemImage: "list.bullet.clipboard.fill")
                }

            HistoryTab(viewModel: viewModel)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            NavigationView {
                BillingView()
            }
            .tabItem {
                Label("Billing", systemImage: "creditcard.fill")
            }
        }
    }
}

// MARK: - Active Loads Tab

struct ActiveLoadsTab: View {
    @ObservedObject var viewModel: DispatcherViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager

    @State private var searchText = ""
    @State private var selectedStatus: LoadStatus? = nil
    @State private var showAddLoad = false

    var filteredLoads: [Load] {
        viewModel.loads.filter { load in
            let matchesSearch = searchText.isEmpty ||
                load.loadNumber.localizedCaseInsensitiveContains(searchText) ||
                load.customerName.localizedCaseInsensitiveContains(searchText) ||
                load.assignedDriverName?.localizedCaseInsensitiveContains(searchText) == true
            let matchesStatus = selectedStatus == nil || load.status == selectedStatus
            return matchesSearch && matchesStatus
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                summaryBar
                statusFilterChips

                if viewModel.isLoading {
                    Spacer()
                    ProgressView("Loading loads…")
                    Spacer()
                } else if filteredLoads.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filteredLoads) { load in
                            NavigationLink(destination: LoadDetailView(load: load, viewModel: viewModel)) {
                                LoadRowView(load: load)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await viewModel.refreshLoads() }
                }
            }
            .navigationTitle("Dispatch Board")
            .searchable(text: $searchText, prompt: "Search loads, customers, drivers…")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 10) {
                        Text("Routelo")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Button(action: { authManager.signOut(); appState.logout() }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddLoad = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddLoad) {
                AddLoadView(viewModel: viewModel)
            }
            .task { await viewModel.refreshLoads() }
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                SummaryCard(title: "In Transit", count: viewModel.loads.filter { $0.status == .inTransit }.count, icon: "truck.box.fill",      color: .orange)
                SummaryCard(title: "Accepted",   count: viewModel.loads.filter { $0.status == .accepted  }.count, icon: "hand.thumbsup.fill",    color: .purple)
                SummaryCard(title: "Assigned",   count: viewModel.loads.filter { $0.status == .assigned  }.count, icon: "person.fill",           color: .blue)
                SummaryCard(title: "Pending",    count: viewModel.loads.filter { $0.status == .pending   }.count, icon: "clock",                 color: .gray)
                SummaryCard(title: "Delivered",  count: viewModel.loads.filter { $0.status == .delivered }.count, icon: "checkmark.seal.fill",   color: .green)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Filter Chips

    private var statusFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: selectedStatus == nil) { selectedStatus = nil }
                ForEach(LoadStatus.allCases, id: \.self) { status in
                    FilterChip(title: status.rawValue, isSelected: selectedStatus == status) {
                        selectedStatus = selectedStatus == status ? nil : status
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No Loads Found")
                .font(.title2).fontWeight(.semibold)
            Text("Tap + to create a new load or adjust your filters.")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - History Tab

struct HistoryTab: View {
    @ObservedObject var viewModel: DispatcherViewModel
    @State private var searchText = ""

    private var filtered: [Load] {
        guard !searchText.isEmpty else { return viewModel.history }
        return viewModel.history.filter {
            $0.loadNumber.localizedCaseInsensitiveContains(searchText) ||
            $0.customerName.localizedCaseInsensitiveContains(searchText) ||
            $0.assignedDriverName?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    /// Group loads by calendar week label, e.g. "This Week", "Last Week", "Mar 1 – Mar 7"
    private var grouped: [(String, [Load])] {
        let cal = Calendar.current
        let now = Date()
        let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now

        var groups: [(String, [Load])] = []
        var seen = Set<String>()
        var buckets: [String: [Load]] = [:]

        for load in filtered {
            let date = load.completedAt ?? load.deliveryDate
            let label: String
            if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                label = "This Week"
            } else if let prev = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart),
                      date >= prev {
                label = "Last Week"
            } else {
                let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
                let end   = cal.date(byAdding: .day, value: 6, to: start) ?? date
                let fmt   = DateFormatter()
                fmt.dateFormat = "MMM d"
                label = "\(fmt.string(from: start)) – \(fmt.string(from: end))"
            }
            if !seen.contains(label) { seen.insert(label); groups.append((label, [])) }
            buckets[label, default: []].append(load)
        }
        return groups.map { ($0.0, buckets[$0.0] ?? []) }
    }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.history.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 60)).foregroundColor(.secondary)
                        Text("No History Yet")
                            .font(.title2).fontWeight(.semibold)
                        Text("Delivered and cancelled loads appear here for 30 days.")
                            .font(.body).foregroundColor(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    List {
                        // ── Stats banner ──────────────────────────────────────
                        Section {
                            HStack(spacing: 0) {
                                HistoryStat(
                                    value: "\(viewModel.history.filter { $0.status == .delivered }.count)",
                                    label: "Delivered",
                                    icon: "checkmark.seal.fill",
                                    color: .green
                                )
                                Divider()
                                HistoryStat(
                                    value: "\(viewModel.history.filter { $0.status == .cancelled }.count)",
                                    label: "Cancelled",
                                    icon: "xmark.circle.fill",
                                    color: .red
                                )
                                Divider()
                                HistoryStat(
                                    value: "\(viewModel.history.count)",
                                    label: "Total (30d)",
                                    icon: "calendar",
                                    color: .accentColor
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }

                        // ── Grouped load rows ─────────────────────────────────
                        ForEach(grouped, id: \.0) { (week, loads) in
                            Section(header: Text(week).font(.subheadline).fontWeight(.semibold)) {
                                ForEach(loads) { load in
                                    NavigationLink(destination: LoadDetailView(load: load, viewModel: viewModel)) {
                                        HistoryRowView(load: load)
                                    }
                                }
                                .onDelete { offsets in
                                    offsets.forEach { viewModel.deleteHistoryEntry(loads[$0]) }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await viewModel.refreshLoads() }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search history…")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("Last 30 days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - History Stat Cell

struct HistoryStat: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.title2).fontWeight(.bold)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - History Row View

struct HistoryRowView: View {
    let load: Load

    private var completedDate: String {
        let d = load.completedAt ?? load.deliveryDate
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(load.loadNumber).font(.headline)
                Spacer()
                StatusBadge(status: load.status)
            }
            Text(load.description)
                .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            HStack(spacing: 14) {
                Label(load.customerName, systemImage: "building.2")
                    .font(.caption).foregroundColor(.secondary)
                if let driver = load.assignedDriverName {
                    Label(driver, systemImage: "person.fill")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Label(completedDate, systemImage: "calendar")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Image(systemName: "arrow.up.circle").foregroundColor(.accentColor).font(.caption)
                Text(load.pickupAddress).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.green).font(.caption)
                Text(load.deliveryAddress).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Load Row View

struct LoadRowView: View {
    let load: Load

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(load.loadNumber)
                    .font(.headline)
                Spacer()
                StatusBadge(status: load.status)
            }
            Text(load.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 16) {
                Label(load.customerName, systemImage: "building.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let driverName = load.assignedDriverName {
                    Label(driverName, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if load.status == .inTransit, let location = load.lastLocation {
                    Label("\(Int(location.speed)) mph", systemImage: "speedometer")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            HStack {
                Image(systemName: "arrow.up.circle")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text(load.pickupAddress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text(load.deliveryAddress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text("\(count)")
                .font(.title)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 90, height: 90)
        .background(color.opacity(0.1))
        .cornerRadius(14)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

@MainActor
class DispatcherViewModel: ObservableObject {
    @Published var loads: [Load] = []
    @Published var history: [Load] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let network  = NetworkManager.shared
    private let store    = LoadStore.shared
    private let firebase = FirebaseManager.shared

    /// UserDefaults key — once set, we never auto-seed again (survives reinstall via iCloud KV seeding).
    private let seededKey = "cmp.dispatcher.didSeedOnce"

    init() {
        // Load persisted data immediately so the UI is populated on launch
        let persisted = store.load()
        if persisted.isEmpty {
            // Only seed sample data if this is a genuine first-ever install.
            // A re-install that hasn't synced from iCloud yet should NOT be seeded —
            // the real loads will arrive when iCloud KV syncs (handled by the observer below).
            let didSeedBefore = UserDefaults.standard.bool(forKey: seededKey) ||
                                (NSUbiquitousKeyValueStore.default.bool(forKey: seededKey))
            if !didSeedBefore {
                loads = Load.sampleLoads
                store.save(loads)
                UserDefaults.standard.set(true, forKey: seededKey)
                NSUbiquitousKeyValueStore.default.set(true, forKey: seededKey)
                NSUbiquitousKeyValueStore.default.synchronize()
            }
            // else: leave loads empty — iCloud will push real data shortly
        } else {
            loads = persisted
        }
        history = store.loadHistory()

        // Reload whenever another device pushes a change via iCloud KV
        NotificationCenter.default.addObserver(
            forName: .cmpLoadsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.loads   = self.store.load()
            self.history = self.store.loadHistory()
        }
    }

    func refreshLoads() async {
        isLoading = true

        // Trigger iCloud to push any pending remote changes before we read
        NSUbiquitousKeyValueStore.default.synchronize()

        // Try Firebase first (if project ID is configured)
        if firebase.isConfigured {
            await withCheckedContinuation { continuation in
                firebase.fetchLoads { [weak self] remoteLoads, error in
                    if let remoteLoads = remoteLoads, !remoteLoads.isEmpty {
                        self?.loads = remoteLoads
                        self?.store.save(remoteLoads)
                    } else if let error = error {
                        self?.errorMessage = "Sync error: \(error.localizedDescription)"
                    }
                    continuation.resume()
                }
            }
        } else {
            // Reload from local store (iCloud KV + UserDefaults fallback)
            let persisted = store.load()
            loads = persisted
        }
        history = store.loadHistory()
        isLoading = false
    }

    func updateLoadStatus(load: Load, newStatus: LoadStatus) {
        if let index = loads.firstIndex(where: { $0.id == load.id }) {
            loads[index].status = newStatus
            // Stamp completedAt when finishing a load
            if newStatus == .delivered || newStatus == .cancelled {
                loads[index].completedAt = Date()
                store.saveToHistory(loads[index])
                history = store.loadHistory()
            }
            store.save(loads)
            firebase.updateLoadStatus(id: load.id, status: newStatus)
            network.updateLoadStatus(loadId: load.id, status: newStatus)
        }
    }

    func addLoad(_ load: Load) {
        loads.append(load)
        store.save(loads)
        firebase.saveLoad(load) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Cloud sync error: \(error.localizedDescription)"
            }
        }
    }

    func deleteLoad(_ load: Load) {
        // If the load was completed, keep it in history instead of erasing it
        if load.status == .delivered || load.status == .cancelled {
            var archived = load
            archived.completedAt = archived.completedAt ?? Date()
            store.saveToHistory(archived)
            history = store.loadHistory()
        }
        loads.removeAll { $0.id == load.id }
        store.delete(id: load.id)
        firebase.deleteLoad(id: load.id)
    }

    func deleteHistoryEntry(_ load: Load) {
        store.removeFromHistory(id: load.id)
        history = store.loadHistory()
    }
}

// MARK: - Load Detail View

struct LoadDetailView: View {
    @State var load: Load
    @ObservedObject var viewModel: DispatcherViewModel
    @EnvironmentObject var appState: AppState
    @State private var showStatusPicker = false
    @State private var showMap = false
    @State private var showSentBanner = false
    @State private var sentBannerMessage = ""
    @State private var notifyCustomerByEmail = true
    @State private var isSendingLink = false
    @State private var pickupPin: CLLocationCoordinate2D? = nil
    @State private var deliveryPin: CLLocationCoordinate2D? = nil

    var body: some View {
        List {
            // ── Status ──────────────────────────────────────────────────────
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    StatusBadge(status: load.status)
                }
                .contentShape(Rectangle())
                .onTapGesture { showStatusPicker = true }
            } header: {
                Text("Load Info")
            }

            // ── Load Details ─────────────────────────────────────────────────
            Section {
                LabeledContent("Load #", value: load.loadNumber)
                LabeledContent("Description", value: load.description)
                LabeledContent("Weight", value: "\(Int(load.weight)) lbs")
                LabeledContent("Pickup", value: load.pickupAddress)
                LabeledContent("Delivery", value: load.deliveryAddress)
                LabeledContent("Pickup Date", value: load.pickupDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Est. Delivery", value: load.deliveryDate.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Details")
            }

            // ── Map ──────────────────────────────────────────────────────────
            Section {
                Group {
                    if let location = load.lastLocation {
                        // Live location — show driver position
                        let region = MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                        )
                        RoadSnappingMapView(
                            annotations: [TrackAnnotation(location: location)],
                            rawTrail: [],
                            destinationCoordinate: deliveryPin,
                            region: .constant(region)
                        )
                        .frame(height: 220)
                        .cornerRadius(10)
                        .overlay(alignment: .topTrailing) {
                            Button { showMap = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .padding(8)
                            }
                        }
                    } else {
                        // No live location — show pickup/delivery route
                        RouteMapView(pickupCoord: pickupPin, deliveryCoord: deliveryPin)
                            .frame(height: 220)
                            .cornerRadius(10)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                Text(load.lastLocation != nil ? "Live Location" : "Route")
            }

            // ── Driver ───────────────────────────────────────────────────────
            Section {
                if let driverName = load.assignedDriverName {
                    LabeledContent("Driver", value: driverName)
                    if let driverId = load.assignedDriverId {
                        LabeledContent("Driver ID", value: driverId)
                    }
                } else {
                    Text("No driver assigned")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Driver")
            }

            // ── Customer ─────────────────────────────────────────────────────
            Section {
                LabeledContent("Customer", value: load.customerName)
                LabeledContent("Email", value: load.customerEmail)
                if !load.customerPhone.isEmpty {
                    HStack {
                        Text("Phone")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(load.customerPhone) {
                            if let url = URL(string: "tel://\(load.customerPhone.filter { $0.isNumber })") {
                                UIApplication.shared.open(url)
                            }
                        }
                        .foregroundColor(.accentColor)
                    }
                }
            } header: {
                Text("Customer")
            }

            // ── Last Known Location ──────────────────────────────────────────
            if let location = load.lastLocation {
                Section {
                    LabeledContent("Latitude", value: String(format: "%.5f", location.latitude))
                    LabeledContent("Longitude", value: String(format: "%.5f", location.longitude))
                    LabeledContent("Speed", value: "\(Int(location.speed)) mph")
                    LabeledContent("Updated", value: location.timestamp.formatted(date: .omitted, time: .shortened))
                    Button(action: { showMap = true }) {
                        Label("View Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                } header: {
                    Text("Last Known Location")
                }
            }

            // ── Notes ────────────────────────────────────────────────────────
            if !load.notes.isEmpty {
                Section {
                    Text(load.notes)
                } header: {
                    Text("Notes")
                }
            }

            // ── Send Tracking Link ────────────────────────────────────────────
            Section {
                // Notify customer toggle
                Toggle(isOn: $notifyCustomerByEmail) {
                    Label("Email customer when driver starts", systemImage: "envelope.badge")
                }
                .tint(.accentColor)

                // Info row
                if !load.customerEmail.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: notifyCustomerByEmail ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(notifyCustomerByEmail ? .green : .secondary)
                            .font(.caption)
                        Text(notifyCustomerByEmail
                             ? "Live tracking link will be emailed to \(load.customerEmail)"
                             : "Customer will NOT receive a tracking email")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Send SMS to driver button
                Button(action: sendLinkToDriver) {
                    HStack {
                        if isSendingLink {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "message.fill")
                        }
                        Text(isSendingLink ? "Sending…" : "Send Tracking Link to Driver")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(isSendingLink || load.assignedDriverId == nil)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                // Show the web tracking URL
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(load.webTrackingURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = load.webTrackingURL
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            } header: {
                Text("Driver Tracking Link")
            } footer: {
                Text("The driver receives an SMS with a link that opens in their browser — no app required. When they tap Start Tracking, the dispatcher is notified by email.")
            }
        }
        .navigationTitle(load.loadNumber)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { geocodeAddresses() }
        .sheet(isPresented: $showStatusPicker) {
            StatusPickerSheet(currentStatus: load.status) { newStatus in
                viewModel.updateLoadStatus(load: load, newStatus: newStatus)
                load.status = newStatus
            }
        }
        .sheet(isPresented: $showMap) {
            if let location = load.lastLocation {
                TrackingMapView(loadId: load.id, initialLocation: location, loadNumber: load.loadNumber)
            }
        }
        .overlay(alignment: .top) {
            if showSentBanner {
                NotificationBanner(message: sentBannerMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showSentBanner)
            }
        }
    }

    // MARK: – Geocoding for route map
    private func geocodeAddresses() {
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

    // MARK: – Send SMS tracking link to driver via backend
    private func sendLinkToDriver() {
        guard let dispatcherEmail = appState.currentUser?.email, !dispatcherEmail.isEmpty else {
            showBanner("⚠️ Dispatcher email not set — sign in first.")
            return
        }

        let driverPhone = load.assignedDriverPhone ?? ""

        // Try backend first
        if AWSManager.shared.isConfigured {
            isSendingLink = true
            AWSManager.shared.sendDriverTrackingLink(
                loadId: load.id,
                driverPhone: driverPhone,
                dispatcherEmail: dispatcherEmail,
                notifyCustomer: notifyCustomerByEmail
            ) { [self] result in
                isSendingLink = false
                switch result {
                case .success:
                    showBanner("✅ Tracking link sent to driver via SMS")
                case .failure(let err):
                    // Fallback: open iOS Messages app with the web link
                    openSMSFallback(driverPhone: driverPhone)
                    print("sendDriverLink backend error (using SMS fallback):", err.localizedDescription)
                }
            }
        } else {
            // No backend — open Messages app directly
            openSMSFallback(driverPhone: driverPhone)
        }
    }

    private func openSMSFallback(driverPhone: String) {
        let link = load.webTrackingURL
        let msg = "Routelo – Load \(load.loadNumber)\nPickup: \(load.pickupAddress)\nDelivery: \(load.deliveryAddress)\n\nTap here to start tracking:\n\(link)"
        let encoded = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let smsTarget = driverPhone.filter { $0.isNumber || $0 == "+" }
        let urlStr = smsTarget.isEmpty ? "sms:?body=\(encoded)" : "sms:\(smsTarget)?body=\(encoded)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
        showBanner("📱 Messages app opened — send to driver")
    }

    private func showBanner(_ msg: String) {
        sentBannerMessage = msg
        showSentBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            showSentBanner = false
        }
    }
}

// MARK: - Status Picker Sheet

struct StatusPickerSheet: View {
    let currentStatus: LoadStatus
    let onSelect: (LoadStatus) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(LoadStatus.allCases, id: \.self) { status in
                    Button(action: {
                        onSelect(status)
                        dismiss()
                    }) {
                        HStack {
                            StatusBadge(status: status)
                            Spacer()
                            if status == currentStatus {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Update Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Add Load View

struct AddLoadView: View {
    @ObservedObject var viewModel: DispatcherViewModel
    @Environment(\.dismiss) var dismiss

    @State private var loadNumber = ""
    @State private var description = ""
    @State private var weight = ""
    @State private var pickupAddress = ""
    @State private var deliveryAddress = ""
    @State private var driverName = ""
    @State private var driverEmail = ""          // ← driver's account email — used for load matching in app
    @State private var driverPhone = ""          // ← driver's cell — receives the SMS tracking link
    @State private var customerName = ""
    @State private var customerEmail = ""
    @State private var customerPhone = ""
    @State private var notifyCustomerByEmail = true  // ← dispatcher toggle
    @State private var notes = ""
    @State private var pickupDate = Date()
    @State private var deliveryDate = Date().addingTimeInterval(86400)

    var body: some View {
        NavigationView {
            Form {
                Section("Load Info") {
                    TextField("Load Number", text: $loadNumber)
                    TextField("Description", text: $description)
                    TextField("Weight (lbs)", text: $weight)
                        .keyboardType(.decimalPad)
                }
                Section("Addresses") {
                    TextField("Pickup Address", text: $pickupAddress)
                    TextField("Delivery Address", text: $deliveryAddress)
                    DatePicker("Pickup Date", selection: $pickupDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Est. Delivery", selection: $deliveryDate, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    TextField("Driver Name", text: $driverName)
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        TextField("Driver Email (for app login)", text: $driverEmail)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        TextField("Driver Cell (receives tracking link via SMS)", text: $driverPhone)
                            .keyboardType(.phonePad)
                    }
                } header: {
                    Text("Driver")
                } footer: {
                    Text("Enter the driver's email so the load appears in their app, and their phone to send an SMS tracking link.")
                        .font(.caption)
                }
                Section {
                    TextField("Customer Name", text: $customerName)
                    TextField("Customer Email", text: $customerEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    HStack {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        TextField("Customer Phone", text: $customerPhone)
                            .keyboardType(.phonePad)
                    }
                    Toggle(isOn: $notifyCustomerByEmail) {
                        Label("Email customer when driver starts", systemImage: "envelope.badge")
                    }
                } header: {
                    Text("Customer")
                } footer: {
                    notifyCustomerByEmail
                        ? Text("Customer will receive a live tracking link by email once the driver taps Start Tracking.")
                        : Text("Customer will NOT be emailed a tracking link.")
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(height: 80)
                }
            }
            .navigationTitle("New Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveLoad() }
                        .fontWeight(.semibold)
                        .disabled(loadNumber.isEmpty || pickupAddress.isEmpty || deliveryAddress.isEmpty)
                }
            }
        }
    }

    private func saveLoad() {
        let normalizedPhone = driverPhone.filter { $0.isNumber }
        let newLoad = Load(
            id: UUID().uuidString,
            loadNumber: loadNumber.isEmpty ? "CMP-\(Int.random(in: 1000...9999))" : loadNumber,
            description: description,
            weight: Double(weight) ?? 0,
            pickupAddress: pickupAddress,
            deliveryAddress: deliveryAddress,
            pickupDate: pickupDate,
            deliveryDate: deliveryDate,
            status: .pending,
            assignedDriverId: normalizedPhone.isEmpty ? nil : normalizedPhone,
            assignedDriverName: driverName.isEmpty ? nil : driverName,
            assignedDriverEmail: driverEmail.trimmingCharacters(in: .whitespaces).lowercased().isEmpty ? nil : driverEmail.trimmingCharacters(in: .whitespaces).lowercased(),
            assignedDriverPhone: driverPhone.isEmpty ? nil : driverPhone,
            trackingToken: UUID().uuidString,
            customerName: customerName,
            customerEmail: customerEmail,
            customerPhone: customerPhone,
            dispatcherEmail: nil,
            notifyCustomer: notifyCustomerByEmail,
            lastLocation: nil,
            notes: notes
        )
        viewModel.addLoad(newLoad)
        dismiss()
    }
}

#Preview {
    DispatcherView()
        .environmentObject(AppState.shared)
}
