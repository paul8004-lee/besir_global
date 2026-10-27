import UIKit
import UniformTypeIdentifiers

/// 공유 시트에서 besir을 선택했을 때 뜨는 최소 화면.
/// 공유받은 텍스트/이미지를 앱 그룹(SharedInbox)에 저장하고 바로 닫는다 — 실제 파싱·등록은
/// 메인 앱이 다음에 foreground 될 때 처리한다(확장은 메모리·네트워크 제약이 커서 가볍게 유지).
final class ShareViewController: UIViewController {
    private let label = UILabel()
#if DEBUG
    /// Debug only: what each attachment of this share was, as types and sizes (no content).
    private var observed: [ShareObservation.Attachment] = []
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        label.text = "Sending to besir…"
        label.textColor = .label
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        view.addSubview(card)
#if DEBUG
        // Debug only: room for the several lines of the record result.
        let cardSize = CGSize(width: 300, height: 170)
        label.numberOfLines = 0
        label.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -16).isActive = true
#else
        let cardSize = CGSize(width: 220, height: 80)
#endif
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardSize.width),
            card.heightAnchor.constraint(equalToConstant: cardSize.height),
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        Task { await extractAndFinish() }
    }

    private func extractAndFinish() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { finish(); return }
        var text: String?
        var imageData: Data?
        var mimeType: String?

        for item in items {
            for provider in item.attachments ?? [] {
#if DEBUG
                let types = provider.registeredTypeIdentifiers
                let handled = [UTType.image, .plainText, .url].contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
                if !handled { observed.append(ShareObservation.attachment(types: types)) }
#endif
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let loaded = try? await loadImage(provider)
                    if let (data, mime) = loaded { imageData = data; mimeType = mime }
#if DEBUG
                    observed.append(ShareObservation.attachment(types: types, imageData: loaded?.0))
#endif
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let s = try? await loadText(provider)
                    if let s { text = appendText(text, s) }
#if DEBUG
                    observed.append(ShareObservation.attachment(types: types, text: s))
#endif
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let s = try? await loadURL(provider)
                    if let s { text = appendText(text, s) }
#if DEBUG
                    observed.append(ShareObservation.attachment(types: types, url: s.flatMap { URL(string: $0) }))
#endif
                }
            }
        }
        // The image is shrunk to a small JPEG here, once, so the queue never holds a large one.
#if DEBUG
        var queueLine = "Queue: nothing to store"
#endif
        if let queued = SharedInbox.prepare(text: text, imageData: imageData, mime: mimeType) {
#if DEBUG
            queueLine = SharedInbox.standard.enqueue(queued) ? "Queue: stored" : "Queue: write failed"
#else
            SharedInbox.standard.enqueue(queued)
#endif
        }
#if DEBUG
        label.font = .preferredFont(forTextStyle: .footnote)
        label.text = (writeObservation(itemCount: items.count) + [queueLine, inboxLine()]).joined(separator: "\n")
        // Long enough to read and to screenshot; the Release build closes at once.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
#endif
        finish()
    }

#if DEBUG
    /// Appends this share's record to the App Group file and returns the lines for the card: the kinds found and what the
    /// write did. A missing container and a failed write are both said out loud (domain and code only, no path, no content).
    private func writeObservation(itemCount: Int) -> [String] {
        let record = ShareObservation.record(at: Date(), itemCount: itemCount, attachments: observed)
        var lines = ["Found: \(ShareObservation.summary(of: record))"]
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.appGroupID) else {
            return lines + ["App Group: no container"]
        }
        lines.append("App Group: container found")
        let file = container.appendingPathComponent(ShareObservation.fileName)
        do {
            try ShareObservation.append(record, to: file)
            lines.append(FileManager.default.fileExists(atPath: file.path) ? "Record: written, file present" : "Record: written, file missing")
        } catch {
            lines.append("Record: failed \(ShareObservation.describe(error))")
        }
        return lines
    }

    /// How many item files the queue folder holds right now (a count, nothing else).
    private func inboxLine() -> String {
        guard let directory = SharedInbox.standard.directory else { return "Inbox: no folder" }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count
        return count.map { "Inbox: \($0) file(s)" } ?? "Inbox: folder not readable"
    }
#endif

    private func appendText(_ existing: String?, _ new: String) -> String {
        guard let existing, !existing.isEmpty else { return new }
        return existing + "\n" + new
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: item as? String)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (item as? URL)?.absoluteString)
            }
        }
    }

    private func loadImage(_ provider: NSItemProvider) async throws -> (Data, String)? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let url = item as? URL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
                    cont.resume(returning: (data, mime))
                } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                    cont.resume(returning: (data, "image/jpeg"))
                } else if let data = item as? Data {
                    cont.resume(returning: (data, "image/jpeg"))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
