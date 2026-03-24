//
//  RouteMapView.swift
//  CMP Tracking
//
//  A UIViewRepresentable wrapper around MKMapView that reliably shows
//  a pickup pin (green) and delivery pin (red) and auto-fits the visible
//  region to include both — no SwiftUI Map binding quirks.
//

import SwiftUI
import MapKit

struct RouteMapView: UIViewRepresentable {
    let pickupCoord: CLLocationCoordinate2D?
    let deliveryCoord: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate          = context.coordinator
        map.isScrollEnabled   = false
        map.isZoomEnabled     = false
        map.isRotateEnabled   = false
        map.isPitchEnabled    = false
        map.showsUserLocation = false
        map.mapType           = .standard
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Remove all existing annotations
        map.removeAnnotations(map.annotations)

        var annotations: [MKPointAnnotation] = []

        if let coord = pickupCoord {
            let ann = MKPointAnnotation()
            ann.coordinate = coord
            ann.title = "Pickup"
            annotations.append(ann)
        }

        if let coord = deliveryCoord {
            let ann = MKPointAnnotation()
            ann.coordinate = coord
            ann.title = "Delivery"
            annotations.append(ann)
        }

        map.addAnnotations(annotations)

        // Fit map to show all annotations with padding
        if annotations.count == 2,
           let p = pickupCoord, let d = deliveryCoord {
            let minLat = min(p.latitude,  d.latitude)
            let maxLat = max(p.latitude,  d.latitude)
            let minLon = min(p.longitude, d.longitude)
            let maxLon = max(p.longitude, d.longitude)
            let center = CLLocationCoordinate2D(
                latitude:  (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta:  max((maxLat - minLat) * 1.8, 0.04),
                longitudeDelta: max((maxLon - minLon) * 1.8, 0.04)
            )
            map.setRegion(MKCoordinateRegion(center: center, span: span), animated: false)
        } else if annotations.count == 1,
                  let ann = annotations.first {
            map.setRegion(
                MKCoordinateRegion(center: ann.coordinate,
                                   span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)),
                animated: false
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }

            let id = "RoutePin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                       ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation    = annotation
            view.canShowCallout = true

            if point.title == "Pickup" {
                view.markerTintColor = UIColor.systemGreen
                view.glyphImage      = UIImage(systemName: "arrow.up.circle.fill")
            } else {
                view.markerTintColor = UIColor.systemRed
                view.glyphImage      = UIImage(systemName: "arrow.down.circle.fill")
            }
            return view
        }
    }
}

// MARK: - Live Tracking Map (shows driver's current position)

struct LiveMapView: UIViewRepresentable {
    let region: MKCoordinateRegion
    let userLocation: CLLocationCoordinate2D?
    var trail: [CLLocationCoordinate2D] = []

    private static func isZeroCoordinate(_ coord: CLLocationCoordinate2D) -> Bool {
        coord.latitude == 0 && coord.longitude == 0
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate          = context.coordinator
        map.showsUserLocation = true
        map.mapType           = .standard
        map.pointOfInterestFilter = .excludingAll
        // Show a neutral US-centered view until a real GPS fix arrives
        let fallback = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span:   MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
        )
        map.setRegion(fallback, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Only move the map when we have a real GPS coordinate
        if !Self.isZeroCoordinate(region.center) {
            map.setRegion(region, animated: true)
        }

        // Truck pin
        map.removeAnnotations(map.annotations.filter { $0 is DriverPin })
        if let coord = userLocation, !Self.isZeroCoordinate(coord) {
            map.addAnnotation(DriverPin(coordinate: coord))
        }

        // Route polyline — replace existing trail overlay
        map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
        if trail.count >= 2 {
            var coords = trail
            let polyline = MKPolyline(coordinates: &coords, count: coords.count)
            map.addOverlay(polyline, level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is DriverPin else { return nil }
            let id = "DriverPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                       ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation     = annotation
            view.canShowCallout  = false
            view.markerTintColor = UIColor.systemBlue
            view.glyphImage      = UIImage(systemName: "truck.box.fill")
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemBlue
            renderer.lineWidth   = 4
            renderer.lineCap     = .round
            renderer.lineJoin    = .round
            return renderer
        }
    }
}

/// A simple annotation used to mark the driver's live position on the map.
private final class DriverPin: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}
