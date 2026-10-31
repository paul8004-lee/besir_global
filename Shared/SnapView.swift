import SwiftUI
#if os(iOS)
import AVFoundation
import PhotosUI

/// The camera screen (SPEC-CAMSNAP-001): black, dark colour scheme, a live view and one shutter, or the system photo picker
/// where the device has no camera. The only texts are the fixed error and missing-input lines and the data of a candidate row.
struct SnapView: View {
    @ObservedObject var flow: SnapFlow
    @Binding var isPresented: Bool
    @State private var picking = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            VStack {
                HStack {
                    Button {
                        closeScreen()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .preferredColorScheme(.dark)
        .task { await flow.begin() }
        .onDisappear { flow.close() }
        .onChange(of: flow.phase, initial: true) { _, phase in
            if phase == .ready(.picker) { picking = true }
            if phase == .done { isPresented = false }
        }
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images)
        .onChange(of: picking) { _, shown in
            guard !shown else { return }
            // A cancelled picker closes the screen; a pick sets the selection first, so give it one turn to arrive.
            Task {
                await Task.yield()
                if picked == nil, flow.phase == .ready(.picker) { closeScreen() }
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await flow.pick { try? await item.loadTransferable(type: Data.self) } }
        }
        .confirmationDialog(SnapLine.travelTitle,
                            isPresented: Binding(get: { flow.phase == .awaitingMode },
                                                 set: { if !$0 { Task { await flow.chooseMode(nil) } } }),
                            titleVisibility: .visible) {
            ForEach(PlanMyDay.modeChoices) { mode in
                Button(mode.title) { Task { await flow.chooseMode(mode) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func closeScreen() {
        flow.close()
        isPresented = false
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .ready(.camera):
            if let camera = flow.shutter as? SnapCamera {
                SnapPreview(session: camera.session).ignoresSafeArea()
            }
            VStack {
                Spacer()
                Button {
                    Task { await flow.shutterTapped() }
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 68, height: 68)
                        .overlay(Circle().stroke(.white, lineWidth: 3).padding(-6))
                }
                .accessibilityLabel("Take photo")
                .padding(.bottom, 36)
            }
        case .capturing, .reading:
            ProgressView().controlSize(.large).tint(.white)
        case .choosing(let rows):
            candidates(rows)
        case .line(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.warn)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        case .idle, .ready(.picker), .awaitingMode, .done:
            EmptyView()
        }
    }

    private func candidates(_ rows: [SnapCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button {
                    Task { await flow.choose(row) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.subheadline).bold().foregroundStyle(Theme.ink)
                        Text(row.address).font(.caption).foregroundStyle(Theme.muted)
                        if let distance = row.distanceText {
                            Text(distance).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.line)
            }
            if flow.showsGoogleMark {
                GoogleMapsAttribution()
            }
        }
    }
}

/// The live view of a capture session.
private struct SnapPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> SnapPreviewView {
        let view = SnapPreviewView()
        view.preview?.session = session
        view.preview?.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: SnapPreviewView, context: Context) {}
}

private final class SnapPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}

/// The camera circle left of the besir circle on the root screen.
struct SnapEntryButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        if isShown {
            Button(action: action) {
                Image(systemName: "camera")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.ink)
                    .floatingCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera")
        }
    }
}

extension View {
    /// The camera screen as a full-screen cover; `onDismiss` runs when it has gone, so a hand-off never competes with it.
    func snapCamera(flow: SnapFlow, isPresented: Binding<Bool>, onDismiss: @escaping () -> Void) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            SnapView(flow: flow, isPresented: isPresented)
        }
    }
}
#else
/// No camera screen on this platform: the circle is empty and the cover modifier does nothing.
struct SnapEntryButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View { EmptyView() }
}

extension View {
    func snapCamera(flow: SnapFlow, isPresented: Binding<Bool>, onDismiss: @escaping () -> Void) -> some View { self }
}
#endif
