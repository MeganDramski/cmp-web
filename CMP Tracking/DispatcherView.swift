//
//  DispatcherView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//

import SwiftUI

// MARK: - Dispatcher / Admin Dashboard

struct DispatcherView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var viewModel = DispatcherViewModel()

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

                // ── Summary Bar ──────────────────────────────────────────────
                summaryBar

                // ── Filter Chips ─────────────────────────────────────────────
                statusFilterChips

                // ── Load List ────────────────────────────────────────────────
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
                    .refreshable {
                        await viewModel.refreshLoads()
                    }
                }
            }
            .navigationTitle("Dispatch Board")
            .searchable(text: $searchText, prompt: "Search loads, customers, drivers…")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { authManager.signOut(); appState.logout() }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
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
            .task {
                await viewModel.refreshLoads()
            }
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                SummaryCard(
                    title: "Active",
                    count: viewModel.loads.filter { $0.status == .inTransit }.count,
                    icon: "truck.box.fill",
                    color: .orange
                )
                SummaryCard(
                    title: "Assigned",
                    count: viewModel.loads.filter { $0.status == .assigned }.count,
                    icon: "person.fill",
                    color: .blue
                )
                SummaryCard(
                    title: "Pending",
                    count: viewModel.loads.filter { $0.status == .pending }.count,
                    icon: "clock",
                    color: .gray
                )
                SummaryCard(
                    title: "Delivered",
                    count: viewModel.loads.filter { $0.status == .delivered }.count,
                    icon: "checkmark.seal.fill",
                    color: .green
                )
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Filter Chips

    private var statusFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: selectedStatus == nil) {
                    selectedStatus = nil
                }
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
                .font(.title2)
                .fontWeight(.semibold)
            Text("Tap + to create a new load or adjust your filters.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
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

// MARK: - ViewModel

@MainActor
class DispatcherViewModel: ObservableObject {
    @Published var loads: [Load] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let network  = NetworkManager.shared
    private let store    = LoadStore.shared
    private let firebase = FirebaseManager.shared

    init() {
        // Load persisted data immediately so the UI is populated on launch
        let persisted = store.load()
        if persisted.isEmpty {
            // First launch: seed with sample data and persist it
            loads = Load.sampleLoads
            store.save(loads)
        } else {
            loads = persisted
        }

        // Reload whenever another device pushes a change via iCloud KV
        NotificationCenter.default.addObserver(
            forName: .cmpLoadsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let updated = self.store.load()
            if !updated.isEmpty { self.loads = updated }
        }
    }

    func refreshLoads() async {
        isLoading = true

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
            // Fallback: reload from local store
            let persisted = store.load()
            if !persisted.isEmpty {
                loads = persisted
            }
        }

        isLoading = false
    }

    func updateLoadStatus(load: Load, newStatus: LoadStatus) {
        if let index = loads.firstIndex(where: { $0.id == load.id }) {
            loads[index].status = newStatus
            store.save(loads)
            firebase.updateLoadStatus(id: load.id, status: newStatus)
            network.updateLoadStatus(loadId: load.id, status: newStatus)
        }
    }

    func addLoad(_ load: Load) {
        loads.append(load)
        // 1. Persist locally (instant, offline-safe)
        store.save(loads)
        // 2. Sync to Firebase cloud database
        firebase.saveLoad(load) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Cloud sync error: \(error.localizedDescription)"
            }
        }
    }

    func deleteLoad(_ load: Load) {
        loads.removeAll { $0.id == load.id }
        store.save(loads)
        firebase.deleteLoad(id: load.id)
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
                        Label("View on Map", systemImage: "map.fill")
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
        let msg = "CMP Logistics – Load \(load.loadNumber)\nPickup: \(load.pickupAddress)\nDelivery: \(load.deliveryAddress)\n\nTap here to start tracking:\n\(link)"
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
                        Image(systemName: "phone.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        TextField("Driver Cell (receives tracking link via SMS)", text: $driverPhone)
                            .keyboardType(.phonePad)
                    }
                } header: {
                    Text("Driver")
                } footer: {
                    Text("A text message with a browser-based tracking link will be sent to this number. No app required.")
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
            assignedDriverId: driverName.isEmpty ? nil : "D\(Int.random(in: 100...999))",
            assignedDriverName: driverName.isEmpty ? nil : driverName,
            assignedDriverEmail: nil,
            assignedDriverPhone: driverPhone.isEmpty ? nil : driverPhone,
            trackingToken: UUID().uuidString,
            customerName: customerName,
            customerEmail: customerEmail,
            customerPhone: customerPhone,
            dispatcherEmail: nil,  // set by dispatcher's signed-in email at send time
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
