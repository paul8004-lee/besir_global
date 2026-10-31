import XCTest
@testable import besir

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class BookingSendRecorder {
    private(set) var requests: [URLRequest] = []
    var result: Result<(Data, Int), Error>
    /// Runs inside the send call, before the answer is handed back (for a task cancelled in flight).
    var duringSend: (() -> Void)?

    init(status: Int = 200, body: String = "") {
        result = .success((Data(body.utf8), status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var send: PartnerClient.Send {
        { [self] request in
            requests.append(request)
            duringSend?()
            switch result {
            case .success(let (data, status)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }
}

/// Answers by path, so one client can be driven through the directory and several routes. A path with no script gives 404.
final class PartnerRouteRecorder {
    private(set) var requests: [URLRequest] = []
    var bodies: [String: String]

    init(_ bodies: [String: String]) {
        self.bodies = bodies
    }

    var send: PartnerClient.Send {
        { [self] request in
            requests.append(request)
            let path = request.url?.path ?? String()
            let text = bodies[path]
            let response = HTTPURLResponse(url: request.url!, statusCode: text == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
            return (Data((text ?? "{}").utf8), response)
        }
    }

    func bodyText(_ index: Int) -> String {
        String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
    }
}

/// SPEC-BOOKCARD-001 AC-006 to AC-009: one client for every partner; the directory and the form are read from the proxy, only an
/// exact answer is accepted, and the exchange is drawn as packets that hold fixed words and the partner's name only. Every log is
/// built with a temporary file.
@MainActor
final class PartnerClientTests: XCTestCase {
    private let token = "partner-token-0001"
    private let host = "partner-host.invalid"
    private let flow = UUID()
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }

    private let entry = PartnerEntry(id: "booking", name: "Example Tables", title: "Reserve a table",
                                     summary: "Reserves a table at a restaurant.", route: "/booking")
    private let second = PartnerEntry(id: "second", name: "Second Partner", title: "Second request",
                                      summary: "Takes a second kind of request.", route: "/second")

    /// The form the sample partner announces: four required fields and one optional one.
    private var fieldList: [PartnerField] {
        [PartnerField(key: "restaurant", kind: .text, label: "Restaurant", options: []),
         PartnerField(key: "party_size", kind: .number, label: "Party size", options: []),
         PartnerField(key: "start", kind: .time, label: "Time", options: []),
         PartnerField(key: "name", kind: .text, label: "Name", options: []),
         PartnerField(key: "note", kind: .text, label: "Note", options: [], isOptional: true)]
    }

    private var announced: [PartnerResultSpec] {
        [PartnerResultSpec(name: "Booking time", kind: .time), PartnerResultSpec(name: "Reservation number", kind: .text),
         PartnerResultSpec(name: "Estimated cost", kind: .money), PartnerResultSpec(name: "Partner note", kind: .text)]
    }

    private var spec: PartnerSpec { PartnerSpec(entry: entry, fields: fieldList, results: announced) }

    private var items: [PartnerResultItem] {
        [PartnerResultItem(name: "Booking time", value: .time("2026-11-02T19:00")),
         PartnerResultItem(name: "Reservation number", value: .text("EX-AB12CD")),
         PartnerResultItem(name: "Estimated cost", value: .money(6000)),
         PartnerResultItem(name: "Partner note", value: .text("Table held for 15 minutes"))]
    }

    private var sample: PartnerRequest {
        PartnerRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B",
                       values: [.init(key: "restaurant", value: .text("Test Cafe")), .init(key: "party_size", value: .number(2)),
                                .init(key: "start", value: .text("2026-11-02T19:00")), .init(key: "name", value: .text("Sam"))])
    }

    // MARK: Helpers

    private func makeLog(failing: Bool = false) -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("partner-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        if failing { return (ConnectionLog(fileURL: file, write: { _, _ in throw WriteFailure() }), file) }
        return (ConnectionLog(fileURL: file, secrets: { [self] in [token, host] }), file)
    }

    private struct WriteFailure: Error {}

    private func client(_ send: @escaping PartnerClient.Send, log: ConnectionLog? = nil, config: AppConfig? = nil) -> PartnerClient {
        PartnerClient(config: config ?? self.config, send: send, connections: log ?? makeLog().log)
    }

    private func submit(_ recorder: BookingSendRecorder, request: PartnerRequest? = nil, log: ConnectionLog? = nil,
                        config: AppConfig? = nil) async -> Result<PartnerAnswer, PartnerFailure> {
        await client(recorder.send, log: log, config: config).submit(request ?? sample, to: spec, flow: flow)
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func resultObjects() -> [[String: Any]] {
        [["name": "Booking time", "kind": "time", "value": "2026-11-02T19:00"],
         ["name": "Reservation number", "kind": "text", "value": "EX-AB12CD"],
         ["name": "Estimated cost", "kind": "money", "value": 6000],
         ["name": "Partner note", "kind": "text", "value": "Table held for 15 minutes"]]
    }

    /// The submit answer the sample partner gives; `mutate` bends it.
    private func object(_ mutate: (inout [String: Any]) -> Void = { _ in }, declined: Bool = false) -> String {
        var fields: [String: Any] = ["status": declined ? "declined" : "confirmed", "partner": "Example Tables", "simulated": true]
        if declined { fields["reason"] = "no_table" } else { fields["results"] = resultObjects() }
        mutate(&fields)
        return json(fields)
    }

    private func fieldObject(_ field: PartnerField) -> [String: Any] {
        var object: [String: Any] = ["key": field.key, "kind": field.kind.rawValue, "label": field.label]
        if field.kind.hasOptions { object["options"] = field.options.map { ["id": $0.id, "label": $0.label] } }
        if field.isOptional { object["optional"] = true }
        return object
    }

    /// The form answer of a route; `mutate` bends it.
    private func formObject(partner: String = "Example Tables", fields: [PartnerField]? = nil,
                            _ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        var answer: [String: Any] = ["partner": partner, "simulated": true, "fields": (fields ?? fieldList).map(fieldObject),
                                     "result_fields": announced.map { ["name": $0.name, "kind": $0.kind.rawValue] }]
        mutate(&answer)
        return json(answer)
    }

    private func entryObject(_ entry: PartnerEntry, _ mutate: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var object: [String: Any] = ["id": entry.id, "name": entry.name, "title": entry.title, "summary": entry.summary, "route": entry.route]
        mutate(&object)
        return object
    }

    private func directoryObject(_ entries: [[String: Any]]) -> String { json(["partners": entries]) }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func assertOther(_ bodies: [String], file: StaticString = #filePath, line: UInt = #line) async {
        for text in bodies {
            let result = await submit(BookingSendRecorder(body: text))
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
        }
    }

    // MARK: F01 the directory and form requests

    func testPARTNER_F01_TheDirectoryAndFormRequestsAreFixedPostsAndNoProxyGivesNotSetUp() async throws {
        let recorder = PartnerRouteRecorder(["/partners": directoryObject([entryObject(entry), entryObject(second)]),
                                             "/booking": formObject(), "/second": formObject(partner: "Second Partner")])
        let (log, _) = makeLog()
        let partners = client(recorder.send, log: log)
        let listed = await partners.directory(flow: flow)
        XCTAssertEqual(listed, .success([entry, second]))
        let first = await partners.form(of: entry, flow: flow)
        XCTAssertEqual(first, .success(spec))
        let other = await partners.form(of: second, flow: flow)
        XCTAssertEqual(other, .success(PartnerSpec(entry: second, fields: fieldList, results: announced)))

        guard recorder.requests.count == 3 else { return XCTFail("expected three requests, saw \(recorder.requests.count)") }
        for (index, (path, text)) in [("/partners", #"{"op":"list"}"#), ("/booking", #"{"op":"fields"}"#), ("/second", #"{"op":"fields"}"#)].enumerated() {
            let sent = recorder.requests[index]
            XCTAssertEqual(sent.httpMethod, "POST")
            XCTAssertEqual(sent.url?.path, path)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(recorder.bodyText(index), text)
            XCTAssertEqual(sent.timeoutInterval, 20)
        }
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Partners requested", "partner>besir partner ok Partners received",
                                    "besir>partner partner ok Example Tables: Fields requested",
                                    "partner>besir partner ok Example Tables: Fields received",
                                    "besir>partner partner ok Second Partner: Fields requested",
                                    "partner>besir partner ok Second Partner: Fields received"])
        XCTAssertEqual(Set(log.packets.map(\.flowID)), [flow])

        // No proxy: nothing is called and nothing is recorded.
        let (quiet, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let idle = PartnerRouteRecorder(["/partners": directoryObject([entryObject(entry)]), "/booking": formObject()])
            let unset = client(idle.send, log: quiet, config: blank)
            let listing = await unset.directory(flow: flow)
            let form = await unset.form(of: entry, flow: flow)
            XCTAssertEqual(listing, .failure(.notSetUp))
            XCTAssertEqual(form, .failure(.notSetUp))
            XCTAssertTrue(idle.requests.isEmpty)
        }
        await quiet.flush()
        XCTAssertTrue(quiet.packets.isEmpty)
    }

    // MARK: F02 the directory answer

    func testPARTNER_F02_OnlyTheExactDirectoryAnswerIsAcceptedAndOneDefectFailsTheWholeDirectory() async throws {
        func listed(_ entries: [[String: Any]]) -> Data { Data(directoryObject(entries).utf8) }
        let many = (0..<8).map { index in
            entryObject(PartnerEntry(id: "p\(index)", name: "Partner \(index)", title: "Title \(index)", summary: "Summary \(index)", route: "/r\(index)"))
        }
        // Positive first: one entry and eight entries decode, in the proxy's order.
        XCTAssertEqual(PartnerEntry.list(from: listed([entryObject(entry)])), [entry])
        XCTAssertEqual(PartnerEntry.list(from: listed(many))?.map(\.id), (0..<8).map { "p\($0)" })
        // The edges: a 33-character route, a 24-character id, a 40-character name and title, a 120-character summary.
        let edge = PartnerEntry(id: "a" + String(repeating: "b", count: 23), name: String(repeating: "N", count: 40),
                                title: String(repeating: "T", count: 40), summary: String(repeating: "S", count: 120),
                                route: "/a" + String(repeating: "b", count: 31))
        XCTAssertEqual(edge.route.count, 33)
        XCTAssertEqual(PartnerEntry.list(from: listed([entryObject(edge)])), [edge])
        XCTAssertEqual(PartnerEntry.list(from: listed([entryObject(entry) { $0["route"] = "/a-b-9" }]))?.first?.route, "/a-b-9")

        func with(_ key: String, _ value: Any) -> [String: Any] { entryObject(entry) { $0[key] = value } }
        let hidden = ["A\tB", "A\nB", "A\u{200B}B", "A\u{2028}B", "A\u{2029}B", "A\u{202E}B"]
        var cases: [(String, Data)] = [
            ("a second key", Data(json(["partners": [entryObject(entry)], "more": 1]).utf8)),
            ("no partners key", Data(json(["list": [entryObject(entry)]]).utf8)),
            ("partners not a list", Data(json(["partners": entryObject(entry)]).utf8)),
            ("zero entries", listed([])),
            ("nine entries", listed(many + [entryObject(PartnerEntry(id: "p8", name: "Partner 8", title: "T", summary: "S", route: "/r8"))])),
            ("a repeated id", listed([entryObject(entry), entryObject(second) { $0["id"] = "booking" }])),
            ("a repeated route", listed([entryObject(entry), entryObject(second) { $0["route"] = "/booking" }])),
            ("the route of the directory", listed([with("route", "/partners")])),
            ("a route with an upper-case letter", listed([with("route", "/Booking")])),
            ("a route with no slash", listed([with("route", "booking")])),
            ("a route of 34 characters", listed([with("route", "/a" + String(repeating: "b", count: 32))])),
            ("a route that is only a slash", listed([with("route", "/")])),
            ("a route starting with a digit", listed([with("route", "/1abc")])),
            ("a route with a space", listed([with("route", "/a b")])),
            ("a route with a second slash", listed([with("route", "/a/b")])),
            ("a route with a dot", listed([with("route", "/a.b")])),
            ("a route not a string", listed([with("route", 5)])),
            ("an id with an upper-case letter", listed([with("id", "Booking")])),
            ("an id of 25 characters", listed([with("id", "a" + String(repeating: "b", count: 24))])),
            ("an empty id", listed([with("id", "")])), ("an id starting with a digit", listed([with("id", "1abc")])),
            ("an id with a dash", listed([with("id", "a-b")])), ("an id not a string", listed([with("id", 1)])),
            ("a name of 41 characters", listed([with("name", String(repeating: "N", count: 41))])),
            ("an empty name", listed([with("name", "")])),
            ("a non-ASCII name", listed([with("name", "Caf\u{00E9}")])), ("a name with a newline", listed([with("name", "A\nB")])),
            ("a name not a string", listed([with("name", 7)])),
            ("a title of 41 characters", listed([with("title", String(repeating: "T", count: 41))])),
            ("an empty title", listed([with("title", "")])),
            ("a summary of 121 characters", listed([with("summary", String(repeating: "S", count: 121))])),
            ("an empty summary", listed([with("summary", "")])),
            ("an extra key in an entry", listed([with("hint", "x")])),
            ("a missing key in an entry", listed([entryObject(entry) { $0.removeValue(forKey: "summary") }])),
            ("an entry that is not an object", Data(json(["partners": ["booking"]]).utf8)),
            ("one bad entry among good ones", listed([entryObject(entry), with("route", "/Bad"), entryObject(second)])),
            ("not JSON", Data("not json".utf8)), ("an empty body", Data()), ("an array", Data("[]".utf8)),
        ]
        for text in hidden {
            cases.append(("a title with a hidden character", listed([with("title", text)])))
            cases.append(("a summary with a hidden character", listed([with("summary", text)])))
        }
        for (name, data) in cases { XCTAssertNil(PartnerEntry.list(from: data), name) }

        // Through the client a defect is `other` and records one failed packet.
        for (name, data) in cases.prefix(8) {
            let (log, _) = makeLog()
            let result = await client(BookingSendRecorder(body: String(decoding: data, as: UTF8.self)).send, log: log).directory(flow: flow)
            XCTAssertEqual(result, .failure(.other), name)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"], name)
        }
        let accepted = await client(BookingSendRecorder(body: directoryObject([entryObject(entry)])).send).directory(flow: flow)
        XCTAssertEqual(accepted, .success([entry]))
    }

    // MARK: F03 the form answer is accepted whatever the shape

    func testPARTNER_F03_AFormAnswerOfAnyShapeIsAcceptedWhenItObeysTheGrammar() async throws {
        let (log, _) = makeLog()
        func read(_ fields: [PartnerField], _ mutate: (inout [String: Any]) -> Void = { _ in }) async -> Result<PartnerSpec, PartnerFailure> {
            await client(BookingSendRecorder(body: formObject(fields: fields, mutate)).send, log: log).form(of: entry, flow: flow)
        }
        let all = fieldList
        // The sample form, a reordered list, a shorter one, one with no `time` field, one with a `place` field, one with a
        // `number` field and an `optional` field.
        let place = PartnerField(key: "where_to", kind: .place, label: "Where", options: [])
        let pick = PartnerField(key: "size", kind: .pickOne, label: "Size", options: [PartnerOption(id: "small", label: "Small")], isOptional: true)
        let shapes: [[PartnerField]] = [all, all.reversed(), [all[0]], all.filter { $0.kind != .time }, [place] + all, [all[1], all[4]], [pick, place]]
        for shape in shapes {
            let result = await read(shape)
            XCTAssertEqual(result, .success(PartnerSpec(entry: entry, fields: shape, results: announced)), shape.map(\.key).joined(separator: ","))
        }
        let sized = await read([all[1], all[4]])
        XCTAssertEqual(try sized.get().fields.map(\.kind), [.number, .text])
        XCTAssertEqual(try sized.get().fields.map(\.isOptional), [false, true])
        await log.flush()
        XCTAssertEqual(lines(log).count, shapes.count * 2 + 2)
        XCTAssertEqual(Array(lines(log).prefix(2)), ["besir>partner partner ok Example Tables: Fields requested",
                                                     "partner>besir partner ok Example Tables: Fields received"])
        XCTAssertTrue(lines(log).allSatisfy { $0.hasPrefix("besir>partner partner ok Example Tables: Fields") || $0.hasPrefix("partner>besir partner ok Example Tables: Fields") })
    }

    // MARK: F04 a defect makes a form unusable

    func testPARTNER_F04_EachFormDefectMakesTheFormUnusableAndAFailingEntryIsLeftOutOfTheOthers() async throws {
        // Positive first.
        let good = await client(BookingSendRecorder(body: formObject()).send).form(of: entry, flow: flow)
        XCTAssertEqual(good, .success(spec))

        let nine = (0..<9).map { ["name": "N\($0)", "kind": "text"] }
        let bodies: [(String, String)] = [
            ("no field list", formObject { $0.removeValue(forKey: "fields") }),
            ("no result list", formObject { $0.removeValue(forKey: "result_fields") }),
            ("an extra top-level key", formObject { $0["more"] = 1 }),
            ("a field defect: optional false", formObject { $0["fields"] = [["key": "a", "kind": "text", "label": "A", "optional": false]] }),
            ("a field defect: optional on a switch", formObject {
                $0["fields"] = [["key": "a", "kind": "on_off", "label": "A", "options": [["id": "true", "label": "On"], ["id": "false", "label": "Off"]],
                                 "optional": true]]
            }),
            ("a field defect: a number with options", formObject {
                $0["fields"] = [["key": "a", "kind": "number", "label": "A", "options": [["id": "x", "label": "X"]]]]
            }),
            ("a field defect: zero fields", formObject { $0["fields"] = [Any]() }),
            ("a result defect: nine items", formObject { $0["result_fields"] = nine }),
            ("a result defect: a value key", formObject { $0["result_fields"] = [["name": "A", "kind": "text", "value": "x"]] }),
            ("a result defect: a second time", formObject { $0["result_fields"] = [["name": "A", "kind": "time"], ["name": "B", "kind": "time"]] }),
            ("a result defect: zero items", formObject { $0["result_fields"] = [Any]() }),
            ("simulated false", formObject { $0["simulated"] = false }),
            ("simulated missing", formObject { $0.removeValue(forKey: "simulated") }),
            ("a wrong partner name", formObject(partner: "Real Tables")),
            ("a partner name in another case", formObject(partner: "example tables")),
            ("a missing partner name", formObject { $0.removeValue(forKey: "partner") }),
            ("not JSON", "not json"), ("an array", "[]"),
        ]
        for (name, text) in bodies {
            let (log, _) = makeLog()
            let result = await client(BookingSendRecorder(body: text).send, log: log).form(of: entry, flow: flow)
            XCTAssertEqual(result, .failure(.other), name)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"], name)
        }
        for status in [201, 400, 404, 500] {
            let result = await client(BookingSendRecorder(status: status, body: formObject()).send).form(of: entry, flow: flow)
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }

        // A failing entry among good ones is left out and the others are kept: the lookup keeps the forms that came back.
        let third = PartnerEntry(id: "third", name: "Third Partner", title: "Third request", summary: "Takes a third kind.", route: "/third")
        let recorder = PartnerRouteRecorder(["/booking": formObject(), "/second": formObject(partner: "Wrong Name"),
                                             "/third": formObject(partner: "Third Partner")])
        let partners = client(recorder.send)
        var kept: [PartnerSpec] = []
        for candidate in [entry, second, third] {
            if case .success(let form) = await partners.form(of: candidate, flow: flow) { kept.append(form) }
        }
        XCTAssertEqual(kept.map(\.entry.id), ["booking", "third"])
    }

    // MARK: F05 the submit request

    func testPARTNER_F05_TheSubmitBodyIsTheThreeKeysWithEachValueTypedByItsKindAndNoPacketHoldsAValue() async throws {
        let request = PartnerRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B", values: [
            .init(key: "restaurant", value: .text("SENTINEL-TEXT-731")), .init(key: "party_size", value: .number(4)),
            .init(key: "start", value: .text("2031-02-03T04:05")), .init(key: "size", value: .text("sentinel-option-731")),
            .init(key: "door", value: .flag(true)), .init(key: "where_to", value: .text("SENTINEL-PLACE-731"))])
        let (log, file) = makeLog()
        let recorder = BookingSendRecorder(body: object())
        let result = await client(recorder.send, log: log).submit(request, to: spec, flow: flow)
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/booking")
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        let sentBody = try body(of: sent)
        XCTAssertEqual(Set(sentBody.keys), ["op", "request_id", "values"])
        XCTAssertEqual(sentBody["op"] as? String, "submit")
        XCTAssertEqual(sentBody["request_id"] as? String, request.requestID)
        let values = try XCTUnwrap(sentBody["values"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), ["restaurant", "party_size", "start", "size", "door", "where_to"])
        XCTAssertEqual(values["restaurant"] as? String, "SENTINEL-TEXT-731")
        XCTAssertEqual(values["where_to"] as? String, "SENTINEL-PLACE-731")
        XCTAssertEqual(values["start"] as? String, "2031-02-03T04:05")
        XCTAssertEqual(values["size"] as? String, "sentinel-option-731")
        // A number and a boolean are JSON numbers and booleans, not text.
        XCTAssertTrue(text.contains(#""party_size":4"#), text)
        XCTAssertTrue(text.contains(#""door":true"#), text)

        // A blank optional field has no entry: the sample request holds no `note`.
        let plain = BookingSendRecorder(body: object())
        _ = await submit(plain)
        let plainValues = try XCTUnwrap(body(of: XCTUnwrap(plain.requests.first))["values"] as? [String: Any])
        XCTAssertNil(plainValues["note"])
        XCTAssertEqual(Set(plainValues.keys), ["restaurant", "party_size", "start", "name"])

        // The packets are the partner's name and fixed words; no value is in any of them or in the file.
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Example Tables: Request sent", "partner>besir partner ok Example Tables: Request confirmed"])
        let stored = try String(contentsOf: file, encoding: .utf8).lowercased()
        for secret in ["sentinel", "2031", "04:05", "4:05", "party_size", "door", "where_to", token, host, request.requestID.lowercased()] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
            XCTAssertFalse(lines(log).joined().lowercased().contains(secret), "a packet holds \(secret)")
        }
    }

    // MARK: F06 the submit answer is checked against the announcement

    func testPARTNER_F06_TheSubmitAnswerIsAcceptedOnlyWhenItMatchesTheAnnouncementAndTheEntry() async throws {
        // Positive first: the announced items, and a declined answer, are accepted.
        let confirmed = await submit(BookingSendRecorder(body: object()))
        XCTAssertEqual(confirmed, .success(.confirmed(results: items)))
        let declined = await submit(BookingSendRecorder(body: object(declined: true)))
        XCTAssertEqual(declined, .success(.declined))

        func results(_ mutate: (inout [[String: Any]]) -> Void) -> String {
            object { fields in
                var list = resultObjects()
                mutate(&list)
                fields["results"] = list
            }
        }
        let confirmedBodies: [(String, String)] = [
            ("another partner name", object { $0["partner"] = "Second Partner" }),
            ("simulated false", object { $0["simulated"] = false }),
            ("a different count: three items", results { $0.removeLast() }),
            ("a different count: five items", results { $0.append(["name": "Extra", "kind": "text", "value": "x"]) }),
            ("a different order", results { $0.swapAt(0, 1) }),
            ("a different name", results { $0[1]["name"] = "Confirmation number" }),
            ("a different kind", results { $0[3]["kind"] = "text"; $0[0]["kind"] = "text" }),
            ("a second money item", results { $0.append(["name": "Tip", "kind": "money", "value": 300]) }),
            ("the time item as text", results { $0[0] = ["name": "Booking time", "kind": "text", "value": "tonight"] }),
            ("a money value of zero", results { $0[2]["value"] = 0 }),
            ("a time that is not real", results { $0[0]["value"] = "2026-02-31T19:00" }),
            ("nine items", object { $0["results"] = (0..<9).map { ["name": "N\($0)", "kind": "text", "value": "x"] } }),
            ("a missing results list", object { $0.removeValue(forKey: "results") }),
            ("an empty results list", object { $0["results"] = [Any]() }),
            ("a code key", object { $0["reservation_code"] = "EX-AB12CD" }),
            ("a reason key beside results", object { $0["reason"] = "no_table" }),
        ]
        let declinedBodies: [(String, String)] = [
            ("another partner name", object({ $0["partner"] = "Second Partner" }, declined: true)),
            ("simulated false", object({ $0["simulated"] = false }, declined: true)),
            ("results on a decline", object({ $0["results"] = resultObjects() }, declined: true)),
            ("a missing reason", object({ $0.removeValue(forKey: "reason") }, declined: true)),
            ("a reason in upper case", object({ $0["reason"] = "NO_TABLE" }, declined: true)),
            ("a reason with a dash", object({ $0["reason"] = "no-table" }, declined: true)),
            ("a reason with a digit", object({ $0["reason"] = "full2" }, declined: true)),
            ("an empty reason", object({ $0["reason"] = "" }, declined: true)),
            ("a reason of 41 characters", object({ $0["reason"] = String(repeating: "a", count: 41) }, declined: true)),
            ("a reason that is not a string", object({ $0["reason"] = 1 }, declined: true)),
        ]
        for (name, text) in confirmedBodies + declinedBodies {
            let (log, _) = makeLog()
            let result = await submit(BookingSendRecorder(body: text), log: log)
            XCTAssertEqual(result, .failure(.other), name)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"], name)
        }
        // The decline reason is a word of `a-z` and `_`, 1 to 40 characters; any such word is accepted and then dropped.
        for reason in ["closed", "no_table", "a", "full_for_the_evening", String(repeating: "z", count: 40)] {
            let result = await submit(BookingSendRecorder(body: object({ $0["reason"] = reason }, declined: true)))
            XCTAssertEqual(result, .success(.declined), reason)
        }
    }

    // MARK: C01-C04 the request

    func testPARTNER_C01_RequestIsAPostToTheEntrysRouteWithTokenAndJson() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await submit(recorder)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/booking")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Another entry's route is the path it is sent to.
        let other = BookingSendRecorder(body: object())
        _ = await client(other.send).submit(sample, to: PartnerSpec(entry: second, fields: fieldList, results: announced), flow: flow)
        XCTAssertEqual(other.requests.first?.url?.path, "/second")
    }

    func testPARTNER_C02_BodyHasExactlyTheThreeKeysAndTheRequestValues() async throws {
        let recorder = BookingSendRecorder(body: object())
        let result = await submit(recorder)
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        let sent = try body(of: XCTUnwrap(recorder.requests.first))
        XCTAssertEqual(Set(sent.keys), ["op", "request_id", "values"])
        XCTAssertEqual(sent["op"] as? String, "submit")
        XCTAssertEqual(sent["request_id"] as? String, sample.requestID)
        let values = try XCTUnwrap(sent["values"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), ["restaurant", "party_size", "start", "name"])
        XCTAssertEqual(values["restaurant"] as? String, "Test Cafe")
        XCTAssertEqual(values["party_size"] as? Int, 2)
        XCTAssertEqual(values["start"] as? String, "2026-11-02T19:00")
        XCTAssertEqual(values["name"] as? String, "Sam")
    }

    func testPARTNER_C03_BodyHoldsNothingFromTheConfigurationAndNoKeyBeyondTheThree() async throws {
        var loud = config
        loud.proxyBaseURL = "https://sentinel-host-777.invalid"
        loud.appToken = "sentinel-token-777"
        loud.kakaoJsKey = "sentinel-kakao-777"
        let recorder = BookingSendRecorder(body: object())
        let result = await submit(recorder, config: loud)
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        let data = try XCTUnwrap(recorder.requests.first?.httpBody)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["sentinel", "latitude", "longitude", "timezone", "place_id", "placeid", "address", "phone", "email"] {
            XCTAssertFalse(text.contains(word), "the body holds \(word)")
        }
        XCTAssertEqual(Set(try body(of: XCTUnwrap(recorder.requests.first)).keys).count, 3)
    }

    func testPARTNER_C04_NoProxyGivesNotSetUpWithoutACallOrAPacket() async {
        let (log, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let recorder = BookingSendRecorder(body: object())
            let result = await submit(recorder, log: log, config: blank)
            XCTAssertEqual(result, .failure(.notSetUp))
            XCTAssertTrue(recorder.requests.isEmpty)
        }
        XCTAssertFalse(client(BookingSendRecorder().send, config: AppConfig()).isConfigured)
        XCTAssertTrue(client(BookingSendRecorder().send).isConfigured)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
    }

    // MARK: C05-C14 the answer is checked

    func testPARTNER_C05_AConfirmedAnswerGivesTheAnnouncedItems() async {
        let result = await submit(BookingSendRecorder(body: object()))
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        if case .success(.confirmed(let got)) = result {
            XCTAssertEqual(got.map(\.name), announced.map(\.name))
            XCTAssertEqual(got.map(\.kind), announced.map(\.kind))
            XCTAssertEqual(got.moneyCents, 6000)
        } else {
            XCTFail("not confirmed")
        }
    }

    func testPARTNER_C06_ADeclinedAnswerGivesDeclined() async {
        let result = await submit(BookingSendRecorder(body: object(declined: true)))
        XCTAssertEqual(result, .success(.declined))
    }

    func testPARTNER_C07_AConfirmedAnswerThatDeviatesIsOther() async {
        let accepted = await submit(BookingSendRecorder(body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(results: items)))
        var bodies: [String] = []
        bodies.append(object { $0["results"] = "EX-AB12CD" })
        bodies.append(object { $0["results"] = NSNull() })
        bodies.append(object { $0["reservation_code"] = "EX-AB12CD" })
        bodies.append(object { $0["reason"] = "no_table" })
        bodies.append(object { $0["status"] = "pending" })
        bodies.append(object { $0["status"] = "CONFIRMED" })
        bodies.append(object { $0.removeValue(forKey: "status") })
        bodies.append(object { $0["status"] = true })
        bodies.append(object { $0["results"] = [["name": "Booking time", "kind": "time"]] })
        bodies.append(object { var list = self.resultObjects(); list[2]["value"] = "6000"; $0["results"] = list })
        await assertOther(bodies)
    }

    func testPARTNER_C08_ADeclinedAnswerThatDeviatesIsOther() async {
        let accepted = await submit(BookingSendRecorder(body: object({ $0["reason"] = "closed" }, declined: true)))
        XCTAssertEqual(accepted, .success(.declined))
        var bodies: [String] = []
        bodies.append(object({ $0["reservation_code"] = "EX-AB12CD" }, declined: true))
        bodies.append(object({ $0.removeValue(forKey: "reason") }, declined: true))
        bodies.append(object({ $0["reason"] = "NO_TABLE" }, declined: true))
        bodies.append(object({ $0["reason"] = 1 }, declined: true))
        bodies.append(object({ $0["reason"] = "no table" }, declined: true))
        await assertOther(bodies)
    }

    func testPARTNER_C09_APartnerThatIsWrongOrMissingIsOther() async {
        await assertOther([
            object { $0["partner"] = "Real Tables" },
            object { $0["partner"] = "example tables" },
            object { $0["partner"] = "Example Tables " },
            object { $0.removeValue(forKey: "partner") },
            object { $0["partner"] = 5 },
        ])
    }

    func testPARTNER_C10_SimulatedThatIsNotTrueIsOther() async {
        await assertOther([
            object { $0["simulated"] = false },
            object { $0.removeValue(forKey: "simulated") },
            object { $0["simulated"] = "true" },
            object { $0["simulated"] = 1 },
            object { $0["simulated"] = NSNull() },
        ])
    }

    func testPARTNER_C11_AMissingKeyOrAWrongTypeAmongTheFourKeysIsOther() async {
        let accepted = await submit(BookingSendRecorder(body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(results: items)))
        await assertOther([
            object { $0.removeValue(forKey: "status") },
            object { $0.removeValue(forKey: "partner") },
            object { $0.removeValue(forKey: "simulated") },
            object { $0.removeValue(forKey: "results") },
            object { $0["status"] = 7 },
            object { $0["partner"] = NSNull() },
            object { $0["simulated"] = "yes" },
            object { $0["results"] = 4 },
            object { $0["results"] = ["name": "Booking time"] },
        ])
    }

    func testPARTNER_C13_AnExtraKeyIsOther() async {
        let accepted = await submit(BookingSendRecorder(body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(results: items)))
        await assertOther([
            object { $0["name"] = "x" },
            object { $0["note"] = NSNull() },
            object({ $0["extra"] = 1 }, declined: true),
        ])
    }

    func testPARTNER_C14_ANonObjectBodyOrAStatusOtherThan200IsOther() async {
        await assertOther(["[]", "null", "\"confirmed\"", "5", "", "not json", "{}"])
        for status in [201, 202, 204, 302, 400, 404, 500, 503] {
            let result = await submit(BookingSendRecorder(status: status, body: object()))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        // Positive counterpart: the same body at 200 is accepted.
        let accepted = await submit(BookingSendRecorder(status: 200, body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(results: items)))
    }

    // MARK: C15-C20 failures

    func testPARTNER_C15_ATokenRejectionIsOnlyTheWorkersOwnBody() async {
        let own = await submit(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, "", "unauthorized", "[]"] {
            let other = await submit(BookingSendRecorder(status: 401, body: text))
            XCTAssertEqual(other, .failure(.other), text)
        }
        // The same handling serves the directory and the form.
        let listing = await client(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#).send).directory(flow: flow)
        XCTAssertEqual(listing, .failure(.tokenRejected))
        let form = await client(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#).send).form(of: entry, flow: flow)
        XCTAssertEqual(form, .failure(.tokenRejected))
    }

    func testPARTNER_C16_A404AndA500AreOther() async {
        for status in [404, 500] {
            let result = await submit(BookingSendRecorder(status: status, body: #"{"error":"not_found"}"#))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
    }

    func testPARTNER_C17_AnOfflineErrorIsOfflineAndAnotherErrorIsOther() async {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let result = await submit(BookingSendRecorder(error: URLError(code)))
            XCTAssertEqual(result, .failure(.offline), "\(code)")
        }
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), WriteFailure()] as [Error] {
            let result = await submit(BookingSendRecorder(error: error))
            XCTAssertEqual(result, .failure(.other), "\(error)")
        }
    }

    func testPARTNER_C18_TheTimeoutIsTwentySeconds() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await submit(recorder)
        XCTAssertEqual(try XCTUnwrap(recorder.requests.first).timeoutInterval, 20)
    }

    func testPARTNER_C19_ACancelledTaskReturnsAndRecordsNothing() async {
        // Cancelled before the call: nothing is sent.
        let (before, _) = makeLog()
        let early = BookingSendRecorder(body: object())
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await submit(early, log: before)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)
        await before.flush()
        XCTAssertTrue(before.packets.isEmpty)

        // Cancelled while the request is in flight, with a valid confirmation coming back.
        let (during, _) = makeLog()
        let inFlight = BookingSendRecorder(body: object())
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightResult = await Task { await submit(inFlight, log: during) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(inFlight.requests.count, 1)
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty)
    }

    func testPARTNER_C20_AFailureHoldsNoTextOfTheAnswer() async {
        let leak = "LEAK-SENTINEL-99"
        let (log, file) = makeLog()
        let deviating = object {
            var list = self.resultObjects()
            list[1]["value"] = leak
            $0["results"] = list
            $0["note"] = leak
        }
        for status in [200, 401, 404, 500] {
            let result = await submit(BookingSendRecorder(status: status, body: deviating), log: log)
            guard case .failure(let failure) = result else { return XCTFail("status \(status) is not a failure") }
            XCTAssertEqual(String(describing: failure), "other", "a failure is a bare case")
        }
        await log.flush()
        XCTAssertFalse(lines(log).joined().contains(leak))
        XCTAssertFalse(((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(leak))
    }

    // MARK: L01-L02 the log cases

    func testPARTNER_L01_ThePartnerCasesHaveEnglishNamesAndTheDefaultSummary() {
        XCTAssertEqual(ConnectionParty.partner.rawValue, "partner")
        XCTAssertEqual(ConnectionKind.partner.rawValue, "partner")
        XCTAssertEqual(ConnectionParty.partner.displayName, "Partner (Simulated)")
        XCTAssertEqual(ConnectionKind.partner.displayName, "Partner")
        XCTAssertEqual(ConnectionKind.partner.defaultSummary, "Partner request")
        for text in [ConnectionParty.partner.displayName, ConnectionKind.partner.displayName, ConnectionKind.partner.defaultSummary] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // The delivery and budget cases stay, and every earlier case keeps its raw value and name.
        XCTAssertEqual(ConnectionParty.deliveryPartner.rawValue, "deliveryPartner")
        XCTAssertEqual(ConnectionParty.budgetPartner.rawValue, "budgetPartner")
        XCTAssertEqual(ConnectionKind.delivery.rawValue, "delivery")
        XCTAssertEqual(ConnectionKind.budget.rawValue, "budget")
        XCTAssertEqual(ConnectionParty.appleCalendar.rawValue, "appleCalendar")
        XCTAssertEqual(ConnectionParty.museSpark.displayName, "Muse Spark")
        XCTAssertEqual(ConnectionKind.calendarSave.defaultSummary, "Event saved")
    }

    func testPARTNER_L02_APartnerPacketLoadsAndTheRemovedAndUnknownCasesDropThatPacketAlone() throws {
        let file = makeLog().file
        func packet(_ at: Double, from: ConnectionParty = .besir, to: ConnectionParty = .partner) -> ConnectionPacket {
            ConnectionPacket(id: UUID(), flowID: flow, at: Date(timeIntervalSince1970: at), from: from, to: to, kind: .partner,
                             summary: "Example Tables: Request sent", status: .ok)
        }
        let good = packet(100)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([good, packet(200), packet(300), packet(400)])) as? [[String: Any]])
        objects[1]["from"] = "bookingPartner"
        objects[2]["kind"] = "booking"
        objects[3]["from"] = "carrierPigeon"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: file)
        let loaded = ConnectionLog(fileURL: file)
        XCTAssertEqual(loaded.packets, [good])
    }

    // MARK: P01-P03, P05, P06, P08 the packets

    func testPARTNER_P01_AConfirmationRecordsTwoPacketsInOrderWithOneFlow() async {
        let (log, _) = makeLog()
        _ = await submit(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Example Tables: Request sent",
                                    "partner>besir partner ok Example Tables: Request confirmed"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testPARTNER_P02_ADeclineRecordsRequestDeclinedAsDeclined() async {
        let (log, _) = makeLog()
        let big = PartnerRequest(requestID: sample.requestID, values: [.init(key: "party_size", value: .number(9))])
        _ = await submit(BookingSendRecorder(body: object(declined: true)), request: big, log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Example Tables: Request sent",
                                    "partner>besir partner declined Example Tables: Request declined"])
    }

    func testPARTNER_P03_AFailureRecordsOneRequestFailedPacket() async {
        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: object { $0["partner"] = "Real Tables" })]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await submit(recorder, log: log)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"])
            XCTAssertEqual(log.packets.first?.flowID, flow)
        }
    }

    private func makeRig(config: AppConfig = PlaceSentinel.config, partner: StubPartner = StubPartner(),
                         failingLog: Bool = false) -> PartnerRig {
        let rig = PartnerRig(config: config, partner: partner, failingLog: failingLog)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    func testPARTNER_P04_CancelNoProxyAndACancelledTaskRecordNoRequestPacket() async throws {
        // Cancel: the lookup's four packets exist, the request has none.
        let cancelRig = makeRig()
        let cancelCard = await cancelRig.card()
        _ = await cancelCard?.resolve(.cancel)
        // No proxy: the gate refuses before any card exists.
        let blankRig = makeRig(config: PlaceSentinel.unconfigured)
        let blankCard = await blankRig.card()
        XCTAssertNil(blankCard)
        // A task cancelled while the request is in flight.
        let flightRig = makeRig()
        let flightBuilt = await flightRig.card()
        let card = try XCTUnwrap(flightBuilt)
        flightRig.partner.mode = .cancel
        _ = await Task { await card.resolve(.confirm) }.value
        XCTAssertEqual(flightRig.partner.bodies(op: "submit").count, 1)
        for rig in [cancelRig, flightRig] {
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.count, 4, "the lookup only")
            XCTAssertEqual(rig.partner.requests.count, rig === flightRig ? 3 : 2)
        }
        await blankRig.log.flush()
        XCTAssertTrue(blankRig.log.packets.isEmpty)
        XCTAssertEqual(blankRig.partner.requests.count, 0)
        // Positive counterpart: a confirmed request does record.
        let doneRig = makeRig()
        let doneCard = await doneRig.card()
        _ = await doneCard?.resolve(.confirm)
        await doneRig.log.flush()
        XCTAssertEqual(doneRig.log.packets.count, 6)
    }

    func testPARTNER_P07_ALogThatCannotWriteChangesNothingTheUserOrTheModelSees() async throws {
        /// Everything a request shows, except the random ids. `failure` is set after the card is built.
        func shown(_ rig: PartnerRig, failure: Error? = nil) async throws -> String {
            let built = await rig.card()
            let card = try XCTUnwrap(built)
            if let failure { rig.partner.mode = .error(failure) }
            let resolved = await card.resolve(.confirm)
            let resolution = try XCTUnwrap(resolved)
            var json = resolution.json ?? [:]
            json.removeValue(forKey: "id")
            let result = String(decoding: (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            let entries = rig.store.activities.map { "\($0.title)|\($0.startDate)|\($0.endDate)|\($0.location?.name ?? "")" }
            return [result, card.mark?.rawValue ?? "pending", resolution.notice ?? "no notice"].joined(separator: "\n") + "\n" + entries.joined(separator: "\n")
        }
        let healthy = try await shown(makeRig())
        let broken = try await shown(makeRig(failingLog: true))
        XCTAssertEqual(healthy, broken)
        XCTAssertTrue(healthy.contains("applied"))

        let offline = URLError(.notConnectedToInternet)
        let failedHealthy = try await shown(makeRig(), failure: offline)
        let failedBroken = try await shown(makeRig(failingLog: true), failure: offline)
        XCTAssertEqual(failedHealthy, failedBroken)
        XCTAssertTrue(failedHealthy.contains("unavailable"))
    }

    func testPARTNER_P09_ARequestDoesNotChangeTheFlowOfTheAgentMessagePackets() async throws {
        let rig = makeRig()
        let first = Turns.call("get_partners", "{}", id: "c0")
        let second = Turns.call("request_partner", PlaceTurns.arguments(PartnerRig.arguments()), id: "c1")
        let fake = FakeTransport([.turn(Turns.turn(first)), .turn(Turns.turn(second)), .turn(Turns.text("Booked, and it is simulated."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send(PartnerRig.parts(.init()).line)
        await session.settle()
        XCTAssertNotNil(session.pendingCard)
        await session.confirmCard()
        await session.settle()
        await rig.log.flush()
        let agentFlows = Set(rig.log.packets.filter { $0.kind == .agentMessage || $0.kind == .agentToolCall }.map(\.flowID))
        let lookupFlows = Set(rig.log.packets.filter { $0.kind == .partner && !$0.summary.contains("Request") }.map(\.flowID))
        let requestFlows = Set(rig.log.packets.filter { $0.kind == .partner && $0.summary.contains("Request") }.map(\.flowID))
        XCTAssertEqual(agentFlows.count, 1, "the agent's packets stay in one flow")
        XCTAssertNotNil(agentFlows.first ?? nil)
        XCTAssertEqual(lookupFlows, agentFlows, "the lookup runs under the message's flow")
        XCTAssertEqual(requestFlows.count, 1)
        XCTAssertFalse(requestFlows.contains(nil))
        XCTAssertTrue(agentFlows.isDisjoint(with: requestFlows), "a request is a flow of its own")
        XCTAssertEqual(rig.log.packets.filter { $0.kind == .partner }.count, 6)
        XCTAssertFalse(rig.log.packets.filter { $0.kind == .agentMessage }.isEmpty)
    }

    func testPARTNER_P05_TheFileHoldsNoValueTimeCodeTokenOrHost() async throws {
        let place = "Pasta Palace Unique"
        let start = "2026-11-02T19:00"
        let specific = PartnerRequest(requestID: sample.requestID, values: [.init(key: "restaurant", value: .text(place)),
                                                                          .init(key: "party_size", value: .number(2)),
                                                                          .init(key: "start", value: .text(start))])
        let reply = object()
        let recorder = BookingSendRecorder(body: reply)
        let (log, file) = makeLog()
        let result = await client(recorder.send, log: log).submit(specific, to: spec, flow: flow)
        // The name and the time exist in the request, and the code in the answer, so the checks below can fail.
        let sent = String(decoding: try XCTUnwrap(recorder.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(sent.contains(place))
        XCTAssertTrue(sent.contains(start))
        XCTAssertTrue(reply.contains("EX-AB12CD"))
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        await log.flush()
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(stored.contains("Example Tables: Request sent"))
        for secret in [place, "Pasta", start, "19:00", "7:00", "EX-AB12CD", "Table held", token, host, sample.requestID] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
    }

    func testPARTNER_P06_TheFlowReadsBesirPartnerBesir() async {
        let (log, _) = makeLog()
        _ = await submit(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        let flows = ConnectionFlows.group(log.packets)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.map(ConnectionFlows.chainText), ["besir → Partner (Simulated) → besir"])
    }

    func testPARTNER_P08_TwoRequestsMakeTwoFlows() async {
        let (log, _) = makeLog()
        let first = UUID()
        let second = UUID()
        _ = await client(BookingSendRecorder(body: object()).send, log: log).submit(sample, to: spec, flow: first)
        _ = await client(BookingSendRecorder(body: object()).send, log: log).submit(sample, to: spec, flow: second)
        await log.flush()
        XCTAssertEqual(log.packets.count, 4)
        XCTAssertEqual(ConnectionFlows.group(log.packets).count, 2)
        XCTAssertEqual(Set(log.packets.compactMap(\.flowID)), [first, second])
    }

    // MARK: PLACE the partner place lookup (SPEC-PARTNERPLACE-001, card t98)

    /// A form with one field the partner resolves itself (`restaurant`), an unmarked place field and two ordinary fields.
    private var lookupSpec: PartnerSpec {
        PartnerSpec(entry: entry,
                    fields: [PartnerField(key: "restaurant", kind: .place, label: "Restaurant", options: [], canLookUp: true),
                             PartnerField(key: "from", kind: .place, label: "From", options: []),
                             PartnerField(key: "party_size", kind: .number, label: "Party size", options: []),
                             PartnerField(key: "name", kind: .text, label: "Name", options: [])],
                    results: announced)
    }

    private let tartine = Place(name: "Tartine Bakery", address: "600 Guerrero St, San Francisco, CA 94110",
                                latitude: 37.7614, longitude: -122.4241)

    private var fivePlaces: [Place] {
        (0..<5).map { Place(name: "Branch \($0)", address: "\($0 + 1) Market St, San Francisco, CA",
                            latitude: 37.5 + Double($0) / 10, longitude: -122.5 + Double($0) / 10) }
    }

    private let typedSentinel = "Typed-Sentinel-55"
    private let sentinelPlace = Place(name: "Sentinel-Name-91", address: "91 Sentinel-Addr Lane, Testville",
                                      latitude: 12.34375, longitude: -65.4375)
    private let sentinelNear = (latitude: 41.2712, longitude: -73.5391)

    private func candidateObject(_ place: Place, _ mutate: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var object: [String: Any] = ["name": place.name, "address": place.address,
                                     "location": ["latitude": place.latitude, "longitude": place.longitude] as [String: Any]]
        mutate(&object)
        return object
    }

    private func locationObject(_ latitude: Any, _ longitude: Any) -> [String: Any] {
        ["latitude": latitude, "longitude": longitude]
    }

    /// The lookup answer of the sample partner; `mutate` bends it.
    private func lookupAnswer(field: String = "restaurant", places: [Place]? = nil, objects: [[String: Any]]? = nil,
                              _ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        var answer: [String: Any] = ["partner": "Example Tables", "simulated": true, "field": field,
                                     "candidates": objects ?? (places ?? [tartine]).map { candidateObject($0) }]
        mutate(&answer)
        return json(answer)
    }

    private func askLookup(_ recorder: BookingSendRecorder, text: String = "Tartine", near: (latitude: Double, longitude: Double)? = nil,
                           field: String = "restaurant", log: ConnectionLog? = nil, config: AppConfig? = nil,
                           flow: UUID? = nil) async -> Result<[Place], PartnerFailure> {
        await client(recorder.send, log: log, config: config).candidates(of: lookupSpec, field: field, text: text, near: near,
                                                                          flow: flow ?? self.flow)
    }

    /// The JSON body of the one request a lookup sent; a failure when the recorder does not hold exactly one.
    private func lookupBody(_ recorder: BookingSendRecorder, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        guard recorder.requests.count == 1, let data = recorder.requests.first?.httpBody,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("\(label): expected exactly one request with a JSON body, saw \(recorder.requests.count)", file: file, line: line)
            return nil
        }
        return object
    }

    private func isRoundedTo2(_ value: Double?) -> Bool {
        guard let value else { return false }
        return abs(value * 100 - (value * 100).rounded()) < 1e-9
    }

    // MARK: C01 the request

    func testPLACE_C01_TheLookupBodyIsFourFixedKeysAtMostAndTheTextIsTheLookupText() async {
        // A plain lookup: one POST to the entry's own route with the token, exactly three keys and no area.
        let plain = BookingSendRecorder(body: lookupAnswer())
        let plainResult = await askLookup(plain)
        XCTAssertEqual(plainResult, .success([tartine]), "a good answer is accepted")
        if let body = lookupBody(plain, "plain"), let sent = plain.requests.first {
            XCTAssertEqual(sent.httpMethod, "POST")
            XCTAssertEqual(sent.url?.path, "/booking")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(Set(body.keys), ["op", "field", "text"], "no near key without a device position")
            XCTAssertEqual(body["op"] as? String, "lookup")
            XCTAssertEqual(body["field"] as? String, "restaurant")
            XCTAssertEqual(body["text"] as? String, "Tartine")
            XCTAssertEqual(String(decoding: sent.httpBody ?? Data(), as: UTF8.self),
                           #"{"field":"restaurant","op":"lookup","text":"Tartine"}"#)
        }

        // A known position goes out as `near`, exactly two keys, each rounded to 2 decimals and nothing finer.
        let rounded: [((latitude: Double, longitude: Double), (Double, Double), [String])] = [
            ((37.7749295, -122.4194155), (37.77, -122.42), ["37.7749", "122.4194"]),
            ((-33.8688197, 151.2092955), (-33.87, 151.21), ["33.8688", "151.2092"]),
        ]
        for (position, expected, finer) in rounded {
            let recorder = BookingSendRecorder(body: lookupAnswer())
            let result = await askLookup(recorder, near: position)
            XCTAssertEqual(result, .success([tartine]), "near \(position)")
            guard let body = lookupBody(recorder, "near \(position)") else { continue }
            XCTAssertEqual(Set(body.keys), ["op", "field", "text", "near"], "near \(position)")
            let near = body["near"] as? [String: Any]
            XCTAssertEqual(Set((near ?? [:]).keys), ["latitude", "longitude"], "near \(position)")
            let latitude = (near?["latitude"] as? NSNumber)?.doubleValue
            let longitude = (near?["longitude"] as? NSNumber)?.doubleValue
            XCTAssertEqual(latitude ?? .nan, expected.0, accuracy: 1e-9, "latitude of \(position)")
            XCTAssertEqual(longitude ?? .nan, expected.1, accuracy: 1e-9, "longitude of \(position)")
            XCTAssertTrue(isRoundedTo2(latitude), "latitude has no digit beyond the second decimal")
            XCTAssertTrue(isRoundedTo2(longitude), "longitude has no digit beyond the second decimal")
            let raw = String(decoding: recorder.requests.first?.httpBody ?? Data(), as: UTF8.self)
            for digits in finer { XCTAssertFalse(raw.contains(digits), "the body holds \(digits)") }
        }

        // The text is the lookup text: hidden characters out, trimmed, cut at 80 scalars, trimmed again.
        let eighty = String((0..<80).map { Character(Unicode.Scalar(UInt8(97 + $0 % 26))) })
        let head = String(eighty.prefix(78))
        let normalised: [(String, String, String)] = [
            ("surrounding spaces", "  Tartine  ", "Tartine"),
            ("a zero-width space inside", "Mc\u{200B}Donald's", "McDonald's"),
            ("a line feed inside", "Mc\nDonald's", "McDonald's"),
            ("a line separator inside", "Mc\u{2028}Donald's", "McDonald's"),
            ("hidden characters remove before the trim", "\u{200B}  Tartine  \u{200B}", "Tartine"),
            ("hidden characters remove before the cut", String(repeating: "\u{200B}", count: 5) + eighty, eighty),
            ("an 85-scalar text with spaces at scalars 79 to 81", head + "   " + "wxyz", head),
            ("a text over 80 scalars", eighty + "TAIL-IGNORED", eighty),
            ("90 emoji", String(repeating: "\u{1F600}", count: 90), String(repeating: "\u{1F600}", count: 80)),
        ]
        for (label, typed, expected) in normalised {
            let recorder = BookingSendRecorder(body: lookupAnswer())
            let result = await askLookup(recorder, text: typed)
            XCTAssertEqual(result, .success([tartine]), label)
            guard let body = lookupBody(recorder, label) else { continue }
            let text = body["text"] as? String
            XCTAssertEqual(text, expected, label)
            XCTAssertEqual(text?.unicodeScalars.count, expected.unicodeScalars.count, "\(label): counted in scalars")
        }

        // A key that is not a lookup field of the partner's own list sends nothing: an unmarked place field, other kinds, an
        // unknown key; and the same key on a form where the field is not marked.
        for key in ["from", "party_size", "name", "nothing_here"] {
            let recorder = BookingSendRecorder(body: lookupAnswer(field: key))
            let result = await askLookup(recorder, field: key)
            XCTAssertEqual(result, .failure(.other), key)
            XCTAssertTrue(recorder.requests.isEmpty, "\(key) is not a marked field")
        }
        let unmarked = BookingSendRecorder(body: lookupAnswer())
        let unmarkedResult = await client(unmarked.send).candidates(of: spec, field: "restaurant", text: "Tartine", near: nil, flow: flow)
        XCTAssertEqual(unmarkedResult, .failure(.other))
        XCTAssertTrue(unmarked.requests.isEmpty, "a restaurant field that is not marked sends nothing")
    }

    // MARK: C02 the answer

    func testPLACE_C02_OnlyAnExactLookupAnswerIsAcceptedAndEveryDefectIsAFailure() async {
        let eighty = String(repeating: "N", count: 80)
        let emoji80 = String(repeating: "\u{1F600}", count: 80)
        let emoji81 = String(repeating: "\u{1F600}", count: 81)

        // Positive controls: the exact answers give exactly their places.
        let controls: [(String, [Place])] = [
            ("one candidate", [tartine]),
            ("five candidates", fivePlaces),
            ("a name of 80 code points", [Place(name: eighty, address: tartine.address, latitude: 1, longitude: 2)]),
            ("a name of 80 emoji", [Place(name: emoji80, address: tartine.address, latitude: 1, longitude: 2)]),
            ("an address of 120 code points", [Place(name: "Tartine", address: String(repeating: "S", count: 120), latitude: 1, longitude: 2)]),
            ("a name and an address of one code point", [Place(name: "T", address: "A", latitude: 1, longitude: 2)]),
            ("the corner coordinates", [Place(name: "North", address: "Pole", latitude: 90, longitude: -180),
                                       Place(name: "South", address: "Pole", latitude: -90, longitude: 180)]),
        ]
        for (name, places) in controls {
            let got = await askLookup(BookingSendRecorder(body: lookupAnswer(places: places)))
            XCTAssertEqual(got, .success(places), "control: \(name)")
        }

        // The defect table: every case bends one thing of an otherwise exact answer.
        var defects: [(String, String)] = []
        func add(_ name: String, _ body: String) { defects.append((name, body)) }
        func bad(_ mutate: (inout [String: Any]) -> Void) -> String { lookupAnswer(objects: [candidateObject(tartine, mutate)]) }

        add("an extra top-level key", lookupAnswer { $0["note"] = "x" })
        for key in ["partner", "simulated", "field", "candidates"] {
            add("a missing top-level key \(key)", lookupAnswer { $0.removeValue(forKey: key) })
        }
        add("partner not the entry's", lookupAnswer { $0["partner"] = "Real Tables" })
        add("partner in another case", lookupAnswer { $0["partner"] = "example tables" })
        add("partner not a string", lookupAnswer { $0["partner"] = 5 })
        add("simulated false", lookupAnswer { $0["simulated"] = false })
        add("simulated the text true", lookupAnswer { $0["simulated"] = "true" })
        add("simulated the number 1", lookupAnswer { $0["simulated"] = 1 })
        add("simulated null", lookupAnswer { $0["simulated"] = NSNull() })
        add("field not the requested one", lookupAnswer(field: "name"))
        add("field empty", lookupAnswer(field: ""))
        add("field not a string", lookupAnswer { $0["field"] = 5 })
        add("6 candidates", lookupAnswer(places: fivePlaces + [tartine]))
        add("candidates an object", lookupAnswer { $0["candidates"] = candidateObject(self.tartine) })
        add("candidates a text", lookupAnswer { $0["candidates"] = "Tartine Bakery" })
        add("candidates null", lookupAnswer { $0["candidates"] = NSNull() })
        add("a candidate that is a text", lookupAnswer { $0["candidates"] = ["Tartine Bakery"] })
        add("a candidate that is a number", lookupAnswer { $0["candidates"] = [7] })
        add("a candidate that is null", lookupAnswer { $0["candidates"] = [NSNull()] })
        add("a bad candidate first among good ones", lookupAnswer(objects: [candidateObject(tartine) { $0["trackingId"] = "t" }, candidateObject(tartine)]))
        add("a bad candidate in the middle of good ones", lookupAnswer(objects: [candidateObject(tartine), candidateObject(tartine) { $0["name"] = "" }, candidateObject(tartine)]))
        add("a bad candidate last among good ones", lookupAnswer(objects: [candidateObject(tartine), candidateObject(tartine) { $0["location"] = NSNull() }]))
        add("a name of 0 code points", bad { $0["name"] = "" })
        add("a name of 81 code points", bad { $0["name"] = eighty + "N" })
        add("a name of 81 emoji", bad { $0["name"] = emoji81 })
        add("an address of 0 code points", bad { $0["address"] = "" })
        add("an address of 121 code points", bad { $0["address"] = String(repeating: "S", count: 121) })
        add("a name that is not a text", bad { $0["name"] = 5 })
        add("an address that is not a text", bad { $0["address"] = NSNull() })
        add("a candidate with an extra key", bad { $0["trackingId"] = "t-1" })
        add("a candidate lacking name", bad { $0.removeValue(forKey: "name") })
        add("a candidate lacking address", bad { $0.removeValue(forKey: "address") })
        add("a candidate lacking location", bad { $0.removeValue(forKey: "location") })
        for (label, scalar) in [("a control character", "\u{0007}"), ("a line feed", "\n"), ("a tab", "\t"), ("a format character (U+200E)", "\u{200E}"),
                                ("a zero-width space", "\u{200B}"), ("a line separator", "\u{2028}"), ("a paragraph separator", "\u{2029}")] {
            add("\(label) in a name", bad { $0["name"] = "Tar\(scalar)tine" })
            add("\(label) in an address", bad { $0["address"] = "600 Guerrero\(scalar) St" })
        }
        add("a name of only spaces", bad { $0["name"] = "   " })
        add("an address of only spaces", bad { $0["address"] = "   " })
        add("a boolean latitude", bad { $0["location"] = self.locationObject(true, -122.4) })
        add("a boolean longitude", bad { $0["location"] = self.locationObject(37.7, false) })
        add("a text latitude", bad { $0["location"] = self.locationObject("37.7", -122.4) })
        add("a text longitude", bad { $0["location"] = self.locationObject(37.7, "-122.4") })
        add("a null latitude", bad { $0["location"] = self.locationObject(NSNull(), -122.4) })
        add("a null longitude", bad { $0["location"] = self.locationObject(37.7, NSNull()) })
        add("latitude 91", bad { $0["location"] = self.locationObject(91, -122.4) })
        add("latitude -91", bad { $0["location"] = self.locationObject(-91, -122.4) })
        add("longitude 181", bad { $0["location"] = self.locationObject(37.7, 181) })
        add("longitude -181", bad { $0["location"] = self.locationObject(37.7, -181) })
        add("a location with a third key", bad { $0["location"] = self.locationObject(37.7, -122.4).merging(["altitude": 3] as [String: Any]) { first, _ in first } })
        add("a location lacking latitude", bad { $0["location"] = ["longitude": -122.4] as [String: Any] })
        add("a location lacking longitude", bad { $0["location"] = ["latitude": 37.7] as [String: Any] })
        add("a location that is a list", bad { $0["location"] = [37.7, -122.4] })
        add("a location that is a text", bad { $0["location"] = "37.7,-122.4" })
        add("a body that is a list", "[]")
        add("a body that is not JSON", "not json")
        add("an empty body", "")

        for (name, body) in defects {
            let got = await askLookup(BookingSendRecorder(body: body))
            XCTAssertEqual(got, .failure(.other), "defect case: \(name)")
        }
    }

    // MARK: C03 empty, and each failure keeps its kind

    func testPLACE_C03_AnEmptyAnswerIsAnAnswerAndEachFailureKeepsItsKind() async {
        // An exact answer with no candidate is an answer, never a failure.
        let empty = await askLookup(BookingSendRecorder(body: lookupAnswer(objects: [])))
        XCTAssertEqual(empty, .success([]))
        let good = await askLookup(BookingSendRecorder(body: lookupAnswer()))
        XCTAssertEqual(good, .success([tartine]), "control: the same answer with one candidate")

        // Offline and other transport errors.
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let got = await askLookup(BookingSendRecorder(error: URLError(code)))
            XCTAssertEqual(got, .failure(.offline), "\(code)")
        }
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), WriteFailure()] as [Error] {
            let got = await askLookup(BookingSendRecorder(error: error))
            XCTAssertEqual(got, .failure(.other), "\(error)")
        }

        // The Worker's own rejection of the token is exactly one body; any other 401 is `other`.
        let own = await askLookup(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, "", "unauthorized", "[]"] {
            let other = await askLookup(BookingSendRecorder(status: 401, body: text))
            XCTAssertEqual(other, .failure(.other), "401 with \(text)")
        }

        // The status alone decides: a good answer under any other status is `other`.
        for status in [404, 500, 502, 503] {
            let withAnswer = await askLookup(BookingSendRecorder(status: status, body: lookupAnswer()))
            XCTAssertEqual(withAnswer, .failure(.other), "status \(status) with a good answer")
            let withError = await askLookup(BookingSendRecorder(status: status, body: #"{"error":"upstream_failed"}"#))
            XCTAssertEqual(withError, .failure(.other), "status \(status) with an error body")
        }

        // No proxy: nothing is called and nothing is recorded.
        let (quiet, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let idle = BookingSendRecorder(body: lookupAnswer())
            let got = await askLookup(idle, log: quiet, config: blank)
            XCTAssertEqual(got, .failure(.notSetUp))
            XCTAssertTrue(idle.requests.isEmpty, "no proxy sends nothing")
        }
        await quiet.flush()
        XCTAssertTrue(quiet.packets.isEmpty)
    }

    // MARK: C04 the lookup text is asked only from two scalars on

    func testPLACE_C04_TextsUnderTwoCodePointsAfterNormalisationSendNothing() async {
        let (log, _) = makeLog()
        let tooShort: [(String, String)] = [
            ("one letter plus a zero-width space", "a\u{200B}"),
            ("one letter plus a line feed", "a\n"),
            ("M, 79 spaces and s", "M" + String(repeating: " ", count: 79) + "s"),
            ("an empty text", ""),
            ("one letter", "a"),
            ("only spaces", "     "),
            ("only hidden characters", "\u{200B}\u{200B}\u{200E}"),
            ("one emoji", "\u{1F600}"),
        ]
        for (label, typed) in tooShort {
            XCTAssertNil(PartnerCandidates.requestText(typed), label)
            let recorder = BookingSendRecorder(body: lookupAnswer())
            let got = await askLookup(recorder, text: typed, log: log)
            XCTAssertEqual(got, .failure(.other), label)
            XCTAssertTrue(recorder.requests.isEmpty, "\(label) sends nothing")
        }
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty, "nothing sent, nothing recorded")

        // Positive controls: two scalars are enough, counted in code points and after the hidden ones are removed.
        let enough: [(String, String, String)] = [
            ("two letters", "ab", "ab"),
            ("two letters around a zero-width space", "a\u{200B}b", "ab"),
            ("a letter and a combining accent (one character, two scalars)", "e\u{0301}", "e\u{0301}"),
            ("two emoji", "\u{1F600}\u{1F600}", "\u{1F600}\u{1F600}"),
        ]
        for (label, typed, expected) in enough {
            XCTAssertEqual(PartnerCandidates.requestText(typed).map { Array($0.unicodeScalars) }, Array(expected.unicodeScalars), label)
            let recorder = BookingSendRecorder(body: lookupAnswer())
            let got = await askLookup(recorder, text: typed)
            XCTAssertEqual(got, .success([tartine]), label)
            if let body = lookupBody(recorder, label) {
                XCTAssertEqual((body["text"] as? String).map { Array($0.unicodeScalars) }, Array(expected.unicodeScalars), label)
            }
        }
    }

    func testPLACE_C05_FortyOneFlagsAre82CodePointsAndAreRefusedAsANameWhileFortyAreAccepted() async {
        // One flag is two regional-indicator code points but one character, so `String.count` (or a JS `.length` of 2 per flag) and a
        // count of code points disagree here: a name of 40 flags is 80 code points, a name of 41 flags is 82.
        let flag = "\u{1F1FA}\u{1F1F8}"
        let forty = String(repeating: flag, count: 40)
        let fortyOne = String(repeating: flag, count: 41)
        XCTAssertEqual(forty.unicodeScalars.count, 80, "premise: 40 flags are 80 code points")
        XCTAssertEqual(fortyOne.unicodeScalars.count, 82, "premise: 41 flags are 82 code points")
        XCTAssertEqual(fortyOne.count, 41, "premise: 41 flags are 41 characters, so a character count would let them through")

        let accepted = Place(name: forty, address: tartine.address, latitude: 1, longitude: 2)
        let got = await askLookup(BookingSendRecorder(body: lookupAnswer(places: [accepted])))
        XCTAssertEqual(got, .success([accepted]), "a name of 40 flags (80 code points) is accepted")

        let refused = Place(name: fortyOne, address: tartine.address, latitude: 1, longitude: 2)
        let bad = await askLookup(BookingSendRecorder(body: lookupAnswer(places: [refused])))
        XCTAssertEqual(bad, .failure(.other), "a name of 41 flags (82 code points) is refused")
    }

    // MARK: P01-P02 the packets of a lookup

    func testPLACE_P01_ALookupWritesTwoPacketsUnderAFlowOfItsOwn() async {
        let words = ["besir>partner partner ok Example Tables: Candidates requested",
                     "partner>besir partner ok Example Tables: Candidates received"]

        // One lookup, one flow of its own; the packets hold fixed words and the partner's name only.
        let (log, file) = makeLog()
        let reply = lookupAnswer(places: [sentinelPlace])
        let recorder = BookingSendRecorder(body: reply)
        let result = await askLookup(recorder, text: typedSentinel, near: sentinelNear, log: log)
        XCTAssertEqual(result, .success([sentinelPlace]))
        await log.flush()
        XCTAssertEqual(lines(log), words)
        XCTAssertEqual(Set(log.packets.map(\.flowID)), [flow])
        XCTAssertEqual(log.packets.map(\.kind), [.partner, .partner])
        XCTAssertEqual(log.packets.map(\.status), [.ok, .ok])

        // The sentinels are in the request and the answer, so the absence checks below can fail.
        let sent = String(decoding: recorder.requests.first?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(sent.contains(typedSentinel))
        XCTAssertTrue(sent.contains("41.27"))
        XCTAssertTrue(reply.contains(sentinelPlace.name))
        XCTAssertTrue(reply.contains("12.34375"), "the coordinates are binary-exact, so the JSON text holds them as written")
        let stored = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertTrue(stored.contains("Example Tables: Candidates requested"), "the packets reached the file")
        for secret in [typedSentinel, "Typed-Sentinel", sentinelPlace.name, "Sentinel-Addr", "Testville", "12.34375", "65.4375", token, host] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
        for secret in ["41.27", "73.54"] {
            XCTAssertFalse(lines(log).joined().contains(secret), "a packet summary holds \(secret)")
        }

        // Two lookups make two flows.
        let (twice, _) = makeLog()
        let first = UUID()
        let second = UUID()
        _ = await askLookup(BookingSendRecorder(body: lookupAnswer()), log: twice, flow: first)
        _ = await askLookup(BookingSendRecorder(body: lookupAnswer()), text: "Zuni", log: twice, flow: second)
        await twice.flush()
        XCTAssertEqual(twice.packets.count, 4)
        XCTAssertEqual(ConnectionFlows.group(twice.packets).count, 2)
        XCTAssertEqual(Set(twice.packets.compactMap(\.flowID)), [first, second])
        XCTAssertEqual(lines(twice), words + words)

        // A lookup whose task is cancelled while its request is in flight writes no packet at all.
        let (during, _) = makeLog()
        let inFlight = BookingSendRecorder(body: lookupAnswer())
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = await Task { await askLookup(inFlight, log: during) }.value
        XCTAssertEqual(inFlight.requests.count, 1, "the request was in flight when the task was cancelled")
        XCTAssertEqual(cancelled, .failure(.other))
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty, "a cancelled lookup records nothing")
    }

    func testPLACE_P02_AFailedLookupWritesOneFailurePacketAndNoValue() async {
        let reply = lookupAnswer(places: [sentinelPlace]) { $0["note"] = "extra" }
        let scenarios: [(String, BookingSendRecorder, PartnerFailure)] = [
            ("a defective answer", BookingSendRecorder(body: reply), .other),
            ("a 500 with the answer", BookingSendRecorder(status: 500, body: lookupAnswer(places: [sentinelPlace])), .other),
            ("offline", BookingSendRecorder(error: URLError(.notConnectedToInternet)), .offline),
            ("a rejected token", BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#), .tokenRejected),
            ("a wrong partner", BookingSendRecorder(body: lookupAnswer(places: [sentinelPlace]) { $0["partner"] = "Real Tables" }), .other),
        ]
        XCTAssertTrue(reply.contains(sentinelPlace.name), "the answer holds the sentinel candidate")
        for (label, recorder, failure) in scenarios {
            let (log, file) = makeLog()
            let result = await askLookup(recorder, text: typedSentinel, near: sentinelNear, log: log)
            XCTAssertEqual(result, .failure(failure), label)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"], label)
            XCTAssertEqual(log.packets.first?.flowID, flow, label)

            // The typed text and the area are in the request, so the absence checks below can fail.
            let sent = String(decoding: recorder.requests.first?.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(sent.contains(typedSentinel), "\(label): the request holds the typed text")
            XCTAssertTrue(sent.contains("41.27"), "\(label): the request holds the area")
            XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "x-besir-token"), token, label)
            XCTAssertEqual(recorder.requests.first?.url?.host, host, label)

            let stored = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertTrue(stored.contains("Request failed"), "\(label): the failure reached the file")
            for secret in [typedSentinel, "Typed-Sentinel", sentinelPlace.name, "Sentinel-Addr", "Testville", "12.34375", "65.4375", token, host] {
                XCTAssertFalse(stored.contains(secret), "\(label): connections.json holds \(secret)")
            }
            for secret in ["41.27", "73.54", "Sentinel", "Typed"] {
                XCTAssertFalse(lines(log).joined().contains(secret), "\(label): a packet summary holds \(secret)")
            }
        }
    }

    // MARK: GROUP the repeatable row group (card t102, SPEC-GROUPFIELD-001)

    func testGROUP_GC1_AGroupIsSentAsAnArrayOfRowObjectsWithOnlyItsValuedMembersAndNoPacketOrFileHoldsAValue() async throws {
        let note = "SENTINEL-ROW-NOTE-731"
        let group = PartnerField(key: "items", kind: .group, label: "Items", options: [], members: [
            PartnerField(key: "item", kind: .pickOne, label: "Item",
                         options: [PartnerOption(id: "ramen", label: "Ramen"), PartnerOption(id: "gyoza", label: "Gyoza")]),
            PartnerField(key: "quantity", kind: .number, label: "Quantity", options: []),
            PartnerField(key: "row_note", kind: .text, label: "Note", options: [], isOptional: true)
        ], maxRows: 6)
        let menu = PartnerSpec(entry: entry, fields: [PartnerField(key: "table", kind: .text, label: "Table", options: []), group],
                               results: announced)
        let request = PartnerRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B", values: [
            .init(key: "table", value: .text("Nine")),
            .init(key: "items", value: .rows([
                [.init(key: "item", value: .text("ramen")), .init(key: "quantity", value: .number(2)),
                 .init(key: "row_note", value: .text(note))],
                [.init(key: "item", value: .text("gyoza")), .init(key: "quantity", value: .number(1))]
            ]))])
        let (log, file) = makeLog()
        let recorder = BookingSendRecorder(body: object())
        let result = await client(recorder.send, log: log).submit(request, to: menu, flow: flow)
        XCTAssertEqual(result, .success(.confirmed(results: items)))
        let sent = try XCTUnwrap(recorder.requests.first)
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        let sentBody = try body(of: sent)
        XCTAssertEqual(Set(sentBody.keys), ["op", "request_id", "values"])
        XCTAssertEqual(sentBody["op"] as? String, "submit")
        XCTAssertEqual(sentBody["request_id"] as? String, request.requestID)
        let values = try XCTUnwrap(sentBody["values"] as? [String: Any])
        // The group key holds an array of two row objects in card order; the keys outside the group are as before.
        let rows = values["items"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 2)
        guard let rows, rows.count == 2 else { return }
        XCTAssertEqual(Set(values.keys), ["table", "items"])
        XCTAssertEqual(values["table"] as? String, "Nine")
        // Each row holds only its members that have a value: a text as a string, a number as a JSON number, a `pick_one`
        // member as the option id; the blank optional member of the second row has no entry.
        XCTAssertEqual(Set(rows[0].keys), ["item", "quantity", "row_note"])
        XCTAssertEqual(rows[0]["item"] as? String, "ramen")
        XCTAssertEqual(rows[0]["quantity"] as? Int, 2)
        XCTAssertEqual(rows[0]["row_note"] as? String, note)
        XCTAssertEqual(Set(rows[1].keys), ["item", "quantity"])
        XCTAssertEqual(rows[1]["item"] as? String, "gyoza")
        XCTAssertEqual(rows[1]["quantity"] as? Int, 1)
        XCTAssertTrue(text.contains(#""quantity":2"#), text)
        XCTAssertTrue(text.contains(note), text)

        // The packets are the partner's name and fixed words; no row value is in any of them or in the file.
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Example Tables: Request sent",
                                    "partner>besir partner ok Example Tables: Request confirmed"])
        let stored = try String(contentsOf: file, encoding: .utf8).lowercased()
        for secret in ["sentinel", "ramen", "gyoza", "nine", "row_note", token, host, request.requestID.lowercased()] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
            XCTAssertFalse(lines(log).joined().lowercased().contains(secret), "a packet holds \(secret)")
        }
    }
}
