import Foundation

/// The app's rules document `besir.md`, shipped in the app bundle: the `## Always` lines go into every chat request, the
/// `## Memory` lines go in only together with count lines.
struct BesirRules: Equatable {
    static let resourceName = "besir"
    static let resourceExtension = "md"

    let always: [String]
    let memory: [String]

    static func parse(_ text: String) -> BesirRules {
        BesirRules(always: [], memory: [])
    }

    static func read(fileAt url: URL) -> BesirRules? {
        nil
    }

    static func bundled(in bundle: Bundle = Bundle(for: BesirRulesBundleToken.self)) -> BesirRules? {
        nil
    }
}

/// A class declared in the app, so `Bundle(for:)` finds the app bundle.
final class BesirRulesBundleToken {}
