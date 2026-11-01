import Foundation
import SwiftUI

// SPEC-VOICE-001: the microphone control's logic. Nothing here touches AVFoundation; the recorder is behind
// `VoiceRecording` and the Worker call behind `VoiceTranscribing`, so every path is tested with fakes.

/// The numbers of a recording. Plain numbers: the Worker accepts exactly this format.
enum VoiceRecordingFormat {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitDepth = 16
    /// The recorder stops by itself here; the Worker's own cap (30 s) is never met by timer jitter.
    static let maxSeconds = 28.0
    /// A shorter clip is not sent.
    static let minSeconds = 0.3
    /// Sample bytes per second of a clip in this format.
    static let bytesPerSecond = sampleRate * channels * bitDepth / 8
}

/// A finished recording: the file and its length in seconds, taken from the file's sample bytes.
struct VoiceClip: Equatable {
    var url: URL
    var seconds: Double
}

enum VoiceWav {
    /// The size of the `data` chunk of a WAV, found by a chunk walk that skips every other chunk (JUNK, FLLR, LIST, ...)
    /// wherever it sits before `data`. A size that runs past the end of the file (a header not finalised) is cut to the
    /// bytes that are there. Nil for a file that is not a RIFF/WAVE with `fmt ` before `data`.
    static func sampleByteCount(in data: Data) -> Int? {
        let b = [UInt8](data)
        func tag(_ at: Int) -> String { String(decoding: b[at..<at + 4], as: UTF8.self) }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        guard b.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12
        var sawFmt = false
        while offset + 8 <= b.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " { sawFmt = true }
            if id == "data" { return sawFmt ? min(size, b.count - body) : nil }
            offset = body + size + (size & 1)
        }
        return nil
    }
}

/// How a recording ended without a tap.
enum VoiceRecordingEnd: Equatable {
    case limit
    case interrupted
    case failed
}

/// The recorder as `VoiceInput` sees it. Contract: `onEnd` fires at most once per `start`, only for an end the recorder
/// caused itself, and never after `finish()` or `cancel()`; `cancel()` is idempotent and deletes the recorder's own file.
@MainActor
protocol VoiceRecording: AnyObject {
    func requestAccess() async -> Bool
    func start(onEnd: @escaping @MainActor (VoiceRecordingEnd) -> Void) -> Bool
    func finish() -> VoiceClip?
    func cancel()
}

/// The lines the chat shows for a voice failure (exact strings).
enum VoiceLine {
    static let micOff = "Microphone access is off. Turn it on in Settings."
    static let recordFailed = "The recording could not be made. Try again."
    static let noSpeech = "No speech was heard. Try again."
    static let offline = "Couldn't reach the voice service. Check your connection and try again."
    static let busy = "The voice service is busy. Try again in a moment."
    static let tokenRejected = "The voice service rejected this build's access token."
    static let notSetUp = "The voice service is not set up in this build."
    static let other = "The voice service returned an unexpected response."

    static func line(for failure: VoiceFailure) -> String {
        switch failure {
        case .notSetUp: return notSetUp
        case .tokenRejected: return tokenRejected
        case .busy: return busy
        case .offline: return offline
        case .other: return other
        }
    }
}

/// Where a transcribed text goes (decision D1: send at once when the chat can take it).
enum VoiceDelivery {
    static let autoSend = true

    enum Route: Equatable {
        case send(String)
        case draft(String)
    }

    static func route(text: String, canSend: Bool, autoSend: Bool = autoSend) -> Route {
        autoSend && canSend ? .send(text) : .draft(text)
    }

    /// A voice text for the draft is appended after what the user typed, never a replacement.
    static func merged(draft: String, voice: String) -> String {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return voice }
        var kept = draft
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        return kept + " " + voice
    }
}

/// Leftover clip files of a recording that was cut off by the end of the app.
enum VoiceFiles {
    static let prefix = "besir-voice-"

    static func sweep(in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".wav") {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
                try? fm.removeItem(at: url)
            }
        }
    }
}

