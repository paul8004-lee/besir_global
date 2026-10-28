import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
import GoogleMaps
#endif

/// The notice shown in place of the map when the build has no usable Maps key.
/// There is no other map to fall back to: Google-derived coordinates are drawn on a Google map only.
struct MapUnavailableNotice: View {
    var body: some View {
        Label("Map unavailable", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(Theme.warn)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised)
    }
}

#if os(iOS)

/// Origin and destination on a Google map from the Maps SDK for iOS.
/// The logo and copyright text are the SDK's own and stay as the SDK draws them.
struct RouteMapView: View {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let destinationName: String

    var body: some View {
        if GoogleMapsSetup.shared.isConfigured {
            GoogleMapRepresentable(origin: origin, destination: destination, destinationName: destinationName)
        } else {
            MapUnavailableNotice()
        }
    }
}

/// Holds the map and reports its first non-empty layout, so a camera fit never runs on a zero-size map.
private final class MapHostView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0 { onLayout?() }
    }
}

private struct GoogleMapRepresentable: UIViewRepresentable {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let destinationName: String

    /// Space kept free at the left and bottom so the caller's rounded clip cannot cut the logo or the copyright text.
    private static let edgePadding: CGFloat = 12
    private static let fitInset: CGFloat = 48
    private static let maxFitZoom: Float = 16

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapHostView {
        // The key goes to the SDK here, before the first map view exists, and never at launch.
        _ = GoogleMapsSetup.shared.start()

        let initial = Self.camera(for: MapFraming.plan(origin: origin, destination: destination))
        let options = GMSMapViewOptions()
        options.camera = initial
        let map = GMSMapView(options: options)
        map.padding = UIEdgeInsets(top: 0, left: Self.edgePadding, bottom: Self.edgePadding, right: 0)
        map.settings.compassButton = false
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let host = MapHostView()
        map.frame = host.bounds
        host.addSubview(map)

        let coordinator = context.coordinator
        coordinator.map = map
        host.onLayout = { [weak coordinator] in coordinator?.didLayout() }
        coordinator.update(origin: origin, destination: destination, name: destinationName,
                           dark: context.environment.colorScheme == .dark)
        coordinator.sync()
        return host
    }

    func updateUIView(_ host: MapHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(origin: origin, destination: destination, name: destinationName,
                           dark: context.environment.colorScheme == .dark)
        coordinator.sync()
    }

    private static func camera(for plan: MapFraming) -> GMSCameraPosition {
        switch plan {
        case let .point(lat, lon, zoom):
            return GMSCameraPosition(latitude: lat, longitude: lon, zoom: zoom)
        case let .bounds(south, west, north, east):
            // Replaced by a fit at the first layout; this only gives the map a sensible start.
            return GMSCameraPosition(latitude: (south + north) / 2, longitude: (west + east) / 2, zoom: 12)
        }
    }

    final class Coordinator {
        var map: GMSMapView?
        private var hasSize = false

        /// What the map shows now, so a redraw that changes nothing leaves the markers and the camera alone.
        private var lastMarkers: [MapMarkerSpec] = []
        private var lastFraming: MapFraming?
        private var lastDark: Bool?

        private var origin: CLLocationCoordinate2D?
        private var destination: CLLocationCoordinate2D?
        private var name = ""
        private var dark = false

        func update(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?, name: String, dark: Bool) {
            self.origin = origin
            self.destination = destination
            self.name = name
            self.dark = dark
        }

        /// The first non-empty layout lets the camera fit run; every later layout re-checks the newest inputs.
        func didLayout() {
            hasSize = true
            sync()
        }

        func sync() {
            guard let map else { return }

            let markers = MapMarkerSpec.markers(origin: origin, destination: destination, destinationName: name)
            if markers != lastMarkers || lastDark != dark {
                replaceMarkers(markers, on: map)
                lastMarkers = markers
                lastDark = dark
            }

            guard hasSize else { return }
            let plan = MapFraming.plan(origin: origin, destination: destination)
            if plan != lastFraming {
                apply(plan, to: map)
                lastFraming = plan
            }
        }

        private func replaceMarkers(_ specs: [MapMarkerSpec], on map: GMSMapView) {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            map.clear()
            var destinationMarker: GMSMarker?
            for spec in specs {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: spec.latitude, longitude: spec.longitude))
                marker.title = spec.title
                let tint = spec.role == .origin ? Theme.travel : Theme.warn
                marker.icon = GMSMarker.markerImage(with: UIColor(tint).resolvedColor(with: traits))
                marker.map = map
                if spec.role == .destination { destinationMarker = marker }
            }
            // The name label shows on the destination marker, as the old map showed it.
            map.selectedMarker = destinationMarker
        }

        private func apply(_ plan: MapFraming, to map: GMSMapView) {
            switch plan {
            case let .bounds(south, west, north, east):
                let bounds = GMSCoordinateBounds(
                    coordinate: CLLocationCoordinate2D(latitude: south, longitude: west),
                    coordinate: CLLocationCoordinate2D(latitude: north, longitude: east))
                let inset = GoogleMapRepresentable.fitInset
                map.moveCamera(GMSCameraUpdate.fit(bounds, with: UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)))
                if map.camera.zoom > GoogleMapRepresentable.maxFitZoom {
                    map.moveCamera(GMSCameraUpdate.zoom(to: GoogleMapRepresentable.maxFitZoom))
                }
            case let .point(lat, lon, zoom):
                map.moveCamera(GMSCameraUpdate.setTarget(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoom: zoom))
            }
        }
    }
}

#else

/// The Maps SDK for iOS does not run on this platform; the symbol stays so shared screens still compile.
struct RouteMapView: View {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let destinationName: String

    var body: some View { MapUnavailableNotice() }
}

#endif
