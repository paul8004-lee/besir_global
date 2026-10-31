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
    /// The route between the two places; fewer than two usable points means no line.
    var routeLine: [RoutePoint] = []

    var body: some View {
        if GoogleMapsSetup.shared.isConfigured {
            GoogleMapRepresentable(origin: origin, destination: destination, destinationName: destinationName,
                                   routeLine: routeLine)
        } else {
            MapUnavailableNotice()
        }
    }
}

/// Holds the map and reports its first non-empty layout, so a camera fit never runs on a zero-size map.
private final class MapHostView: UIView {
    var onLayout: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MapHostView, _) in
            view.onAppearanceChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0 { onLayout?() }
    }
}

private struct GoogleMapRepresentable: UIViewRepresentable {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let destinationName: String
    let routeLine: [RoutePoint]

    /// Space kept free at the left and bottom so the caller's rounded clip cannot cut the logo or the copyright text.
    private static let edgePadding: CGFloat = 12
    private static let maxFitZoom: Float = 16

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapHostView {
        // The key goes to the SDK here, before the first map view exists, and never at launch.
        _ = GoogleMapsSetup.shared.start()

        let initial = Self.camera(for: MapFraming.plan(origin: origin, destination: destination, path: routeLine))
        let options = GMSMapViewOptions()
        options.camera = initial
        let map = GMSMapView(options: options)
        map.padding = UIEdgeInsets(top: 0, left: Self.edgePadding, bottom: Self.edgePadding, right: 0)
        map.settings.compassButton = false
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator

        let host = MapHostView()
        map.frame = host.bounds
        host.addSubview(map)

        let coordinator = context.coordinator
        coordinator.map = map
        host.onLayout = { [weak coordinator] in coordinator?.didLayout() }
        host.onAppearanceChange = { [weak coordinator] in coordinator?.beginReassert() }
        coordinator.update(origin: origin, destination: destination, name: destinationName,
                           dark: context.environment.colorScheme == .dark, routeLine: routeLine)
        coordinator.sync()
        return host
    }

    func updateUIView(_ host: MapHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(origin: origin, destination: destination, name: destinationName,
                           dark: context.environment.colorScheme == .dark, routeLine: routeLine)
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

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var map: GMSMapView?
        private var hasSize = false

        /// What the map shows now, so a redraw that changes nothing leaves the markers and the camera alone.
        private var lastMarkers: [MapMarkerSpec] = []
        private var lastFit: MapFitBasis?
        private var lastDark: Bool?
        private var lastLine: RouteLineSpec?
        private var lastLineDark: Bool?

        private var origin: CLLocationCoordinate2D?
        private var destination: CLLocationCoordinate2D?
        private var name = ""
        private var dark = false
        private var routeLine: [RoutePoint] = []
        private var destinationMarker: GMSMarker?
        /// The markers and the line are removed one by one; the map is never cleared, so one never takes the other off.
        private var drawnMarkers: [GMSMarker] = []
        private var polyline: GMSPolyline?

        /// The colours of both the markers and the line resolve for the same appearance.
        private var traits: UITraitCollection { UITraitCollection(userInterfaceStyle: dark ? .dark : .light) }

        func update(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?, name: String, dark: Bool,
                    routeLine: [RoutePoint]) {
            self.origin = origin
            self.destination = destination
            self.name = name
            self.dark = dark
            self.routeLine = routeLine
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
                let appearanceChanged = lastDark != nil && lastDark != dark
                replaceMarkers(markers, on: map)
                lastMarkers = markers
                lastDark = dark
                if appearanceChanged { beginReassert() }
            }

            syncLine(on: map)

            reselect()

            guard hasSize else { return }
            let fit = MapFitBasis(frame: MapFraming.plan(origin: origin, destination: destination, path: routeLine),
                                  labelWidth: labelWidth())
            if MapFitRule.needsFit(last: lastFit, next: fit) {
                apply(fit, to: map)
                lastFit = fit
            }
        }

