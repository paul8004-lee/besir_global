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
    /// The one wait that bounds a positioning attempt. A newer wait replaces it; the generation tells a
    /// replaced or cancelled wait (and the IP lookup it started) that its answer is no longer wanted.
    private var waitTask: Task<Void, Never>?
    private var waitGeneration = 0
    private var nameTask: Task<Void, Never>?
    private var fixGeneration = 0
    /// Whether the app is in the foreground. It starts true; REQ-010 moves it.
    private var isForeground = true

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
        // Updates stay on while the app is open, so a fix is only delivered after 100 m of movement.
        source.distanceFilter = Self.updateDistanceFilter
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
    var realFixLocation: CLLocationCoordinate2D? { isApproximate ? nil : currentLocation }

    /// Metres a fix has to differ from the last delivered one before CoreLocation reports it again.
    static let updateDistanceFilter: CLLocationDistance = 100

    /// Tells the manager whether the app is in the foreground. Becoming active begins positioning when no real
    /// fix is held and resumes the updates otherwise; the background cancels the wait and stops the updates.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            let status = source.authorizationStatus
            guard isAuthorized(status) else { return }
            if realFixLocation == nil {
                beginPositioning(status: status)
            } else {
                source.startUpdatingLocation()
            }
        } else {
            stopPositioning()
        }
    }

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
            if isForeground { source.startUpdatingLocation() }   // updates keep running in the foreground
            return
        }
        // 캐시가 없으면 새로 측위.
        beginPositioning(status: status)
    }

    /// The only place that starts a wait. It also starts the updates, or asks for the permission when the
    /// status is not determined (the grant callback then calls this again). It does nothing in the background.
    private func beginPositioning(status: CLAuthorizationStatus) {
        guard isForeground else { return }
        lastError = nil
        isLocating = true
        armWait()
        if status == .notDetermined {
            source.requestWhenInUseAuthorization()   // 허용되면 didChangeAuthorization에서 측위 시작
        } else {
            source.startUpdatingLocation()            // 이미 허용된 상태
        }
    }

    /// Ends a positioning attempt: no wait, no updates, not locating.
    private func stopPositioning() {
        cancelWait()
        source.stopUpdatingLocation()
        isLocating = false
    }

    private func cancelWait() {
        waitTask?.cancel()
        waitTask = nil
        waitGeneration += 1
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

    private func armWait() {
        waitTask?.cancel()
        waitGeneration += 1
        let generation = waitGeneration
        waitTask = Task { @MainActor in
            // GPS(iOS)는 첫 측위에 시간이 걸리므로 충분히 기다린 뒤, 그래도 안 오면 IP 폴백.
            try? await Task.sleep(nanoseconds: UInt64(self.waitSeconds * 1_000_000_000))
            // A cancelled or replaced wait writes nothing: the sleep wakes at once on cancel, and a
            // fallback run after that would be a cancelled request (t12 sync D4, N1).
            guard !Task.isCancelled, generation == self.waitGeneration else { return }
            await self.waitEnded(generation)
        }
    }

    private var isDenied: Bool {
        let status = source.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// A wait that ends while locating and holding no real fix: ask the IP lookup only when nothing at all is
    /// held and the permission is not denied, then stop locating. A wait that ends while not locating does
    /// nothing (a failure or a denial already ended the attempt).
    private func waitEnded(_ generation: Int) async {
        guard isLocating, realFixLocation == nil else { return }
        if currentLocation == nil, !isDenied {
            await ipLocationFallback(generation)
            guard generation == waitGeneration else { return }
        }
        isLocating = false
        if currentLocation == nil {
            lastError = "Couldn't get your location. Check Settings → Location Services, or search for an origin yourself."
        }
    }

    /// CoreLocation 실패 시 IP 기반 대략 위치(도시 수준). CoreLocation이 나중에 오면 그쪽이 덮어쓴다.
    /// The answer is dropped when the wait it belongs to was replaced or cancelled, the permission is
    /// denied, or a real fix (or any position) arrived while the lookup ran.
    private func ipLocationFallback(_ generation: Int) async {
        guard let a = await ipLookup() else { return }
        guard generation == waitGeneration, !Task.isCancelled, !isDenied,
              realFixLocation == nil, currentLocation == nil else { return }
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
        cancelWait()
        isApproximate = false
        currentLocation = location.coordinate
        // The old name belongs to the old fix: show none until this fix's own name arrives.
        currentPlaceName = nil
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
            // Any grant starts positioning unless a real fix is held: a grant after a denial, after a failed
            // IP lookup and after the approximate state all begin the same way.
            if realFixLocation == nil {
                beginPositioning(status: status)
            } else if isForeground {
                source.startUpdatingLocation()
            }
        } else if status == .denied || status == .restricted {
            // The IP guess does not survive a denial; a real fix does (DL6).
            stopPositioning()
            if isApproximate {
                currentLocation = nil
                isApproximate = false
                currentPlaceName = nil
            }
            lastError = "Location permission was denied. Allow it in Settings."
        }
    }

    /// A fix never stops the updates: the position follows the device while the app is open.
    func handleUpdate(_ location: CLLocation) {
        applyFix(location)
    }

    func handleFailure(_ error: Error) {
        // kCLErrorLocationUnknown(0)은 일시적이므로 계속 시도하게 둔다.
        if (error as NSError).code == CLError.locationUnknown.rawValue { return }
        isLocating = false
        // A position that is already held (real or approximate) makes the error a non-event.
        if currentLocation == nil { lastError = error.localizedDescription }
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

    /// At most one name lookup is in flight: a newer fix cancels the older one, and an answer that still
    /// arrives for a fix that is no longer the latest is dropped.
    private func reverseGeocode(_ location: CLLocation) {
        nameTask?.cancel()
        fixGeneration += 1
        let generation = fixGeneration
        let resolver = nameResolver
        nameTask = Task { @MainActor in
            let name = await resolver(location)
            guard !Task.isCancelled, generation == self.fixGeneration else { return }
            if let name { self.currentPlaceName = name }
        }
    }

    /// The production name lookup.
    nonisolated static func geocodedName(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        // A cancelled lookup (a newer fix replaced it) cancels the request itself.
        let found = await withTaskCancellationHandler {
            try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US"))
        } onCancel: {
            geocoder.cancelGeocode()
        }
        guard let p = found?.first else { return nil }
        // 시·구가 중복(예: "서울특별시 서울특별시")되면 제거하고 합친다.
        var parts: [String] = []
        for part in [p.administrativeArea, p.locality, p.subLocality, p.thoroughfare].compactMap({ $0 }) {
            if !parts.contains(part) { parts.append(part) }
        }
        return parts.isEmpty ? "Current Location" : parts.joined(separator: " ")
    }
}
