//
//  TrackingMapView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//
//  This view is used:
//  • Inside the app (dispatcher taps "View on Map")
//  • As a standalone screen if the customer opens the deep link (tracked via Universal Links / URL schemes)
//

import SwiftUI
import MapKit

// MARK: - Road-Snapping MKMapView Wrapper

/// UIViewRepresentable wrapping MKMapView with OSRM /match road-snapping.
/// Mirrors the same approach used in the web pages (driver-tracking.html /
/// track-shipment.html) so both platforms behave identically.
///
/// Strategy:
///   1. Raw GPS trail is drawn immediately as an MKPolyline (no visual gap).
///   2. A 2-second debounced URLSession call to the free OSRM /match API
///      returns road-snapped GeoJSON geometry.
///   3. The raw overlay is replaced with the snapped one.
///   4. If OSRM fails (no network, timeout, no match) the raw line stays.
struct RoadSnappingMapView: UIViewRepresentable {
    let annotations: [TrackAnnotation]
    let rawTrail: [CLLocationCoordinate2D]
    @Binding var region: MKCoordinateRegion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = false
        mv.isZoomEnabled = true
        mv.isScrollEnabled = true
        mv.isPitchEnabled = false
        mv.setRegion(region, animated: false)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // ── Sync region only when SwiftUI explicitly moves it ────────────
        let c = mv.region.center
        let d = region.center
        if abs(c.latitude - d.latitude) > 0.0001 || abs(c.longitude - d.longitude) > 0.0001 {
            mv.setRegion(region, animated: true)
        }

        // ── Sync truck annotation ────────────────────────────────────────
        mv.removeAnnotations(mv.annotations)
        for ann in annotations {
            mv.addAnnotation(TrackPin(annotation: ann))
        }

        // ── Update raw trail overlay immediately ─────────────────────────
        guard rawTrail.count >= 2 else { return }

        // Replace raw overlay with latest points so there's never a gap
        if let existing = coordinator.rawOverlay { mv.removeOverlay(existing) }
        var coords = rawTrail
        let rawPolyline = MKPolyline(coordinates: &coords, count: coords.count)
        coordinator.rawOverlay = rawPolyline
        mv.addOverlay(rawPolyline, level: .aboveRoads)

        // ── Schedule debounced OSRM snap (3 s after last GPS update) ─────
        coordinator.debounceTimer?.invalidate()
        coordinator.debounceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            coordinator.snapToRoads(rawTrail, mapView: mv)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        var rawOverlay: MKPolyline?        // straight GPS trail (shown while snap is pending)
        var snappedOverlay: MKPolyline?    // road-snapped result from OSRM
        var debounceTimer: Timer?
        var currentTask: URLSessionDataTask?

        // MARK: OSRM map-match snap
        // Uses /match/v1 (GPS trace → road) instead of /route/v1 (A→B routing).
        // /match is specifically designed to snap a recorded GPS track onto roads.
        func snapToRoads(_ trail: [CLLocationCoordinate2D], mapView mv: MKMapView) {
            guard trail.count >= 2 else { return }

            // Sample down to ≤100 waypoints — more points = better accuracy on curves
            // but OSRM match caps at 100 per request.
            var pts = trail
            if pts.count > 100 {
                let step = Double(pts.count - 1) / 99.0
                var sampled: [CLLocationCoordinate2D] = []
                for i in 0..<99 { sampled.append(pts[Int((Double(i) * step).rounded())]) }
                sampled.append(pts[pts.count - 1])
                pts = sampled
            }

            let coordStr   = pts.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
            // radiuses: tell OSRM how far (meters) each GPS point may be from the road.
            // 25m is a good default for automotive GPS accuracy.
            let radiusStr  = Array(repeating: "25", count: pts.count).joined(separator: ";")
            // Synthetic timestamps spaced 5s apart so OSRM can infer speed per segment
            let timestamps = (0..<pts.count).map { "\($0 * 5)" }.joined(separator: ";")

            let urlStr = "https://router.project-osrm.org/match/v1/driving/\(coordStr)"
                       + "?overview=full&geometries=geojson&steps=false"
                       + "&radiuses=\(radiusStr)"
                       + "&timestamps=\(timestamps)"
                       + "&tidy=true"   // remove impossible jumps / GPS noise
            guard let url = URL(string: urlStr) else { return }

            currentTask?.cancel()
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            currentTask = URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["code"] as? String) == "Ok",
                      let matchings = json["matchings"] as? [[String: Any]]
                else {
                    // OSRM match failed — raw trail remains visible
                    return
                }

