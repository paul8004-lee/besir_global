import XCTest
import UserNotifications
@testable import besir

/// SPEC-SHAREOPEN-001: the fixed doorbell notification a share posts, T1 to T8.
/// Every test uses `FakeNudgeCenter`; none touches the real notification center.
@MainActor
final class ShareNudgeTests: XCTestCase {
    func testSHAREOPEN_RequestIsFixedAndCarriesNothing() {
        let request = ShareNudge.request()
        let content = request.content
        XCTAssertEqual(request.identifier, "besir.share.nudge")
        XCTAssertEqual(content.title, "besir")
        XCTAssertEqual(content.body, "Tap to review what you shared.")
        XCTAssertNil(content.sound)
        XCTAssertTrue(content.userInfo.isEmpty)
        XCTAssertTrue(content.attachments.isEmpty)
        XCTAssertNil(request.trigger)
        // The defaults of everything the SPEC excludes.
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertNil(content.badge)
        XCTAssertEqual(content.categoryIdentifier, "")
        XCTAssertEqual(content.subtitle, "")
        XCTAssertEqual(content.threadIdentifier, "")
    }

    func testSHAREOPEN_PostAddsOnceWhenStored() async {
        let center = FakeNudgeCenter()
        let outcome = await ShareNudge.post(stored: true, center: center)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(center.adds.count, 1)
        let expected = ShareNudge.request()
        let added = center.adds.first
        XCTAssertEqual(added?.identifier, expected.identifier)
        XCTAssertEqual(added?.content.title, expected.content.title)
        XCTAssertEqual(added?.content.body, expected.content.body)
        XCTAssertEqual(added?.content.userInfo.isEmpty, true)
    }

    func testSHAREOPEN_PostSkipsWhenNothingStored() async {
        let center = FakeNudgeCenter()
        let outcome = await ShareNudge.post(stored: false, center: center)
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(center.adds.isEmpty)
    }

    func testSHAREOPEN_PostReturnsOnlyAfterAddFinished() async throws {
        let center = FakeNudgeCenter(mode: .parking)
        var returned = false
        var completedAtReturn = -1
        let task = Task { () -> ShareNudge.Outcome in
            let outcome = await ShareNudge.post(stored: true, center: center)
            returned = true
            completedAtReturn = center.completedAdds
            return outcome
        }
        // Wait until the add has begun and is parked (at most 2 s).
        var waited = 0
        while !center.isParked && waited < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(center.isParked, "the fake's add never began")
        // 20 checks, 10 ms apart: post has not returned while the add is parked.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertFalse(returned, "post returned before the add finished")
        }
        center.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(completedAtReturn, 1)
    }

    func testSHAREOPEN_PostReturnsFailedWhenAddThrows() async {
        let center = FakeNudgeCenter(mode: .throwing)
        let outcome = await ShareNudge.post(stored: true, center: center)
        XCTAssertEqual(outcome, .failed)
    }

    func testSHAREOPEN_TwoSharesUseOneIdentifier() async {
        let center = FakeNudgeCenter()
        _ = await ShareNudge.post(stored: true, center: center)
        _ = await ShareNudge.post(stored: true, center: center)
        XCTAssertEqual(center.adds.count, 2)
        guard center.adds.count == 2 else { return }
        XCTAssertEqual(center.adds[0].identifier, center.adds[1].identifier)
    }

    func testSHAREOPEN_ClearRemovesOnlyTheNudge() {
        let center = FakeNudgeCenter()
        ShareNudge.clear(center: center)
        XCTAssertEqual(center.removed, [["besir.share.nudge"]])
    }

    func testSHAREOPEN_ManagerClearShareNudgeUsesTheGivenCenter() {
        let center = FakeNudgeCenter()
        NotificationManager().clearShareNudge(center: center)
        XCTAssertEqual(center.removed, [["besir.share.nudge"]])
    }
}

/// Records what the nudge asked of the center. `.parking` holds `add` until `release()`, so a test can see whether `post`
/// waits for the add; `.throwing` makes `add` throw. The lock keeps the state safe across the hop `add` makes off the main actor.
final class FakeNudgeCenter: NudgeCenter, @unchecked Sendable {
    enum Mode { case succeeding, parking, throwing }
    struct AddFailed: Error {}

    private let lock = NSLock()
    private let mode: Mode
    private var _adds: [UNNotificationRequest] = []
    private var _completedAdds = 0
    private var _removed: [[String]] = []
    private var _isParked = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(mode: Mode = .succeeding) { self.mode = mode }

    var adds: [UNNotificationRequest] { lock.withLock { _adds } }
    var completedAdds: Int { lock.withLock { _completedAdds } }
    var removed: [[String]] { lock.withLock { _removed } }
    var isParked: Bool { lock.withLock { _isParked } }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _adds.append(request) }
        switch mode {
        case .throwing:
            throw AddFailed()
        case .parking:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { continuation = c; _isParked = true }
            }
        case .succeeding:
            break
        }
        lock.withLock { _completedAdds += 1 }
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {
        lock.withLock { _removed.append(identifiers) }
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let held = continuation
            continuation = nil
            return held
        }
        c?.resume()
    }
}
