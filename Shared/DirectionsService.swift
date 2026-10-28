import Foundation
import CoreLocation

/// Travel time per mode and the transit steps of one route, from Google Routes through the Worker route `/routes`.
/// All four modes use the one source. There is no fallback source: with two sources the same trip would show
/// different minutes on the chip and on the detail screen, and a failure would hide behind the fallback (D1).
struct DirectionsService {
    let config: AppConfig
    var transport: GoogleRoutes.Transport = GoogleRoutes.urlSession

    /// What the detail screen of an event looks up for its mode.
    enum DetailLookup: Equatable {
        /// Transit: the steps of one route.
        case transitPlan
        /// Walk and bicycle: one estimate, for the warnings Google returns with those routes.
        case estimateForWarnings
        /// Car: nothing; the screen shows the stored travel time.
        case none
    }

    static func detailLookup(for mode: TransportMode) -> DetailLookup {
        switch mode {
        case .transit: return .transitPlan
        case .walk, .bicycle: return .estimateForWarnings
        case .car: return .none
        }
    }

    /// Every mode comes from TransportMode.allCases, so a hand-written list can never silently miss a new case.
    func estimateAll(from origin: CLLocationCoordinate2D,
                     to dest: CLLocationCoordinate2D) async -> [TransportMode: TravelEstimate] {
        await withTaskGroup(of: TravelEstimate.self) { group in
            for mode in TransportMode.allCases {
                group.addTask { await self.estimate(mode, from: origin, to: dest) }
            }
            var map: [TransportMode: TravelEstimate] = [:]
            for await e in group { map[e.mode] = e }
            return map
        }
    }

    // @MX:ANCHOR fan_in 3 - Store.lookupTravelSeconds, Store.travelSeconds and estimateAll call this
    // @MX:REASON the failure contract: a value, or a typed reason (a cancelled lookup has neither)
    /// A failed lookup (no proxy, offline, no route and so on) comes back as an estimate with no value.
    /// The one place a reason is attached is the catch below.
    func estimate(_ mode: TransportMode,
                  from origin: CLLocationCoordinate2D,
                  to dest: CLLocationCoordinate2D) async -> TravelEstimate {
        // Without a proxy nothing goes on the network and the reason is fixed at once.
        guard config.hasProxy,
              let request = GoogleRoutes.request(mode: mode, from: origin, to: dest,
                                                 mask: GoogleRoutes.mask(for: mode), config: config) else {
            return TravelEstimate(mode: mode, duration: nil, distance: nil, source: Self.source,
                                  failure: .notConfigured)
        }
        do {
            let route = try GoogleRoutes.parse(try await GoogleRoutes.fetch(request, transport: transport))
            return TravelEstimate(mode: mode, duration: route.duration, distance: route.distance,
                                  source: Self.source, warnings: route.warnings)
        } catch {
            // A cancelled lookup has no failure, so the caller does not draw it as one.
            return TravelEstimate(mode: mode, duration: nil, distance: nil, source: Self.source,
                                  failure: GoogleRoutes.failure(for: error, hasProxy: config.hasProxy))
        }
    }

    private static let source = "Google"

    // MARK: - Transit

    /// The steps of one transit route for the detail screen.
    struct TransitPlan {
        var steps: [TransitStep] = []
        /// Minutes the steps do not explain (waiting and the like). Present only when 1 or more.
        var extraMinutes: Int?
        /// Why the plan is empty (one line on the detail screen). Nil on success and on cancellation.
        var failure: TravelFailure?
    }

    /// Google picks the route; the app does not, so the chip and the detail screen cannot disagree about which route.
    /// A failure comes back as an empty plan.
    func transitPlan(from origin: CLLocationCoordinate2D,
                     to dest: CLLocationCoordinate2D) async -> TransitPlan {
        guard config.hasProxy,
              let request = GoogleRoutes.request(mode: .transit, from: origin, to: dest,
                                                 mask: GoogleRoutes.transitPlanMask, config: config) else {
            return TransitPlan(failure: .notConfigured)
        }
        do {
            let route = try GoogleRoutes.parse(try await GoogleRoutes.fetch(request, transport: transport))
            let converted = GoogleRoutes.transitSteps(from: route)
            return TransitPlan(steps: converted.steps, extraMinutes: converted.extraMinutes)
        } catch {
            return TransitPlan(failure: GoogleRoutes.failure(for: error, hasProxy: config.hasProxy))
        }
    }
}
