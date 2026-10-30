#if os(iOS)
@preconcurrency import AVFoundation

/// The real camera of the snap screen: one photo output on a back-camera session. It takes one still photo per call, keeps the
/// photo in memory only and stops the session when the flow tells it to. Nothing here can run in a test; the flow's seam
/// tests, a source scan and the device check cover it (SPEC-CAMSNAP-001).
@MainActor
final class SnapCamera: NSObject, SnapCameraAccess, SnapShutter {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "besir.snap.camera")
    private var configured = false
    private var pending: CheckedContinuation<Data?, Never>?

    var hasCamera: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    var status: SnapAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        if !configured { configured = configure() }
        guard configured else { return }
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        // A capture that has not finished ends with nothing.
        pending?.resume(returning: nil)
        pending = nil
    }

    func capture() async -> Data? {
        guard configured, pending == nil, session.isRunning, output.connection(with: .video)?.isActive == true else { return nil }
        return await withCheckedContinuation { continuation in
            pending = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        return true
    }
}

extension SnapCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            self.pending?.resume(returning: data)
            self.pending = nil
        }
    }
}
#endif
