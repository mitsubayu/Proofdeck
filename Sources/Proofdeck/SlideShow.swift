import AppKit

/// 縁なしでもキー入力を受けられるウインドウ
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// スライドショー。元のウインドウはそのままにして、別の全画面ウインドウに 1 枚ずつ出す。
/// ← → Space PageUp PageDown で移動、Esc で終わる。ショーの最中にファイルが変わったら描き直す。
@MainActor
final class SlideShowController: NSWindowController, NSWindowDelegate {
    private let web = WebSlideView()
    var onSlideChange: ((Int) -> Void)?
    var onClose: (() -> Void)?
    private var keyMonitor: Any?
    private var savedPresentation: NSApplication.PresentationOptions = []

    init(screen: NSScreen) {
        let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        super.init(window: w)
        w.delegate = self
        web.frame = NSRect(origin: .zero, size: screen.frame.size)
        web.autoresizingMask = [.width, .height]
        w.contentView = web
        web.onSlideChange = { [weak self] i in self?.onSlideChange?(i) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(snapshot: URL, slide: Int) async {
        guard let window else { return }
        savedPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.setFrame(window.screen?.frame ?? window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.setBackground("#000")
        _ = await web.load(deckURL: snapshot, slide: slide)
        window.makeFirstResponder(web.webView)
        NSCursor.setHiddenUntilMouseMoves(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if e.keyCode == 53 { self.finish(); return nil }   // Esc
            NSCursor.setHiddenUntilMouseMoves(true)
            return e
        }
    }

    /// ショーの最中にファイルが変わった
    func reload(snapshot: URL, slide: Int) async {
        _ = await web.load(deckURL: snapshot, slide: slide)
    }

    func goTo(_ i: Int) async { await web.goTo(i) }

    func finish() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        NSApp.presentationOptions = savedPresentation
        window?.orderOut(nil)
        Task { await web.unload() }
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // ⌘Tab などで離れたら、メニューバーと Dock を戻す
        NSApp.presentationOptions = savedPresentation
    }
    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }
}
