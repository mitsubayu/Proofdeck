import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let recentMenu = NSMenu(title: "最近使った項目")
    private var controllers: [ViewerWindowController] = []
    private var openedByEvent = false
    private var control: ControlServer?
    /// MCP から裏で起動されたか（ファイルの選択画面を出さない、前に出ない）
    private let launchedInBackground = CommandLine.arguments.contains("--background")
    /// 起動時に前回のファイルを開き直し終えたか
    private var restoreDone = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 動作確認用: Claude Code の場所と登録の状態を出して終わる
        if ProcessInfo.processInfo.environment["PPV_CLAUDE_PROBE"] != nil {
            print("claude:", ClaudeSetup.findClaude() ?? "(not found)")
            print("registered:", ClaudeSetup.registeredCommand() ?? "(none)")
            print("mcpPath:", ClaudeSetup.mcpPath, "isRegistered:", ClaudeSetup.isRegistered)
            exit(0)
        }
        control = ControlServer { [weak self] method, params in
            guard let self else { throw ViewerWindowController.ExternalError.notReady }
            return try await self.handleControl(method, params)
        }
        control?.start()
        // コマンドラインからパスを渡された場合（swift run など）
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        for a in args { open(URL(fileURLWithPath: a)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.controllers.isEmpty && !self.openedByEvent else { return }
            // ファイルを指定せずに起動したら、前回終了したときに開いていたファイルを開き直す
            var previous = WindowMemory.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            if previous.isEmpty, let last = WindowMemory.mostRecentFile { previous = [last] }
            if previous.isEmpty { if !self.launchedInBackground { self.openDocument(nil) } } else { previous.forEach { self.open($0) } }
            self.restoreDone = true
        }
        if !launchedInBackground { NSApp.activate(ignoringOtherApps: true) }
        // 動作確認用: PPV_OPEN=about|help で開き、PPV_SNAPSHOT にその窓を撮る
        if let what = ProcessInfo.processInfo.environment["PPV_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if what == "about" { self.showAbout(nil) } else { self.showHelp(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let path = ProcessInfo.processInfo.environment["PPV_SNAPSHOT"],
                          let view = NSApp.keyWindow?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedByEvent = true
        for u in urls { open(u) }
    }

    private var terminating = false

    func applicationWillTerminate(_ notification: Notification) { control?.stop() }

    // MARK: - MCP からの頼み

    /// path が無ければ、最後に前に出ていたウインドウ。path はフルパスでもファイル名だけでもよい
    private func target(_ params: [String: Any]) throws -> ViewerWindowController {
        if let path = params["path"] as? String, !path.isEmpty {
            let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            if let c = controllers.first(where: { $0.fileURL == u }) { return c }
            let byName = controllers.filter { $0.fileURL.lastPathComponent == path }
            if byName.count == 1 { return byName[0] }
            throw ViewerWindowController.ExternalError.failed("\(path) はビューアで開かれていません（open_deck で開けます）")
        }
        if let key = NSApp.keyWindow?.windowController as? ViewerWindowController { return key }
        guard let c = controllers.max(by: { $0.lastFocused < $1.lastFocused }) else {
            throw ViewerWindowController.ExternalError.failed("ビューアで開いている資料がありません（open_deck で開けます）")
        }
        return c
    }

    private func handleControl(_ method: String, _ p: [String: Any]) async throws -> Any {
        // 起動したばかりなら、前回の資料を開き直して描き終えるまで少し待つ（最大 6 秒）
        for _ in 0..<60 {
            let loading = !restoreDone || controllers.contains { ($0.externalInfo()["slide_count"] as? Int) == 0 }
            if !loading { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        func int(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue }
        func bool(_ k: String, _ d: Bool) -> Bool { (p[k] as? NSNumber)?.boolValue ?? d }
        switch method {
        case "ping":
            return ["ok": true]
        case "decks":
            return controllers.sorted { $0.lastFocused > $1.lastFocused }.map { $0.externalInfo() }
        case "open":
            guard let path = p["path"] as? String else { throw ViewerWindowController.ExternalError.failed("path が要ります") }
            let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: u.path), ["pptx", "pptm", "ppsx", "potx"].contains(u.pathExtension.lowercased()) else {
                throw ViewerWindowController.ExternalError.failed("\(u.path) は pptx ではないか、見つかりません")
            }
            open(u)
            let c = try target(["path": u.path])
            for _ in 0..<150 where c.externalInfo()["slide_count"] as? Int == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            if bool("activate", false) { c.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            return c.externalInfo()
        default:
            break
        }
        let c = try target(p)
        switch method {
        case "info":
            return c.externalInfo()
        case "current":
            let i = try c.slideIndex(nil)
            var d = c.externalSlide(i)
            d["deck"] = c.externalInfo()
            return d
        case "slides":
            return try c.externalSlides(from: int("from"), to: int("to"), includeText: bool("include_text", true))
        case "render":
            let i = try c.slideIndex(int("slide"))
            let w = CGFloat(min(3840, max(320, int("width") ?? 1600)))
            let jpeg = (p["format"] as? String) == "jpeg"
            let r = try await c.externalRender(i, pixelWidth: w, jpeg: jpeg)
            return ["slide": i + 1, "width": r.width, "height": r.height, "mime": jpeg ? "image/jpeg" : "image/png",
                    "data": r.data.base64EncodedString(), "title": c.externalSlide(i, includeText: false)["title"] ?? ""]
        case "check_layout":
            let count = (c.externalInfo()["slide_count"] as? Int) ?? 0
            var nums = (p["slides"] as? [NSNumber])?.map(\.intValue) ?? Array(1...max(1, count))
            nums = nums.filter { $0 >= 1 && $0 <= count }
            let issues = try await c.externalCheckLayout(nums.map { $0 - 1 })
            return ["checked_slides": nums.count, "issue_count": issues.count, "issues": issues]
        case "changes":
            return c.externalChanges()
        case "memos":
            return ["deck": c.fileURL.path, "memos": c.externalMemos(includeDone: bool("include_done", false))]
        case "resolve_memo":
            let i = try c.slideIndex(int("slide"))
            try c.externalResolveMemo(i, done: bool("done", true))
            return ["slide": i + 1, "done": bool("done", true)]
        case "goto":
            let i = try c.slideIndex(int("slide"))
            c.externalGoTo(i, activate: bool("activate", false))
            return ["slide": i + 1]
        case "generating":
            let on = bool("on", true)
            c.externalSetGenerating(on, message: p["message"] as? String, timeout: (p["timeout_sec"] as? NSNumber)?.doubleValue ?? 600)
            return ["generating": on]
        default:
            throw ViewerWindowController.ExternalError.failed("知らない頼み: \(method)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 終了時に開いていたファイルを覚えておく（ウインドウが閉じられて一覧が空になる前に）
        saveOpenFiles()
        terminating = true
        return .terminateNow
    }

    private func saveOpenFiles() {
        WindowMemory.openFiles = controllers.map(\.fileURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    func open(_ url: URL) {
        let u = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.fileURL == u }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = ViewerWindowController(fileURL: u)
        c.onClose = { [weak self] c in
            guard let self, !self.terminating else { return }
            self.controllers.removeAll { $0 === c }
            self.saveOpenFiles()
        }
        if !c.hasRememberedFrame, let w = c.window {
            // 初めてのファイル: 開いているウインドウか、最後に使った大きさから少しずらして置く
            if let last = controllers.last?.window {
                w.setContentSize(last.contentLayoutRect.size)
                w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            } else if let f = WindowMemory.lastFrame, WindowMemory.usable(f) {
                w.setFrame(f, display: false)
            } else {
                w.center()
            }
        }
        controllers.append(c)
        saveOpenFiles()
        c.showWindow(nil)
        c.start()
        NSDocumentController.shared.noteNewRecentDocumentURL(u)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pptx", "pptm", "ppsx", "potx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { open(u) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        if FileManager.default.fileExists(atPath: u.path) { open(u) }
        else {
            let a = NSAlert()
            a.messageText = "ファイルが見つかりません"
            a.informativeText = u.path
            a.runModal()
        }
    }

    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }

    /// 「最近使った項目」は開くたびに作り直す
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for u in urls {
            let it = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            it.representedObject = u
            it.toolTip = u.path
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            it.image = icon
            menu.addItem(it)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "メニューを消去", action: urls.isEmpty ? nil : #selector(clearRecent(_:)), keyEquivalent: "")
        menu.addItem(clear)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutCredits.attributedString()])
    }

    @objc func showHelp(_ sender: Any?) { HelpWindow.show() }

    @objc func setupClaude(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        ClaudeSetup.register()
    }

    @objc func copyClaudeCommand(_ sender: Any?) { ClaudeSetup.copyCommand() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let viewer = NSApp.keyWindow?.windowController as? ViewerWindowController
        if item.action == #selector(ViewerWindowController.toggleNotes(_:)) {
            item.state = viewer?.notesVisible == true ? .on : .off
        }
        if item.action == #selector(setupClaude(_:)) {
            item.state = ClaudeSetup.isRegistered ? .on : .off
        }
        if item.action == #selector(ViewerWindowController.toggleSlideShow(_:)) {
            item.state = viewer?.slideShowActive == true ? .on : .off
        }
        if item.action == #selector(ViewerWindowController.togglePrevious(_:)) {
            item.state = viewer?.previousVisible == true ? .on : .off
        }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m; return m
        }
        let appMenu = submenu("Proofdeck")
        appMenu.addItem(withTitle: "Proofdeck について", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Claude Code と連携する…", action: #selector(setupClaude(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "MCP の登録コマンドをコピー", action: #selector(copyClaudeCommand(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "サービス")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Proofdeck を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "ほかを隠す", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "すべてを表示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Proofdeck を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("ファイル")
        file.addItem(withTitle: "開く…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "最近使った項目", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(withTitle: "再読み込み", action: #selector(ViewerWindowController.reloadNow(_:)), keyEquivalent: "r")
        file.addItem(.separator())
        let exportItem = NSMenuItem(title: "書き出す", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "書き出す")
        exportMenu.addItem(withTitle: "PDF…", action: #selector(ViewerWindowController.exportPDF(_:)), keyEquivalent: "e")
        exportMenu.addItem(withTitle: "画像（PNG）…", action: #selector(ViewerWindowController.exportPNGs(_:)), keyEquivalent: "")
        exportMenu.addItem(.separator())
        exportMenu.addItem(withTitle: "このスライドだけを pptx で…", action: #selector(ViewerWindowController.exportCurrentSlidePptx(_:)), keyEquivalent: "")
        exportItem.submenu = exportMenu
        file.addItem(exportItem)
        file.addItem(.separator())
        file.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu("編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "スライドを画像としてコピー", action: #selector(ViewerWindowController.copyCurrentSlideImage(_:)), keyEquivalent: "C")
        edit.addItem(.separator())
        edit.addItem(withTitle: "検索…", action: #selector(ViewerWindowController.showFind(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "次を検索", action: #selector(ViewerWindowController.findNext(_:)), keyEquivalent: "g")
        edit.addItem(withTitle: "前を検索", action: #selector(ViewerWindowController.findPrevious(_:)), keyEquivalent: "G")
        edit.addItem(.separator())
        edit.addItem(withTitle: "メモをまとめてコピー", action: #selector(ViewerWindowController.copyAllMemos(_:)), keyEquivalent: "c").keyEquivalentModifierMask = [.command, .option]
        edit.addItem(withTitle: "このファイルのメモをすべて消す…", action: #selector(ViewerWindowController.clearAllMemos(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu("表示")
        view.addItem(withTitle: "拡大", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "縮小", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "ウインドウに合わせる", action: #selector(ViewerWindowController.zoomToFit(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let show = NSMenuItem(title: "スライドショー", action: #selector(ViewerWindowController.toggleSlideShow(_:)), keyEquivalent: "\r")
        show.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(show)
        view.addItem(.separator())
        view.addItem(withTitle: "前の版と切り替え", action: #selector(ViewerWindowController.togglePrevious(_:)), keyEquivalent: "b")
        view.addItem(withTitle: "ノートとメモ", action: #selector(ViewerWindowController.toggleNotes(_:)), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .option]

        let win = submenu("ウインドウ")
        win.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "拡大/縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        let help = submenu("ヘルプ")
        help.addItem(withTitle: "Proofdeck ヘルプ", action: #selector(showHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
