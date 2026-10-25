import AppKit

/// アプリのメニューから、Claude Code にこのアプリの MCP サーバーを登録する。
/// Claude Code の本体を探し、`claude mcp add proofdeck --scope user -- <proofdeck-mcp>` を実行する。
@MainActor
enum ClaudeSetup {
    static let serverName = "proofdeck"

    /// アプリに同梱した MCP サーバー
    static var mcpPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/proofdeck-mcp").path
    }

    static var addCommand: String {
        "claude mcp add \(serverName) --scope user -- \"\(mcpPath)\""
    }

    /// ~/.claude.json に登録済みか。登録されているコマンドの場所も返す
    static func registeredCommand() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let me = servers[serverName] as? [String: Any] else { return nil }
        return me["command"] as? String
    }

    static var isRegistered: Bool { registeredCommand() == mcpPath }

    /// Claude Code の本体を探す。動くもの（--version に答えるもの）だけを使う
    static func findClaude() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        // Claude デスクトップアプリに入っている Claude Code（新しい版から）
        let base = home + "/Library/Application Support/Claude/claude-code"
        if let versions = try? fm.contentsOfDirectory(atPath: base) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                if let e = fm.enumerator(atPath: base + "/" + v) {
                    while let rel = e.nextObject() as? String {
                        if rel.hasSuffix("claude.app/Contents/MacOS/claude") { candidates.append(base + "/" + v + "/" + rel) }
                        if e.level > 5 { e.skipDescendants() }
                    }
                }
            }
        }
        candidates += [home + "/.claude/local/claude", home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            if let out = try? run(c, ["--version"], timeout: 20), out.status == 0, out.text.contains("Claude Code") { return c }
        }
        return nil
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, text)
    }

    /// メニュー「Claude Code と連携する…」
    static func register() {
        if isRegistered {
            let a = NSAlert()
            a.messageText = "Claude Code に登録済みです"
            a.informativeText = "Claude Code から「proofdeck」の MCP サーバーとして使えます。\n\n登録をやり直すこともできます。"
            a.addButton(withTitle: "閉じる")
            a.addButton(withTitle: "登録し直す")
            a.addButton(withTitle: "登録を外す")
            switch a.runModal() {
            case .alertSecondButtonReturn: break
            case .alertThirdButtonReturn: unregister(); return
            default: return
            }
        }
        guard let claude = findClaude() else {
            let a = NSAlert()
            a.messageText = "Claude Code が見つかりませんでした"
            a.informativeText = "ターミナルで次のコマンドを実行すると登録できます。\n\n\(addCommand)"
            a.addButton(withTitle: "コマンドをコピー")
            a.addButton(withTitle: "閉じる")
            if a.runModal() == .alertFirstButtonReturn { copyCommand() }
            return
        }
        do {
            // 古い場所で登録されていれば、外してから登録し直す
            if registeredCommand() != nil { _ = try run(claude, ["mcp", "remove", serverName, "--scope", "user"], timeout: 30) }
            let r = try run(claude, ["mcp", "add", serverName, "--scope", "user", "--", mcpPath], timeout: 30)
            let a = NSAlert()
            if isRegistered {
                a.messageText = "Claude Code に登録しました"
                a.informativeText = "Claude Code を開き直すと、「proofdeck」の道具が使えるようになります。\nClaude に「いま見ているスライドを確かめて」のように頼んでみてください。"
            } else {
                a.alertStyle = .warning
                a.messageText = "登録できませんでした"
                a.informativeText = r.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nターミナルで次のコマンドを実行しても登録できます。\n\(addCommand)"
                a.addButton(withTitle: "閉じる")
                a.addButton(withTitle: "コマンドをコピー")
                if a.runModal() == .alertSecondButtonReturn { copyCommand() }
                return
            }
            a.runModal()
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    static func unregister() {
        guard let claude = findClaude() else { NSSound.beep(); return }
        _ = try? run(claude, ["mcp", "remove", serverName, "--scope", "user"], timeout: 30)
        let a = NSAlert()
        a.messageText = registeredCommand() == nil ? "登録を外しました" : "登録を外せませんでした"
        a.runModal()
    }

    static func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addCommand, forType: .string)
    }
}
