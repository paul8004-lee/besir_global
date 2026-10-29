import Foundation
import Combine

// MARK: - Parties, kinds, status, packet

/// Who sent or received something. A closed set; a later card may add cases.
enum ConnectionParty: String, Codable, CaseIterable {
    case instagram
    case shareSheet
    case besir
    case museSpark
    case imageReader
    case googlePlaces
    case googleRoutes
    case appleCalendar
    case bookingPartner
    case budgetPartner
    case deliveryPartner

    var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .shareSheet: return "Share sheet"
        case .besir: return "besir"
        case .museSpark: return "Muse Spark"
        case .imageReader: return "Image reader"
        case .googlePlaces: return "Google Places"
        case .googleRoutes: return "Google Routes"
        case .appleCalendar: return "Apple Calendar"
        case .bookingPartner: return BookingClient.partnerName + " (Simulated)"
        case .budgetPartner: return BudgetClient.partnerName + " (Simulated)"
        case .deliveryPartner: return DeliveryClient.partnerName + " (Simulated)"
        }
    }

    /// The share extension cannot see the sending app, so `instagram` is claimed only when the data says so:
    /// the text holds at least one URL and every URL has the host `instagram.com` or a subdomain of it.
    static func forSharedText(_ text: String?) -> ConnectionParty {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return .shareSheet }
        var hosts: [String] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let host = match.url?.host?.lowercased() else { return .shareSheet }
            hosts.append(host)
        }
        guard !hosts.isEmpty else { return .shareSheet }
        let allInstagram = hosts.allSatisfy { $0 == "instagram.com" || $0.hasSuffix(".instagram.com") }
        return allInstagram ? .instagram : .shareSheet
    }
}

/// What kind of thing passed.
enum ConnectionKind: String, Codable, CaseIterable {
    case share
    case imageRead
    case placeSearch
    case route
    case agentMessage
    case agentToolCall
    case calendarSave
    case booking
    case budget
    case delivery

    var displayName: String {
        switch self {
        case .share: return "Share"
        case .imageRead: return "Image read"
        case .placeSearch: return "Place search"
        case .route: return "Route"
        case .agentMessage: return "Message"
        case .agentToolCall: return "Tool call"
        case .calendarSave: return "Calendar save"
        case .booking: return "Booking"
        case .budget: return "Budget"
        case .delivery: return "Delivery"
        }
    }

    /// Used when a summary is empty after cleaning.
    var defaultSummary: String {
        switch self {
        case .share: return "Shared item"
        case .imageRead: return "Image read"
        case .placeSearch: return "Place search"
        case .route: return "Route lookup"
        case .agentMessage: return "Message"
        case .agentToolCall: return "Tool call"
        case .calendarSave: return "Event saved"
        case .booking: return "Reservation"
        case .budget: return "Budget"
        case .delivery: return "Delivery"
        }
    }
}

/// A packet is a finished fact: there is no pending state.
enum ConnectionStatus: String, Codable, CaseIterable {
    case ok
    case failed
    case declined
    /// A normal answer, not a failure: the lookup worked and there is no route.
    case noRoute

    var word: String {
        switch self {
        case .ok: return "OK"
        case .failed: return "Failed"
        case .declined: return "Declined"
        case .noRoute: return "No route"
        }
    }
}

/// One thing that passed from one app or service to another. It has no place for content, a key or an image.
struct ConnectionPacket: Codable, Identifiable, Equatable {
    let id: UUID
    let flowID: UUID?
    let at: Date
    let from: ConnectionParty
    let to: ConnectionParty
    let kind: ConnectionKind
    let summary: String
    let status: ConnectionStatus
}

// MARK: - The log

/// The connection log: a capped list of packets on the device. It cleans every summary itself, never throws, and never
/// gets in the way of the connection it describes. Not `@MainActor`: `record` is callable from any thread or task.
final class ConnectionLog: ObservableObject, @unchecked Sendable {
    static let fileName = "connections.json"
    static let maxPackets = 200
    static let hiddenText = "Details hidden"
    static let emptyText = "No connections yet"
    static let maxSummaryLength = 80

    /// Published on the main queue only (the one other write is the load inside `init`).
    @Published private(set) var packets: [ConnectionPacket] = []

    private let fileURL: URL
    private let secrets: @Sendable () -> [String]
    private let now: @Sendable () -> Date
    private let write: @Sendable (Data, URL) throws -> Void
    private let limit: Int

    private let lock = NSLock()
    private var store: [ConnectionPacket] = []
    private let writeQueue = DispatchQueue(label: "besir.connection-log.write")

    /// The flow on offer (REQ-CONNECT-022): at most one, touched on the main actor only.
    @MainActor private var offered: UUID?

