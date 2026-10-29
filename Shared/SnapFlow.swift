import Foundation
import CoreLocation

/// Where the frame comes from.
enum SnapSource: Equatable {
    case camera, picker
}

/// The camera permission as the flow needs it; a restricted camera counts as denied.
enum SnapAccess: Equatable {
    case authorized, notDetermined, denied
}

/// The camera device and its permission. The real one lives in `SnapCapture.swift`; tests inject a fake.
@MainActor
protocol SnapCameraAccess {
    var hasCamera: Bool { get }
    var status: SnapAccess { get }
    func request() async -> Bool
}

/// One still photo per tap: `capture` returns the photo or nil (the session was interrupted, the camera is in use).
@MainActor
protocol SnapShutter {
    func start()
    func capture() async -> Data?
    func stop()
}

/// A device with no camera (macOS): the flow falls to the photo picker.
@MainActor
struct SnapNoCamera: SnapCameraAccess, SnapShutter {
    var hasCamera: Bool { false }
    var status: SnapAccess { .denied }
    func request() async -> Bool { false }
    func start() {}
    func capture() async -> Data? { nil }
    func stop() {}
}

/// One row of the candidate list. The texts are cut and cleaned; no coordinate or link is ever shown.
struct SnapCandidate: Equatable, Identifiable {
    var id: String { "\(place.name)-\(place.latitude)-\(place.longitude)" }
    let place: Place
    let name: String
    let address: String
    let distanceText: String?

    init(_ near: NearbyPlace) {
        place = near.place
        name = AgentPlaces.displayName(near.place.name)
        address = AgentPlaces.displayAddress(near.place.address)
        distanceText = near.distanceText
    }
}

/// What a finished tap hands to the agent. `flow` is the tap's Connections flow.
enum SnapOutcome {
    case message(text: String, shown: String, flow: UUID)
    case plan(text: String, shown: String, context: DayPlanContext, flow: UUID)
}

enum SnapPhase: Equatable {
    case idle
    case ready(SnapSource)
    case capturing
    case reading
    case choosing([SnapCandidate])
    case awaitingMode
    case line(String)
    case done
}

/// The camera screen's state machine (SPEC-CAMSNAP-001): one frame in, one decision out. Every seam (camera, shutter, reader,
/// place search, calendar, agent session closures) is injected, so the whole path runs in tests. The frame is a local value
/// of one call and is never stored or written.
@MainActor
final class SnapFlow: ObservableObject {
    struct Deps {
        var reader: SnapReading
        var placeSearch: PlaceSearch
        /// The phone's real position, nil while only a guess is held.
        var realFix: () -> CLLocationCoordinate2D?
        var activities: () -> [ActivityBlock]
        var mirror: CalendarMirroring
        /// Registers the Store places in the agent session and gives the events their handles.
        var prepare: ([PlanMyDay.Event]) -> [PlanMyDay.Event]
        /// Registers one place in the agent session and returns its handle.
        var register: (Place) -> String?
        var access: SnapCameraAccess
        var shutter: SnapShutter
        var now: () -> Date = { Date() }
        var calendar: Calendar = .current
        var connections: ConnectionLog = .shared
    }

    @Published private(set) var phase: SnapPhase = .idle

    private var deps: Deps?
    /// Minted by `start`, cleared by `close`. Every step that follows an await compares it with the one it began under.
    private var generation: UUID?
    /// The Connections flow of the current tap.
    private var tap = ConnectionLog.beginFlow()
    private var cancelWork: () -> Void = {}
    private var sessionRunning = false
    private var clue: SnapClue?
    private var place: Place?
    private var outcome: SnapOutcome?

    /// The shutter of the open screen, for the view's live preview.
    var shutter: SnapShutter? { deps?.shutter }
    /// The Google mark goes under a list of Google results.
    var showsGoogleMark: Bool {
        if case .choosing = phase { return true }
        return false
    }

    func start(_ deps: Deps) {
        cancelWork()
        stopSession()
        self.deps = deps
        generation = UUID()
        clue = nil
        place = nil
        outcome = nil
        phase = .idle
    }

