// WalletCardStack.swift
// Each load card shows full details + an embedded map.
// Active card is expanded; others are compact collapsed rows.

import SwiftUI
import MapKit

private let CORNER: CGFloat = 18

// MARK: - WalletCardStack

struct WalletCardStack: View {
    @ObservedObject var wallet: LoadWallet
    var locationManager: LocationManager? = nil
    var onTrack:  (WalletEntry) -> Void
    var onAccept: (WalletEntry) -> Void

    var body: some View {
        let activeId = wallet.activeId ?? wallet.cards.first?.id
        VStack(spacing: 12) {
            ForEach(wallet.cards) { entry in
                LoadCard(
                    entry:           entry,
                    isActive:        entry.id == activeId,
                    locationManager: locationManager,
                    onTap:    { withAnimation(.easeInOut(duration: 0.2)) { wallet.activate(id: entry.id) } },
                    onTrack:  { onTrack(entry) },
                    onAccept: { onAccept(entry) },
                    onDismiss:{ wallet.remove(id: entry.id) }
                )
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - LoadCard

private struct LoadCard: View {
    let entry:           WalletEntry
    let isActive:        Bool
    var locationManager: LocationManager?
    let onTap:           () -> Void
    let onTrack:         () -> Void
    let onAccept:        () -> Void
    let onDismiss:       () -> Void

    @State private var pickupCoord:   CLLocationCoordinate2D? = nil
    @State private var deliveryCoord: CLLocationCoordinate2D? = nil
    @State private var geocoded = false

    // Live driver location (only when this card's load is being tracked)
    private var driverCoord: CLLocationCoordinate2D? {
        guard let lm = locationManager,
              lm.isTracking,
              entry.status == "In Transit"
        else { return nil }
        return lm.currentLocation?.coordinate
    }

    var body: some View {
        VStack(spacing: 0) {
            if isActive { expandedContent } else { collapsedContent }
        }
        .background(RoundedRectangle(cornerRadius: CORNER)
            .fill(Color(red: 0.11, green: 0.11, blue: 0.18)))
        .overlay(RoundedRectangle(cornerRadius: CORNER)
            .stroke(isActive ? Color.white.opacity(0.15) : Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CORNER))
        .shadow(color: .black.opacity(isActive ? 0.45 : 0.2),
                radius: isActive ? 18 : 5, x: 0, y: isActive ? 8 : 2)
        .onTapGesture { if !isActive { onTap() } }
        .onAppear     { if isActive  { geocode() } }
        .onChange(of: isActive) { _, active in if active { geocode() } }
    }

    // MARK: Collapsed row
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(statusColor(entry.status))
                .frame(width: 4, height: 40)
                .padding(.leading, 14)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.loadNumber)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    statusPill(entry.status)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 14)
                }
                if !entry.companyName.isEmpty {
                    Text(entry.companyName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.68, green: 0.47, blue: 1.0))
                        .lineLimit(1)
                }
                Text(shortRoute)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                    .lineLimit(1)
            }
            .padding(.vertical, 14)
        }
        .contentShape(Rectangle())
    }

    // MARK: Expanded card
    private var expandedContent: some View {
        VStack(spacing: 0) {

            // Header
            if !entry.companyName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.68, green: 0.47, blue: 1.0))
                    Text(entry.companyName.uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(1.0)
                        .foregroundColor(Color(red: 0.68, green: 0.47, blue: 1.0))
                    Spacer()
                    statusPill(entry.status)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                divider
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20)).foregroundColor(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.loadNumber)
                        .font(.system(size: 22, weight: .heavy)).foregroundColor(.white)
                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(.system(size: 14)).foregroundColor(Color(white: 0.6))
                    }
                }
                Spacer()
                if entry.companyName.isEmpty { statusPill(entry.status) }
            }
            .padding(.horizontal, 16)
            .padding(.top, entry.companyName.isEmpty ? 16 : 12)
            .padding(.bottom, 14)

            divider

            // Embedded Map
            ZStack(alignment: .bottomTrailing) {
                CardMapView(
                    pickupCoord:   pickupCoord,
                    deliveryCoord: deliveryCoord,
                    driverCoord:   driverCoord,
                    trail:         locationManager?.isTracking == true && entry.status == "In Transit"
                                   ? (locationManager?.routeTrail ?? []) : []
                )
                .frame(height: 190)

                if entry.status == "In Transit" {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("LIVE").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial).cornerRadius(8)
                    .padding(10)
                }
            }

            divider

            // Route
            routeRow(icon: "circle.fill",       color: .green, label: "PICKUP",   value: entry.pickupAddress)
            HStack { Spacer().frame(width: 38)
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 2, height: 14) }
            routeRow(icon: "mappin.circle.fill", color: .red,   label: "DELIVERY", value: entry.deliveryAddress)

            divider

            // Date / weight grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                if !entry.pickupDate.isEmpty   { metaCell(icon: "calendar",             color: .green,                                   label: "PICKUP DATE",   value: entry.pickupDate) }
                if !entry.deliveryDate.isEmpty { metaCell(icon: "calendar.badge.clock", color: Color(red:1,green:0.58,blue:0),           label: "EST. DELIVERY", value: entry.deliveryDate) }
                if !entry.weight.isEmpty       { metaCell(icon: "scalemass.fill",       color: .blue,                                    label: "WEIGHT",        value: entry.weight) }
                if !entry.notes.isEmpty        { metaCell(icon: "note.text",            color: Color(red:1,green:0.84,blue:0),           label: "NOTES",         value: entry.notes) }
            }

            divider

            // Action button
            actionButton
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
        }
    }

    // MARK: Action button
    @ViewBuilder
    private var actionButton: some View {
        if entry.isComplete {
            HStack {
                Image(systemName: entry.status == "Delivered" ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Text(entry.status).font(.system(size: 15, weight: .semibold))
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Spacer()
                Button(action: onDismiss) {
                    Label("Remove", systemImage: "trash").font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        } else if entry.status == "Assigned" {
            Button(action: onAccept) {
                Label("Accept Load", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color(red:0.59,green:0.33,blue:0.97))
                    .foregroundColor(.white).cornerRadius(14)
            }.buttonStyle(.plain)
        } else {
            Button(action: onTrack) {
                let inTransit = entry.status == "In Transit"
                Label(inTransit ? "Stop Tracking" : "Start Tracking",
                      systemImage: inTransit ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(inTransit ? Color.orange : Color.green)
                    .foregroundColor(.white).cornerRadius(14)
            }.buttonStyle(.plain)
        }
    }

    // MARK: Helper views
    private func routeRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 14))
                .frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(white: 0.5)).kerning(0.8)
                Text(value).font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func metaCell(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(white: 0.5)).kerning(0.7)
                Text(value).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func statusPill(_ status: String) -> some View {
        let c = statusColor(status)
        return Text(status).font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(c.opacity(0.18)).foregroundColor(c)
            .overlay(Capsule().stroke(c.opacity(0.5), lineWidth: 1)).clipShape(Capsule())
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "Assigned":   return Color(red:0.27,green:0.60,blue:1.0)
        case "Accepted":   return Color(red:0.68,green:0.47,blue:1.0)
        case "In Transit": return Color(red:1.0, green:0.58,blue:0.0)
        case "Delivered":  return Color(red:0.20,green:0.78,blue:0.35)
        case "Cancelled":  return Color(red:1.0, green:0.23,blue:0.19)
        default:           return Color(white:0.5)
        }
    }

    private var divider: some View {
        Divider().background(Color.white.opacity(0.08))
    }

    private var shortRoute: String {
        let p = entry.pickupAddress.split(separator:",").first.map(String.init) ?? entry.pickupAddress
        let d = entry.deliveryAddress.split(separator:",").first.map(String.init) ?? entry.deliveryAddress
        return "\(p) → \(d)"
    }

    private func geocode() {
        guard !geocoded else { return }
        geocoded = true
        CLGeocoder().geocodeAddressString(entry.pickupAddress) { p, _ in
            if let c = p?.first?.location?.coordinate { DispatchQueue.main.async { pickupCoord = c } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CLGeocoder().geocodeAddressString(entry.deliveryAddress) { p, _ in
                if let c = p?.first?.location?.coordinate { DispatchQueue.main.async { deliveryCoord = c } }
            }
        }
    }
}

