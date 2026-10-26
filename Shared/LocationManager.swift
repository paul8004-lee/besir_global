import Foundation
import CoreLocation

/// 현재 위치를 관리한다. CoreLocation 권한이 없거나 실패하면
/// 사용자가 수동으로 출발지를 지정할 수 있게 한다.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocationCoordinate2D?
    /// 현재 위치를 역지오코딩한 사람이 읽을 수 있는 이름(예: "서울 성북구 안암동").
    @Published var currentPlaceName: String?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastError: String?
    /// 측위가 진행 중인지.
    @Published var isLocating = false

    /// 사용자가 수동으로 지정한 출발지(있으면 현재 위치보다 우선).
    @Published var manualOrigin: Place?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var timeoutTask: Task<Void, Never>?

    private func isAuthorized(_ s: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return s == .authorizedAlways || s == .authorizedWhenInUse
        #else
        return s == .authorizedAlways
        #endif
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest   // GPS 정확도
        authorizationStatus = manager.authorizationStatus
    }

    /// 실제 출발지로 사용할 좌표. 수동 지정 > 현재 위치 순.
    var originCoordinate: CLLocationCoordinate2D? {
        if let m = manualOrigin {
            return CLLocationCoordinate2D(latitude: m.latitude, longitude: m.longitude)
        }
        return currentLocation
    }

    /// 현재 위치를 출발지로 쓰겠다고 요청한다. 권한이 없으면 프롬프트를 띄운다.
    func useCurrentLocation() {
        manualOrigin = nil
        lastError = nil
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            lastError = "위치 권한이 꺼져 있습니다. 시스템 설정에서 허용해 주세요."
            return
        }
        // 이미 확보된 최신 위치가 있으면 즉시 사용 (재요청 시 콜백이 안 와 멈추는 문제 방지).
        if let loc = manager.location {
            timeoutTask?.cancel()
            isLocating = false
            currentLocation = loc.coordinate
            reverseGeocode(loc)
            manager.startUpdatingLocation()   // 백그라운드 갱신(첫 콜백 후 자동 정지)
            return
        }
        // 캐시가 없으면 새로 측위.
        isLocating = true
        startTimeout()
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()   // 허용되면 didChangeAuthorization에서 측위 시작
        } else {
            manager.startUpdatingLocation()            // 이미 허용된 상태
        }
    }

    /// 측위가 이 시한 안에 오지 않으면 IP 폴백으로 넘어간다. prefillOrigin의 대기 시한도 여기서
    /// 파생한다 — 두 시한이 어긋나면 측위가 늦게(5~8초) 왔을 때 빈 출발지 줄을 채우지 못한다
    /// (t11 sync N5).
    static let locateTimeoutSeconds: TimeInterval = {
        #if os(iOS)
        8
        #else
        3
        #endif
    }()

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            // GPS(iOS)는 첫 측위에 시간이 걸리므로 충분히 기다린 뒤, 그래도 안 오면 IP 폴백.
            try? await Task.sleep(nanoseconds: UInt64(Self.locateTimeoutSeconds * 1_000_000_000))
            // 취소된 태스크는 아무것도 쓰지 않게 여기서 돌려보낸다 — sleep은 취소에 즉시 깨는데
            // 이어서 폴백을 돌리면, 취소된 URLSession 요청이 서버에 닿기 전 -999로 끝나 폴백이
            // 조용히 실패하고 isLocating=false와 실패 lastError가 ~0.05초에 쓰인다(프리필 이중
            // 호출 경로의 실제 증상 — IP 폴백이 죽고 출발지 스피너가 일찍 꺼진다. 대략 위치가
            // 확정되는 일은 없다. t12 sync D4·N1).
            guard !Task.isCancelled, self.isLocating, self.currentLocation == nil else { return }
            await self.ipLocationFallback()
            if self.currentLocation == nil {
                self.isLocating = false
                self.lastError = "위치를 가져오지 못했습니다. 시스템 설정 → 위치 서비스를 확인하거나 출발지를 직접 검색해 주세요."
            }
        }
    }

    /// CoreLocation 실패 시 IP 기반 대략 위치(도시 수준). CoreLocation이 나중에 오면 그쪽이 덮어쓴다.
    private func ipLocationFallback() async {
        guard let url = URL(string: "https://ipwho.is/") else { return }   // HTTPS (ATS 통과)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = (obj["latitude"] as? Double) ?? (obj["lat"] as? Double),
                  let lon = (obj["longitude"] as? Double) ?? (obj["lon"] as? Double) else { return }
            guard currentLocation == nil else { return }
            currentLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            isLocating = false
            lastError = nil
            let region = (obj["region"] as? String) ?? (obj["regionName"] as? String)
            let city = obj["city"] as? String
            let name = [region, city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            currentPlaceName = name.isEmpty ? "현재 위치(대략)" : "\(name) (대략)"
        } catch {
            // 폴백 실패 시 조용히 무시(상위에서 에러 메시지 처리)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isAuthorized(status) {
                if self.isLocating { manager.startUpdatingLocation() }
            } else if status == .denied || status == .restricted {
                self.isLocating = false
                self.lastError = "위치 권한이 거부되었습니다. 시스템 설정에서 허용해 주세요."
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.timeoutTask?.cancel()
            manager.stopUpdatingLocation()
            self.currentLocation = loc.coordinate
            self.lastError = nil
            self.isLocating = false
            self.reverseGeocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // kCLErrorLocationUnknown(0)은 일시적이므로 계속 시도하게 둔다.
            if (error as NSError).code == CLError.locationUnknown.rawValue { return }
            self.isLocating = false
            self.lastError = error.localizedDescription
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ko_KR")) { [weak self] placemarks, _ in
            guard let p = placemarks?.first else { return }
            // 시·구가 중복(예: "서울특별시 서울특별시")되면 제거하고 합친다.
            var parts: [String] = []
            for part in [p.administrativeArea, p.locality, p.subLocality, p.thoroughfare].compactMap({ $0 }) {
                if !parts.contains(part) { parts.append(part) }
            }
            let name = parts.isEmpty ? "현재 위치" : parts.joined(separator: " ")
            Task { @MainActor in self?.currentPlaceName = name }
        }
    }
}
