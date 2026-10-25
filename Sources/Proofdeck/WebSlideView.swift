import AppKit
import WebKit

/// pptx を JavaScript（pptx-vanilla-viewer）で描くビュー。
/// ページと資料は ppv:// という専用の URL で渡し、外部への通信は一切させない。
@MainActor
final class WebSlideView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let scheme = PPVSchemeHandler()
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// プロデューサーがこちらの表示でスライドを動かしたとき
    var onSlideChange: ((Int) -> Void)?
    private(set) var slideCount = 0

    static let webRoot: URL? = {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("web"), FileManager.default.fileExists(atPath: u.appendingPathComponent("index.html").path) { return u }
        // swift build のままで動かすとき（.app にしていない）
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/web").standardized
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("index.html").path) ? dev : nil
    }()

    private let createdAt = Date()

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: "ppv")
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        config.userContentController.add(WeakMessageHandler(self), name: "ppv")
        // ページ内のエラーを Swift 側へ送る（動作確認用のログに出す）
        config.userContentController.addUserScript(WKUserScript(source: """
            window.addEventListener('error', e => { try { webkit.messageHandlers.ppv.postMessage({type:'log', message:'error: ' + e.message + ' @' + e.filename + ':' + e.lineno}) } catch {} });
            window.addEventListener('unhandledrejection', e => { try { webkit.messageHandlers.ppv.postMessage({type:'log', message:'rejection: ' + String(e.reason)}) } catch {} });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scheme.webRoot = Self.webRoot
        // 念のため、http/https への読み込みも WebKit の段階で止める
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ppv-block-network",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let list { self.webView.configuration.userContentController.add(list) }
                self.ruleReady = true
                if self.pageRequested { self.webView.load(URLRequest(url: URL(string: "ppv://app/index.html")!)) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// ページ（12MB の描画ライブラリ）は、初めて使うときに読み込む。撮影用・前の版用の表示が、起動時に主の表示の足を引っ張らないように
    private var pageRequested = false
    private var ruleReady = false
    func preparePage() {
        guard !pageRequested else { return }
        pageRequested = true
        if ruleReady { webView.load(URLRequest(url: URL(string: "ppv://app/index.html")!)) }
    }

    private func waitReady() async {
        if ready { return }
        preparePage()
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// 資料を描く。返り値はスライド枚数（失敗したら nil）
    func load(deckURL: URL, slide: Int, thumbnails: Bool = false) async -> Int? {
        await waitReady()
        guard let data = try? Data(contentsOf: deckURL) else { return nil }
        let token = UUID().uuidString
        scheme.setDeck(data, token: token)
        Self.log("load start \(data.count) bytes slide=\(slide)")
        do {
            let r = try await webView.callAsyncJavaScript(
                "return await window.ppv.load(url, slide, { thumbnails })",
                arguments: ["url": "ppv://app/__deck/\(token).pptx", "slide": slide, "thumbnails": thumbnails], contentWorld: .page)
            let n = (r as? NSNumber)?.intValue ?? -1
            Self.log(String(format: "load result %d at %.2fs since view created", n, Date().timeIntervalSince(createdAt)))
            if n > 0 { slideCount = n }
            return n > 0 ? n : nil
        } catch {
            Self.log("load failed: \(error)")
            return nil
        }
    }

    /// 倍率と位置を取り出す / 当てる（前の版を今の版と同じ見え方で出す）
    func viewState() async -> Any? {
        await waitReady()
        return try? await webView.callAsyncJavaScript("return window.ppv.viewState()", arguments: [:], contentWorld: .page)
    }
    func applyView(_ state: Any) async {
        await waitReady()
        _ = try? await webView.callAsyncJavaScript("await window.ppv.applyView(s)", arguments: ["s": state], contentWorld: .page)
    }

    /// いま出しているスライド（0 始まり。無ければ -1）
    func currentIndex() async -> Int {
        await waitReady()
        let r = try? await webView.callAsyncJavaScript("return window.ppv.current()", arguments: [:], contentWorld: .page)
        return (r as? NSNumber)?.intValue ?? -1
    }

    func setBackground(_ css: String) {
        Task { await waitReady(); _ = try? await webView.callAsyncJavaScript("window.ppv.setBackground(c)", arguments: ["c": css], contentWorld: .page) }
    }

    /// 表示を捨ててメモリを返す
    func unload() async {
        await waitReady()
        _ = try? await webView.callAsyncJavaScript("window.ppv.unload()", arguments: [:], contentWorld: .page)
        slideCount = 0
    }

    func zoom(_ action: String) {
        Task { await waitReady(); _ = try? await webView.callAsyncJavaScript("window.ppv.\(action)()", arguments: [:], contentWorld: .page) }
    }

    /// 表示全体を撮る（サムネイル用。ビューの大きさをスライドの縦横比に合わせておくと、そのままスライドになる）。
    /// pixelWidth を指定すると、その横幅のピクセル数で描き直して撮る（文字も図形もその解像度で描かれる）
    func snapshotWhole(pixelWidth: CGFloat? = nil) async -> NSImage? {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        if let pixelWidth { cfg.snapshotWidth = NSNumber(value: Double(pixelWidth)) }
        return try? await webView.takeSnapshot(configuration: cfg)
    }

    /// ページの中でスクリプトを走らせて、結果をそのまま返す
    func evaluateJSON(_ js: String) async -> Any? {
        await waitReady()
        return try? await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
    }

    /// 動作確認用: ページの中でスクリプトを走らせて結果を文字列で返す
    func evaluate(_ js: String) async -> String {
        await waitReady()
        do {
            let r = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            if let r, JSONSerialization.isValidJSONObject(r), let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) {
                return String(decoding: d, as: UTF8.self)
            }
            return String(describing: r ?? "nil")
        } catch {
            return "error: \(error)"
        }
    }

    func goTo(_ index: Int) async {
        await waitReady()
        _ = try? await webView.callAsyncJavaScript("await window.ppv.goTo(i)", arguments: ["i": index], contentWorld: .page)
    }

    /// 表示中のスライドだけを切り出した画像（比較用）
    func snapshotSlide() async -> NSImage? {
        guard let r = try? await webView.callAsyncJavaScript("return window.ppv.slideRect()", arguments: [:], contentWorld: .page) as? [String: Any],
              let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["width"] as? NSNumber)?.doubleValue, let h = (r["height"] as? NSNumber)?.doubleValue, w > 1, h > 1 else { return nil }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: x, y: y, width: w, height: h)
        cfg.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: cfg)
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("[web] \(s)\n".utf8))
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { Self.log("navigation failed: \(error)") }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { Self.log("navigation failed: \(error)") }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { Self.log("page loaded: \(webView.url?.absoluteString ?? "")") }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                Self.log(String(format: "ready after %.2fs", Date().timeIntervalSince(createdAt)))
                ready = true
                readyWaiters.forEach { $0.resume() }
                readyWaiters.removeAll()
            case "log":
                Self.log(body["message"] as? String ?? "")
            case "slide":
                if let i = (body["index"] as? NSNumber)?.intValue { onSlideChange?(i) }
            default:
                break
            }
        }
    }
}

/// WKUserContentController が強参照で持つので、循環を切るための中継
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?
    init(_ t: NSObject & WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// ppv://app/... はアプリ同梱のページ、ppv://app/__deck/<token>.pptx は表示する資料を返す（同じオリジンにして CORS を避ける）
final class PPVSchemeHandler: NSObject, WKURLSchemeHandler {
    var webRoot: URL?
    private var decks: [String: Data] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    func setDeck(_ data: Data, token: String) {
        lock.lock(); defer { lock.unlock() }
        decks[token] = data
        order.append(token)
        while order.count > 2 { decks.removeValue(forKey: order.removeFirst()) }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var data: Data?
        var mime = "application/octet-stream"
        if url.path.hasPrefix("/__deck/") {
            let token = url.deletingPathExtension().lastPathComponent
            lock.lock(); data = decks[token]; lock.unlock()
        } else if let root = webRoot {
            let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let file = root.appendingPathComponent(rel).standardized
            if file.path.hasPrefix(root.standardized.path) { data = try? Data(contentsOf: file) }
            switch file.pathExtension {
            case "html": mime = "text/html; charset=utf-8"
            case "js": mime = "text/javascript; charset=utf-8"
            case "css": mime = "text/css; charset=utf-8"
            default: break
            }
        }
        guard let data else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