                // Collect all road-snapped coordinates from every matching segment
                var roadCoords: [CLLocationCoordinate2D] = []
                for match in matchings {
                    guard let geometry  = match["geometry"] as? [String: Any],
                          let coordsArr = geometry["coordinates"] as? [[Double]]
                    else { continue }
                    for c in coordsArr {
                        guard c.count >= 2 else { continue }
                        roadCoords.append(CLLocationCoordinate2D(latitude: c[1], longitude: c[0]))
                    }
                }
                guard roadCoords.count >= 2 else { return }

                DispatchQueue.main.async {
                    if let raw = self.rawOverlay    { mv.removeOverlay(raw) }
                    if let old = self.snappedOverlay { mv.removeOverlay(old) }
                    var snapped = roadCoords
                    let snappedPolyline = MKPolyline(coordinates: &snapped, count: snapped.count)
                    self.snappedOverlay = snappedPolyline
                    self.rawOverlay = nil
                    mv.addOverlay(snappedPolyline, level: .aboveRoads)
                }
            }
            currentTask?.resume()
        }

        // MARK: MKMapViewDelegate
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: polyline)
            r.strokeColor = UIColor.systemBlue
            r.lineWidth   = 5
            r.lineJoin    = .round
            r.lineCap     = .round
            r.alpha       = 0.85
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? TrackPin else { return nil }
            let view = MKAnnotationView(annotation: pin, reuseIdentifier: "truck")
            let host = UIHostingController(rootView:
                TruckAnnotationView(speed: pin.trackAnnotation.speed,
                                    heading: pin.trackAnnotation.heading))
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
            view.addSubview(host.view)
            view.frame = host.view.frame
            view.centerOffset = CGPoint(x: 0, y: -24)
            return view
        }
    }
}

/// MKAnnotation wrapper for TrackAnnotation
class TrackPin: NSObject, MKAnnotation {
    let trackAnnotation: TrackAnnotation
    var coordinate: CLLocationCoordinate2D { trackAnnotation.coordinate }
    init(annotation: TrackAnnotation) { self.trackAnnotation = annotation }
}

// MARK: - Tracking Map View

struct TrackingMapView: View {
    let loadId: String
    let initialLocation: LocationUpdate
    let loadNumber: String

    @StateObject private var network = NetworkManager.shared
    @State private var mapRegion: MKCoordinateRegion
    @State private var annotations: [TrackAnnotation] = []
    @State private var rawTrail: [CLLocationCoordinate2D] = []   // raw GPS points fed to RoadSnappingMapView
    @State private var pollingTimer: Timer?
    @State private var lastUpdate: LocationUpdate?
    @Environment(\.dismiss) var dismiss

