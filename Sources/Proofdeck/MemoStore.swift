import Foundation

/// スライドごとのメモ（Claude へのフィードバックの下書き）を、ファイルごとに保存する。
/// 置き場所は ~/Library/Application Support/Proofdeck/memos.json。
@MainActor
enum MemoStore {
    private static let url = appSupportDir.appendingPathComponent("memos.json")
    /// ファイルのパス → スライド番号（0 始まり、文字列）→ メモ
    private static var all: [String: [String: String]] = {
        guard let d = try? Data(contentsOf: url),
              let v = try? JSONDecoder().decode([String: [String: String]].self, from: d) else { return [:] }
        return v
    }()
    private static var saveTimer: Timer?
    /// 「済」の印（Claude が直し終えたメモ）。ファイルのパス → スライド番号（0 始まり）
    private static let doneURL = appSupportDir.appendingPathComponent("memos-done.json")
    private static var doneAll: [String: [Int]] = {
        guard let d = try? Data(contentsOf: doneURL), let v = try? JSONDecoder().decode([String: [Int]].self, from: d) else { return [:] }
        return v
    }()

    static func done(for file: URL) -> Set<Int> { Set(doneAll[file.path] ?? []) }

    static func setDone(_ done: Bool, at index: Int, for file: URL) {
        var s = Set(doneAll[file.path] ?? [])
        if done { s.insert(index) } else { s.remove(index) }
        doneAll[file.path] = s.isEmpty ? nil : s.sorted()
        scheduleSave()
    }

    static func memos(for file: URL) -> [Int: String] {
        var out: [Int: String] = [:]
        for (k, v) in all[file.path] ?? [:] { if let i = Int(k) { out[i] = v } }
        return out
    }

    static func set(_ text: String, at index: Int, for file: URL) {
        var m = all[file.path] ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { m.removeValue(forKey: String(index)) } else { m[String(index)] = text }
        all[file.path] = m.isEmpty ? nil : m
        scheduleSave()
    }

    static func clear(for file: URL) {
        all.removeValue(forKey: file.path)
        doneAll.removeValue(forKey: file.path)
        scheduleSave()
    }

    private static func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated { saveNow() }
        }
    }

    static func saveNow() {
        saveTimer?.invalidate()
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) }
        if let d = try? JSONEncoder().encode(doneAll) { try? d.write(to: doneURL, options: .atomic) }
    }
}

let appSupportDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Proofdeck", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
