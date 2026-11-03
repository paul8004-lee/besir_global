import Foundation

/// SPEC-UBERLINK-001 (card t120): the travel choice a trip is made with. Foundation only. Uber is not a fifth transport
/// mode: it is a car trip that carries a mark (`ScheduledEvent.viaUber`), so it is timed, looked up and drawn as a car.
/// This file is the one rule that names, lists and parses the choices and the one writer of the mark.
enum TravelChoice: Hashable {
    case standard(TransportMode)
    case uber

    /// The choices a hand travel picker offers, in order.
    static let all: [TravelChoice] = TransportMode.allCases.map { .standard($0) }

    /// The choice of a chip value or a model argument, read exactly.
    init?(value: String) {
        guard let mode = TransportMode(rawValue: value) else { return nil }
        self = .standard(mode)
    }

    /// The choice a stored trip reads as.
    init(mode: TransportMode, viaUber: Bool?) {
        self = .standard(mode)
    }

    /// The mode the trip is routed and timed with.
    var mode: TransportMode {
        switch self {
        case .standard(let mode): return mode
        case .uber: return .car
        }
    }

    /// The chip value.
    var value: String { mode.rawValue }

    var title: String { mode.title }

    var titleWithParticle: String { mode.titleWithParticle }

    var systemImage: String { mode.systemImage }

    /// True when a line the user wrote names Uber.
    static func namesUber(_ line: String) -> Bool {
        false
    }
}

extension ScheduledEvent {
    /// The choice this trip reads as.
    var travelChoice: TravelChoice { TravelChoice(mode: mode, viaUber: viaUber) }

    /// Sets the trip's travel choice.
    mutating func setTravel(_ choice: TravelChoice) {
        mode = choice.mode
    }
}
