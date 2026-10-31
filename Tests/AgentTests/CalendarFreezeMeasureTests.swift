import XCTest
@testable import besir

/// SPEC-CALFREEZE-001 (card t36): does one Apple Calendar mirror pass block the main thread long enough to be felt?
/// The measurement drives the real mirror over the real EventKit store and runs only when the environment variable
/// `CALFREEZE_MEASURE` is `1` and the test host already has full calendar access (it never asks for access).

/// Wraps a backend and counts what a mirror pass does to it.
@MainActor
final class RecordingCalendarBackend: CalendarBackend {
    let inner: CalendarBackend
    private(set) var creates = 0
    private(set) var updates = 0
    private(set) var removes = 0
    private(set) var requestCalls = 0
    /// Uptime at the entry of the first write since the last `reset()`.
    private(set) var firstWriteAt: TimeInterval?
    private(set) var titles: [String] = []
    /// Seconds spent inside the forwarded calls.
    private(set) var ekSeconds = 0.0
    var onWrite: (() -> Void)?

    init(inner: CalendarBackend) {
        self.inner = inner
    }

    func reset() {
        creates = 0
        updates = 0
        removes = 0
        firstWriteAt = nil
        titles = []
        ekSeconds = 0
    }

    func access() -> CalendarAccess { inner.access() }

    /// Counts the call and answers with the current state; the real request is never forwarded.
    func requestAccess() async -> CalendarAccess {
        requestCalls += 1
        return inner.access()
    }

    func create(_ draft: CalendarDraft) throws -> String {
        creates += 1
        noteWrite()
        titles.append(draft.title)
        onWrite?()
        return try timed { try inner.create(draft) }
    }

    func update(id: String, _ draft: CalendarDraft) throws -> Bool {
        updates += 1
        noteWrite()
        titles.append(draft.title)
        onWrite?()
        return try timed { try inner.update(id: id, draft) }
    }

    func remove(id: String) throws {
        removes += 1
        noteWrite()
        onWrite?()
        try timed { try inner.remove(id: id) }
    }

    func entries(from: Date, to: Date) throws -> [CalendarEntry] {
        try inner.entries(from: from, to: to)
    }

    private func noteWrite() {
        if firstWriteAt == nil { firstWriteAt = ProcessInfo.processInfo.systemUptime }
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> T {
        let begin = ProcessInfo.processInfo.systemUptime
        defer { ekSeconds += ProcessInfo.processInfo.systemUptime - begin }
        return try body()
    }
}

/// All mutable state the probe timer and the tasks of the measurement touch.
@MainActor
final class FreezeMeasureState {
    var ticks: [TimeInterval] = []
    var done = false
    /// Link files the run wrote; the teardown removes the events they still name.
    var linkURLs: [URL] = []
    /// Ids of events created in setup through the real backend.
    var setupIds: [String] = []
}

@MainActor
final class CalendarFreezeMeasureTests: XCTestCase {
    private enum MeasureFailure: Error {
        case stopped(String)
    }

    private struct Timing {
        var blockMs = 0.0
        var preMs = 0.0
        var writeMs = 0.0
        var wallMs = 0.0
        var ekMs = 0.0
        var ticksInWindow = 0
    }

    private let tickSeconds = 0.005
    private let namePrefix = "CALFREEZE "

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func ms(_ value: Double) -> String { String(format: "%.1f", value) }

    private func busy(_ seconds: TimeInterval) {
        let end = now + seconds
        while now < end {}
    }

    // MARK: window and one timed pass

