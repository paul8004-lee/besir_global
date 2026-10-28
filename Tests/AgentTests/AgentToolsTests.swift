import XCTest
@testable import besir

/// AC-AGENT-002, declarations: exactly the four flat function tools of spec.md section 3.2.
@MainActor
final class AgentToolsTests: XCTestCase {
    // SPEC-AGENTPLACE-001: six tools; create_activity gains place_id and route_id, search_places and get_travel_time are new.
    private static let expectedParams: [String: [String]] = [
        "list_activities": ["from", "to"],
        "create_activity": ["title", "start", "end", "place_id", "route_id"],
        "update_activity": ["id", "title", "start", "end"],
        "delete_activity": ["id"],
        "search_places": ["query"],
        "get_travel_time": ["place_id", "mode", "origin_place_id", "arrive_by"],
        "request_booking": ["place_id", "start", "party_size"],
    ]
    private static let expectedRequired: [String: [String]] = [
        "list_activities": ["from", "to"],
        "create_activity": ["title", "start", "end"],
        "update_activity": ["id"],
        "delete_activity": ["id"],
        "search_places": ["query"],
        "get_travel_time": ["place_id", "mode"],
        "request_booking": ["place_id", "start", "party_size"],
    ]

    private func declarations() -> [[String: Any]] {
        let any = try? JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())
        return (any as? [[String: Any]]) ?? []
    }

    private func properties(_ decl: [String: Any]) -> [String: Any] {
        ((decl["parameters"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    }

    /// Names that must never be declared: anything that confirms, approves or forces a write, or carries a place.
    /// SPEC-AGENTPLACE-001: the handle names `place_id` and `origin_place_id` are the only allowed names with `place`.
    private func forbiddenNames(in names: [String]) -> [String] {
        let contains = ["confirm", "approv", "yes", "force", "skip", "authoriz", "accept", "location", "place",
                        "address", "coord", "latitude", "longitude", "geo"]
        let exact = ["lat", "lng", "lon"]
        let allowed = ["place_id", "origin_place_id"]
        return names.filter { name in
            let n = name.lowercased()
            if allowed.contains(n) { return false }
            return contains.contains { n.contains($0) } || exact.contains(n)
        }
    }

    func testAG002_ExactlyFourFlatFunctionTools() {
        // SPEC-AGENTPLACE-001 supersedes REQ-AGENT-005: six tools now (the name is kept for the SPEC-AGENT trace).
        let decls = declarations()
        XCTAssertEqual(decls.count, 7)
        XCTAssertEqual(decls.compactMap { $0["name"] as? String },
                       ["list_activities", "create_activity", "update_activity", "delete_activity",
                        "search_places", "get_travel_time", "request_booking"])
        for decl in decls {
            XCTAssertEqual(decl["type"] as? String, "function")
            // Flat: the name and the parameters sit at the top level, not under a "function" key.
            XCTAssertNil(decl["function"])
            XCTAssertNotNil(decl["name"] as? String)
            XCTAssertNotNil(decl["parameters"] as? [String: Any])
            XCTAssertEqual((decl["parameters"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testAG002_ParametersMatchArgumentContract() {
        // SPEC-AGENTPLACE-001: the contract covers six tools and the two new create_activity arguments.
        let decls = declarations()
        XCTAssertEqual(decls.count, 7)
        for decl in decls {
            let name = decl["name"] as? String ?? "?"
            let props = properties(decl)
            XCTAssertEqual(Set(props.keys), Set(Self.expectedParams[name] ?? ["missing tool"]), name)
            for (param, spec) in props {
                XCTAssertEqual((spec as? [String: Any])?["type"] as? String, "string", "\(name).\(param)")
            }
            let required = (decl["parameters"] as? [String: Any])?["required"] as? [String] ?? []
            XCTAssertEqual(Set(required), Set(Self.expectedRequired[name] ?? ["missing tool"]), name)
        }
    }

    func testAG002_NoConfirmLikeOrLocationParameter() {
        // SPEC-AGENTPLACE-001: "no location parameter" is superseded for handles only; `place` stays forbidden
        // except in exactly `place_id` and `origin_place_id`.
        let decls = declarations()
        // First: the six tools and at least one parameter each are present, so an empty declaration fails.
        XCTAssertEqual(decls.count, 7)
        var names: [String] = []
        for decl in decls {
            let params = Array(properties(decl).keys)
            XCTAssertFalse(params.isEmpty, "\(decl["name"] ?? "?") declares no parameter")
            names += params
        }
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(forbiddenNames(in: names), [])
        // The scan can fire: planted declarations that do contain such names.
        XCTAssertEqual(forbiddenNames(in: ["title", "start", "end", "confirm"]), ["confirm"])
        XCTAssertEqual(forbiddenNames(in: ["place_id", "origin_place_id", "route_id", "place_name", "placeholder"]),
                       ["place_name", "placeholder"])
        XCTAssertEqual(forbiddenNames(in: ["id", "approved", "force", "skip_confirmation", "location", "place_name"]).count, 5)
        XCTAssertEqual(forbiddenNames(in: ["id", "title", "start", "end", "from", "to"]), [])
    }

    func testAG002_DeclarationsEqualRecordedFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        // SPEC-AGENTPLACE-001: the fixture is the amended six declarations, so an empty fixture cannot match an empty encoding.
        XCTAssertEqual((recorded as? [Any])?.count, 7)
        let encoded = try JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())
        XCTAssertTrue((encoded as AnyObject).isEqual(recorded), "encoded declarations differ from Fixtures/tools.json")
    }

    /// The gate reads exactly the declared parameters: each declared one is read (a wrong type is refused naming it)
    /// and an undeclared key is not (a wrong type there changes nothing).
    /// SPEC-AGENTPLACE-001: the loop covers the four original tools, with the five-parameter create_activity; the two
    /// new lookup tools are skipped here because the baseline call helper expects a card or a list answer (they are
    /// covered by testAGPLACE_WrongTypeIsRefusedOnEveryNewParameter).
    func testAG002_GateReadSetEqualsDeclaredParameters() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let id = record.id.uuidString
        let valid: [String: [String: Any]] = [
            "list_activities": ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00"],
            "create_activity": ["title": "Team sync", "start": "2026-10-28T15:00", "end": "2026-10-28T16:00"],
            "update_activity": ["id": id, "title": "Renamed", "start": "2026-10-28T12:00", "end": "2026-10-28T13:00"],
            "delete_activity": ["id": id],
        ]
        let decls = declarations()
        XCTAssertEqual(decls.count, 7)
        var checked = 0
        for decl in decls {
            let tool = decl["name"] as? String ?? "?"
            if tool == "search_places" || tool == "get_travel_time" || tool == "request_booking" { continue }
            let base = valid[tool] ?? [:]
            XCTAssertFalse(base.isEmpty, tool)
            // The baseline call is accepted: a list answer or a card, never a rejection.
            let baseline = h.call(tool, base)
            XCTAssertTrue(baseline.accepted, "baseline \(tool)")
            for param in properties(decl).keys {
                var args = base
                args[param] = 5
                let outcome = h.call(tool, args)
                XCTAssertEqual(outcome.status, "rejected", "\(tool).\(param)")
                XCTAssertEqual(outcome.message, ToolText.wrongType(tool, param), "\(tool).\(param)")
                checked += 1
            }
            // An undeclared key with a wrong type is dropped before any rule runs.
            var extra = base
            extra["bogus"] = 5
            extra["duration"] = ["x"]
            let outcome = h.call(tool, extra)
            XCTAssertTrue(outcome.accepted, "undeclared key read by \(tool)")
        }
        XCTAssertEqual(checked, 12)
    }
}
