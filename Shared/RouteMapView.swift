import SwiftUI
import MapKit

/// 출발지·목적지를 보여주는 네이티브 지도.
struct RouteMapView: View {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let destinationName: String

    private var region: MKCoordinateRegion {
        if let o = origin, let d = destination {
            let center = CLLocationCoordinate2D(latitude: (o.latitude + d.latitude) / 2,
                                                longitude: (o.longitude + d.longitude) / 2)
            let span = MKCoordinateSpan(
                latitudeDelta: max(abs(o.latitude - d.latitude) * 1.8, 0.01),
                longitudeDelta: max(abs(o.longitude - d.longitude) * 1.8, 0.01))
            return MKCoordinateRegion(center: center, span: span)
        }
        let c = destination ?? origin ?? CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        return MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
    }

    var body: some View {
        Map(initialPosition: .region(region)) {
            if let o = origin {
                Marker("출발", systemImage: "location.fill", coordinate: o)
                    // 출발점도 이동의 일부다 — 시스템 파랑 대신 전역 틴트(App.swift)와 같은 세이지를 쓴다.
                    .tint(Theme.travel)
            }
            if let d = destination {
                Marker(destinationName, systemImage: "flag.fill", coordinate: d)
                    .tint(Theme.warn)
            }
        }
        .mapStyle(.standard)
    }
}