    /// Polls every millisecond until a tick later than `after` exists; fails after 100 ms.
    private func waitForTick(after: TimeInterval, state: FreezeMeasureState) async throws {
        let deadline = now + 0.1
        while (state.ticks.last ?? 0) <= after {
            if now > deadline { throw MeasureFailure.stopped("probe stopped") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// The five steps of plan 3.1. `prepare` is step 1 (not timed), `start` returns `t_call`, `wait` returns `t_done`.
    private func measure(state: FreezeMeasureState, rec: RecordingCalendarBackend, prepare: () -> Void,
                         start: () -> TimeInterval, wait: () async throws -> TimeInterval) async throws -> Timing {
        prepare()
        let tSetup = now
        try await waitForTick(after: tSetup, state: state)
        let tCall = start()
        let tDone = try await wait()
        try await waitForTick(after: tDone, state: state)

        let ticks = state.ticks
        var i0 = ticks.count - 1
        while i0 > 0 && ticks[i0] > tCall { i0 -= 1 }
        var i1 = ticks.count - 1
        while i1 > 0 && ticks[i1 - 1] >= tDone { i1 -= 1 }
        guard i0 < i1, ticks[i0] <= tCall, ticks[i1] >= tDone else { throw MeasureFailure.stopped("window not found") }

        var block = 0.0
        for index in i0..<i1 {
            block = max(block, (ticks[index + 1] - ticks[index]) * 1000 - tickSeconds * 1000)
        }
        block = max(block, 0)

        var pre = block
        if let firstWrite = rec.firstWriteAt {
            var j = i0
            while j + 1 < ticks.count && ticks[j + 1] <= firstWrite { j += 1 }
            pre = min(max((firstWrite - ticks[j]) * 1000 - tickSeconds * 1000, 0), block)
        }
        return Timing(blockMs: block, preMs: pre, writeMs: block - pre, wallMs: (tDone - tCall) * 1000,
                      ekMs: rec.ekSeconds * 1000, ticksInWindow: i1 - i0 + 1)
    }

    /// One mirror pass: step 1 builds the list, steps 2 to 5 time it.
    private func timedPass(state: FreezeMeasureState, rec: RecordingCalendarBackend, mirror: AppleCalendarMirror,
                           store: Store, setup: () -> Void) async throws -> (Timing, listMs: Double) {
        var list: [ActivityBlock] = []
        var listMs = 0.0
        let timing = try await measure(state: state, rec: rec, prepare: {
            setup()
            let begin = now
            list = store.mirrorActivities(now: Date())
            listMs = (now - begin) * 1000
        }, start: {
            rec.reset()
            let tCall = now
            mirror.reconcile(list)
            return tCall
        }, wait: {
            let deadline = now + 600
            while mirror.running {
                if now > deadline { throw MeasureFailure.stopped("pass did not end in 600 s") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            return now
        })
        return (timing, listMs)
    }

    // MARK: controls

    private func runControl(_ name: String, state: FreezeMeasureState, rec: RecordingCalendarBackend) async throws -> Bool {
        state.done = false
        let timing = try await measure(state: state, rec: rec, prepare: { busy(0.2) }, start: {
            let tCall = now
            if name == "busy" {
                Task { @MainActor in
                    let end = ProcessInfo.processInfo.systemUptime + 0.3
                    while ProcessInfo.processInfo.systemUptime < end {}
                    state.done = true
                }
            }
            return tCall
        }, wait: {
            if name == "busy" {
                let deadline = now + 5
                while !state.done {
                    if now > deadline { throw MeasureFailure.stopped("busy control did not end") }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            } else {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            return now
        })
        let passed = name == "idle"
            ? timing.ticksInWindow >= 30 && timing.blockMs < 30
            : timing.blockMs >= 290 && timing.blockMs <= 400
        print("CALFREEZE-CONTROL|\(name)|ticks=\(timing.ticksInWindow)|block_ms=\(ms(timing.blockMs))|pass=\(passed ? 1 : 0)")
        return passed
    }

    // MARK: calendar helpers

    private func sweep(_ inner: CalendarBackend, start: Date, end: Date) throws -> [String] {
        try inner.entries(from: start, to: end).filter { $0.title.hasPrefix(namePrefix) }.map { $0.id }
    }

    private func dailySeries(title: String, firstDay: Date, startMinute: Int, place: Place) -> RepeatSeries {
        RepeatSeries(id: RepeatSeries.newID(), title: title, location: place,
                     rule: RecurrenceRule(unit: .daily), lunarCalendar: nil,
                     firstDayKey: Store.dayKey(firstDay), lastDayKey: nil, startMinute: startMinute,
                     endMinute: startMinute + 30, endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [],
                     legPlan: nil, legsFilledThroughDayKey: nil)
    }

    private func fileKb(_ url: URL) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        return Double(size) / 1024
    }

    // MARK: test 1

    func testCALFREEZE_MeasureMirrorPassesOnTheRealCalendar() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CALFREEZE_MEASURE"] == "1",
                          "set CALFREEZE_MEASURE=1 to run the calendar freeze measurement")
        let inner = EventKitBackend()
        let access = inner.access()
        print("CALFREEZE-ACCESS|\(access)")
        try XCTSkipUnless(access == .full, "calendar access is \(access), not full")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let sweepStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -400, to: today))
        let sweepEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 70, to: today))
        let yearAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -365, to: today))
        let windowEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: Store.mirrorWindowDays, to: today))
        let runID = UUID().uuidString
        let place = Place(name: "Freeze Place", address: "1 Freeze St", latitude: 37.5, longitude: 127.0)
        let state = FreezeMeasureState()
        let rec = RecordingCalendarBackend(inner: inner)

        let timer = Timer(timeInterval: tickSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { state.ticks.append(ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        addTeardownBlock { @MainActor in
            timer.invalidate()
            for url in state.linkURLs {
                if let file = CalendarTestSupport.loadFile(url) {
                    for link in file.links.values where !link.eventId.hasPrefix("filler-") {
                        try? inner.remove(id: link.eventId)
                    }
                }
            }
            for id in state.setupIds { try? inner.remove(id: id) }
        }

        let leftoverAtStart = try sweep(inner, start: sweepStart, end: sweepEnd)
        for id in leftoverAtStart { try inner.remove(id: id) }
        print("CALFREEZE-LEFTOVER|start|\(leftoverAtStart.count)")

        let idlePassed = try await runControl("idle", state: state, rec: rec)
        let busyPassed = try await runControl("busy", state: state, rec: rec)
        guard idlePassed && busyPassed else { throw MeasureFailure.stopped("a control failed") }

        func newMirror(_ store: Store, preFilled: CalendarLinkFile? = nil) -> (AppleCalendarMirror, URL) {
            let url = CalendarTestSupport.freshLinksURL()
            state.linkURLs.append(url)
            let mirror = AppleCalendarMirror(backend: rec, linksURL: url)
            mirror.retains = { [weak store] key in store?.retainsCalendarLink(key) ?? true }
            if let preFilled {
                XCTAssertTrue(preFilled.save(to: url), "the pre-filled link file was not saved")
            } else {
                mirror.captureBaseline([])
            }
            return (mirror, url)
        }

        /// A store with three year-old daily series and the link file that holds one filler link per occurrence.
        func yearOldSetup() -> (Store, [RepeatSeries], CalendarLinkFile) {
            let store = EmptyStore.make()
            var all: [RepeatSeries] = []
            for (index, minute) in [540, 660, 780].enumerated() {
                let series = dailySeries(title: "\(namePrefix)\(runID) Y\(index)", firstDay: yearAgo,
                                         startMinute: minute, place: place)
                XCTAssertTrue(store.addSeries(series))
                all.append(series)
            }
            var file = CalendarLinkFile()
            var number = 0
            for series in all {
                for occurrence in series.occurrences(in: DateInterval(start: yearAgo, end: windowEnd)) {
                    number += 1
                    file.links[occurrence.id.uuidString] = CalendarLink(eventId: "filler-\(number)",
                                                                       signature: CalendarDraft(occurrence))
                }
            }
            return (store, all, file)
        }

        func row(_ id: String, _ rep: Int, _ timing: Timing, _ listMs: Double, rec: RecordingCalendarBackend,
                 url: URL, expected: (Int, Int, Int), status: CalendarStatus, expectedStatus: CalendarStatus) {
            let links = CalendarTestSupport.loadFile(url)?.links.count ?? -1
            print("CALFREEZE-ROW|\(id)|\(rep)|c=\(rec.creates)|u=\(rec.updates)|r=\(rec.removes)"
                  + "|block_ms=\(ms(timing.blockMs))|pre_ms=\(ms(timing.preMs))|write_ms=\(ms(timing.writeMs))"
                  + "|wall_ms=\(ms(timing.wallMs))|ek_ms=\(ms(timing.ekMs))|list_ms=\(ms(listMs))"
                  + "|links=\(links)|file_kb=\(ms(fileKb(url)))")
            XCTAssertEqual(rec.creates, expected.0, "\(id) rep \(rep): creates")
            XCTAssertEqual(rec.updates, expected.1, "\(id) rep \(rep): updates")
            XCTAssertEqual(rec.removes, expected.2, "\(id) rep \(rep): removes")
            XCTAssertEqual(status, expectedStatus, "\(id) rep \(rep): status")
        }

        /// Removes the events a pass wrote, through the real backend, so the next scenario starts clean.
        func removeWritten(from url: URL) {
            guard let file = CalendarTestSupport.loadFile(url) else { return }
            for link in file.links.values where !link.eventId.hasPrefix("filler-") {
                try? inner.remove(id: link.eventId)
            }
        }

        for rep in 0...3 {
            // S1, S3, S4: one daily series added, moved as a whole, deleted as a whole.
            let store1 = EmptyStore.make()
            let series1 = dailySeries(title: "\(namePrefix)\(runID) S1", firstDay: today, startMinute: 540, place: place)
            XCTAssertTrue(store1.addSeries(series1))
            let (mirror1, url1) = newMirror(store1)

            let (s1, s1List) = try await timedPass(state: state, rec: rec, mirror: mirror1, store: store1, setup: {})
            row("S1", rep, s1, s1List, rec: rec, url: url1, expected: (60, 0, 0), status: mirror1.status,
                expectedStatus: .ok)

            let (s3, s3List) = try await timedPass(state: state, rec: rec, mirror: mirror1, store: store1, setup: {
                let todays = store1.mirrorActivities(now: Date()).min { $0.startDate < $1.startDate }
                if let todays { store1.moveActivity(todays, byMinutes: 30, wholeSeries: true) }
            })
            row("S3", rep, s3, s3List, rec: rec, url: url1, expected: (0, 60, 0), status: mirror1.status,
                expectedStatus: .ok)

            let (s4, s4List) = try await timedPass(state: state, rec: rec, mirror: mirror1, store: store1, setup: {
                store1.deleteRecurringSeries(series1.id)
            })
            row("S4", rep, s4, s4List, rec: rec, url: url1, expected: (0, 0, 60), status: mirror1.status,
                expectedStatus: .ok)

            // S2: three series reach the mirror at once; an untimed pass then removes the 180 events.
            let store2 = EmptyStore.make()
            var threeSeries: [RepeatSeries] = []
            for (index, minute) in [540, 660, 780].enumerated() {
                let series = dailySeries(title: "\(namePrefix)\(runID) S2-\(index)", firstDay: today,
                                         startMinute: minute, place: place)
                XCTAssertTrue(store2.addSeries(series))
                threeSeries.append(series)
            }
            let (mirror2, url2) = newMirror(store2)
            let (s2, s2List) = try await timedPass(state: state, rec: rec, mirror: mirror2, store: store2, setup: {})
            row("S2", rep, s2, s2List, rec: rec, url: url2, expected: (180, 0, 0), status: mirror2.status,
                expectedStatus: .ok)
            for series in threeSeries { store2.deleteRecurringSeries(series.id) }
            mirror2.reconcile(store2.mirrorActivities(now: Date()))
            let cleanupDeadline = now + 600
            while mirror2.running && now < cleanupDeadline { try await Task.sleep(nanoseconds: 1_000_000) }

            // Y0: any save, one year in. Nothing is written.
            let (storeY0, _, fileY0) = yearOldSetup()
            let (mirrorY0, urlY0) = newMirror(storeY0, preFilled: fileY0)
            let (y0, y0List) = try await timedPass(state: state, rec: rec, mirror: mirrorY0, store: storeY0, setup: {})
            row("Y0", rep, y0, y0List, rec: rec, url: urlY0, expected: (0, 0, 0), status: mirrorY0.status,
                expectedStatus: .idle)

            // Y1: a fourth series is added one year in; its 60 events are removed afterwards.
            let (storeY1, _, fileY1) = yearOldSetup()
            let (mirrorY1, urlY1) = newMirror(storeY1, preFilled: fileY1)
            XCTAssertTrue(storeY1.addSeries(dailySeries(title: "\(namePrefix)\(runID) Y1-new", firstDay: today,
                                                        startMinute: 900, place: place)))
            let (y1, y1List) = try await timedPass(state: state, rec: rec, mirror: mirrorY1, store: storeY1, setup: {})
            row("Y1", rep, y1, y1List, rec: rec, url: urlY1, expected: (60, 0, 0), status: mirrorY1.status,
                expectedStatus: .ok)
            removeWritten(from: urlY1)

            // Y2: a year-old series is deleted; its 425 links point at real events made in setup.
            let (storeY2, seriesY2, plainY2) = yearOldSetup()
            var fileY2 = plainY2
            var created = 0
            for occurrence in seriesY2[0].occurrences(in: DateInterval(start: yearAgo, end: windowEnd)) {
                let eventId = try inner.create(CalendarDraft(occurrence))
                state.setupIds.append(eventId)
                fileY2.links[occurrence.id.uuidString] = CalendarLink(eventId: eventId,
                                                                      signature: CalendarDraft(occurrence))
                created += 1
            }
            XCTAssertEqual(created, 425, "Y2 setup events")
            let (mirrorY2, urlY2) = newMirror(storeY2, preFilled: fileY2)
            let (y2, y2List) = try await timedPass(state: state, rec: rec, mirror: mirrorY2, store: storeY2, setup: {
                storeY2.deleteRecurringSeries(seriesY2[0].id)
            })
            row("Y2", rep, y2, y2List, rec: rec, url: urlY2, expected: (0, 0, 425), status: mirrorY2.status,
                expectedStatus: .ok)
            state.setupIds.removeAll()
        }

        print("CALFREEZE-REQUESTS|\(rec.requestCalls)")
        XCTAssertEqual(rec.requestCalls, 0, "test 1 must never ask for access")
        let leftoverAtEnd = try sweep(inner, start: sweepStart, end: sweepEnd)
        print("CALFREEZE-LEFTOVER|end|\(leftoverAtEnd.count)")
        for id in leftoverAtEnd { try? inner.remove(id: id) }
        XCTAssertEqual(leftoverAtEnd.count, 0, "events titled \(namePrefix) were left in the calendar")
    }
}