@MainActor
final class VoiceInput: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var phase: Phase = .idle

    private let recorder: VoiceRecording
    private let client: VoiceTranscribing
    /// Renewed by every start tap and by `cancel()`: a permission answer, an upload answer or a recorder end that belongs
    /// to an older identity is dropped.
    private var operation = UUID()
    private var askingAccess = false
    /// The closures of the tap that started the recording: an end event arrives without a tap.
    private var deliver: (@MainActor (String) -> Void)?
    private var fail: (@MainActor (String) -> Void)?
    private var upload: Task<Result<String, VoiceFailure>, Never>?

    init(recorder: VoiceRecording, client: VoiceTranscribing) {
        self.recorder = recorder
        self.client = client
    }

    /// The tap of the microphone control: starts a recording when idle, stops and sends when recording, nothing otherwise.
    func tap(deliver: @escaping @MainActor (String) -> Void, fail: @escaping @MainActor (String) -> Void) async {
        switch phase {
        case .idle:
            guard !askingAccess else { return }
            await begin(deliver: deliver, fail: fail)
        case .recording:
            await stop(operation)
        case .transcribing:
            return
        }
    }

    /// The chat sheet closed or the app went to the background: stop, delete, send nothing, show nothing.
    func cancel() {
        let wasRecording = phase == .recording
        operation = UUID()
        askingAccess = false
        upload?.cancel()
        upload = nil
        if wasRecording { recorder.cancel() }
        phase = .idle
        deliver = nil
        fail = nil
    }

    /// Only a real move to the background cancels; `.inactive` is what the system permission alert causes.
    static func cancels(onScene phase: ScenePhase) -> Bool {
        phase == .background
    }

    /// Disabled while idle and the chat cannot send, and while a transcription runs; enabled while recording so that the stop tap is never lost.
    static func isControlDisabled(phase: Phase, canSend: Bool) -> Bool {
        switch phase {
        case .idle: return !canSend
        case .recording: return false
        case .transcribing: return true
        }
    }

    // MARK: Steps

    private func begin(deliver: @escaping @MainActor (String) -> Void, fail: @escaping @MainActor (String) -> Void) async {
        operation = UUID()
        let identity = operation
        self.deliver = deliver
        self.fail = fail
        askingAccess = true
        let granted = await recorder.requestAccess()
        guard identity == operation else { return }
        askingAccess = false
        guard granted else { return end(line: VoiceLine.micOff) }
        let started = recorder.start(onEnd: { [weak self] end in self?.recorderEnded(end, identity) })
        guard started else {
            recorder.cancel()
            return end(line: VoiceLine.recordFailed)
        }
        phase = .recording
    }

    private func stop(_ identity: UUID) async {
        guard phase == .recording, identity == operation else { return }
        phase = .transcribing
        guard let clip = recorder.finish() else { return end(line: VoiceLine.recordFailed) }
        let long = clip.seconds >= VoiceRecordingFormat.minSeconds
        let bytes: Data? = long ? (try? Data(contentsOf: clip.url)) : nil
        try? FileManager.default.removeItem(at: clip.url)
        guard long else { return end(line: VoiceLine.noSpeech) }
        guard let bytes, !bytes.isEmpty else { return end(line: VoiceLine.recordFailed) }

        let client = client
        let task = Task { await client.transcribe(wav: bytes) }
        upload = task
        let result = await task.value
        guard identity == operation else { return }
        upload = nil
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { end(line: VoiceLine.noSpeech) } else { end(text: trimmed) }
        case .failure(let failure):
            end(line: VoiceLine.line(for: failure))
        }
    }

    /// The one terminal-event callback of the recorder (contract in `VoiceRecording`). It is ignored outside a recording
    /// and when it belongs to an older operation.
    private func recorderEnded(_ ended: VoiceRecordingEnd, _ identity: UUID) {
        guard identity == operation, phase == .recording else { return }
        switch ended {
        case .limit:
            Task { [weak self] in await self?.stop(identity) }
        case .interrupted:
            recorder.cancel()
            end()
        case .failed:
            recorder.cancel()
            end(line: VoiceLine.recordFailed)
        }
    }

    /// Returns to idle, then shows the line or delivers the text, once.
    private func end(line: String? = nil, text: String? = nil) {
        phase = .idle
        let fail = fail
        let deliver = deliver
        self.fail = nil
        self.deliver = nil
        if let line { fail?(line) }
        if let text { deliver?(text) }
    }
}
