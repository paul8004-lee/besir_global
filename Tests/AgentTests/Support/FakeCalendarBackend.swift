import Foundation
@testable import besir

/// Scripted calendar for the mirror tests: an access state, a request result, per-call counters, failure
/// injection, a gate that holds `requestAccess`, and an event table. Everything runs on the main actor, so
/// the state a test waits for is set before the test can observe it.
@MainActor
final class FakeCalendarBackend: CalendarBackend {
    var accessState: CalendarAccess = .full
    var requestResult: CalendarAccess = .full
    /// Create call number (1-based) -> the error that call throws.
    var createErrors: [Int: CalendarBackendError] = [:]
    /// What `entries(from:to:)` returns.
    var entriesResult: [CalendarEntry] = []
    var entriesError: Error?

    private(set) var accessCalls = 0
    private(set) var requestCalls = 0
    private(set) var createCalls = 0
    private(set) var updateCalls = 0
    private(set) var removeCalls = 0
    private(set) var entriesCalls = 0
    private(set) var lastWindow: (from: Date, to: Date)?

    /// Events by identifier; `create` adds, `remove` deletes, `userDelete` is the user's own deletion.
    private(set) var events: [String: CalendarDraft] = [:]
    private var nextId = 1

    var totalWriteCalls: Int { createCalls + updateCalls + removeCalls }

    // MARK: request gate

    private var holdEnabled = false
    private var heldContinuation: CheckedContinuation<Void, Never>?
    /// True while `requestAccess` is parked inside the hold.
    private(set) var isHoldingRequest = false

    func holdRequest() { holdEnabled = true }

    func releaseRequest() {
        holdEnabled = false
        heldContinuation?.resume()
        heldContinuation = nil
    }

    /// Waits until the fake reports it holds the request; returns false after 5 seconds.
    func waitUntilHolding() async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !isHoldingRequest {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: CalendarBackend

    func access() -> CalendarAccess {
        accessCalls += 1
        return accessState
    }

    func requestAccess() async -> CalendarAccess {
        requestCalls += 1
        if holdEnabled {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                heldContinuation = continuation
                isHoldingRequest = true
            }
            isHoldingRequest = false
        }
        accessState = requestResult
        return requestResult
    }

    func create(_ draft: CalendarDraft) throws -> String {
        createCalls += 1
        if let error = createErrors[createCalls] { throw error }
        let id = "fake-\(nextId)"
        nextId += 1
        events[id] = draft
        return id
    }

    func update(id: String, _ draft: CalendarDraft) throws -> Bool {
        updateCalls += 1
        guard events[id] != nil else { return false }
        events[id] = draft
        return true
    }

    func remove(id: String) throws {
        removeCalls += 1
        events[id] = nil
    }

    func entries(from: Date, to: Date) throws -> [CalendarEntry] {
        entriesCalls += 1
        lastWindow = (from, to)
        if let entriesError { throw entriesError }
        return entriesResult
    }

    /// The user deletes an event in the Calendar app.
    func userDelete(_ id: String) { events[id] = nil }
}
