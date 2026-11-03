import Foundation

/// SPEC-UBERLINK-001 (card t120): the travel choice a trip is made with. Foundation only. Uber is not a fifth transport
/// mode: it is a car trip that carries a mark (`ScheduledEvent.viaUber`), so it is timed, looked up and drawn as a car.
/// This file is the one rule that names, lists and parses the choices and the one writer of the mark.
enum TravelChoice: Hashable {
    case standard(TransportMode)
    case uber

    /// The chip value and the model argument of the Uber choice.
    private static let uberValue = "uber"

    /// The choices a hand travel picker offers, in order: Car, Uber, Transit, Walk, Bicycle.
    static let all: [TravelChoice] = [.standard(.car), .uber, .standard(.transit), .standard(.walk), .standard(.bicycle)]

    /// The choice of a chip value or a model argument, read exactly: no trimming, no case folding.
    init?(value: String) {
        if value == Self.uberValue {
            self = .uber
            return
        }
        guard let mode = TransportMode(rawValue: value) else { return nil }
        self = .standard(mode)
    }

    /// The choice a stored trip reads as: Uber exactly when the mode is car and the mark is true; a mark on any other
    /// mode is read as that mode.
    init(mode: TransportMode, viaUber: Bool?) {
        self = mode == .car && viaUber == true ? .uber : .standard(mode)
    }

    /// The mode the trip is routed and timed with (car for Uber).
    var mode: TransportMode {
        switch self {
        case .standard(let mode): return mode
        case .uber: return .car
        }
    }

    /// The chip value.
    var value: String {
        switch self {
        case .standard(let mode): return mode.rawValue
        case .uber: return Self.uberValue
        }
    }

    var title: String {
        switch self {
        case .standard(let mode): return mode.title
        case .uber: return "Uber"
        }
    }

    var titleWithParticle: String {
        switch self {
        case .standard(let mode): return mode.titleWithParticle
        case .uber: return "By Uber"
        }
    }

    /// The symbol of the routing mode, so the car symbol for Uber (no brand art).
    var systemImage: String { mode.systemImage }

    /// `uber` in any letter case with no Unicode letter or number right before or after it.
    private static let namesUberPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])uber(?![\\p{L}\\p{N}])", options: [.caseInsensitive])

    /// True when a line the user wrote names Uber: the letters `uber` in any letter case (diacritics are not ignored)
    /// with neither a Unicode letter nor a Unicode number right before or right after them. Every occurrence is tried.
    static func namesUber(_ line: String) -> Bool {
        guard let pattern = namesUberPattern else { return false }
        return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

extension ScheduledEvent {
    /// The choice this trip reads as.
    var travelChoice: TravelChoice { TravelChoice(mode: mode, viaUber: viaUber) }

    /// Sets the trip's travel choice: its routing mode and, for Uber only, the mark.
    // @MX:NOTE: [AUTO] The only writer of viaUber; the mark is true only with mode car.
    mutating func setTravel(_ choice: TravelChoice) {
        mode = choice.mode
        viaUber = choice == .uber ? true : nil
    }
}
