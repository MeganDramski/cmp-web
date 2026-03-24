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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate          = context.coordinator
        map.showsUserLocation = true
        map.mapType           = .standard
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.setRegion(region, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, MKMapViewDelegate {}
}
