import AppKit

/// ウインドウの位置・大きさと見ていたスライドを、ファイルごとに覚えておく。
/// あわせて、終了時に開いていたファイルの一覧も覚え、次の起動で開き直す。
@MainActor
enum WindowMemory {
    struct Entry: Codable {
        var frame: String       // NSStringFromRect
        var slide: Int
        var lastUsed: Double
    }

    private static let entriesKey = "windowMemory"
    private static let openFilesKey = "openFiles"
    private static let lastFrameKey = "lastWindowFrame"
    private static let limit = 100

    private static var entries: [String: Entry] = {
        guard let d = UserDefaults.standard.data(forKey: entriesKey),
              let e = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return e
    }()

    static func entry(for url: URL) -> Entry? { entries[url.path] }

    static func save(url: URL, frame: NSRect, slide: Int) {
        entries[url.path] = Entry(frame: NSStringFromRect(frame), slide: slide, lastUsed: Date().timeIntervalSince1970)
        if entries.count > limit {
            for (k, _) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(entries.count - limit) {
                entries.removeValue(forKey: k)
            }
        }
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: entriesKey) }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: lastFrameKey)
    }

    /// 初めて開くファイル用: 最後に使ったウインドウの位置と大きさ
    static var lastFrame: NSRect? {
        UserDefaults.standard.string(forKey: lastFrameKey).map(NSRectFromString)
    }

    /// 最後に使ったファイル（いま存在するもの）
    static var mostRecentFile: URL? {
        entries.sorted { $0.value.lastUsed > $1.value.lastUsed }
            .map { URL(fileURLWithPath: $0.key) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var openFiles: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: openFilesKey) ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: openFilesKey) }
    }

    /// 画面の構成が変わって、覚えていた位置がどの画面にも入らないときは使わない
    static func usable(_ frame: NSRect) -> Bool {
        guard frame.width >= 300, frame.height >= 200 else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 100 && $0.visibleFrame.intersection(frame).height >= 100 }
    }
}
