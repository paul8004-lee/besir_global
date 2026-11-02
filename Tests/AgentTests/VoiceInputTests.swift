import XCTest
import SwiftUI
#if os(iOS)
import AVFoundation
#endif
@testable import besir

/// A recorder that writes a real temp file named with `VoiceFiles.prefix`. Its `fire` calls the `onEnd` of the latest
/// `start` even after `finish()` or `cancel()`, on purpose: a real recorder never does, so a test that fires late proves
/// that `VoiceInput` ignores an end event that does not belong to a recording.
@MainActor
final class FakeVoiceRecorder: VoiceRecording {
    var granted = true
    var holdAccess = false
    var startSucceeds = true
    var finishReturnsClip = true
    var clipSeconds = 1.0
    /// The bytes of the file; nil means the file is gone before `VoiceInput` can read it.
    var clipData: Data? = Data(repeating: 7, count: 32_000)

    private(set) var accessCalls = 0
    private(set) var startCalls = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0
    private(set) var fileURL: URL?
    private var lastOnEnd: (@MainActor (VoiceRecordingEnd) -> Void)?
    private var access: CheckedContinuation<Bool, Never>?

    var fileExists: Bool { fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func requestAccess() async -> Bool {
        accessCalls += 1
        guard holdAccess else { return granted }
        return await withCheckedContinuation { access = $0 }
    }

    func releaseAccess(_ result: Bool) {
        access?.resume(returning: result)
        access = nil
    }

    func start(onEnd: @escaping @MainActor (VoiceRecordingEnd) -> Void) -> Bool {
        startCalls += 1
        guard startSucceeds else { return false }
        lastOnEnd = onEnd
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(VoiceFiles.prefix)\(UUID().uuidString).wav")
        try? (clipData ?? Data([1])).write(to: url)
        fileURL = url
        return true
    }

    func finish() -> VoiceClip? {
        finishCalls += 1
        guard let url = fileURL else { return nil }
        guard finishReturnsClip else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if clipData == nil { try? FileManager.default.removeItem(at: url) }
        return VoiceClip(url: url, seconds: clipSeconds)
    }

    func cancel() {
        cancelCalls += 1
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    func fire(_ end: VoiceRecordingEnd) {
        lastOnEnd?(end)
    }
}

/// A transcriber that answers at once, or waits until the test releases it. A held call notices task cancellation.
@MainActor
final class FakeVoiceClient: VoiceTranscribing {
    var isConfigured = true
    var result: Result<String, VoiceFailure> = .success("move dinner 30 minutes later")
    var hold = false

    private(set) var calls: [Data] = []
    private(set) var sawCancellation = false
    private var pending: CheckedContinuation<Result<String, VoiceFailure>, Never>?
    /// An answer released before the call began to wait is kept, so a release can never be lost.
    private var early: Result<String, VoiceFailure>?

    func transcribe(wav: Data) async -> Result<String, VoiceFailure> {
        calls.append(wav)
        guard hold else { return result }
        if let answer = early {
            early = nil
            return answer
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor in self.sawCancellation = true }
        }
    }

    func release(_ answer: Result<String, VoiceFailure>) {
        guard let waiting = pending else {
            early = answer
            return
        }
        pending = nil
        waiting.resume(returning: answer)
    }
}

/// A `VoiceInput` over the two fakes, with what it delivered and what it showed.
@MainActor
final class VoiceRig {
    let recorder = FakeVoiceRecorder()
    let client = FakeVoiceClient()
    let input: VoiceInput
    private(set) var delivered: [String] = []
    private(set) var shown: [String] = []

    init(configure: (VoiceRig) -> Void = { _ in }) {
        input = VoiceInput(recorder: recorder, client: client)
        configure(self)
    }

    func tap() async {
        await input.tap(deliver: { [self] in delivered.append($0) }, fail: { [self] in shown.append($0) })
    }

    /// The start tap and the stop tap, with the client answering at once.
    func record() async {
        await tap()
        await tap()
    }
}

/// SPEC-VOICE-001 AC-VOICE-008 to 012 and 011: the logic of the microphone control, over fakes.
@MainActor
final class VoiceInputTests: XCTestCase {

