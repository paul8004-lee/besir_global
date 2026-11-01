import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import besir

/// Counts the posts of `BudgetLedger.didChange`, by the object each one carried.
private final class PostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject?] = []

    func add(_ object: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        objects.append(object)
    }

    func count(for ledger: BudgetLedger) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.filter { $0 === ledger }.count
    }
}

/// A flag a stub closure sets once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// True the first time it is called, false after.
    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { done = true }
        return !done
    }
}

/// SPEC-RICHHAND-001 (card t103): the neutral budget desk, the ledger's week read and change notice, the screen texts, the
/// screen model and the lobby row.
@MainActor
final class BudgetDeskTests: XCTestCase {
    typealias Problem = BeRichSirModel.Problem

    // MARK: Helpers

    private struct Desked {
        let rig: BudgetToolRig
        let desk: BudgetDesk
        let model: BeRichSirModel
    }

    /// A rig whose ledger, stub partner and connection log also back a desk and a screen model on the rig's clock.
    private func makeDesked(config: AppConfig = BudgetToolFixture.config) -> Desked {
        let rig = BudgetToolRig(config: config)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let client = BudgetClient(config: config, ledger: rig.ledger, send: rig.partner.send, connections: rig.log)
        let desk = BudgetDesk(client: client)
        let clock = rig.clock
        let model = BeRichSirModel(desk: desk, now: { clock.now }, zone: { clock.zone })
        return Desked(rig: rig, desk: desk, model: model)
    }

    private func entry(_ cents: Int, estimate: Bool = false, week: String = BudgetToolFixture.week,
                       id: String = UUID().uuidString) -> BudgetEntry {
        BudgetEntry(requestID: id, weekStart: week, amountCents: cents, isEstimate: estimate)
    }

