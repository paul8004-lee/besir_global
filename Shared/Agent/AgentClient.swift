import Foundation

// SPEC-AGENT-002 (M4b): the request builder, the response parser and the transport. The Worker keeps no responses,
// so every request replays the whole conversation: the model's own output items as received, then the tool outputs.

/// The reasoning effort level sent with every request (fixed by the effort measurement).
let reasoningEffort = "medium"

/// The pure parts: instructions, request body, response parser. No network, no clock of their own.
enum AgentWire {
    // MARK: Instructions

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f
    }

    /// The date line, then the bundled Always lines, one per line, with no trailing newline.
    static func instructions(now: Date, timeZone: TimeZone) -> String {
        instructions(now: now, timeZone: timeZone, rules: BesirRules.bundled(), countLines: []) ?? ""
    }

    // @MX:NOTE: [AUTO] Line order of every request: the date line, the Always lines, then (only with at least one count line and a non-empty Memory section) the Memory lines and the count lines. The place after the Always lines is reserved for the user's own rules (SPEC-MEMORY-003).
    /// The date line, the Always lines of `rules`, then, only when `countLines` is not empty and `rules` has Memory lines, the
    /// Memory lines followed by `countLines`; one per line, with no trailing newline. Nil when `rules` is nil or has no Always line.
    static func instructions(now: Date, timeZone: TimeZone, rules: BesirRules?, countLines: [String],
                             userRules: [String] = []) -> String? {
        guard let rules, !rules.always.isEmpty else { return nil }
        let stamp = formatter("yyyy-MM-dd'T'HH:mm", timeZone).string(from: now)
        let weekday = formatter("EEEE", timeZone).string(from: now)
        let first = "Current local date and time: \(stamp) (\(weekday)), time zone \(timeZone.identifier)."
        var lines = [first] + rules.always
        if !countLines.isEmpty, !rules.memory.isEmpty {
            lines += rules.memory + countLines
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Request body

    private static func encode(_ value: Any) -> Data {
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: value, options: options)) ?? Data("null".utf8)
    }

    /// The JSON text of one replayed item, exactly as received, or nil when it is not a JSON object.
    private static func replayable(_ raw: Data) -> Data? {
        (try? JSONSerialization.jsonObject(with: raw)) is [String: Any] ? raw : nil
    }

    private static func rawBytes(of item: AgentItem) -> Data {
        switch item {
        case .message(_, let raw): return raw
        case .functionCall(_, _, _, let raw): return raw
        case .reasoning(let raw): return raw
        }
    }

    /// The request body: `instructions`, `input`, `tools`, `parallel_tool_calls`, `include` and `reasoning`.
    /// Items of earlier model turns are spliced in byte for byte.
    static func requestBody(history: [AgentEntry], instructions: String) -> Data {
        var pieces: [Data] = []
        for entry in history {
            switch entry {
            case .user(let text):
                pieces.append(encode(["role": "user", "content": [["type": "input_text", "text": text]]] as [String: Any]))
            case .assistant(let items, _):
                pieces.append(contentsOf: items.compactMap { replayable(rawBytes(of: $0)) })
            case .callOutput(let callID, let result):
                pieces.append(encode(["type": "function_call_output", "call_id": callID, "output": result] as [String: Any]))
            }
        }
        var body = Data(#"{"include":["reasoning.encrypted_content"],"input":["#.utf8)
        for (index, piece) in pieces.enumerated() {
            if index > 0 { body.append(Data(",".utf8)) }
            body.append(piece)
        }
        body.append(Data(#"],"instructions":"#.utf8))
        body.append(encode(instructions))
        body.append(Data(#","parallel_tool_calls":false,"reasoning":{"effort":"#.utf8))
        body.append(encode(reasoningEffort))
        body.append(Data(#"},"tools":"#.utf8))
        body.append(AgentTools.declarationsJSON())
        body.append(Data("}".utf8))
        return body
    }

    // MARK: Response parser

    /// Maps a response body into the neutral turn. Each item keeps its raw bytes as received.
    static func parse(_ data: Data) throws -> AgentTurn {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentTransportError.unreadableBody
        }
        let elements = (root["output"] as? [Any]) ?? []
        let slices = rawOutputElements(in: data)
        let exact = slices?.count == elements.count ? slices : nil

        var items: [AgentItem] = []
        for (index, element) in elements.enumerated() {
            guard let object = element as? [String: Any] else { continue }
            let raw = exact?[index] ?? encode(object)
            switch object["type"] as? String {
            case "reasoning":
                items.append(.reasoning(raw: raw))
            case "message":
                let parts = (object["content"] as? [[String: Any]]) ?? []
                let text = parts.compactMap { part -> String? in
                    part["type"] as? String == "output_text" ? part["text"] as? String : nil
                }.joined()
                items.append(.message(text: text, raw: raw))
            case "function_call":
                items.append(.functionCall(callID: object["call_id"] as? String,
                                           name: object["name"] as? String,
                                           arguments: (object["arguments"] as? String) ?? "",
                                           raw: raw))
            default:
                break
            }
        }
        return AgentTurn(completed: root["status"] as? String == "completed", items: items, responseID: root["id"] as? String)
    }

    /// The bytes of each element of the top-level `output` array, or nil when the body cannot be sliced.
    private static func rawOutputElements(in data: Data) -> [Data]? {
        let b = [UInt8](data)
        let n = b.count
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

        func skipSpace(_ start: Int) -> Int {
            var j = start
            while j < n, space.contains(b[j]) { j += 1 }
            return j
        }
        /// Index after the string that starts at `start`.
        func stringEnd(_ start: Int) -> Int? {
            var j = start + 1
            while j < n {
                if b[j] == 0x5C { j += 2 } else if b[j] == 0x22 { return j + 1 } else { j += 1 }
            }
            return nil
        }
        /// Index after the value that starts at `start`.
        func valueEnd(_ start: Int) -> Int? {
            guard start < n else { return nil }
            if b[start] == 0x22 { return stringEnd(start) }
            if b[start] == 0x7B || b[start] == 0x5B {
                var depth = 0
                var j = start
                while j < n {
                    switch b[j] {
                    case 0x22:
                        guard let end = stringEnd(j) else { return nil }
                        j = end
                        continue
                    case 0x7B, 0x5B:
                        depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { return j + 1 }
                    default:
                        break
                    }
                    j += 1
                }
                return nil
            }
            var j = start
            while j < n, b[j] != 0x2C, b[j] != 0x7D, b[j] != 0x5D, !space.contains(b[j]) { j += 1 }
            return j
        }

        var i = skipSpace(0)
        guard i < n, b[i] == 0x7B else { return nil }
        i = skipSpace(i + 1)
        while i < n, b[i] == 0x22 {
            guard let keyEnd = stringEnd(i) else { return nil }
            let key = Array(b[(i + 1)..<(keyEnd - 1)])
            var j = skipSpace(keyEnd)
            guard j < n, b[j] == 0x3A else { return nil }
            j = skipSpace(j + 1)
            guard let end = valueEnd(j) else { return nil }
            if key == Array("output".utf8) {
                guard b[j] == 0x5B else { return nil }
                var elements: [Data] = []
                var k = skipSpace(j + 1)
                while k < end - 1 {
                    guard let elementEnd = valueEnd(k) else { return nil }
                    elements.append(Data(b[k..<elementEnd]))
                    k = skipSpace(elementEnd)
                    if k < end, b[k] == 0x2C { k = skipSpace(k + 1) }
                }
                return elements
            }
            i = skipSpace(end)
            guard i < n, b[i] == 0x2C else { break }
            i = skipSpace(i + 1)
        }
        return nil
    }
}

// MARK: - Transport

@MainActor
final class AgentClient: AgentTransport {
    private let config: AppConfig
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let session: URLSession
    private let rules: () -> BesirRules?
    private let memoryLines: () -> [String]
    /// The user's standing rules (SPEC-MEMORY-003).
    private let userRules: () -> [String]

    /// `timeZone` is read for every request, so a zone change while the app runs reaches the instruction text.
    init(config: AppConfig, now: @escaping () -> Date, timeZone: @escaping () -> TimeZone,
         session: URLSession = URLSession(configuration: .ephemeral),
         rules: @escaping () -> BesirRules? = { BesirRules.bundled() },
         memoryLines: @escaping () -> [String] = { [] },
         userRules: @escaping () -> [String] = { [] }) {
        self.config = config
        self.now = now
        self.timeZone = timeZone
        self.session = session
        self.rules = rules
        self.memoryLines = memoryLines
        self.userRules = userRules
    }

    convenience init(config: AppConfig, now: @escaping () -> Date, timeZone: TimeZone,
                     session: URLSession = URLSession(configuration: .ephemeral),
                     rules: @escaping () -> BesirRules? = { BesirRules.bundled() },
                     memoryLines: @escaping () -> [String] = { [] },
                     userRules: @escaping () -> [String] = { [] }) {
        self.init(config: config, now: now, timeZone: { timeZone }, session: session, rules: rules, memoryLines: memoryLines,
                  userRules: userRules)
    }

    var isConfigured: Bool { config.hasAI }

    /// The request for a history, made by the configuration's single request builder (60 second timeout).
    /// The rules and the memory lines are read again for every request; nil when the rules cannot be read.
    func makeRequest(history: [AgentEntry]) -> URLRequest? {
        let at = now()
        let zone = timeZone()
        let counts = MemoryCounts.summary(lines: memoryLines(), now: at, timeZone: zone)
        guard let text = AgentWire.instructions(now: at, timeZone: zone, rules: rules(), countLines: counts) else { return nil }
        let body = AgentWire.requestBody(history: history, instructions: text)
        return config.proxyPOSTRequest("/ai", body: body, timeout: 60)
    }

    func send(history: [AgentEntry]) async throws -> AgentTurn {
        guard let request = makeRequest(history: history) else { throw AgentTransportError.other }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw AgentTransportError.other }
        guard (200...299).contains(http.statusCode) else {
            throw AgentTransportError.http(status: http.statusCode, body: data)
        }
        return try AgentWire.parse(data)
    }

    /// Maps a failure of the network call to the session's neutral error.
    nonisolated static func transportError(for error: Error) -> AgentTransportError {
        if error is CancellationError { return .cancelled }
        guard let failure = error as? URLError else { return .other }
        switch failure.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .other
        }
    }
}