// MARK: - CardMapView

private struct CardMapView: UIViewRepresentable {
    let pickupCoord:   CLLocationCoordinate2D?
    let deliveryCoord: CLLocationCoordinate2D?
    var driverCoord:   CLLocationCoordinate2D? = nil
    var trail:         [CLLocationCoordinate2D] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.mapType = .standard
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
        ), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)

        var pins: [MKPointAnnotation] = []

        // Driver position (highest priority — center on this when tracking)
        if let d = driverCoord {
            let a = MKPointAnnotation(); a.coordinate = d; a.title = "Driver"
            pins.append(a)
            map.setRegion(MKCoordinateRegion(
                center: d,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ), animated: true)
        } else {
            // No driver yet — show route overview
            if let p = pickupCoord { let a = MKPointAnnotation(); a.coordinate = p; a.title = "Pickup";   pins.append(a) }
            if let d = deliveryCoord { let a = MKPointAnnotation(); a.coordinate = d; a.title = "Delivery"; pins.append(a) }

            if let p = pickupCoord, let d = deliveryCoord {
                let minLat = min(p.latitude, d.latitude), maxLat = max(p.latitude, d.latitude)
                let minLng = min(p.longitude, d.longitude), maxLng = max(p.longitude, d.longitude)
                map.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: (minLat+maxLat)/2, longitude: (minLng+maxLng)/2),
                    span:   MKCoordinateSpan(latitudeDelta: max((maxLat-minLat)*1.6, 0.05),
                                            longitudeDelta: max((maxLng-minLng)*1.6, 0.05))
                ), animated: true)
            } else if let c = pickupCoord ?? deliveryCoord {
                map.setRegion(MKCoordinateRegion(center: c,
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)), animated: true)
            }
        }

        map.addAnnotations(pins)

        // Route trail polyline
        if trail.count >= 2 {
            map.addOverlay(MKPolyline(coordinates: trail, count: trail.count))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = UIColor.systemBlue
                r.lineWidth = 3
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let title = annotation.title else { return nil }
            if title == "Driver" {
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "driver")
                v.markerTintColor = .systemBlue
                v.glyphImage = UIImage(systemName: "truck.box.fill")
                v.displayPriority = .required
                return v
            }
            if title == "Pickup" {
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pickup")
                v.markerTintColor = .systemGreen
                v.glyphImage = UIImage(systemName: "arrow.up.circle.fill")
                return v
            }
            if title == "Delivery" {
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "delivery")
                v.markerTintColor = .systemRed
                v.glyphImage = UIImage(systemName: "mappin")
                return v
            }
            return nil
        }
    }
}

// MARK: - Preview
#Preview {
    let w = LoadWallet.shared
    w.add(entry: WalletEntry(id:"1",token:"t1",loadNumber:"CMP-001",description:"Electronics",
        pickupAddress:"Chicago, IL",deliveryAddress:"Dallas, TX",
        pickupDate:"Mar 26 at 8:00 AM",deliveryDate:"Mar 27 at 5:00 PM",
        status:"In Transit",companyName:"OTTIO LLC",notes:"Handle with care",weight:"38,000 lbs",addedAt:.now))
    w.add(entry: WalletEntry(id:"2",token:"t2",loadNumber:"CMP-002",description:"Auto Parts",
        pickupAddress:"Detroit, MI",deliveryAddress:"Nashville, TN",
        pickupDate:"Mar 27 at 9:00 AM",deliveryDate:"Mar 28 at 3:00 PM",
        status:"Assigned",companyName:"Acme Freight",notes:"",weight:"22,000 lbs",addedAt:.now))
    return ZStack {
        Color(red:0.059,green:0.059,blue:0.102).ignoresSafeArea()
        ScrollView { WalletCardStack(wallet: w, onTrack:{_ in}, onAccept:{_ in}).padding(.top, 20) }
    }
}