    private func standing(spent: Int, estimate: Bool = false, week: String = BudgetToolFixture.week) -> BudgetStanding {
        BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: spent, leftCents: 20000 - spent, isWithin: spent <= 20000,
                       includesEstimate: estimate)
    }

    /// The `op` of every request the stub partner has seen, in order.
    private func ops(_ rig: BudgetToolRig) -> [String] {
        (0..<rig.partner.requests.count).map { rig.partner.body($0)?["op"] as? String ?? "" }
    }

    /// Waits while the model runs a request.
    private func idle(_ model: BeRichSirModel) async {
        var waited = 0
        while model.isBusy && waited < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }

    /// Lets the events of a ledger change reach the model, then waits for any request they started.
    private func settle(_ model: BeRichSirModel) async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        await idle(model)
    }

    /// Amounts the gate refuses (the G04 list of `AgentBudgetToolTests`).
    private let refusedAmounts = ["", " 18", "18 ", "-5", "+5", "1,000", "$18", "18.", ".5", "0", "0.00", "0.001", "10000.01", "100000",
                                  "1e2", "\u{0661}\u{0668}", "NaN"]

    private func without(_ object: [String: Any]?, _ key: String) -> NSDictionary {
        var copy = object ?? [:]
        copy[key] = nil
        return NSDictionary(dictionary: copy)
    }

    // MARK: T01 the desk makes the week and checks the amount

    func testRICHHAND_T01_TheDeskMakesTheWeekAndChecksTheAmountByTheRuleOfRecordSpend() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = Date(timeIntervalSince1970: 1_793_588_400)
        XCTAssertEqual(BudgetDesk.week(now: instant, zone: utc), "2026-11-02")
        XCTAssertEqual(BudgetDesk.week(now: instant, zone: la), "2026-10-26")
        XCTAssertEqual(BudgetDesk.week(now: instant, zone: utc), BudgetWeek.start(of: instant, in: utc))
        XCTAssertEqual(BudgetDesk.week(now: instant, zone: la), BudgetWeek.start(of: instant, in: la))
        let sunday = TestClock.date("2026-11-01T23:59")
        XCTAssertEqual(BudgetDesk.week(now: sunday, zone: TestClock.zone), "2026-10-26")

        let accepted: [(String, Int)] = [("18.50", 1850), ("5", 500), ("00018", 1800), ("10000.00", 1_000_000), ("0.01", 1)]
        for (text, cents) in accepted {
            let plan = try XCTUnwrap(BudgetDesk.spendPlan(amountText: text, now: instant, zone: la), text)
            XCTAssertEqual(plan.cents, cents, text)
            XCTAssertEqual(plan.cents, AgentBudget.parseAmountCents(text), text)
            XCTAssertEqual(plan.weekStart, "2026-10-26", text)
            XCTAssertNotNil(UUID(uuidString: plan.requestID), text)
        }
        let inUTC = try XCTUnwrap(BudgetDesk.spendPlan(amountText: "18.50", now: instant, zone: utc))
        XCTAssertEqual(inUTC.weekStart, "2026-11-02")

        for text in refusedAmounts {
            XCTAssertNil(BudgetDesk.spendPlan(amountText: text, now: instant, zone: la), text.debugDescription)
        }

        let first = try XCTUnwrap(BudgetDesk.spendPlan(amountText: "5", now: instant, zone: la))
        let second = try XCTUnwrap(BudgetDesk.spendPlan(amountText: "5", now: instant, zone: la))
        XCTAssertNotEqual(first.requestID, second.requestID)
        let given = UUID().uuidString
        let kept = try XCTUnwrap(BudgetDesk.spendPlan(amountText: "5", now: instant, zone: la, requestID: given))
        XCTAssertEqual(kept.requestID, given)
    }

    // MARK: T02 the desk sends one request and writes only on an exact answer

    func testRICHHAND_T02_TheDeskSendsOneLeftOrOneStatedSpendAndWritesTheLedgerOnlyOnAnExactAnswer() async throws {
        let week = BudgetToolFixture.week

        // left
        let ask = makeDesked()
        ask.rig.hold(5000)
        let askFlow = UUID()
        let answer = await ask.desk.askLeft(weekStart: week, flow: askFlow)
        XCTAssertEqual(ask.rig.partner.requests.count, 1)
        XCTAssertEqual(Set(ask.rig.partner.body()?.keys.map { $0 } ?? []), ["op", "week_start", "spent_cents"])
        XCTAssertEqual(ask.rig.partner.body()?["op"] as? String, "left")
        XCTAssertEqual(ask.rig.partner.body()?["spent_cents"] as? Int, 5000)
        XCTAssertEqual(answer, .success(standing(spent: 5000)))
        XCTAssertTrue(ask.desk.isConfigured)
        let askPackets = await ask.rig.packets()
        XCTAssertEqual(askPackets.map(\.summary), ["Budget left asked", "Budget left answered"])
        XCTAssertEqual(askPackets.map(\.flowID), [askFlow, askFlow])

        // spend
        let spend = makeDesked()
        let plan = BudgetSpendPlan(cents: 1850, weekStart: week, requestID: UUID().uuidString)
        let spendFlow = UUID()
        let applied = await spend.desk.send(plan, flow: spendFlow)
        XCTAssertEqual(spend.rig.partner.requests.count, 1)
        XCTAssertEqual(Set(spend.rig.partner.body()?.keys.map { $0 } ?? []),
                       ["op", "week_start", "spent_cents", "amount_cents", "request_id"])
        XCTAssertEqual(spend.rig.partner.body()?["op"] as? String, "spend")
        XCTAssertEqual(spend.rig.partner.body()?["request_id"] as? String, plan.requestID)
        XCTAssertEqual(spend.rig.partner.body()?["amount_cents"] as? Int, 1850)
        XCTAssertEqual(applied, .success(standing(spent: 1850)))
        XCTAssertEqual(spend.rig.ledger.weekEntries(weekStart: week).count, 1)
        XCTAssertEqual(spend.rig.ledger.entry(requestID: plan.requestID)?.isEstimate, false)
        XCTAssertEqual(spend.rig.entries.count, 1)
        let spendPackets = await spend.rig.packets()
        XCTAssertEqual(spendPackets.map(\.summary), ["Spend sent", "Spend recorded"])
        XCTAssertEqual(spendPackets.map(\.flowID), [spendFlow, spendFlow])

        // the same plan twice makes one request
        let again = await spend.desk.send(plan, flow: UUID())
        XCTAssertEqual(spend.rig.partner.requests.count, 1)
        XCTAssertEqual(again, .failure(.other))
        XCTAssertEqual(spend.rig.entries.count, 1)

        // a failed request writes nothing and records one failure
        let failures: [(String, BudgetToolPartner.Mode, BudgetFailure)] = [
            ("offline", .error(URLError(.notConnectedToInternet)), .offline), ("server", .status(500, "oops"), .other),
            ("missing route", .status(404, "Not found"), .other), ("token", .status(401, #"{"error":"unauthorized"}"#), .tokenRejected),
        ]
        for (name, mode, expected) in failures {
            let failing = makeDesked()
            failing.rig.hold(1000)
            failing.rig.partner.mode = mode
            let result = await failing.desk.send(BudgetSpendPlan(cents: 1850, weekStart: week, requestID: UUID().uuidString), flow: UUID())
            XCTAssertEqual(failing.rig.partner.requests.count, 1, name)
            XCTAssertEqual(result, .failure(expected), name)
            XCTAssertEqual(failing.rig.ledger.spentCents(weekStart: week), 1000, name)
            XCTAssertEqual(failing.rig.entries.count, 1, name)
            let lines = await failing.rig.lines()
            XCTAssertEqual(lines, ["besir>budgetPartner budget failed Request failed"], name)
        }

        // no proxy
        let off = makeDesked(config: BudgetToolFixture.unconfigured)
        XCTAssertFalse(off.desk.isConfigured)
        let offLeft = await off.desk.askLeft(weekStart: week, flow: UUID())
        let offSend = await off.desk.send(BudgetSpendPlan(cents: 1850, weekStart: week, requestID: UUID().uuidString), flow: UUID())
        XCTAssertEqual(offLeft, .failure(.notSetUp))
        XCTAssertEqual(offSend, .failure(.notSetUp))
        XCTAssertEqual(off.rig.partner.requests.count, 0)
        let offPackets = await off.rig.packets()
        XCTAssertTrue(offPackets.isEmpty)
        XCTAssertTrue(off.rig.entries.isEmpty)
    }

    // MARK: T03 the ledger lists a week and announces every change

    func testRICHHAND_T03_TheLedgerListsOneWeeksEntriesInOrderAndAnnouncesEveryChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-desk-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(BudgetLedger.fileName)
        let ledger = BudgetLedger(fileURL: file)
        let other = BudgetLedger(fileURL: folder.appendingPathComponent("other.json"))
        let weekA = BudgetToolFixture.week
        let weekB = "2026-11-02"
        let spend = entry(1850, week: weekA)
        let estimate = entry(6000, estimate: true, week: weekA)
        let later = entry(2500, week: weekB)

        let counter = PostCounter()
        let token = NotificationCenter.default.addObserver(forName: BudgetLedger.didChange, object: nil, queue: nil) {
            counter.add($0.object as AnyObject?)
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(ledger.add(spend))
        XCTAssertTrue(ledger.add(estimate))
        XCTAssertTrue(ledger.add(later))
        XCTAssertEqual(ledger.weekEntries(weekStart: weekA).count, 2)
        XCTAssertEqual(ledger.weekEntries(weekStart: weekA), [spend, estimate])
        XCTAssertEqual(ledger.weekEntries(weekStart: weekA).map(\.isEstimate), [false, true])
        XCTAssertEqual(ledger.weekEntries(weekStart: weekB), [later])
        XCTAssertEqual(ledger.weekEntries(weekStart: "2026-11-09"), [])

        let client = BudgetClient(config: BudgetToolFixture.config, ledger: ledger, send: BudgetToolPartner().send,
                                  connections: ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName)))
        XCTAssertEqual(client.weekEntries(weekStart: weekA), [spend, estimate])
        XCTAssertEqual(client.weekEntries(weekStart: "2026-11-09"), [])

        XCTAssertEqual(counter.count(for: ledger), 3, "one post per effective add")
        XCTAssertFalse(ledger.add(spend))
        XCTAssertFalse(ledger.remove(requestID: "no-such-id"))
        XCTAssertEqual(counter.count(for: ledger), 3, "a duplicate id and a missing id post nothing")
        XCTAssertTrue(ledger.remove(requestID: estimate.requestID))
        XCTAssertEqual(counter.count(for: ledger), 4, "one post per effective remove")
        XCTAssertEqual(ledger.weekEntries(weekStart: weekA), [spend])

        XCTAssertTrue(other.add(entry(100, week: weekA)))
        XCTAssertEqual(counter.count(for: ledger), 4, "another ledger's change is not this ledger's")
        XCTAssertEqual(counter.count(for: other), 1)

        let data = try Data(contentsOf: file)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(saved.count, 2)
        for item in saved {
            XCTAssertEqual(Set(item.keys), ["requestID", "weekStart", "amountCents", "isEstimate"])
        }
    }

    // MARK: T04 the screen's texts

    func testRICHHAND_T04_TheScreenTextsAreFactsOnlyEnglishAndMarkEstimates() throws {
        XCTAssertEqual(AgentBudget.standingWords(standing(spent: 6000)), "$140.00 left")
        XCTAssertEqual(AgentBudget.standingWords(standing(spent: 20000)), "$0.00 left")
        XCTAssertEqual(AgentBudget.standingWords(standing(spent: 25000)), "$50.00 over")
        XCTAssertEqual(AgentBudget.standingWords(standing(spent: 143_450)), "$1,234.50 over")
        XCTAssertEqual(AgentBudget.entryText(entry(1850)), "$18.50")
        XCTAssertEqual(AgentBudget.entryText(entry(9000, estimate: true)), "Estimate $90.00")
        XCTAssertEqual(AgentBudget.entryText(entry(5)), "$0.05")
        XCTAssertEqual(AgentBudget.partnerLabel, "Example Budget (Simulated)")

        XCTAssertEqual(Problem.amount.line, "Enter an amount from 0.01 to 10000.00.")
        XCTAssertEqual(Problem.notSetUp.line, "Budget is not set up.")
        XCTAssertEqual(Problem.offline.line, "You are offline.")
        XCTAssertEqual(Problem.unreachable.line, "Budget could not be reached.")

        let advice = try NSRegularExpression(pattern: #"\b(should|recommend|advise|afford|save|invest|cut back|stop spending|overspend)\b"#,
                                             options: [.caseInsensitive])
        func hits(_ text: String) -> Int { advice.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
        XCTAssertEqual(hits("You should save and invest. Do not overspend. Stop spending, cut back, afford it, advise, recommend."), 9)
        XCTAssertEqual(hits("Give no advice about savings or the saved amount."), 0)
        let lines = [Problem.amount, .notSetUp, .offline, .unreachable].map(\.line)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertTrue(line.allSatisfy(\.isASCII), line)
            XCTAssertEqual(hits(line), 0, line)
        }
        let words = [AgentBudget.standingWords(standing(spent: 6000)), AgentBudget.entryText(entry(9000, estimate: true))]
        for word in words {
            XCTAssertFalse(word.isEmpty)
            XCTAssertEqual(hits(word), 0, word)
        }
    }

    // MARK: T05 the model asks once on appear and lists this week's entries

    func testRICHHAND_T05_TheScreenModelAsksOnceOnAppearAndListsThisWeeksEntriesNewestFirst() async throws {
        let week = BudgetToolFixture.week
        let spend = entry(1850)
        let estimate = entry(6000, estimate: true)
        let elsewhere = entry(2500, week: "2026-11-02")

        let ok = makeDesked()
        for item in [spend, estimate, elsewhere] { ok.rig.ledger.add(item) }
        await ok.model.appear()
        XCTAssertEqual(ok.rig.partner.requests.count, 1)
        XCTAssertEqual(ok.rig.partner.body()?["op"] as? String, "left")
        XCTAssertEqual(ok.rig.partner.body()?["week_start"] as? String, week)
        XCTAssertEqual(ok.rig.partner.body()?["spent_cents"] as? Int, 7850)
        XCTAssertEqual(ok.model.standing, standing(spent: 7850, estimate: true))
        XCTAssertEqual(ok.model.standing?.includesEstimate, true)
        XCTAssertEqual(ok.model.rows, [estimate, spend])
        XCTAssertNil(ok.model.problem)
        XCTAssertTrue(ok.rig.partner.requests.allSatisfy { $0.url?.path == "/budget" })
        let packets = await ok.rig.packets()
        XCTAssertEqual(packets.map(\.summary), ["Budget left asked", "Budget left answered"])
        XCTAssertNotNil(packets.first?.flowID)
        XCTAssertEqual(Set(packets.map(\.flowID)).count, 1)

        let empty = makeDesked()
        await empty.model.appear()
        XCTAssertEqual(empty.rig.partner.requests.count, 1)
        XCTAssertEqual(empty.model.rows, [])
        XCTAssertNil(empty.model.problem)
        XCTAssertEqual(empty.model.standing, standing(spent: 0))

        let failures: [(String, BudgetToolPartner.Mode, Problem)] = [
            ("offline", .error(URLError(.notConnectedToInternet)), .offline), ("server", .status(500, "oops"), .unreachable),
            ("token", .status(401, #"{"error":"unauthorized"}"#), .unreachable),
        ]
        for (name, mode, expected) in failures {
            let failing = makeDesked()
            failing.rig.ledger.add(spend)
            failing.rig.partner.mode = mode
            await failing.model.appear()
            XCTAssertEqual(failing.rig.partner.requests.count, 1, name)
            XCTAssertEqual(failing.model.problem, expected, name)
            XCTAssertNil(failing.model.standing, name)
            XCTAssertEqual(failing.model.rows, [spend], name)
        }

        let off = makeDesked(config: BudgetToolFixture.unconfigured)
        off.rig.ledger.add(spend)
        await off.model.appear()
        XCTAssertEqual(off.rig.partner.requests.count, 0)
        XCTAssertEqual(off.model.problem, Problem.notSetUp)
        XCTAssertNil(off.model.standing)
        XCTAssertEqual(off.model.rows, [spend])
    }

    // MARK: T06 recording

    func testRICHHAND_T06_RecordingSendsOneSpendShowsTheAnswersStandingAndKeepsTheTextOnAnyRefusal() async throws {
        let week = BudgetToolFixture.week

        let good = makeDesked()
        good.model.amountText = "18.50"
        await good.model.record()
        XCTAssertEqual(good.rig.partner.requests.count, 1)
        XCTAssertEqual(good.rig.partner.body()?["op"] as? String, "spend")
        XCTAssertEqual(good.rig.partner.body()?["amount_cents"] as? Int, 1850)
        XCTAssertEqual(good.rig.entries.count, 1)
        XCTAssertEqual(good.rig.ledger.entry(requestID: good.rig.partner.body()?["request_id"] as? String ?? "")?.isEstimate, false)
        XCTAssertEqual(good.model.standing, standing(spent: 1850))
        XCTAssertEqual(good.model.rows.first?.amountCents, 1850)
        XCTAssertEqual(good.model.rows.count, 1)
        XCTAssertEqual(good.model.amountText, "")
        XCTAssertNil(good.model.problem)
        XCTAssertFalse(good.model.isBusy)

        // every refused text: a warning, no request, the text kept, the ledger unchanged
        let refusing = makeDesked()
        for text in refusedAmounts + ["   "] {
            refusing.model.amountText = text
            await refusing.model.record()
            XCTAssertEqual(refusing.model.problem, Problem.amount, text.debugDescription)
            XCTAssertEqual(refusing.model.amountText, text, text.debugDescription)
            XCTAssertEqual(refusing.rig.partner.requests.count, 0, text.debugDescription)
            XCTAssertTrue(refusing.rig.entries.isEmpty, text.debugDescription)
        }
        XCTAssertEqual(refusing.model.rows, [])
        XCTAssertFalse(refusing.model.isBusy)

        // a failure after a good record keeps the ledger, the text and the earlier figure
        let failing = makeDesked()
        failing.model.amountText = "18.50"
        await failing.model.record()
        let earlier = failing.model.standing
        XCTAssertNotNil(earlier)
        failing.rig.partner.mode = .status(500, "oops")
        failing.model.amountText = "5"
        await failing.model.record()
        XCTAssertEqual(failing.rig.partner.requests.count, 2)
        XCTAssertEqual(failing.model.problem, Problem.unreachable)
        XCTAssertEqual(failing.rig.entries.count, 1)
        XCTAssertEqual(failing.model.rows.count, 1)
        XCTAssertEqual(failing.model.amountText, "5")
        XCTAssertEqual(failing.model.standing, earlier)
        XCTAssertFalse(failing.model.isBusy)

        // two records started together make one request
        let twin = makeDesked()
        twin.model.amountText = "7"
        async let first: Void = twin.model.record()
        async let second: Void = twin.model.record()
        _ = await (first, second)
        XCTAssertEqual(twin.rig.partner.requests.count, 1)
        XCTAssertEqual(twin.rig.entries.count, 1)
        XCTAssertFalse(twin.model.isBusy)

        // each action has a flow of its own
        let flows = makeDesked()
        await flows.model.appear()
        flows.model.amountText = "18.50"
        await flows.model.record()
        flows.model.amountText = "5"
        await flows.model.record()
        let packets = await flows.rig.packets()
        XCTAssertEqual(packets.map(\.summary), ["Budget left asked", "Budget left answered", "Spend sent", "Spend recorded",
                                               "Spend sent", "Spend recorded"])
        if packets.count == 6 {
            let ids = stride(from: 0, to: 6, by: 2).map { packets[$0].flowID }
            XCTAssertEqual(packets.map(\.flowID), [ids[0], ids[0], ids[1], ids[1], ids[2], ids[2]])
            XCTAssertEqual(Set(ids).count, 3)
            XCTAssertFalse(ids.contains(nil))
        } else {
            XCTFail("expected six packets, found \(packets.count)")
        }
        XCTAssertEqual(flows.rig.ledger.spentCents(weekStart: week), 2350)
    }

    // MARK: T07 a change made by another path

    func testRICHHAND_T07_AChangeMadeByAnotherPathRefreshesTheListAndAsksAgainOnlyWhenTheTotalDiffers() async throws {
        let week = BudgetToolFixture.week

        // a booking's estimate
        let f = makeDesked()
        await f.model.appear()
        let booked = entry(6000, estimate: true)
        f.rig.ledger.add(booked)
        await f.model.ledgerChanged()
        await settle(f.model)
        XCTAssertEqual(f.model.rows.count, 1)
        XCTAssertEqual(f.model.rows, [booked])
        XCTAssertEqual(ops(f.rig), ["left", "left"])
        XCTAssertEqual(f.model.standing, standing(spent: 6000, estimate: true))

        // no change, no request
        await f.model.ledgerChanged()
        await settle(f.model)
        XCTAssertEqual(ops(f.rig), ["left", "left"])

        // the model's own record asks nothing more
        f.model.amountText = "5"
        await f.model.record()
        await settle(f.model)
        XCTAssertEqual(ops(f.rig), ["left", "left", "spend"])
        await f.model.ledgerChanged()
        await settle(f.model)
        XCTAssertEqual(ops(f.rig), ["left", "left", "spend"])

        // a spend made by the chat tool on the same ledger
        _ = await f.rig.run(f.rig.spend("7"))
        await f.model.ledgerChanged()
        await settle(f.model)
        XCTAssertEqual(f.model.rows.count, 3)
        XCTAssertEqual(f.model.rows.first?.amountCents, 700)
        XCTAssertEqual(ops(f.rig), ["left", "left", "spend", "spend", "left"])
        XCTAssertEqual(f.model.standing?.spentCents, f.rig.ledger.spentCents(weekStart: week))

        // a ledger add made while the appearance's request runs
        let racing = makeDesked()
        let once = Once()
        let ledger = racing.rig.ledger
        let sneaked = entry(6000, estimate: true)
        racing.rig.partner.duringSend = { if once.first() { ledger.add(sneaked) } }
        await racing.model.appear()
        await settle(racing.model)
        XCTAssertEqual(ops(racing.rig), ["left", "left"])
        XCTAssertEqual(racing.model.standing?.spentCents, ledger.spentCents(weekStart: week))
        XCTAssertEqual(racing.model.rows, [sneaked])

        // a removal
        let removing = makeDesked()
        let gone = entry(6000, estimate: true)
        removing.rig.ledger.add(gone)
        await removing.model.appear()
        XCTAssertEqual(removing.model.standing?.includesEstimate, true)
        removing.rig.ledger.remove(requestID: gone.requestID)
        await removing.model.ledgerChanged()
        await settle(removing.model)
        XCTAssertEqual(removing.model.rows, [])
        XCTAssertEqual(ops(removing.rig), ["left", "left"])
        XCTAssertEqual(removing.model.standing?.includesEstimate, false)
        XCTAssertEqual(removing.model.standing?.spentCents, 0)

        // with start() called, a change from outside arrives by itself
        let watching = makeDesked()
        await watching.model.appear()
        watching.model.start()
        let outside = entry(4000)
        watching.rig.ledger.add(outside)
        let refreshed = expectation(description: "the list and the figure follow the ledger")
        let poll = Task { @MainActor in
            while !Task.isCancelled && !(watching.model.rows == [outside] && !watching.model.isBusy
                                            && watching.model.standing?.spentCents == 4000) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 2)
        poll.cancel()
        XCTAssertEqual(watching.model.rows, [outside])
        XCTAssertEqual(ops(watching.rig), ["left", "left"])
        XCTAssertEqual(watching.model.standing?.spentCents, watching.rig.ledger.spentCents(weekStart: week))

        // a request that fails asks nothing more, and the figure shown before stays
        let failing = makeDesked()
        await failing.model.appear()
        let shown = failing.model.standing
        XCTAssertNotNil(shown)
        failing.rig.ledger.add(entry(3000))
        failing.rig.partner.mode = .status(500, "oops")
        let before = failing.rig.partner.requests.count
        await failing.model.ledgerChanged()
        await settle(failing.model)
        XCTAssertEqual(failing.rig.partner.requests.count - before, 1)
        XCTAssertEqual(failing.model.standing, shown)
        XCTAssertEqual(failing.model.rows.count, 1)
    }

    // MARK: T08 the chat tool and the desk

    func testRICHHAND_T08_TheChatToolAndTheDeskMakeTheSameRequestsPacketsAndLedgerEntries() async throws {
        let tool = makeDesked()
        let desk = makeDesked()
        let week = BudgetToolFixture.week

        // left
        let toolLeft = try await tool.rig.runJSON(tool.rig.call("get_budget_left"))
        let deskLeft = await desk.desk.askLeft(weekStart: week, flow: ConnectionLog.beginFlow())
        XCTAssertEqual(desk.rig.partner.requests.count, tool.rig.partner.requests.count)
        XCTAssertEqual(desk.rig.partner.body(0) as NSDictionary?, tool.rig.partner.body(0) as NSDictionary?)
        switch deskLeft {
        case .success(let standing):
            XCTAssertEqual(AgentBudget.dollars(cents: standing.leftCents), toolLeft["left"] as? String)
        case .failure(let failure):
            XCTFail("the desk's left request failed: \(failure)")
        }

        // spend
        let toolSpend = try await tool.rig.runJSON(tool.rig.spend("18.50"))
        let plan = try XCTUnwrap(BudgetDesk.spendPlan(amountText: "18.50", now: desk.rig.clock.now, zone: desk.rig.clock.zone))
        let deskSpend = await desk.desk.send(plan, flow: ConnectionLog.beginFlow())
        XCTAssertEqual(desk.rig.partner.requests.count, tool.rig.partner.requests.count)
        XCTAssertEqual(without(desk.rig.partner.body(1), "request_id"), without(tool.rig.partner.body(1), "request_id"))
        XCTAssertNotNil(UUID(uuidString: desk.rig.partner.body(1)?["request_id"] as? String ?? ""))
        switch deskSpend {
        case .success(let standing):
            XCTAssertEqual(AgentBudget.dollars(cents: standing.leftCents), toolSpend["left"] as? String)
            XCTAssertEqual(standing.includesEstimate, toolSpend["includes_estimate"] as? Bool)
        case .failure(let failure):
            XCTFail("the desk's spend failed: \(failure)")
        }

        // packets and ledger entries
        let toolLines = await tool.rig.lines()
        let deskLines = await desk.rig.lines()
        XCTAssertEqual(deskLines, toolLines)
        XCTAssertEqual(desk.rig.entries.count, 1)
        let toolEntries = tool.rig.entries.map { without($0, "requestID") }
        let deskEntries = desk.rig.entries.map { without($0, "requestID") }
        XCTAssertEqual(NSArray(array: deskEntries), NSArray(array: toolEntries))
    }

    // MARK: T09 the lobby row

    func testRICHHAND_T09_TheLobbyHasABeRichSirRowAfterTheTwoOldOnesAndItsSymbolsExist() {
        let services = RootView.Service.allCases
        XCTAssertEqual(services.map(\.title), ["be on-time sir", "be full sir", "be rich sir"])
        XCTAssertEqual(Set(services.map(\.id)).count, services.count)
        #if canImport(UIKit)
        for service in services {
            XCTAssertNotNil(UIImage(systemName: service.systemImage), service.systemImage)
        }
        XCTAssertNotNil(UIImage(systemName: BeRichSirView.recordSymbol), BeRichSirView.recordSymbol)
        #endif
    }
}