        /// The line changes only when its points change or the appearance changes while a line is showing.
        private func syncLine(on map: GMSMapView) {
            let spec = RouteLineSpec.make(routeLine)
            guard RouteLineSpec.needsRedraw(last: lastLine, next: spec, colourSchemeChanged: lastLineDark != dark) else { return }
            polyline?.map = nil
            polyline = nil
            if let spec {
                let path = GMSMutablePath()
                for point in spec.points { path.add(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) }
                let line = GMSPolyline(path: path)
                line.strokeWidth = CGFloat(RouteLineSpec.width)
                line.strokeColor = UIColor(Theme.travel).resolvedColor(with: traits)
                line.map = map
                polyline = line
            }
            lastLine = spec
            lastLineDark = dark
        }

        private func replaceMarkers(_ specs: [MapMarkerSpec], on map: GMSMapView) {
            map.selectedMarker = nil
            for marker in drawnMarkers { marker.map = nil }
            drawnMarkers = []
            destinationMarker = nil
            for spec in specs {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: spec.latitude, longitude: spec.longitude))
                marker.title = spec.title
                let tint = spec.role == .origin ? Theme.travel : Theme.warn
                marker.icon = GMSMarker.markerImage(with: UIColor(tint).resolvedColor(with: traits))
                marker.map = map
                drawnMarkers.append(marker)
                if spec.role == .destination { destinationMarker = marker }
            }
            map.selectedMarker = destinationMarker
        }

        /// The name label is the info window of the selected destination marker. The SDK drops the selection
        /// on a tap on the map and when the style changes, so it is put back whenever nothing is selected;
        /// a tap on the origin marker keeps showing its own title.
        func reselect() {
            guard let map, let destinationMarker, map.selectedMarker == nil else { return }
            map.selectedMarker = destinationMarker
        }

        /// One run-loop turn later, so it runs after the SDK has finished its own change.
        func reselectSoon() {
            DispatchQueue.main.async { [weak self] in self?.reselect() }
        }

        /// After a change of appearance the SDK restyles the map a little later, and the first switch to a style
        /// it has not drawn yet can drop the info window without any event we get (seen in the walk: the first
        /// Dark switch after a pan showed no label; the cause is a reading, not proven). So for a few seconds
        /// the selection is set again from a timer and from every end of tile rendering.
        private var reassertUntil = Date.distantPast

        func beginReassert() {
            reassertUntil = LabelReassert.until(from: Date())
            reselectSoon()
            for delay in LabelReassert.delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reassert() }
            }
        }

        /// Selects the destination marker again even if the map still reports it as selected,
        /// but leaves a tap on the origin marker alone.
        private func reassert() {
            guard let map, let destinationMarker else { return }
            if let selected = map.selectedMarker, selected !== destinationMarker { return }
            map.selectedMarker = nil
            map.selectedMarker = destinationMarker
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) { reselect() }

        func mapViewDidFinishTileRendering(_ mapView: GMSMapView) {
            if LabelReassert.isActive(now: Date(), until: reassertUntil) { reassert() } else { reselect() }
        }

        func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) { reselectSoon() }

        /// Width of the destination's name label: the title in the info window's text size plus its own padding.
        private func labelWidth() -> CGFloat {
            let title = MapMarkerSpec.markers(origin: origin, destination: destination, destinationName: name)
                .first { $0.role == .destination }?.title ?? ""
            let text = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width
            return ceil(text) + 32
        }

        private func apply(_ fit: MapFitBasis, to map: GMSMapView) {
            switch fit.frame {
            case let .bounds(south, west, north, east):
                let bounds = GMSCoordinateBounds(
                    coordinate: CLLocationCoordinate2D(latitude: south, longitude: west),
                    coordinate: CLLocationCoordinate2D(latitude: north, longitude: east))
                let insets = MapFitInsets.make(labelWidth: fit.labelWidth, mapWidth: map.bounds.width, mapHeight: map.bounds.height)
                map.moveCamera(GMSCameraUpdate.fit(bounds, with: UIEdgeInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)))
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
    var routeLine: [RoutePoint] = []

    var body: some View { MapUnavailableNotice() }
}

#endif
