import Foundation
import CoreLocation

/// An IP-based position guess (city level). It is a display and search-bias value, never an origin to commit.
struct ApproximateLocation: Equatable {
    var latitude: Double
    var longitude: Double
    var region: String?
    var city: String?
}

/// Asks for an IP-based guess; nil when the lookup fails or answers nothing usable.
typealias IPLookup = @Sendable () async -> ApproximateLocation?
/// Turns a fix into a readable name; nil when there is no placemark.
typealias PlaceNameResolver = @Sendable (CLLocation) async -> String?

/// The part of CoreLocation that `LocationManager` drives. Tests pass a fake.
@MainActor
protocol LocationSource: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var cachedLocation: CLLocation? { get }
    var distanceFilter: CLLocationDistance { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

/// The production source: one `CLLocationManager`. `LocationManager` becomes its delegate.
@MainActor
final class CoreLocationSource: LocationSource {
    let manager = CLLocationManager()

    init() {
        manager.desiredAccuracy = kCLLocationAccuracyBest   // GPS 정확도
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var cachedLocation: CLLocation? { manager.location }
    var distanceFilter: CLLocationDistance {
        get { manager.distanceFilter }
        set { manager.distanceFilter = newValue }
    }
    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func startUpdatingLocation() { manager.startUpdatingLocation() }
    func stopUpdatingLocation() { manager.stopUpdatingLocation() }
}

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
    /// currentLocation이 IP 폴백이 만든 대략 위치인지. 진짜 측위가 오면 그쪽이 덮어쓴다.
    @Published private(set) var isApproximate = false

    /// 사용자가 수동으로 지정한 출발지(있으면 현재 위치보다 우선).
    @Published var manualOrigin: Place?

    private let source: any LocationSource
    private let ipLookup: IPLookup
    private let nameResolver: PlaceNameResolver
    private let waitSeconds: TimeInterval
    private var timeoutTask: Task<Void, Never>?

    private func isAuthorized(_ s: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return s == .authorizedAlways || s == .authorizedWhenInUse
        #else
        return s == .authorizedAlways
        #endif
    }

    /// Every collaborator has a production default, so `LocationManager()` is the app's manager.
    init(source: (any LocationSource)? = nil,
         ipLookup: IPLookup? = nil,
         nameResolver: PlaceNameResolver? = nil,
         waitSeconds: TimeInterval? = nil) {
        let source = source ?? CoreLocationSource()
        self.source = source
        self.ipLookup = ipLookup ?? { await LocationManager.ipwhoLookup() }
        self.nameResolver = nameResolver ?? { await LocationManager.geocodedName($0) }
        self.waitSeconds = waitSeconds ?? Self.locateTimeoutSeconds
        super.init()
        (source as? CoreLocationSource)?.manager.delegate = self
        authorizationStatus = source.authorizationStatus
    }

    /// 실제 출발지로 사용할 좌표. 수동 지정 > 현재 위치 순.
    var originCoordinate: CLLocationCoordinate2D? {
        if let m = manualOrigin {
            return CLLocationCoordinate2D(latitude: m.latitude, longitude: m.longitude)
        }
        return currentLocation
    }

    /// The position from a real fix, nil while only the IP guess is held.
    var realFixLocation: CLLocationCoordinate2D? { currentLocation }

    /// Tells the manager whether the app is in the foreground.
    func setForeground(_ foreground: Bool) {}

    /// 현재 위치를 출발지로 쓰겠다고 요청한다. 권한이 없으면 프롬프트를 띄운다.
    func useCurrentLocation() {
        manualOrigin = nil
        lastError = nil
        let status = source.authorizationStatus
        if status == .denied || status == .restricted {
            lastError = "Location permission is off. Allow it in Settings."
            return
        }
        // 이미 확보된 최신 위치가 있으면 즉시 사용 (재요청 시 콜백이 안 와 멈추는 문제 방지).
        if let loc = source.cachedLocation {
            applyFix(loc)
            source.startUpdatingLocation()   // 백그라운드 갱신(첫 콜백 후 자동 정지)
            return
        }
        // 캐시가 없으면 새로 측위.
        isLocating = true
        startTimeout()
        if status == .notDetermined {
            source.requestWhenInUseAuthorization()   // 허용되면 didChangeAuthorization에서 측위 시작
        } else {
            source.startUpdatingLocation()            // 이미 허용된 상태
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
            try? await Task.sleep(nanoseconds: UInt64(self.waitSeconds * 1_000_000_000))
            // A cancelled task writes nothing: the sleep wakes at once on cancel, and a fallback run
            // after that would be a cancelled request (t12 sync D4, N1).
            guard !Task.isCancelled, self.isLocating, self.currentLocation == nil else { return }
            await self.ipLocationFallback()
            if self.currentLocation == nil {
                self.isLocating = false
                self.lastError = "Couldn't get your location. Check Settings → Location Services, or search for an origin yourself."
            }
        }
    }

    /// CoreLocation 실패 시 IP 기반 대략 위치(도시 수준). CoreLocation이 나중에 오면 그쪽이 덮어쓴다.
    private func ipLocationFallback() async {
        guard let a = await ipLookup() else { return }
        guard currentLocation == nil else { return }
        applyApproximate(latitude: a.latitude, longitude: a.longitude, region: a.region, city: a.city)
    }

    /// The production IP lookup: city-level position from the device address.
    nonisolated static func ipwhoLookup() async -> ApproximateLocation? {
        guard let url = URL(string: "https://ipwho.is/") else { return nil }   // HTTPS (ATS 통과)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = (obj["latitude"] as? Double) ?? (obj["lat"] as? Double),
                  let lon = (obj["longitude"] as? Double) ?? (obj["lon"] as? Double) else { return nil }
            let region = (obj["region"] as? String) ?? (obj["regionName"] as? String)
            return ApproximateLocation(latitude: lat, longitude: lon, region: region, city: obj["city"] as? String)
        } catch {
            return nil   // 폴백 실패 시 조용히 무시(상위에서 에러 메시지 처리)
        }
    }

    /// 대략 위치를 현재 위치로 쓴다. isLocating을 내리므로, 이 뒤에 오는 권한 허용에서도 측위를
    /// 시작할 수 있게 isApproximate를 남긴다(t39: 권한 대화상자가 8초 넘게 떠 있으면 폴백이 서울을
    /// 넣고, 허용해도 측위가 시작되지 않아 서울이 세션 내내 남았다).
    func applyApproximate(latitude: Double, longitude: Double, region: String?, city: String?) {
        currentLocation = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        isApproximate = true
        isLocating = false
        lastError = nil
        let name = Self.joinedApproxName(region: region, city: city)
        currentPlaceName = name.isEmpty ? "Current Location (approx.)" : "\(name) (approx.)"
    }

    /// 진짜 측위를 받아들인다. 대략 위치의 이름은 새 이름이 올 때까지 남기지 않는다 — 역지오코딩이
    /// 실패하면 새 좌표에 옛 "(approx.)" 이름이 붙어 남는다.
    func applyFix(_ location: CLLocation) {
        timeoutTask?.cancel()
        if isApproximate {
            currentPlaceName = nil
            isApproximate = false
        }
        currentLocation = location.coordinate
        lastError = nil
        isLocating = false
        reverseGeocode(location)
    }

    /// Joins region and city for the approximate name; writes the text once when both are exactly equal.
    static func joinedApproxName(region: String?, city: String?) -> String {
        let parts = [region, city].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.count == 2, parts[0] == parts[1] { return parts[0] }
        return parts.joined(separator: " ")
    }

    // MARK: - Authorization, fixes and failures

    func handleAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if isAuthorized(status) {
            if isLocating || isApproximate { source.startUpdatingLocation() }
        } else if status == .denied || status == .restricted {
            isLocating = false
            lastError = "Location permission was denied. Allow it in Settings."
        }
    }

    func handleUpdate(_ location: CLLocation) {
        source.stopUpdatingLocation()
        applyFix(location)
    }

    func handleFailure(_ error: Error) {
        // kCLErrorLocationUnknown(0)은 일시적이므로 계속 시도하게 둔다.
        if (error as NSError).code == CLError.locationUnknown.rawValue { return }
        isLocating = false
        lastError = error.localizedDescription
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handleAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.handleUpdate(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.handleFailure(error) }
    }

    private func reverseGeocode(_ location: CLLocation) {
        let resolver = nameResolver
        Task { @MainActor in
            if let name = await resolver(location) { self.currentPlaceName = name }
        }
    }

    /// The production name lookup.
    nonisolated static func geocodedName(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        guard let p = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")).first
        else { return nil }
        // 시·구가 중복(예: "서울특별시 서울특별시")되면 제거하고 합친다.
        var parts: [String] = []
        for part in [p.administrativeArea, p.locality, p.subLocality, p.thoroughfare].compactMap({ $0 }) {
            if !parts.contains(part) { parts.append(part) }
        }
        return parts.isEmpty ? "Current Location" : parts.joined(separator: " ")
    }
}