    func begin() async {
        guard let deps, let g = generation, phase == .idle else { return }
        guard deps.access.hasCamera else { phase = .ready(.picker); return }
        switch deps.access.status {
        case .authorized:
            startCamera(deps)
        case .notDetermined:
            let granted = await deps.access.request()
            guard generation == g else { return }
            if granted { startCamera(deps) } else { phase = .line(SnapLine.cameraOff) }
        case .denied:
            phase = .line(SnapLine.cameraOff)
        }
    }

    func shutterTapped() async {
        guard let deps, let g = generation, phase == .ready(.camera) else { return }
        phase = .capturing
        let frame = await deps.shutter.capture()
        guard generation == g else { return }
        guard let frame else {
            stopSession()
            phase = .line(SnapLine.unreadable)
            return
        }
        stopSession()
        await process(frame, g)
    }

    /// A frame from the photo picker or a test. Ignored unless the screen is ready, so one tap is one read.
    func submit(frame: Data) async {
        guard let g = generation, case .ready = phase else { return }
        await process(frame, g)
    }

    /// The picked photo is loaded under the generation the screen has now, so a late load after close is dropped.
    func pick(_ load: () async -> Data?) async {
        guard let g = generation, phase == .ready(.picker) else { return }
        let data = await load()
        guard generation == g, case .ready = phase else { return }
        guard let data else { phase = .line(SnapLine.unreadable); return }
        await submit(frame: data)
    }

    func choose(_ candidate: SnapCandidate) async {
        guard generation != nil, case .choosing(let rows) = phase, rows.contains(candidate) else { return }
        proceed(with: candidate.place)
    }

    /// The travel mode of a place to eat; nil (Cancel, or the dialog dismissed) ends the flow with nothing.
    func chooseMode(_ mode: TransportMode?) async {
        guard let deps, let g = generation, let clue, let place, phase == .awaitingMode else { return }
        guard let mode else {
            self.clue = nil
            self.place = nil
            phase = .done
            return
        }
        phase = .reading
        let entries = await PlanMyDay.todaysEntries(from: deps.mirror, now: deps.now(), calendar: deps.calendar)
        guard generation == g else { return }
        let now = deps.now()
        guard let meal = SnapPlan.suggestedMeal(now: now, calendar: deps.calendar) else { phase = .line(SnapLine.noTime); return }
        let today = PlanMyDay.events(activities: deps.activities(), entries: entries ?? [], now: now, calendar: deps.calendar)
        let events = deps.prepare(today.events)
        // The chosen place is registered last, so it is the newest entry of the registry.
        guard let handle = deps.register(place) else { phase = .line(SnapLine.assistantBusy); return }
        let text = SnapMessage.meal(now: now, zone: deps.calendar.timeZone, mode: mode, events: events, place: place, handle: handle,
                                    start: meal.start, end: meal.end)
        let dayEnd = deps.calendar.date(byAdding: .day, value: 1, to: deps.calendar.startOfDay(for: now)) ?? now
        outcome = .plan(text: text, shown: SnapMessage.shownLine(for: clue, calendarAvailable: entries != nil),
                        context: DayPlanContext(mode: mode, events: events, checkWindowEnd: dayEnd), flow: tap)
        self.clue = nil
        self.place = nil
        phase = .done
    }

    /// The finished outcome, once. It survives `close()`, which the cover may call before the hand-off reads it.
    func takeOutcome() -> SnapOutcome? {
        defer { outcome = nil }
        return outcome
    }

    func close() {
        cancelWork()
        stopSession()
        generation = nil
        clue = nil
        place = nil
        phase = .done
    }

    // MARK: Steps

    private func startCamera(_ deps: Deps) {
        deps.shutter.start()
        sessionRunning = true
        phase = .ready(.camera)
    }

    private func stopSession() {
        guard sessionRunning else { return }
        sessionRunning = false
        deps?.shutter.stop()
    }

    /// Runs `body` as a task that `close()` can cancel.
    private func cancellable<T>(_ body: @escaping () async -> T) async -> T {
        let task = Task { await body() }
        cancelWork = { task.cancel() }
        return await task.value
    }