    init(loadId: String, initialLocation: LocationUpdate, loadNumber: String) {
        self.loadId = loadId
        self.initialLocation = initialLocation
        self.loadNumber = loadNumber
        _mapRegion = State(initialValue: MKCoordinateRegion(
            center: initialLocation.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
        _annotations = State(initialValue: [TrackAnnotation(location: initialLocation)])
        _lastUpdate = State(initialValue: initialLocation)
        _rawTrail = State(initialValue: [initialLocation.coordinate])
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {

                // ── Map — road-following polyline via MKDirections ─────────
                RoadSnappingMapView(
                    annotations: annotations,
                    rawTrail: rawTrail,
                    region: $mapRegion
                )
                .ignoresSafeArea(edges: .top)

                // ── Info Panel ───────────────────────────────────────────────
                infoPanel
            }
            .navigationTitle("Load \(loadNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(network.wsConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(network.wsConnected ? "Live" : "Polling")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                startLiveTracking()
            }
            .onDisappear {
                stopTracking()
            }
            .onReceive(network.$liveLocation) { update in
                guard let update = update, update.loadId == loadId else { return }
                handleLocationUpdate(update)
            }
        }
    }

    // MARK: - Info Panel

    private var infoPanel: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            VStack(spacing: 14) {
                // Status Row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load \(loadNumber)")
                            .font(.headline)
                        if let update = lastUpdate {
                            Text("Updated \(update.timestamp, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if let update = lastUpdate {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label("\(Int(update.speed)) mph", systemImage: "speedometer")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Label(headingText(update.heading), systemImage: "location.north.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(update.heading))
                        }
                    }
                }

                // Coordinates
                if let update = lastUpdate {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LATITUDE")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("\(update.latitude, specifier: "%.5f")")
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LONGITUDE")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("\(update.longitude, specifier: "%.5f")")
                                .font(.system(.body, design: .monospaced))
                        }
                        Spacer()
                        Button(action: recenterMap) {
                            Image(systemName: "location.fill")
                                .padding(10)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Circle())
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(.regularMaterial)
        .cornerRadius(20, corners: [.topLeft, .topRight])
    }

    // MARK: - Live Tracking

    private func startLiveTracking() {
        // Try WebSocket first
        network.connectWebSocket(forLoadId: loadId)
        // Also start polling as fallback (every 10s)
        startPolling()
    }

    private func stopTracking() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        network.disconnectWebSocket()
    }

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            // Only poll if WebSocket is NOT connected
            if !network.wsConnected {
                network.fetchLatestLocation(loadId: loadId) { update, _ in
                    if let update = update {
                        handleLocationUpdate(update)
                    }
                }
            }
        }
    }

    private func handleLocationUpdate(_ update: LocationUpdate) {
        lastUpdate = update
        let coord = update.coordinate
        annotations = [TrackAnnotation(location: update)]
        rawTrail.append(coord)

        // Only move the map center if the truck has drifted outside
        // the currently visible region — this way manual zoom/pan is preserved.
        let visibleLatDelta = mapRegion.span.latitudeDelta
        let visibleLngDelta = mapRegion.span.longitudeDelta
        let center = mapRegion.center
        let latDiff = abs(coord.latitude  - center.latitude)
        let lngDiff = abs(coord.longitude - center.longitude)
        if latDiff > visibleLatDelta * 0.4 || lngDiff > visibleLngDelta * 0.4 {
            withAnimation {
                mapRegion.center = coord
            }
        }
    }

    private func recenterMap() {
        guard let update = lastUpdate else { return }
        withAnimation {
            mapRegion.center = update.coordinate
        }
    }

    private func headingText(_ heading: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
        let index = Int((heading + 22.5) / 45) % 8
        return directions[index]
    }
}

// MARK: - Track Annotation Model

struct TrackAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let speed: Double
    let heading: Double

    init(location: LocationUpdate) {
        self.coordinate = location.coordinate
        self.speed = location.speed
        self.heading = location.heading
    }
}

// MARK: - Truck Annotation View

struct TruckAnnotationView: View {
    let speed: Double
    let heading: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 48, height: 48)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 32, height: 32)
            Image(systemName: "truck.box.fill")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .rotationEffect(.degrees(heading))
        }
    }
}

