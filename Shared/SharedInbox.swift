import Foundation

/// 공유 확장(Share Extension)이 앱 그룹을 통해 메인 앱에 공유 항목을 전달하는 큐.
/// 두 타겟(besir-iOS, besirShare)에 모두 포함되는 최소 의존성 파일.
enum SharedInbox {
    struct Item: Codable {
        var text: String?
        var imageBase64: String?
        var mimeType: String?
    }

    static let appGroupID = "group.com.iseongmin.besir"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    private static var fileURL: URL? { containerURL?.appendingPathComponent("pendingShares.json") }

    /// 공유 확장에서 호출: 새 항목을 큐에 추가한다.
    static func enqueue(text: String?, imageData: Data?, mimeType: String?) {
        guard let url = fileURL else { return }
        var items = load(url)
        items.append(Item(text: text, imageBase64: imageData?.base64EncodedString(), mimeType: mimeType))
        try? JSONEncoder().encode(items).write(to: url)
    }

    /// 메인 앱에서 호출: 큐에 쌓인 항목을 전부 꺼내고 비운다.
    static func drain() -> [Item] {
        guard let url = fileURL else { return [] }
        let items = load(url)
        try? FileManager.default.removeItem(at: url)
        return items
    }

    private static func load(_ url: URL) -> [Item] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }
}
