import Foundation

#if os(iOS)
import AVFoundation

extension VoiceRecordingFormat {
    /// `AVAudioRecorder` / `AVAudioFile` settings: linear PCM, little-endian integer, the numbers of `VoiceRecordingFormat`.
    static var settings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

/// The only file that touches the microphone (SPEC-VOICE-001). One clip at a time, in the temporary directory, deleted
/// on every path. The contract with `VoiceInput` is on `VoiceRecording`: `onEnd` fires at most once per start, only for an
/// end this recorder caused itself, and never after `finish()` or `cancel()`.
@MainActor
final class VoiceRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var onEnd: (@MainActor (VoiceRecordingEnd) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        VoiceFiles.sweep(in: FileManager.default.temporaryDirectory)
    }

    func requestAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    // @MX:WARN: [AUTO] global state mutation: sets the category of the shared `AVAudioSession` and makes it active.
    // @MX:REASON: the session is process-wide; every exit after `setActive(true)` (a failed start, `finish()`,
    // `cancel()`) must reach `deactivate()`, or the session stays active and other audio is not told it may resume.
    func start(onEnd: @escaping @MainActor (VoiceRecordingEnd) -> Void) -> Bool {
        if recorder != nil { cancel() }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            return false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(VoiceFiles.prefix)\(UUID().uuidString).wav")
        guard let made = try? AVAudioRecorder(url: url, settings: VoiceRecordingFormat.settings) else {
            deactivate()
            return false
        }
        made.delegate = self
        guard made.prepareToRecord(), made.record(forDuration: VoiceRecordingFormat.maxSeconds) else {
            made.stop()
            try? FileManager.default.removeItem(at: url)
            deactivate()
            return false
        }
        recorder = made
        fileURL = url
        self.onEnd = onEnd
        observe()
        return true
    }

    func finish() -> VoiceClip? {
        onEnd = nil
        removeObservers()
        guard let url = fileURL else {
            reset()
            return nil
        }
        recorder?.stop()
        recorder = nil
        fileURL = nil
        deactivate()
        guard let data = try? Data(contentsOf: url), let samples = VoiceWav.sampleByteCount(in: data), samples > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return VoiceClip(url: url, seconds: Double(samples) / Double(VoiceRecordingFormat.bytesPerSecond))
    }

    // @MX:ANCHOR: [AUTO] fan_in 3 - `start`, `finished` and `interrupted` call it, and `VoiceInput` calls it through
    // `VoiceRecording`.
    // @MX:REASON: the contract of `VoiceRecording`: idempotent, deletes this recorder's own file, and clears `onEnd`
    // before `stop()` so the delegate's finish after a cancel fires nothing.
    func cancel() {
        onEnd = nil
        removeObservers()
        let url = fileURL
        let hadRecorder = recorder != nil
        recorder?.stop()
        reset()
        if let url { try? FileManager.default.removeItem(at: url) }
        if hadRecorder { deactivate() }
    }

    // MARK: AVAudioRecorderDelegate

    // @MX:WARN: [AUTO] the delegate is called off the main actor and hops back in an unstored `Task`, so the call can
    // arrive after `finish()`, `cancel()` or a newer `start`.
    // @MX:REASON: `finished` acts only for the current recorder (by `ObjectIdentifier`) while `onEnd` is set; without
    // that filter a stale callback ends the next recording.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in self.finished(identity, successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in self.finished(identity, successfully: false) }
    }

    // MARK: Ends this recorder causes itself

    /// A finish the recorder did not cause: the 28 s limit when it succeeded, a failure otherwise. A callback of an older
    /// recorder, or one that arrives after `finish()` or `cancel()`, finds no `onEnd` and does nothing.
    private func finished(_ identity: ObjectIdentifier, successfully: Bool) {
        guard let current = recorder, ObjectIdentifier(current) == identity, let callback = onEnd else { return }
        onEnd = nil
        if successfully {
            callback(.limit)
        } else {
            cancel()
            callback(.failed)
        }
    }

    private func interrupted() {
        guard let callback = onEnd else { return }
        cancel()
        callback(.interrupted)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func reset() {
        recorder = nil
        fileURL = nil
    }

    // @MX:ANCHOR: [AUTO] fan_in 3 - `start` (two failure exits), `finish` and `cancel` call it.
    // @MX:REASON: the one place the shared audio session is given back, with `.notifyOthersOnDeactivation`.
    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
/// Inert on a platform without a recorder (the macOS target is not built or verified for this feature).
@MainActor
final class VoiceRecorder: VoiceRecording {
    func requestAccess() async -> Bool { false }
    func start(onEnd: @escaping @MainActor (VoiceRecordingEnd) -> Void) -> Bool { false }
    func finish() -> VoiceClip? { nil }
    func cancel() {}
}
#endif