// MARK: - Corner Radius Helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Customer Tracking Screen
//
// HOW THE CUSTOMER GETS HERE — two paths:
//
//  1. Deep Link (phone):  cmptrack://track/abc123token
//     → iOS opens the app → CMP_TrackingApp.handleDeepLink parses the token
//     → presents CustomerTrackingView(trackingToken: "abc123token")
//
//  2. Browser link:       https://tracking.cmpfreight.com/track/abc123token
//     → Your web server calls GET /api/track/abc123token
//     → Returns ONLY the data for THAT load (token is the key — no load ID exposed)
//     → This app mirrors that same API call inside CustomerTrackingView.loadShipment()
//
// SECURITY: The customer never sees a load ID, driver ID, or any other load.
// The trackingToken is a UUID — impossible to guess another customer's token.

struct CustomerTrackingView: View {
    /// The opaque token from the URL — e.g. "abc123token"
    let trackingToken: String

    @StateObject private var network = NetworkManager.shared
    @State private var load: Load?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var liveLocation: LocationUpdate?
    @State private var rawTrail: [CLLocationCoordinate2D] = []
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @State private var annotations: [TrackAnnotation] = []

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(message: error)
                } else if let load = load {
                    customerTrackingContent(load: load)
                }
            }
            .navigationTitle("Track My Shipment")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: loadShipment)
        // Receive live WebSocket pushes
        .onReceive(network.$liveLocation) { update in
            guard let update = update, update.loadId == load?.id else { return }
            liveLocation = update
            let coord = update.coordinate
            annotations = [TrackAnnotation(location: update)]
            rawTrail.append(coord)
            withAnimation { mapRegion.center = coord }
        }
    }

    // MARK: - Main Content (only shown after token resolves to a real load)

    @ViewBuilder
    private func customerTrackingContent(load: Load) -> some View {
        ScrollView {
            VStack(spacing: 0) {


                // ── Live Map ─────────────────────────────────────────────────
                ZStack(alignment: .topLeading) {
                    RoadSnappingMapView(
                        annotations: annotations,
                        rawTrail: rawTrail,
                        region: $mapRegion
                    )
                    .frame(height: 280)

                    // Live badge
                    if network.wsConnected {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("LIVE").font(.caption).fontWeight(.bold).foregroundColor(.green)
                        }
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .padding(12)
                    }

                    // No location yet overlay
                    if liveLocation == nil && load.lastLocation == nil {
                        ZStack {
                            Color.black.opacity(0.35)
                            VStack(spacing: 6) {
                                Image(systemName: "location.slash.fill")
                                    .font(.largeTitle).foregroundColor(.white)
                                Text("Awaiting driver location…")
                                    .font(.caption).foregroundColor(.white)
                            }
                        }
                    }
                }

                VStack(spacing: 16) {

                    // ── Carrier Header ────────────────────────────────────────
                    HStack {
                        Image(systemName: "truck.box.fill")
                            .font(.title2).foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CMP Freight")
                                .font(.headline)
                            Text("Load \(load.loadNumber)")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        StatusBadge(status: load.status)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)

                    // ── Current Speed / Last Update ───────────────────────────
                    if let loc = liveLocation ?? load.lastLocation {
                        HStack(spacing: 0) {
                            Divider()
                            speedStatCell(
                                value: "\(Int(loc.speed))",
                                unit: "mph",
                                icon: "speedometer"
                            )
                            Divider()
                            speedStatCell(
                                value: headingLabel(loc.heading),
                                unit: "heading",
                                icon: "location.north.fill"
                            )
                            Divider()
                            speedStatCell(
                                value: loc.timestamp.formatted(date: .omitted, time: .shortened),
                                unit: "last update",
                                icon: "clock"
                            )
                            Divider()
                        }
                        .frame(height: 72)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                    }

                    // ── Status Timeline ───────────────────────────────────────
                    statusTimeline(current: load.status)

                    // ── Shipment Details (only what the customer needs) ───────
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shipment Details")
                            .font(.headline)
                        Divider()
                        InfoRow(icon: "shippingbox.fill",   label: "Load",       value: load.loadNumber)
                        InfoRow(icon: "doc.text",            label: "Contents",   value: load.description)
                        InfoRow(icon: "arrow.up.circle",     label: "Pickup",     value: load.pickupAddress)
                        InfoRow(icon: "arrow.down.circle.fill", label: "Delivery", value: load.deliveryAddress)
                        InfoRow(icon: "calendar",            label: "Est. Delivery",
                                value: load.deliveryDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)

                    // ── Contact Carrier ───────────────────────────────────────
                    Button(action: callCarrier) {
                        Label("Contact Carrier", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    Text("This tracking link is private and unique to your shipment.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal)
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Supporting Sub-Views

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Loading your shipment…")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52)).foregroundColor(.orange)
            Text("Tracking Unavailable")
                .font(.title2).fontWeight(.semibold)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Contact CMP Freight: 1-800-CMP-LOAD")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func speedStatCell(value: String, unit: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundColor(.accentColor)
            Text(value).font(.headline).fontWeight(.semibold)
            Text(unit).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Visual timeline showing Pending → Assigned → In Transit → Delivered
    private func statusTimeline(current: LoadStatus) -> some View {
        let steps: [(LoadStatus, String)] = [
            (.pending,   "Order Created"),
            (.assigned,  "Driver Assigned"),
            (.inTransit, "In Transit"),
            (.delivered, "Delivered")
        ]
        let order: [LoadStatus] = [.pending, .assigned, .inTransit, .delivered]
        let currentIndex = order.firstIndex(of: current) ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            Text("Delivery Status")
                .font(.headline)
                .padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(index <= currentIndex ? Color.accentColor : Color(.systemGray4))
                            .frame(width: 18, height: 18)
                            .overlay(
                                index <= currentIndex ?
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white) : nil
                            )
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(index < currentIndex ? Color.accentColor : Color(.systemGray5))
                                .frame(width: 2, height: 28)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.1)
                            .font(.subheadline)
                            .fontWeight(index == currentIndex ? .semibold : .regular)
                            .foregroundColor(index <= currentIndex ? .primary : .secondary)
                        if index == currentIndex {
                            Text("Current status")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Data Loading

    private func loadShipment() {
        isLoading = true
        // ─────────────────────────────────────────────────────────────────────
        // PRODUCTION: Replace this block with a real API call:
        //
        //   GET https://api.cmpfreight.com/api/track/{trackingToken}
        //
        // Your server looks up the load by trackingToken (NOT by loadId).
        // It returns ONLY the fields the customer is allowed to see.
        // The customer never knows any other load's token or ID.
        // ─────────────────────────────────────────────────────────────────────
        NetworkManager.shared.fetchLoadByToken(trackingToken) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resolvedLoad):
                    self.load = resolvedLoad
                    if let loc = resolvedLoad.lastLocation {
                        self.liveLocation = loc
                        self.annotations = [TrackAnnotation(location: loc)]
                        self.mapRegion = MKCoordinateRegion(
                            center: loc.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                        )
                        // Seed trail with current location; more points arrive via WebSocket
                        self.rawTrail = [loc.coordinate]
                    }
                    // Connect WebSocket to receive live pushes for THIS load only
                    NetworkManager.shared.connectWebSocket(forLoadId: resolvedLoad.id)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.isLoading = false
            }
        }
    }

    private func callCarrier() {
        if let url = URL(string: "tel://18002675623") {
            UIApplication.shared.open(url)
        }
    }

    private func headingLabel(_ heading: Double) -> String {
        let dirs = ["N","NE","E","SE","S","SW","W","NW"]
        return dirs[Int((heading + 22.5) / 45) % 8]
    }
}

#Preview {
    TrackingMapView(
        loadId: "L001",
        initialLocation: LocationUpdate.preview,
        loadNumber: "CMP-2026-0001"
    )
}