    private enum Text {
        static let micOff = "Microphone access is off. Turn it on in Settings."
        static let recordFailed = "The recording could not be made. Try again."
        static let noSpeech = "No speech was heard. Try again."
        static let offline = "Couldn't reach the voice service. Check your connection and try again."
        static let busy = "The voice service is busy. Try again in a moment."
        static let tokenRejected = "The voice service rejected this build's access token."
        static let notSetUp = "The voice service is not set up in this build."
        static let other = "The voice service returned an unexpected response."
    }

    // MARK: T04

    /// (tag, channels, rate, bits, data size) of the first `fmt ` and `data` chunks, by an independent walk.
    private func walk(_ data: Data) -> (tag: Int, channels: Int, rate: Int, bits: Int, dataSize: Int)? {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var offset = 12
        var fmt: (Int, Int, Int, Int)?
        while offset + 8 <= b.count {
            let id = String(decoding: b[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "fmt ", offset + 24 <= b.count { fmt = (u16(offset + 8), u16(offset + 10), u32(offset + 12), u16(offset + 22)) }
            if id == "data", let fmt { return (fmt.0, fmt.1, fmt.2, fmt.3, size) }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    private func chunk(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        if payload.count % 2 == 1 { out.append(0) }
        return out
    }

    private func fmtPayload() -> Data {
        var out = Data()
        for (value, width) in [(1, 2), (1, 2), (16_000, 4), (32_000, 4), (2, 2), (16, 2)] {
            withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0.prefix(width)) }
        }
        return out
    }

    private func riff(_ chunks: [Data]) -> Data {
        let body = Data("WAVE".utf8) + chunks.reduce(Data(), +)
        var out = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        return out + body
    }

    func testVOICE_T04_recordingNumbersTheRealWritersFileAndTheChunkWalk() throws {
        XCTAssertEqual(VoiceRecordingFormat.sampleRate, 16_000)
        XCTAssertEqual(VoiceRecordingFormat.channels, 1)
        XCTAssertEqual(VoiceRecordingFormat.bitDepth, 16)
        XCTAssertEqual(VoiceRecordingFormat.maxSeconds, 28)
        XCTAssertEqual(VoiceRecordingFormat.minSeconds, 0.3)

        let padded = riff([chunk("JUNK", Data(count: 28)), chunk("fmt ", fmtPayload()), chunk("FLLR", Data(count: 4_008)), chunk("data", Data(count: 3_200))])
        XCTAssertEqual(VoiceWav.sampleByteCount(in: padded), 3_200)
        XCTAssertNil(VoiceWav.sampleByteCount(in: Data()))
        XCTAssertNil(VoiceWav.sampleByteCount(in: Data("not a riff file at all".utf8)))
        XCTAssertNil(VoiceWav.sampleByteCount(in: riff([chunk("fmt ", fmtPayload())])))

        #if os(iOS)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(VoiceFiles.prefix)t04-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: VoiceRecordingFormat.settings)
        let format = try XCTUnwrap(file?.processingFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        if let channel = buffer.floatChannelData?[0] { for i in 0..<16_000 { channel[i] = 0 } }
        try file?.write(from: buffer)
        file = nil
        let written = try Data(contentsOf: url)
        let found = try XCTUnwrap(walk(written))
        XCTAssertEqual([found.tag, found.channels, found.rate, found.bits, found.dataSize], [1, 1, 16_000, 16, 32_000])
        let sampleBytes = try XCTUnwrap(VoiceWav.sampleByteCount(in: written))
        XCTAssertEqual(sampleBytes, 32_000)
        XCTAssertEqual(Double(sampleBytes) / 32_000, 1.0)
        #endif
    }

    // MARK: T05 to T08

    func testVOICE_T05_happyPathRecordsSendsDeliversTheTrimmedTextAndDeletesTheFile() async throws {
        let rig = VoiceRig { $0.client.hold = true }
        await rig.tap()
        XCTAssertEqual(rig.input.phase, .recording)
        let url = try XCTUnwrap(rig.recorder.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let stop = Task { await rig.tap() }
        let transcribing = await eventually { rig.input.phase == .transcribing && rig.client.calls.count == 1 }
        XCTAssertTrue(transcribing)
        rig.client.release(.success("  move dinner 30 minutes later \n"))
        await stop.value

        XCTAssertEqual(rig.input.phase, .idle)
        XCTAssertEqual(rig.client.calls, [Data(repeating: 7, count: 32_000)])
        XCTAssertEqual(rig.delivered, ["move dinner 30 minutes later"])
        XCTAssertEqual(rig.shown, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testVOICE_T06_permissionDeniedShowsOneLineAndStartsNothingAndAGrantStartsAtOnce() async {
        let denied = VoiceRig { $0.recorder.granted = false }
        await denied.tap()
        XCTAssertEqual(denied.shown, [Text.micOff])
        XCTAssertEqual(denied.recorder.startCalls, 0)
        XCTAssertEqual(denied.client.calls.count, 0)
        XCTAssertEqual(denied.input.phase, .idle)

        let granted = VoiceRig()
        await granted.tap()
        XCTAssertEqual(granted.input.phase, .recording)
        XCTAssertEqual(granted.recorder.startCalls, 1)
        XCTAssertEqual(granted.shown, [])
    }

    func testVOICE_T07_recordingFailuresShowOneLineSendNothingAndLeaveNoFile() async {
        let cannotStart = VoiceRig { $0.recorder.startSucceeds = false }
        await cannotStart.tap()
        XCTAssertEqual(cannotStart.shown, [Text.recordFailed])
        XCTAssertEqual(cannotStart.input.phase, .idle)
        XCTAssertEqual(cannotStart.client.calls.count, 0)

        let noClip = VoiceRig { $0.recorder.finishReturnsClip = false }
        await noClip.record()
        XCTAssertEqual(noClip.shown, [Text.recordFailed])
        XCTAssertEqual(noClip.client.calls.count, 0)
        XCTAssertFalse(noClip.recorder.fileExists)
        XCTAssertEqual(noClip.input.phase, .idle)

        let tooShort = VoiceRig { $0.recorder.clipSeconds = 0.29 }
        await tooShort.record()
        XCTAssertEqual(tooShort.shown, [Text.noSpeech])
        XCTAssertEqual(tooShort.client.calls.count, 0)
        XCTAssertFalse(tooShort.recorder.fileExists)
        XCTAssertEqual(tooShort.input.phase, .idle)

        let unreadable = VoiceRig { $0.recorder.clipData = nil }
        await unreadable.record()
        XCTAssertEqual(unreadable.shown, [Text.recordFailed])
        XCTAssertEqual(unreadable.client.calls.count, 0)
        XCTAssertFalse(unreadable.recorder.fileExists)
        XCTAssertEqual(unreadable.input.phase, .idle)

        let longEnough = VoiceRig { $0.recorder.clipSeconds = 0.3 }
        await longEnough.record()
        XCTAssertEqual(longEnough.client.calls.count, 1)
        XCTAssertEqual(longEnough.shown, [])
    }

    func testVOICE_T08_blankTranscriptAndEveryFailureShowTheirExactLine() async {
        for blank in ["", "  \n "] {
            let rig = VoiceRig { $0.client.result = .success(blank) }
            await rig.record()
            XCTAssertEqual(rig.shown, [Text.noSpeech], "blank \(blank.debugDescription)")
            XCTAssertEqual(rig.delivered, [])
            XCTAssertFalse(rig.recorder.fileExists)
            XCTAssertEqual(rig.input.phase, .idle)
        }
        let lines: [(VoiceFailure, String)] = [
            (.notSetUp, Text.notSetUp), (.tokenRejected, Text.tokenRejected), (.busy, Text.busy),
            (.offline, Text.offline), (.other, Text.other),
        ]
        for (failure, line) in lines {
            let rig = VoiceRig { $0.client.result = .failure(failure) }
            await rig.record()
            XCTAssertEqual(rig.shown, [line], "\(failure)")
            XCTAssertEqual(rig.delivered, [])
            XCTAssertFalse(rig.recorder.fileExists)
            XCTAssertEqual(rig.input.phase, .idle)
        }
    }

    // MARK: T09, T10

    func testVOICE_T09_reentryAndTerminalEventsChangeNothingTheyShouldNot() async {
        let busy = VoiceRig { $0.client.hold = true }
        await busy.tap()
        let stop = Task { await busy.tap() }
        let transcribing = await eventually { busy.input.phase == .transcribing && busy.client.calls.count == 1 }
        XCTAssertTrue(transcribing)
        await busy.tap()
        await busy.tap()
        busy.recorder.fire(.limit)
        busy.recorder.fire(.interrupted)
        busy.recorder.fire(.failed)
        XCTAssertEqual(busy.client.calls.count, 1)
        XCTAssertEqual(busy.recorder.startCalls, 1)
        XCTAssertEqual(busy.recorder.finishCalls, 1)
        XCTAssertEqual(busy.recorder.cancelCalls, 0)
        XCTAssertEqual(busy.shown, [])
        XCTAssertEqual(busy.input.phase, .transcribing)
        busy.client.release(.success("done"))
        await stop.value
        XCTAssertEqual(busy.delivered, ["done"])

        let waiting = VoiceRig { $0.recorder.holdAccess = true }
        let first = Task { await waiting.tap() }
        let asked = await eventually { waiting.recorder.accessCalls == 1 }
        XCTAssertTrue(asked)
        await waiting.tap()
        XCTAssertEqual(waiting.recorder.accessCalls, 1)
        waiting.recorder.releaseAccess(true)
        await first.value
        XCTAssertEqual(waiting.recorder.startCalls, 1)
        XCTAssertEqual(waiting.input.phase, .recording)

        let limit = VoiceRig()
        await limit.tap()
        limit.recorder.fire(.limit)
        let finished = await eventually { limit.input.phase == .idle && limit.delivered.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(limit.client.calls.count, 1)
        XCTAssertEqual(limit.recorder.finishCalls, 1)

        let late = VoiceRig()
        await late.record()
        for end in [VoiceRecordingEnd.limit, .interrupted, .failed] { late.recorder.fire(end) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(late.client.calls.count, 1)
        XCTAssertEqual(late.recorder.finishCalls, 1)
        XCTAssertEqual(late.recorder.cancelCalls, 0)
        XCTAssertEqual(late.delivered.count, 1)
        XCTAssertEqual(late.shown, [])
        XCTAssertEqual(late.input.phase, .idle)

        XCTAssertTrue(VoiceInput.isControlDisabled(phase: .idle, canSend: false))
        XCTAssertFalse(VoiceInput.isControlDisabled(phase: .idle, canSend: true))
        XCTAssertFalse(VoiceInput.isControlDisabled(phase: .recording, canSend: false))
        XCTAssertFalse(VoiceInput.isControlDisabled(phase: .recording, canSend: true))
        XCTAssertTrue(VoiceInput.isControlDisabled(phase: .transcribing, canSend: false))
        XCTAssertTrue(VoiceInput.isControlDisabled(phase: .transcribing, canSend: true))
    }

    func testVOICE_T10_cancelInterruptionAndLateAnswersDeliverAndShowNothing() async {
        let recording = VoiceRig()
        await recording.tap()
        recording.input.cancel()
        XCTAssertEqual(recording.recorder.cancelCalls, 1)
        XCTAssertFalse(recording.recorder.fileExists)
        XCTAssertEqual(recording.input.phase, .idle)
        XCTAssertEqual(recording.delivered, [])
        XCTAssertEqual(recording.shown, [])

        let uploading = VoiceRig { $0.client.hold = true }
        await uploading.tap()
        let stop = Task { await uploading.tap() }
        let transcribing = await eventually { uploading.input.phase == .transcribing && uploading.client.calls.count == 1 }
        XCTAssertTrue(transcribing)
        uploading.input.cancel()
        let noticed = await eventually { uploading.client.sawCancellation }
        XCTAssertTrue(noticed)
        uploading.client.release(.success("late"))
        await stop.value
        XCTAssertEqual(uploading.input.phase, .idle)
        XCTAssertEqual(uploading.delivered, [])
        XCTAssertEqual(uploading.shown, [])

        let asking = VoiceRig { $0.recorder.holdAccess = true }
        let ask = Task { await asking.tap() }
        let asked = await eventually { asking.recorder.accessCalls == 1 }
        XCTAssertTrue(asked)
        asking.input.cancel()
        asking.recorder.releaseAccess(true)
        await ask.value
        XCTAssertEqual(asking.recorder.startCalls, 0)
        XCTAssertEqual(asking.shown, [])
        XCTAssertEqual(asking.input.phase, .idle)

        let newer = VoiceRig { $0.client.hold = true }
        await newer.tap()
        let older = Task { await newer.tap() }
        let olderUploading = await eventually { newer.input.phase == .transcribing && newer.client.calls.count == 1 }
        XCTAssertTrue(olderUploading)
        newer.input.cancel()
        await newer.tap()
        XCTAssertEqual(newer.input.phase, .recording)
        newer.client.release(.success("old answer"))
        await older.value
        XCTAssertEqual(newer.delivered, [])
        XCTAssertEqual(newer.shown, [])
        XCTAssertEqual(newer.input.phase, .recording)
        newer.input.cancel()

        let interrupted = VoiceRig()
        await interrupted.tap()
        interrupted.recorder.fire(.interrupted)
        XCTAssertEqual(interrupted.recorder.cancelCalls, 1)
        XCTAssertEqual(interrupted.input.phase, .idle)
        XCTAssertFalse(interrupted.recorder.fileExists)
        XCTAssertEqual(interrupted.delivered, [])
        XCTAssertEqual(interrupted.shown, [])
        await interrupted.tap()
        XCTAssertEqual(interrupted.input.phase, .recording)
        XCTAssertEqual(interrupted.recorder.startCalls, 2)
        XCTAssertEqual(interrupted.shown, [])

        XCTAssertTrue(VoiceInput.cancels(onScene: .background))
        XCTAssertFalse(VoiceInput.cancels(onScene: .inactive))
        XCTAssertFalse(VoiceInput.cancels(onScene: .active))

        let failed = VoiceRig()
        await failed.tap()
        failed.recorder.fire(.failed)
        XCTAssertEqual(failed.recorder.cancelCalls, 1)
        XCTAssertEqual(failed.input.phase, .idle)
        XCTAssertFalse(failed.recorder.fileExists)
        XCTAssertEqual(failed.delivered, [])
        XCTAssertEqual(failed.shown, [Text.recordFailed])
        await failed.tap()
        XCTAssertEqual(failed.input.phase, .recording)
        XCTAssertEqual(failed.shown, [Text.recordFailed])
    }

    // MARK: T11, T13

    func testVOICE_T11_deliveryRoutesByCanSendAndNeverReplacesTheDraft() {
        XCTAssertTrue(VoiceDelivery.autoSend)
        XCTAssertEqual(VoiceDelivery.route(text: "a b", canSend: true, autoSend: true), .send("a b"))
        XCTAssertEqual(VoiceDelivery.route(text: "a b", canSend: false, autoSend: true), .draft("a b"))
        XCTAssertEqual(VoiceDelivery.route(text: "a b", canSend: true, autoSend: false), .draft("a b"))
        XCTAssertEqual(VoiceDelivery.route(text: "a b", canSend: false, autoSend: false), .draft("a b"))
        XCTAssertEqual(VoiceDelivery.route(text: "  keep  ", canSend: true), .send("  keep  "))

        XCTAssertEqual(VoiceDelivery.merged(draft: "", voice: "a b"), "a b")
        XCTAssertEqual(VoiceDelivery.merged(draft: "  ", voice: "a b"), "a b")
        XCTAssertEqual(VoiceDelivery.merged(draft: "typed", voice: "a b"), "typed a b")
        XCTAssertEqual(VoiceDelivery.merged(draft: "typed  \n", voice: "a b"), "typed a b")
        XCTAssertTrue(VoiceDelivery.merged(draft: "typed", voice: "x").hasPrefix("typed"))
    }

    func testVOICE_T13_sweepRemovesOnlyLeftoverClipFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("besir-t13-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for name in ["besir-voice-a.wav", "besir-voice-b.wav", "other.wav", "besir-voice-c.txt"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        try fm.createDirectory(at: folder.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)

        VoiceFiles.sweep(in: folder)

        let left = try fm.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["besir-voice-c.txt", "other.wav", "sub"])
    }
}
