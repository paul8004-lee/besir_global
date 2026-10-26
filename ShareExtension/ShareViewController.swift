import UIKit
import UniformTypeIdentifiers

/// 공유 시트에서 besir을 선택했을 때 뜨는 최소 화면.
/// 공유받은 텍스트/이미지를 앱 그룹(SharedInbox)에 저장하고 바로 닫는다 — 실제 파싱·등록은
/// 메인 앱이 다음에 foreground 될 때 처리한다(확장은 메모리·네트워크 제약이 커서 가볍게 유지).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let label = UILabel()
        label.text = "besir로 전달 중…"
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
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 220),
            card.heightAnchor.constraint(equalToConstant: 80),
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
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let (data, mime) = try? await loadImage(provider) { imageData = data; mimeType = mime }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = try? await loadText(provider) { text = appendText(text, s) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let s = try? await loadURL(provider) { text = appendText(text, s) }
                }
            }
        }
        SharedInbox.enqueue(text: text, imageData: imageData, mimeType: mimeType)
        finish()
    }

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
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
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
