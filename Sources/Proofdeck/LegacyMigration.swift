import AppKit

/// 旧名 PowerPointViewer のころの設定とメモを、初回起動のときに一度だけ引き継ぐ。
/// バンドル ID が変わると UserDefaults も最近使った項目も別物になるため。
@MainActor
enum LegacyMigration {
    private static let oldDomain = "com.mitsuba.powerpointviewer"
    private static let doneKey = "migratedFromPowerPointViewer"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        // Application Support のメモ（memos.json など）を移す。ソケットは起動のたびに作り直すので置いていく
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent("PowerPointViewer", isDirectory: true)
        let newDir = support.appendingPathComponent("Proofdeck", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? [] where name != "control.sock" {
                let to = newDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: to.path) {
                    try? fm.copyItem(at: oldDir.appendingPathComponent(name), to: to)
                }
            }
        }

        // UserDefaults を写す。ウインドウの記憶など、名前に旧名が入ったキーは新しい名前にする
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old {
            let newKey = key.replacingOccurrences(of: "PowerPointViewer", with: "Proofdeck")
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
        }

        // 最近使った項目は UserDefaults の外にあるので、ウインドウの記憶にあるファイルから作り直す
        if let data = old["windowMemory"] as? Data,
           let entries = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            let paths = entries
                .sorted { ($0.value["lastUsed"] as? Double ?? 0) < ($1.value["lastUsed"] as? Double ?? 0) }
                .map(\.key)
                .filter { fm.fileExists(atPath: $0) }
            for p in paths { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: p)) }
        }
    }
}