    init(fileURL: URL,
         secrets: @escaping @Sendable () -> [String] = { [] },
         now: @escaping @Sendable () -> Date = { Date() },
         write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite,
         maxPackets: Int = ConnectionLog.maxPackets) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.now = now
        self.write = write
        self.limit = maxPackets
        let loaded = Self.load(fileURL, limit: maxPackets)
        self.store = loaded
        self.packets = loaded
    }

    /// The log the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static let shared = ConnectionLog(
        fileURL: AppConfig.supportDirectory.appendingPathComponent(ConnectionLog.fileName),
        secrets: { ConnectionLog.secrets(from: AppConfig.load()) })

    /// The two configuration values a summary must never show: the app token, then the host of the proxy address.
    static func secrets(from config: AppConfig) -> [String] {
        [config.appToken, URL(string: config.proxyBaseURL)?.host ?? ""]
    }

    static let defaultWrite: @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func beginFlow() -> UUID { UUID() }

    // MARK: Record

    /// Appends one packet. Returns without waiting for the file write; nothing here throws.
    func record(from: ConnectionParty,
                to: ConnectionParty,
                kind: ConnectionKind,
                summary: String,
                status: ConnectionStatus,
                flowID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let packet = ConnectionPacket(id: UUID(), flowID: flowID, at: now(), from: from, to: to, kind: kind,
                                      summary: Self.clean(summary, kind: kind, secrets: secrets()), status: status)
        store.append(packet)
        if store.count > limit { store.removeFirst(store.count - limit) }
        let snapshot = store
        let data = try? JSONEncoder().encode(snapshot)
        let url = fileURL
        let writer = write
        // Both enqueues happen inside the lock, so the order of the writes and of the publications is the call order.
        if let data {
            writeQueue.async { try? writer(data, url) }
        }
        DispatchQueue.main.async { [self] in packets = snapshot }
    }

    /// Returns when every write and publication queued so far is done. For tests; production code does not call it.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    // MARK: Flow on offer

    @MainActor func offerFlow(_ id: UUID) { offered = id }

    @MainActor func withdrawOffer() { offered = nil }

    @MainActor func takeOfferedFlow() -> UUID? {
        defer { offered = nil }
        return offered
    }

    // MARK: Load

    private struct Lossy: Decodable {
        let packet: ConnectionPacket?
        init(from decoder: Decoder) throws { packet = try? ConnectionPacket(from: decoder) }
    }

    /// A missing, empty or undecodable file gives an empty list; a packet with an unknown case is dropped alone.
    private static func load(_ url: URL, limit: Int) -> [ConnectionPacket] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return Array(all.compactMap(\.packet).suffix(limit))
    }

    // MARK: Cleaning

    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i)data:"#,
        #"[A-Za-z0-9+/=]{40,}"#,
        #"AIza[A-Za-z0-9_-]{20,}"#,
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"#,
        #"(?i)Bearer\s+."#,
        #"(?i)x-besir-token"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func removing(_ categories: Set<Unicode.GeneralCategory>, from text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !categories.contains(scalar.properties.generalCategory) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// True when the text holds anything that looks like a key, a token, an image or the app's own secrets.
    /// It runs on the text as passed and again with the characters of Cc and Cf removed.
    static func hidesSecret(_ text: String, secrets: [String]) -> Bool {
        let forms = [text, removing([.control, .format], from: text)]
        for form in forms {
            let range = NSRange(form.startIndex..., in: form)
            if secretPatterns.contains(where: { $0.firstMatch(in: form, range: range) != nil }) { return true }
        }
        let known = secrets.filter { $0.count >= 4 }
        guard !known.isEmpty else { return false }
        let compared = forms + forms.map { $0.replacingOccurrences(of: " ", with: "_") }
        return known.contains { secret in
            compared.contains { $0.range(of: secret, options: .caseInsensitive) != nil }
        }
    }

    /// The summary as it is stored (REQ-CONNECT-004 and 005).
    static func clean(_ raw: String, kind: ConnectionKind, secrets: [String]) -> String {
        if hidesSecret(raw, secrets: secrets) { return hiddenText }
        var text = removing([.control, .format, .lineSeparator, .paragraphSeparator], from: raw)
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = replacingURLs(in: text)
        if text.count > maxSummaryLength { text = String(text.prefix(maxSummaryLength - 1)) + "…" }
        return text.isEmpty ? kind.defaultSummary : text
    }

    /// Each `http` or `https` URL becomes its host alone.
    private static func replacingURLs(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        var result = text
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: host)
        }
        return result
    }

    // MARK: Time

    /// `h:mm a` for the same calendar day as `now`, else `MMM d, h:mm a`; always `en_US`.
    static func timeText(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Flows

/// The packets of one flow, oldest first.
struct ConnectionFlow: Identifiable, Equatable {
    let id: UUID
    let packets: [ConnectionPacket]
    /// Each packet's `from` then `to`, in packet order, without a party equal to the one just before it.
    let chain: [ConnectionParty]
    let latest: Date
}

enum ConnectionFlows {
    /// The screen shows at most this many flows.
    static let maxShown = 50

    /// Packets with one `flowID` form a flow; a packet without one is a flow of its own. Newest flow first.
    static func group(_ packets: [ConnectionPacket]) -> [ConnectionFlow] {
        var order: [UUID] = []
        var buckets: [UUID: [(index: Int, packet: ConnectionPacket)]] = [:]
        for (index, packet) in packets.enumerated() {
            let key = packet.flowID ?? packet.id
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append((index, packet))
        }
        let flows = order.map { key -> (flow: ConnectionFlow, last: Int) in
            let members = buckets[key] ?? []
            var chain: [ConnectionParty] = []
            var previous: (from: ConnectionParty, to: ConnectionParty)?
            for member in members {
                let pair = (from: member.packet.from, to: member.packet.to)
                // A packet between the same two parties as the one before it adds no hop (four route lookups, one line).
                if let previous, previous == pair { continue }
                previous = pair
                for party in [pair.from, pair.to] where chain.last != party { chain.append(party) }
            }
            let flow = ConnectionFlow(id: key, packets: members.map(\.packet), chain: chain,
                                      latest: members.map(\.packet.at).max() ?? .distantPast)
            return (flow, members.last?.index ?? 0)
        }
        return flows.sorted { ($0.flow.latest, $0.last) > ($1.flow.latest, $1.last) }.map(\.flow)
    }

    /// The flows the Connections screen draws: newest first, at most `maxShown`.
    static func shown(_ packets: [ConnectionPacket]) -> [ConnectionFlow] {
        Array(group(packets).prefix(maxShown))
    }

    static func chainText(_ flow: ConnectionFlow) -> String {
        flow.chain.map(\.displayName).joined(separator: " → ")
    }
}