    private func process(_ frame: Data, _ g: UUID) async {
        guard let deps else { return }
        phase = .reading
        guard deps.reader.isConfigured else { phase = .line(SharedLine.notSetUp); return }
        guard let jpeg = ImageShrink.jpeg(from: frame) else { phase = .line(SnapLine.unreadable); return }
        tap = ConnectionLog.beginFlow()
        let flow = tap
        let base64 = jpeg.base64EncodedString()
        let result = await cancellable { await deps.reader.read(imageBase64: base64, mime: "image/jpeg") }
        guard generation == g else { return }
        record(result, flow, in: deps.connections)
        switch result {
        case .failure(let failure): phase = .line(SnapLine.line(for: failure))
        case .success(let reading): await route(reading, deps, g)
        }
    }

    /// The image-read packet carries fixed words only. Nothing was sent for not set up or an unreadable image.
    private func record(_ result: Result<SnapClue, VisionFailure>, _ flow: UUID, in log: ConnectionLog) {
        switch result {
        case .success:
            log.record(from: .besir, to: .imageReader, kind: .imageRead, summary: "Image read", status: .ok, flowID: flow)
        case .failure(.notSetUp), .failure(.imageUnreadable):
            return
        case .failure:
            log.record(from: .besir, to: .imageReader, kind: .imageRead, summary: "Image read failed", status: .failed, flowID: flow)
        }
    }

    private func route(_ reading: SnapClue, _ deps: Deps, _ g: UUID) async {
        let fix = deps.realFix()
        switch SnapPlan.decide(reading, hasFix: fix != nil) {
        case .line(let line):
            phase = .line(line)
        case .poster:
            outcome = .message(text: SnapMessage.poster(clue: reading), shown: SnapMessage.shownPoster, flow: tap)
            phase = .done
        case .lookup(let query):
            guard let fix else { phase = .line(SnapLine.noLocation); return }
            let found = await cancellable {
                await deps.placeSearch.nearbyPlaces(category: nil, keyword: query, near: fix, radiusMeters: SnapPlan.radiusMeters,
                                                    sort: .distance, limit: SnapPlan.candidateLimit)
            }
            guard generation == g else { return }
            let rows = found.map(SnapCandidate.init)
            clue = reading
            switch rows.count {
            case 0: phase = .line(SnapLine.noMatch)
            case 1: proceed(with: rows[0].place)
            default: phase = .choosing(rows)
            }
        }
    }

    /// A place to eat waits for the travel mode; any other place goes to the agent at once.
    private func proceed(with chosen: Place) {
        guard let deps, let clue else { return }
        if clue.kind == .foodPlace {
            place = chosen
            phase = .awaitingMode
            return
        }
        guard let handle = deps.register(chosen) else { phase = .line(SnapLine.assistantBusy); return }
        outcome = .message(text: SnapMessage.place(now: deps.now(), zone: deps.calendar.timeZone, place: chosen, handle: handle),
                           shown: SnapMessage.shownPlace, flow: tap)
        self.clue = nil
        phase = .done
    }
}

/// Hands a finished outcome to the agent session. The tap's Connections flow is on offer to the log only while the message is
/// sent, so the agent's packets for it join the tap's flow (the share flow does the same). False, with nothing sent and no offer
/// left behind, when the session cannot take a message now.
@MainActor
enum SnapHandOff {
    static func perform(_ outcome: SnapOutcome, to session: AgentSession, connections: ConnectionLog = .shared) -> Bool {
        let accepted: Bool
        switch outcome {
        case .message(let text, let shown, let flow):
            connections.offerFlow(flow)
            accepted = SharedImport.give(message: text, shown: shown, to: session)
        case .plan(let text, let shown, let context, let flow):
            connections.offerFlow(flow)
            accepted = session.sendPlan(message: text, shown: shown, context: context)
        }
        connections.withdrawOffer()
        return accepted
    }
}

/// The camera and its shutter for this device: the AVFoundation pair on iOS, no camera elsewhere.
@MainActor
enum SnapDevice {
    static func make() -> (access: SnapCameraAccess, shutter: SnapShutter) {
#if os(iOS)
        let camera = SnapCamera()
        return (camera, camera)
#else
        let none = SnapNoCamera()
        return (none, none)
#endif
    }
}
