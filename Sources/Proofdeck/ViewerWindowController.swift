import AppKit
import UniformTypeIdentifiers
import ImageIO

/// 1 ファイルにつき 1 ウインドウ。左にスライド一覧、右に 1 枚ずつの表示、下にノート。
/// 描画は JavaScript（pptx-vanilla-viewer）。ファイルの変化を検知したら、スナップショットを取って描き直す。
/// 見ていたスライド番号は保つ。スライドが減ってそのページが無くなったら最後のスライドを出す。
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    let fileURL: URL
    private var watcher: FileWatcher?
    /// 主の表示
    private let webSlides = WebSlideView()
    /// サムネイルの撮影用。主の表示の裏に置いて、見えないまま使う
    private let thumbWeb = WebSlideView()
    /// 前の版。主の表示の上に重ね、⌘B で出し入れする
    private let prevWeb = WebSlideView()
    private let prevBannerBox = NSView()
    private let prevBanner = NSTextField(labelWithString: "")
    private var previousDeck: Deck?
    private var previousSnapshot: URL?
    private var previousGeneration = 0
    private var previousTime: Date?
    private var prevLoadedGeneration = 0
    private var displayedTime: Date?
    var previousVisible: Bool { !prevWeb.isHidden && prevWeb.alphaValue > 0 }
    /// 直前の更新で変わったスライド
    private var lastChanged = Set<Int>()
    /// 最後に前に出た時刻（MCP で「どの資料か」を指定されなかったときに使う）
    private(set) var lastFocused = Date()
    /// Claude が生成中（この間はファイルが変わっても描き直さない）
    private var generatingHold = false
    private var generatingPending = false
    private var generatingTimer: Timer?
    private let genBannerBox = NSView()
    private let genBanner = NSTextField(labelWithString: "")
    private static let thumbSize = NSSize(width: 480, height: 270)
    /// 上: スライド、下: ノート
    private let notesSplit = NSSplitView()
    private let notesScroll = NSScrollView()
    private let notesView = NSTextView()
    /// 下の欄: 左にノート、右にメモ
    private let bottomSplit = NSSplitView()
    private let memoScroll = NSScrollView()
    private let memoView = NSTextView()
    private var memos: [Int: String] = [:]
    private var memoSlide = -1
    /// メモ欄の幅。分割線を動かす力（490）より弱い約束として持ち、動かされたら追従する
    private var memoWidthConstraint: NSLayoutConstraint?
    private let slideList = SlideListController()
    private let mainSplit = NSSplitView()
    private let statusBar = StatusBarView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let slideLabel = NSTextField(labelWithString: "")
    /// 検索（⌘F で出す）
    private let searchField = NSSearchField()
    private let searchLabel = NSTextField(labelWithString: "")
    private var searchTexts: [String] = []
    private var searchTextsGeneration = -1
    private let workRoot: URL
    private var generation = 0
    private var job: Task<Void, Never>?
    /// いま画面に出ている内容が反映している版と、その世代
    private var displayedDeck: Deck?
    private var displayedGeneration = 0
    private var displayedSnapshot: URL?
    private var slideCount = 0
    /// プロデューサーが見ているスライド（0 始まり）
    private var currentSlide = 0
    /// このファイル用に覚えていた位置で開いたか（初めてのファイルは AppDelegate が位置を決める）
    private(set) var hasRememberedFrame = false
    var onClose: ((ViewerWindowController) -> Void)?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    init(fileURL: URL) {
        self.fileURL = fileURL
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Proofdeck", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.minSize = NSSize(width: 500, height: 320)
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        if let e = WindowMemory.entry(for: fileURL) {
            let f = NSRectFromString(e.frame)
            if WindowMemory.usable(f) { window.setFrame(f, display: false); hasRememberedFrame = true }
            currentSlide = max(0, e.slide)
        }
        try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        // 主の表示だけは、すぐ読み込み始める
        webSlides.preparePage()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 画面の組み立て

    private func buildLayout(in window: NSWindow) {
        let right = NSView()

        // 撮影用の表示は、主の表示の裏（最初に足した部品が一番奥）に置く
        thumbWeb.frame = NSRect(origin: NSPoint(x: 0, y: 24), size: Self.thumbSize)
        thumbWeb.autoresizingMask = []
        right.addSubview(thumbWeb)

        let webPanel = NSView()
        webSlides.translatesAutoresizingMaskIntoConstraints = false
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            webSlides.setContentCompressionResistancePriority(.init(1), for: o)
            webSlides.setContentHuggingPriority(.init(1), for: o)
        }
        webPanel.addSubview(webSlides)
        NSLayoutConstraint.activate([
            webSlides.leadingAnchor.constraint(equalTo: webPanel.leadingAnchor),
            webSlides.trailingAnchor.constraint(equalTo: webPanel.trailingAnchor),
            webSlides.topAnchor.constraint(equalTo: webPanel.topAnchor),
            webSlides.bottomAnchor.constraint(equalTo: webPanel.bottomAnchor),
        ])
        webPanel.translatesAutoresizingMaskIntoConstraints = false

        // 前の版（主の表示の上に重ねる）と、その旨を示す帯
        prevWeb.translatesAutoresizingMaskIntoConstraints = false
        prevWeb.isHidden = true
        webPanel.addSubview(prevWeb)
        prevBannerBox.wantsLayer = true
        prevBannerBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.92).cgColor
        prevBannerBox.layer?.cornerRadius = 11
        prevBannerBox.translatesAutoresizingMaskIntoConstraints = false
        prevBannerBox.isHidden = true
        prevBanner.font = .systemFont(ofSize: 12, weight: .semibold)
        prevBanner.textColor = .black
        prevBanner.translatesAutoresizingMaskIntoConstraints = false
        prevBannerBox.addSubview(prevBanner)
        webPanel.addSubview(prevBannerBox)
        NSLayoutConstraint.activate([
            prevWeb.leadingAnchor.constraint(equalTo: webPanel.leadingAnchor),
            prevWeb.trailingAnchor.constraint(equalTo: webPanel.trailingAnchor),
            prevWeb.topAnchor.constraint(equalTo: webPanel.topAnchor),
            prevWeb.bottomAnchor.constraint(equalTo: webPanel.bottomAnchor),
            prevBannerBox.topAnchor.constraint(equalTo: webPanel.topAnchor, constant: 10),
            prevBannerBox.centerXAnchor.constraint(equalTo: webPanel.centerXAnchor),
            prevBannerBox.heightAnchor.constraint(equalToConstant: 22),
            prevBanner.leadingAnchor.constraint(equalTo: prevBannerBox.leadingAnchor, constant: 12),
            prevBanner.trailingAnchor.constraint(equalTo: prevBannerBox.trailingAnchor, constant: -12),
            prevBanner.centerYAnchor.constraint(equalTo: prevBannerBox.centerYAnchor),
        ])
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            prevWeb.setContentCompressionResistancePriority(.init(1), for: o)
            prevWeb.setContentHuggingPriority(.init(1), for: o)
        }
        genBannerBox.wantsLayer = true
        genBannerBox.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
        genBannerBox.layer?.cornerRadius = 11
        genBannerBox.translatesAutoresizingMaskIntoConstraints = false
        genBannerBox.isHidden = true
        genBanner.font = .systemFont(ofSize: 12, weight: .semibold)
        genBanner.textColor = .white
        genBanner.translatesAutoresizingMaskIntoConstraints = false
        genBannerBox.addSubview(genBanner)
        webPanel.addSubview(genBannerBox)
        NSLayoutConstraint.activate([
            genBannerBox.bottomAnchor.constraint(equalTo: webPanel.bottomAnchor, constant: -10),
            genBannerBox.centerXAnchor.constraint(equalTo: webPanel.centerXAnchor),
            genBannerBox.heightAnchor.constraint(equalToConstant: 22),
            genBanner.leadingAnchor.constraint(equalTo: genBannerBox.leadingAnchor, constant: 12),
            genBanner.trailingAnchor.constraint(equalTo: genBannerBox.trailingAnchor, constant: -12),
            genBanner.centerYAnchor.constraint(equalTo: genBannerBox.centerYAnchor),
        ])

        // ノート欄
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.font = .systemFont(ofSize: 15)
        notesView.textColor = .labelColor
        notesView.backgroundColor = .textBackgroundColor
        notesView.textContainerInset = NSSize(width: 16, height: 12)
        notesView.isVerticallyResizable = true
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false

        // メモ欄（スライドごとのフィードバックの下書き）
        memoView.isEditable = true
        memoView.isRichText = false
        memoView.allowsUndo = true
        memoView.font = .systemFont(ofSize: 14)
        memoView.textColor = .labelColor
        memoView.backgroundColor = .textBackgroundColor
        memoView.textContainerInset = NSSize(width: 14, height: 10)
        memoView.isVerticallyResizable = true
        memoView.autoresizingMask = [.width]
        memoView.textContainer?.widthTracksTextView = true
        memoView.isAutomaticQuoteSubstitutionEnabled = false
        memoView.delegate = self
        memoView.setValue(NSAttributedString(string: "このスライドへのメモ（Claude への指示など）。⌥⌘C でまとめてコピー",
                                             attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 14)]),
                          forKey: "placeholderAttributedString")
        memoScroll.documentView = memoView
        memoScroll.hasVerticalScroller = true
        memoScroll.borderType = .noBorder

        func titled(_ title: String, _ content: NSView) -> NSView {
            let box = NSView()
            let strip = StatusBarView()
            strip.separatorAtBottom = true
            strip.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(label)
            content.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(strip); box.addSubview(content)
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: box.topAnchor),
                strip.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                strip.heightAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
                content.topAnchor.constraint(equalTo: strip.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            return box
        }
        bottomSplit.isVertical = true
        bottomSplit.dividerStyle = .thin
        bottomSplit.translatesAutoresizingMaskIntoConstraints = false
        let notesBox = titled("ノート", notesScroll)
        let memoBox = titled("メモ", memoScroll)
        notesBox.translatesAutoresizingMaskIntoConstraints = false
        memoBox.translatesAutoresizingMaskIntoConstraints = false
        bottomSplit.addArrangedSubview(notesBox)
        bottomSplit.addArrangedSubview(memoBox)
        let mw = memoBox.widthAnchor.constraint(equalToConstant: CGFloat(UserDefaults.standard.object(forKey: "memoWidth") as? Double ?? 320))
        mw.priority = .init(300)
        mw.isActive = true
        memoWidthConstraint = mw
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: bottomSplit, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                // 分割線をドラッグしたときだけ、その幅を覚える（ウインドウの大きさの変化では覚えない）
                guard let self, (n.userInfo?["NSSplitViewDividerIndex"] as? Int) != nil else { return }
                let w = self.bottomSplit.arrangedSubviews[1].frame.width
                guard w >= 120 else { return }
                self.memoWidthConstraint?.constant = w
                UserDefaults.standard.set(Double(w), forKey: "memoWidth")
            }
        }

        notesSplit.isVertical = false
        notesSplit.dividerStyle = .paneSplitter
        notesSplit.translatesAutoresizingMaskIntoConstraints = false
        notesSplit.addArrangedSubview(webPanel)
        notesSplit.addArrangedSubview(bottomSplit)
        // 守る強さは分割線を動かす力（約 490）より弱く。ウインドウの大きさが変わったら、スライド側が伸び縮みする
        notesSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        notesSplit.setHoldingPriority(.init(260), forSubviewAt: 1)
        bottomSplit.isHidden = UserDefaults.standard.bool(forKey: "notesHidden")
        right.addSubview(notesSplit)

        let bar = statusBar
        bar.translatesAutoresizingMaskIntoConstraints = false
        slideLabel.translatesAutoresizingMaskIntoConstraints = false
        slideLabel.font = .systemFont(ofSize: 12)
        slideLabel.textColor = .secondaryLabelColor
        bar.addSubview(slideLabel)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "スライドとノートを検索"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.delegate = self
        searchField.isHidden = true
        searchLabel.translatesAutoresizingMaskIntoConstraints = false
        searchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        searchLabel.textColor = .secondaryLabelColor
        bar.addSubview(searchField)
        bar.addSubview(searchLabel)
        NSLayoutConstraint.activate([
            searchField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            searchLabel.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            searchLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        right.addSubview(bar)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isSelectable = true
        right.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            notesSplit.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            notesSplit.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            notesSplit.topAnchor.constraint(equalTo: right.topAnchor),
            notesSplit.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            slideLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            slideLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: webPanel.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: webPanel.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: webPanel.widthAnchor, constant: -80),
        ])

        let split = mainSplit
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "Proofdeck.Split"
        split.addArrangedSubview(slideList.scrollView)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
        // 初めてのときだけ既定の幅。あとは NSSplitView が覚えている幅をそのまま使う
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Proofdeck.Split") == nil {
            split.setPosition(220, ofDividerAt: 0)
        }
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: notesSplit, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.bottomSplit.isHidden, self.bottomSplit.frame.height > 20 else { return }
                UserDefaults.standard.set(Double(self.bottomSplit.frame.height), forKey: "notesHeight")
            }
        }

        slideList.scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: slideList.scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarWidthChanged() }
        }
        slideList.onSelect = { [weak self] i in self?.goToSlide(i) }
        slideList.onCopy = { [weak self] i in self?.copySlideImage(i) }
        webSlides.onSlideChange = { [weak self] i in
            guard let self, i != self.currentSlide, i >= 0, i < self.slideCount else { return }
            self.currentSlide = i
            self.syncSlideUI()
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { 120 }
    /// 一覧は好きなだけ広げてよい。右の表示に最低 320 だけ残す
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView.bounds.width - 320
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === slideList.scrollView }

    /// 分割の位置は、ウインドウが表示されて大きさが決まってから置く
    private func applyInitialSplitPositions() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let h = UserDefaults.standard.object(forKey: "notesHeight") as? Double ?? 180
        if !bottomSplit.isHidden, notesSplit.bounds.height > 300 {
            notesSplit.setPosition(notesSplit.bounds.height - CGFloat(h), ofDividerAt: 0)
        }
        bottomSplit.layoutSubtreeIfNeeded()
        debugLog("bottomSplit w=\(Int(bottomSplit.bounds.width)) notes=\(Int(bottomSplit.arrangedSubviews[0].frame.width)) memo=\(Int(bottomSplit.arrangedSubviews[1].frame.width))")
    }

    func start() {
        loadMemos()
        DispatchQueue.main.async { [weak self] in self?.applyInitialSplitPositions() }
        let sig = FileWatcher.signature(of: fileURL)
        watcher = FileWatcher(url: fileURL, initial: sig) { [weak self] _ in
            DispatchQueue.main.async { self?.fileChanged(force: false) }
        }
        watcher?.start()
        fileChanged(force: true)
    }

    // MARK: - スライドの移動と、画面の同期

    private func remember() {
        guard let window, slideCount > 0 else { return }
        WindowMemory.save(url: fileURL, frame: window.frame, slide: currentSlide)
    }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidBecomeKey(_ notification: Notification) { lastFocused = Date() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    private func goToSlide(_ i: Int) {
        guard i >= 0, i < slideCount else { return }
        currentSlide = i
        Task { await webSlides.goTo(i) }
        syncSlideUI()
    }

    /// scroll: 一覧を見ているスライドまで送るか。描き直しのときは送らない（プロデューサーが一覧を眺めている最中かもしれない）
    private func syncSlideUI(scroll: Bool = true) {
        remember()
        updateNotes()
        updateMemoView()
        if previousVisible { let j = previousIndex(for: currentSlide); Task { await prevWeb.goTo(j) } }
        if let show = slideShow { let i = currentSlide; Task { await show.goTo(i) } }
        if slideList.current != currentSlide || scroll { slideList.select(currentSlide, scroll: scroll) }
        updateSlideLabel()
    }

    private func updateSlideLabel() {
        guard slideCount > 0 else { slideLabel.stringValue = ""; return }
        var s = "スライド \(currentSlide + 1) / \(slideCount)"
        if let deck = displayedDeck, currentSlide < deck.hidden.count, deck.hidden[currentSlide] { s += "（非表示スライド）" }
        slideLabel.stringValue = s
    }

    private func updateNotes() {
        let text = displayedDeck?.notes(at: currentSlide) ?? ""
        if notesView.string != text {
            notesView.string = text
            notesView.scrollToBeginningOfDocument(nil)
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        notesView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ], range: NSRange(location: 0, length: (notesView.string as NSString).length))
    }

    // MARK: - メニューから

    @objc func reloadNow(_ sender: Any?) { fileChanged(force: true) }

    /// いま見ているスライドを画像としてコピー（⇧⌘C）
    @objc func copyCurrentSlideImage(_ sender: Any?) { copySlideImage(currentSlide) }

    /// 裏の表示を大きくして撮り、PNG と TIFF でクリップボードへ入れる
    private static let copyWidth: CGFloat = 1920
    func copySlideImage(_ index: Int) {
        guard index >= 0, index < slideCount, let snapshot = displayedSnapshot, let deck = displayedDeck else { NSSound.beep(); return }
        let gen = displayedGeneration
        setStatus("スライド \(index + 1) を画像にしています…")
        enqueueThumbWork { [weak self] in
            guard let self, await self.ensureThumbLoaded(generation: gen, snapshot: snapshot, aspect: deck.aspect) else { return }
            let w = Self.copyWidth
            self.thumbWeb.frame = NSRect(x: 0, y: 24, width: w, height: (w * CGFloat(deck.aspect)).rounded())
            defer {
                let tw = Self.thumbSize.width
                self.thumbWeb.frame = NSRect(x: 0, y: 24, width: tw, height: (tw * CGFloat(deck.aspect)).rounded())
            }
            // 大きさを変えた直後は描き直しを待つ
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self.thumbWeb.goTo(index, forSnapshot: true)
            guard gen == self.displayedGeneration, let image = await self.thumbWeb.snapshotWhole(pixelWidth: w * 2),
                  let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                self.setStatus("スライド \(index + 1) を画像にできませんでした"); return
            }
            let pb = NSPasteboard.general
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(tiff, forType: .tiff)
            self.setStatus("スライド \(index + 1) を画像としてコピーしました（\(rep.pixelsWide)×\(rep.pixelsHigh)）")
            self.debugLog("copied png=\(png.count) bytes \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
    // MARK: - 書き出し

    private var exporting = false

    /// 裏の表示を大きくして 1 枚ずつ撮る。hidden のスライドは飛ばす。撮れたら body に渡す
    private func renderSlides(pixelWidth: CGFloat, label: String, body: @escaping @MainActor (Int, CGImage) throws -> Void) async throws -> (done: Int, skipped: Int) {
        guard let snapshot = displayedSnapshot, let deck = displayedDeck else { throw ZipArchive.ZipError.corrupt }
        let gen = displayedGeneration
        guard await ensureThumbLoaded(generation: gen, snapshot: snapshot, aspect: deck.aspect) else { throw ZipArchive.ZipError.corrupt }
        let w = Self.copyWidth
        thumbWeb.frame = NSRect(x: 0, y: 24, width: w, height: (w * CGFloat(deck.aspect)).rounded())
        defer {
            let tw = Self.thumbSize.width
            thumbWeb.frame = NSRect(x: 0, y: 24, width: tw, height: (tw * CGFloat(deck.aspect)).rounded())
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        var done = 0, skipped = 0
        for i in 0..<slideCount {
            guard gen == displayedGeneration else { throw CancellationError() }
            if i < deck.hidden.count, deck.hidden[i] { skipped += 1; continue }
            setStatus("\(label)… \(i + 1) / \(slideCount)")
            let t0 = Date()
            await thumbWeb.goTo(i, forSnapshot: true)
            let t1 = Date()
            guard let img = await thumbWeb.snapshotWhole(pixelWidth: pixelWidth),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let t2 = Date()
            try body(i, cg)
            if done < 4 { debugLog(String(format: "render %d: goTo %.2f snap %.2f body %.2f", i + 1, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t2))) }
            done += 1
        }
        return (done, skipped)
    }

    private var exportBaseName: String { fileURL.deletingPathExtension().lastPathComponent }

    /// ファイル > PDF として書き出す…（非表示スライドは除く。PowerPoint の書き出しと同じ）
    @objc func exportPDF(_ sender: Any?) {
        guard !exporting, slideCount > 0, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportBaseName + ".pdf"
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            self.writePDF(to: url)
        }
    }

    private func writePDF(to url: URL) {
        guard let deck = displayedDeck else { return }
        exporting = true
        let size = deck.slideSizePoints
        enqueueThumbWork { [weak self] in
            guard let self else { return }
            defer { self.exporting = false; self.releaseThumbWebIfIdle() }
            var box = CGRect(origin: .zero, size: size)
            let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
            guard let ctx = CGContext(tmp as CFURL, mediaBox: &box, [kCGPDFContextTitle: self.fileURL.lastPathComponent] as CFDictionary) else {
                self.setStatus("PDF を作れませんでした"); return
            }
            do {
                let r = try await self.renderSlides(pixelWidth: 2560, label: "PDF に書き出し中") { _, cg in
                    // JPEG にしてから置く（PDF の中で圧縮されたまま持たれるので、写真の多い資料でも大きくなりすぎない）
                    let data = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    CGImageDestinationFinalize(dest)
                    guard let src = CGImageSourceCreateWithData(data, nil), let jpeg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                    ctx.beginPDFPage(nil)
                    ctx.draw(jpeg, in: box)
                    ctx.endPDFPage()
                }
                ctx.closePDF()
                _ = try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                self.setStatus("PDF に書き出しました（\(r.done) 枚\(r.skipped > 0 ? "・非表示スライド \(r.skipped) 枚は除外" : "")）")
                self.debugLog("pdf exported \(r.done) pages to \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: tmp)
                self.setStatus("PDF の書き出しを中断しました")
            }
        }
    }

    /// ファイル > 画像（PNG）として書き出す…（フォルダを選ぶ。非表示スライドは除く）
    @objc func exportPNGs(_ sender: Any?) {
        guard !exporting, slideCount > 0, let window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "このフォルダに書き出す"
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let dir = panel.url, let self else { return }
            self.writePNGs(into: dir)
        }
    }

    private func writePNGs(into dir: URL) {
        exporting = true
        let base = exportBaseName
        let digits = max(2, String(slideCount).count)
        enqueueThumbWork { [weak self] in
            guard let self else { return }
            defer { self.exporting = false; self.releaseThumbWebIfIdle() }
            do {
                let r = try await self.renderSlides(pixelWidth: 3840, label: "画像に書き出し中") { i, cg in
                    let name = "\(base)-\(String(format: "%0\(digits)d", i + 1)).png"
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
                self.setStatus("画像に書き出しました（\(r.done) 枚\(r.skipped > 0 ? "・非表示スライド \(r.skipped) 枚は除外" : "")）")
                self.debugLog("png exported \(r.done) files to \(dir.path)")
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch {
                self.setStatus("画像の書き出しを中断しました")
            }
        }
    }

    /// ファイル > このスライドだけを pptx で書き出す…（描画の不具合を報告するとき用）
    @objc func exportCurrentSlidePptx(_ sender: Any?) {
        guard let deck = displayedDeck, slideCount > 0, let window else { NSSound.beep(); return }
        let index = currentSlide
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
        panel.nameFieldStringValue = "\(exportBaseName)-slide\(index + 1).pptx"
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            do {
                try deck.writeSingleSlide(index, to: url)
                self.setStatus("スライド \(index + 1) だけを pptx で書き出しました")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.setStatus("書き出せませんでした: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 前の版

    /// ⌘B: 見ているスライドの、前の版と今の版を切り替える
    @objc func togglePrevious(_ sender: Any?) {
        if previousVisible { hidePrevious(); return }
        guard previousSnapshot != nil else {
            NSSound.beep()
            setStatus("前の版はまだありません（ファイルが一度書き換わると比べられます）")
            return
        }
        Task { await showPrevious() }
    }

    /// 今の版のスライド番号を、前の版での番号に直す（同じスライドのパーツがあればそれ、無ければ同じ番号）
    private func previousIndex(for i: Int) -> Int {
        guard let cur = displayedDeck, let prev = previousDeck, !prev.slideParts.isEmpty else { return i }
        if i < cur.slideParts.count, let j = prev.slideParts.firstIndex(of: cur.slideParts[i]) { return j }
        return min(i, prev.slideParts.count - 1)
    }

    private var showingPrevious = false
    private func showPrevious() async {
        guard let snap = previousSnapshot, !showingPrevious else { return }
        showingPrevious = true
        defer { showingPrevious = false }
        let target = previousIndex(for: currentSlide)
        // 隠したままだと WebKit が描かないので、透明にして出しておき、描き終わってから見せる
        let wasHidden = prevWeb.isHidden
        if wasHidden { prevWeb.alphaValue = 0; prevWeb.isHidden = false }
        if prevLoadedGeneration != previousGeneration {
            guard await prevWeb.load(deckURL: snap, slide: target) != nil else {
                if wasHidden { prevWeb.isHidden = true }
                prevWeb.alphaValue = 1
                setStatus("前の版を描けませんでした")
                return
            }
            prevLoadedGeneration = previousGeneration
        } else {
            await prevWeb.goTo(target)
        }
        if let state = await webSlides.viewState() { await prevWeb.applyView(state) }
        let t = previousTime.map { Self.timeFormatter.string(from: $0) } ?? ""
        prevBanner.stringValue = "前の版（\(t) の表示）を見ています ・ ⌘B で今の版へ"
        prevWeb.alphaValue = 1
        prevBannerBox.isHidden = false
        debugLog("previous shown")
        // 矢印キーは一覧で受ける（前の版の表示の中で勝手にめくれないように）
        window?.makeFirstResponder(slideList.tableView)
    }

    private func hidePrevious() {
        prevWeb.isHidden = true
        prevWeb.alphaValue = 1
        prevBannerBox.isHidden = true
        Task { await prevWeb.unload(); prevLoadedGeneration = 0 }
    }

    @objc func zoomIn(_ sender: Any?) { webSlides.zoom("zoomIn") }
    @objc func zoomOut(_ sender: Any?) { webSlides.zoom("zoomOut") }
    @objc func zoomToFit(_ sender: Any?) { webSlides.zoom("zoomToFit") }

    @objc func toggleNotes(_ sender: Any?) {
        bottomSplit.isHidden.toggle()
        UserDefaults.standard.set(bottomSplit.isHidden, forKey: "notesHidden")
        notesSplit.adjustSubviews()
        if !bottomSplit.isHidden {
            let h = UserDefaults.standard.object(forKey: "notesHeight") as? Double ?? 180
            notesSplit.setPosition(max(120, notesSplit.bounds.height - CGFloat(h)), ofDividerAt: 0)
        }
    }

    var notesVisible: Bool { !bottomSplit.isHidden }

    // MARK: - 検索

    /// ⌘F: 検索欄を出して、そこへ入力の焦点を移す
    @objc func showFind(_ sender: Any?) {
        searchField.isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }
    @objc func findNext(_ sender: Any?) { find(searchField.stringValue, forward: true) }
    @objc func findPrevious(_ sender: Any?) { find(searchField.stringValue, forward: false) }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let back = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        find(sender.stringValue, forward: !back)
    }

    /// Esc で検索欄を閉じる
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchField, sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        searchField.isHidden = true
        searchLabel.stringValue = ""
        window?.makeFirstResponder(webSlides.webView)
        return true
    }

    /// 本文とノートを、大文字小文字・全角半角を区別せずに探して、見ているスライドの次（前）の該当へ移る
    private func find(_ text: String, forward: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let deck = displayedDeck, slideCount > 0 else { searchLabel.stringValue = ""; return }
        if searchTextsGeneration != displayedGeneration {
            searchTexts = (0..<deck.slideParts.count).map { deck.searchableText(at: $0) }
            searchTextsGeneration = displayedGeneration
        }
        let opts: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
        let hits = searchTexts.indices.filter { searchTexts[$0].range(of: q, options: opts) != nil }
        guard !hits.isEmpty else {
            NSSound.beep()
            searchLabel.stringValue = "見つかりません"
            searchLabel.textColor = .systemRed
            return
        }
        let next: Int
        if forward { next = hits.first { $0 > currentSlide } ?? hits[0] }
        else { next = hits.last { $0 < currentSlide } ?? hits[hits.count - 1] }
        goToSlide(next)
        let pos = (hits.firstIndex(of: next) ?? 0) + 1
        searchLabel.stringValue = "\(hits.count) 枚中 \(pos) 枚目"
        searchLabel.textColor = .secondaryLabelColor
        debugLog("find \(q): hits=\(hits.map { $0 + 1 }) -> \(next + 1)")
    }

    // MARK: - メモ（フィードバックの下書き）

    private func loadMemos() {
        memos = MemoStore.memos(for: fileURL)
        refreshMemoMarks()
    }

    private func refreshMemoMarks() {
        let done = MemoStore.done(for: fileURL).intersection(memos.keys)
        slideList.setMemos(Set(memos.keys), done: done)
    }

    private func updateMemoView() {
        guard memoSlide != currentSlide else { return }
        memoSlide = currentSlide
        let text = memos[currentSlide] ?? ""
        if memoView.string != text { memoView.string = text; memoView.undoManager?.removeAllActions() }
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === memoView, memoSlide >= 0 else { return }
        // プロデューサーが書き直したら、済の印は外す
        MemoStore.setDone(false, at: memoSlide, for: fileURL)
        setMemo(memoView.string, at: memoSlide)
    }

    private func setMemo(_ text: String, at index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { memos.removeValue(forKey: index) } else { memos[index] = text }
        MemoStore.set(text, at: index, for: fileURL)
        refreshMemoMarks()
        if index == currentSlide, memoView.string != text { memoView.string = text }
    }

    /// スライドの見出し。メモをまとめるとき、MCP で返すときに添える
    private func slideTitle(_ index: Int) -> String { displayedDeck?.title(at: index) ?? "" }

    /// ⌥⌘C: メモを、スライド番号と見出しつきでまとめてコピーする（そのまま Claude に貼れる形）
    @objc func copyAllMemos(_ sender: Any?) {
        let keys = memos.keys.sorted()
        guard !keys.isEmpty else { NSSound.beep(); setStatus("メモはまだありません"); return }
        var out = "\(fileURL.lastPathComponent) へのフィードバック\n"
        for i in keys {
            let title = slideTitle(i)
            out += "\n## スライド \(i + 1)" + (title.isEmpty ? "" : "「\(title)」") + "\n"
            out += (memos[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        setStatus("メモ \(keys.count) 件をまとめてコピーしました")
        debugLog("memos copied: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
    }

    @objc func clearAllMemos(_ sender: Any?) {
        guard !memos.isEmpty, let window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "このファイルのメモをすべて消しますか？"
        alert.informativeText = "\(memos.count) 件のメモが消えます。元に戻せません。"
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.memos.removeAll()
            MemoStore.clear(for: self.fileURL)
            self.slideList.setMemos([])
            self.memoView.string = ""
            self.setStatus("メモをすべて消しました")
        }
    }

    // MARK: - 読み込みと描き直し

    private func fileChanged(force: Bool) {
        if generatingHold && !force {
            generatingPending = true
            setStatus("Claude が生成中のため、描き直しを待っています")
            return
        }
        job?.cancel()
        generation += 1
        let gen = generation
        job = Task { [weak self] in await self?.process(generation: gen, force: force) }
    }

    private func process(generation gen: Int, force: Bool) async {
        let started = Date()
        let dir = workRoot.appendingPathComponent(String(gen), isDirectory: true)
        let snapshot = dir.appendingPathComponent("deck.pptx")
        let deck: Deck
        do {
            let src = fileURL
            deck = try await Task.detached {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: snapshot)
                return try Deck(url: snapshot)
            }.value
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                setStatus("ファイルが見つかりません")
            } else {
                setStatus("読み込みに失敗しました（書き込み途中かもしれません）")
            }
            return
        }
        guard !Task.isCancelled else { return }

        // 何が変わったか
        var changed: [Int]? = nil   // nil = 全部
        if !force, let old = displayedDeck {
            switch deck.changes(since: old) {
            case .none:
                // 中身に関わる変更がない（保存し直しただけ、ノートだけ、など）
                displayedDeck = deck
                updateNotes()
                setStatus("\(Self.timeFormatter.string(from: Date())) に確認・スライドの変更なし")
                cleanupOldGenerations(keeping: displayedGeneration)
                return
            case .slides(let idx): changed = idx
            case .structural: changed = nil
            }
        }

        setStatus("描画中…")
        let firstLoad = slideCount == 0
        guard let n = await webSlides.load(deckURL: snapshot, slide: currentSlide), !Task.isCancelled else {
            if !Task.isCancelled {
                setStatus("描画できませんでした")
                if slideCount == 0 { messageLabel.stringValue = "この pptx を描けませんでした。\nファイルが壊れていないか、確かめてください。" }
            }
            return
        }
        messageLabel.stringValue = ""
        let structural = changed == nil || n != slideCount
        // 変わったスライドを、中身の指紋で比べて求める（挿入や削除で番号がずれても拾える）
        var marks = Set<Int>()
        if !firstLoad, let old = displayedDeck {
            let oldSigs = Set(old.slideSignatures)
            marks = Set(deck.slideSignatures.enumerated().filter { !oldSigs.contains($0.element) }.map(\.offset))
            if !marks.isEmpty || old.slideParts.count != deck.slideParts.count {
                previousDeck = old
                previousSnapshot = displayedSnapshot
                previousGeneration = displayedGeneration
                previousTime = displayedTime
            }
        }
        displayedDeck = deck
        displayedGeneration = gen
        displayedSnapshot = snapshot
        displayedTime = Date()
        slideCount = n
        currentSlide = min(currentSlide, n - 1)
        if structural {
            slideList.setSlides(count: n, aspect: CGFloat(deck.aspect), hidden: deck.hidden)
        } else {
            slideList.invalidate(changed ?? [], hidden: deck.hidden)
        }
        // 読み込んでいる間に移動していたら、そちらへ（JavaScript 側も最新の行き先で出すが、念のため）
        let shown = await webSlides.currentIndex()
        debugLog("loaded: web shows \(shown + 1), wanted \(currentSlide + 1)")
        if shown != currentSlide { await webSlides.goTo(currentSlide) }
        syncSlideUI(scroll: firstLoad)
        debugInitialGoto()
        // 入力の焦点は最初の表示のときだけ。描き直しのたびに奪うと、一覧の矢印キーが効かなくなる
        if firstLoad { window?.makeFirstResponder(webSlides.webView) }
        slideList.setChanged(marks)
        lastChanged = marks
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        var what = ""
        if !marks.isEmpty {
            let nums = marks.sorted().map { String($0 + 1) }
            what = "・スライド " + (nums.count <= 6 ? nums.joined(separator: ", ") : nums.prefix(6).joined(separator: ", ") + " ほか \(nums.count - 6) 枚") + " が変わりました"
        }
        setStatus("\(Self.timeFormatter.string(from: Date())) に更新（\(secs) 秒）\(what)")
        cleanupOldGenerations(keeping: gen)
        if let show = slideShow { await show.reload(snapshot: snapshot, slide: currentSlide) }
        if !firstLoad {
            // 後ろにいるときは、Dock のアイコンを一度跳ねさせて知らせる
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            if previousVisible { await showPrevious() }
        }

        // サムネイル（裏の表示で撮る）。見ているスライドの近くから
        let order = (0..<n).sorted { abs($0 - currentSlide) < abs($1 - currentSlide) }
        let targets = structural ? order : order.filter { (changed ?? []).contains($0) }
        enqueueThumbnails(generation: gen, snapshot: snapshot, aspect: deck.aspect, indices: targets)
        debugSnapshot()
        if ProcessInfo.processInfo.environment["PPV_COPY"] != nil { copySlideImage(currentSlide) }
        if let f = ProcessInfo.processInfo.environment["PPV_EVAL_FILE"], let js = try? String(contentsOfFile: f, encoding: .utf8) {
            if let s = ProcessInfo.processInfo.environment["PPV_EVAL_SLIDE"].flatMap(Int.init) { goToSlide(s - 1); try? await Task.sleep(nanoseconds: 300_000_000) }
            debugLog("eval: " + (await webSlides.evaluate(js)))
        }
    }

    /// 古い版の作業フォルダを片付ける。表示中の版と、前の版（⌘B で見る）は残す
    private func cleanupOldGenerations(keeping gen: Int) {
        let root = workRoot
        let keep: Set<Int> = [gen, displayedGeneration, previousGeneration]
        Task.detached {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for n in names { guard let g = Int(n), g < gen, !keep.contains(g) else { continue }; try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
        }
    }

    // MARK: - 裏の表示での撮影（サムネイル）

    /// 裏の表示への依頼は一つずつ順に行う（WebKit への依頼は取り消せないため）
    private var thumbQueue: Task<Void, Never>?
    private var thumbLoadedGeneration = 0

    /// サムネイルを撮っている最中に来た、急ぎの頼み（Claude からの画像・検査）。1 枚撮るごとに先に通す
    private var priorityJobs: [@MainActor () async -> Void] = []
    private var thumbLoopRunning = false

    private func enqueuePriorityWork(_ body: @escaping @MainActor () async -> Void) {
        if thumbLoopRunning { priorityJobs.append(body) } else { enqueueThumbWork(body) }
    }

    private func runPriorityJobs() async {
        while !priorityJobs.isEmpty { let job = priorityJobs.removeFirst(); await job() }
    }

    private func enqueueThumbWork(_ body: @escaping @MainActor () async -> Void) {
        let previous = thumbQueue
        thumbQueue = Task { [weak self] in
            _ = await previous?.value
            guard self != nil else { return }
            await body()
        }
    }

    /// 裏の表示に、いま表示中の版を読み込ませる（まだなら）
    private func ensureThumbLoaded(generation gen: Int, snapshot: URL, aspect: Double) async -> Bool {
        guard gen == displayedGeneration else { return false }
        if thumbLoadedGeneration == gen { return true }
        // ビューの大きさをスライドの縦横比に合わせる（撮った画像がそのままスライドになる）
        let w = Self.thumbSize.width
        thumbWeb.frame = NSRect(x: 0, y: 24, width: w, height: (w * CGFloat(aspect)).rounded())
        debugLog("thumb load start gen=\(gen)")
        guard await thumbWeb.load(deckURL: snapshot, slide: 0) != nil, gen == displayedGeneration else { debugLog("thumb load failed/stale"); return false }
        debugLog("thumb load done")
        thumbLoadedGeneration = gen
        return true
    }

    /// 一覧の幅に見合ったピクセル数（Retina ぶん 2 倍）。160 刻みで、480〜2560
    private var wantedThumbPixelWidth: CGFloat {
        let points = max(120, slideList.thumbWidthPoints)
        return min(2560, max(480, (points * 2 / 160).rounded(.up) * 160))
    }
    /// いま一覧に入っているサムネイルのピクセル幅
    private var thumbPixelWidth: CGFloat = 0

    private func enqueueThumbnails(generation gen: Int, snapshot: URL, aspect: Double, indices: [Int], force: Bool = false) {
        let pixelWidth = wantedThumbPixelWidth
        enqueueThumbWork { [weak self] in
            guard let self, await self.ensureThumbLoaded(generation: gen, snapshot: snapshot, aspect: aspect) else { return }
            self.thumbLoopRunning = true
            defer { self.thumbLoopRunning = false }
            var made = 0
            for i in indices {
                await self.runPriorityJobs()
                guard gen == self.displayedGeneration else { await self.runPriorityJobs(); return }
                if !force && self.slideList.hasThumbnail(i) { continue }
                await self.thumbWeb.goTo(i, forSnapshot: true)
                guard gen == self.displayedGeneration, let img = await self.thumbWeb.snapshotWhole(pixelWidth: pixelWidth),
                      let compact = Self.compactImage(img) else { continue }
                self.slideList.setThumbnail(compact, at: i)
                made += 1
            }
            await self.runPriorityJobs()
            self.thumbPixelWidth = pixelWidth
            self.debugLog("thumbnails made=\(made) px=\(Int(pixelWidth))")
            self.releaseThumbWebIfIdle()
        }
    }

    /// 撮った画像は JPEG に圧縮して持つ（84 枚を生のまま持つと数百 MB になる。描くときに復号される）
    private static func compactImage(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              let out = NSImage(data: jpeg) else { return nil }
        out.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        return out
    }

    /// 一覧が広がって、いまのサムネイルでは足りなくなったら撮り直す（広げ終わってから）
    private var thumbResizeTimer: Timer?
    private func sidebarWidthChanged() {
        thumbResizeTimer?.invalidate()
        thumbResizeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.slideCount > 0, let snapshot = self.displayedSnapshot, let deck = self.displayedDeck else { return }
                guard self.wantedThumbPixelWidth > self.thumbPixelWidth else { return }
                let order = (0..<self.slideCount).sorted { abs($0 - self.currentSlide) < abs($1 - self.currentSlide) }
                self.enqueueThumbnails(generation: self.displayedGeneration, snapshot: snapshot, aspect: deck.aspect, indices: order, force: true)
            }
        }
    }

    /// 裏の表示は、仕事が無ければ捨ててメモリを返す（次に要るときに読み込み直す。0.3〜1 秒）
    private func releaseThumbWebIfIdle() {
        guard thumbLoadedGeneration != 0 else { return }
        enqueueThumbWork { [weak self] in
            guard let self else { return }
            await self.thumbWeb.unload()
            self.thumbLoadedGeneration = 0
            self.debugLog("thumb web unloaded")
        }
    }

    // MARK: -

    private func setStatus(_ s: String) {
        window?.subtitle = s
        debugLog("status: \(s)")
    }

    /// 動作確認用。環境変数 PPV_LOG にファイルパスがあるときだけ書き出す。
    private func debugLog(_ s: String) {
        guard let path = ProcessInfo.processInfo.environment["PPV_LOG"] else { return }
        var line = "\(Date().timeIntervalSince1970) \(s)"
        if slideCount > 0 { line += " | pages=\(slideCount) slide=\(currentSlide + 1) list=\(slideList.current + 1) [\(slideLabel.stringValue)]" }
        if !notesView.string.isEmpty { line += " notes=\"\(notesView.string.prefix(24).replacingOccurrences(of: "\n", with: "⏎"))\"" }
        line += " web=\(Int(webSlides.frame.width))x\(Int(webSlides.frame.height))"
        if let f = window?.frame { line += " frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))" }
        line += "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// 動作確認用。環境変数 PPV_SNAPSHOT のパスにウインドウの中身を PNG で書き出す。
    private func debugSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["PPV_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PPV_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 動作確認用。環境変数 PPV_GOTO のスライドへ移動する（初回表示時のみ）。
    /// PPV_GOTO_SEQ="30@3,prev@5,zoomin@6,snap@7" のように、起動からの秒数で操作を流せる。
    /// 数字はそのスライドへ移動、prev は前の版の切り替え、zoomin / zoomout / fit は拡大、
    /// snap は PPV_SNAPSHOT のパスに番号を付けてウインドウを撮る、memo:文字 はメモを書く、find:文字 は検索、
    /// show はスライドショーの切り替え、log:js は JavaScript の結果をログへ。
    private var didInitialGoto = false
    private var snapCount = 0
    private func debugInitialGoto() {
        guard !didInitialGoto else { return }
        didInitialGoto = true
        if let n = ProcessInfo.processInfo.environment["PPV_GOTO"].flatMap(Int.init) { goToSlide(n - 1); debugLog("goto \(n)") }
        for item in (ProcessInfo.processInfo.environment["PPV_GOTO_SEQ"] ?? "").split(separator: ",") {
            guard let at = item.lastIndex(of: "@"), let t = Double(item[item.index(after: at)...]) else { continue }
            let action = String(item[..<at])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.debugAction(action) }
        }
    }

    private func debugAction(_ action: String) {
        debugLog("action \(action)")
        if let n = Int(action) { goToSlide(n - 1); return }
        switch action {
        case "prev": togglePrevious(nil)
        case "zoomin": zoomIn(nil)
        case "zoomout": zoomOut(nil)
        case "fit": zoomToFit(nil)
        case "show": toggleSlideShow(nil)
        case "copymemos": copyAllMemos(nil)
        case let a where a.hasPrefix("pdf:"): writePDF(to: URL(fileURLWithPath: String(a.dropFirst(4))))
        case let a where a.hasPrefix("png:"): writePNGs(into: URL(fileURLWithPath: String(a.dropFirst(4))))
        case let a where a.hasPrefix("single:"):
            if let deck = displayedDeck { do { try deck.writeSingleSlide(currentSlide, to: URL(fileURLWithPath: String(a.dropFirst(7)))); debugLog("single written") } catch { debugLog("single failed \(error)") } }
        case "snap":
            guard let base = ProcessInfo.processInfo.environment["PPV_SNAPSHOT"], let view = window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            snapCount += 1
            view.cacheDisplay(in: view.bounds, to: rep)
            let path = base.replacingOccurrences(of: ".png", with: "-\(snapCount).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        default:
            if action.hasPrefix("memo:") { setMemo(String(action.dropFirst(5)), at: currentSlide) }
            else if action.hasPrefix("find:") { searchField.stringValue = String(action.dropFirst(5)); searchField.isHidden = false; find(searchField.stringValue, forward: true) }
            else if action.hasPrefix("log:") {
                let js = "return " + String(action.dropFirst(4))
                Task { self.debugLog("js: " + (await self.webSlides.evaluate(js))) }
            }
        }
    }

    // MARK: - 外からの操作（MCP 経由で Claude から）

    enum ExternalError: LocalizedError {
        case notReady, badSlide(Int), failed(String)
        var errorDescription: String? {
            switch self {
            case .notReady: return "資料がまだ表示されていません"
            case .badSlide(let n): return "スライド \(n) はありません"
            case .failed(let s): return s
            }
        }
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    func externalInfo() -> [String: Any] {
        var d: [String: Any] = [
            "path": fileURL.path, "name": fileURL.lastPathComponent,
            "slide_count": slideCount, "current_slide": slideCount > 0 ? currentSlide + 1 : 0,
            "changed_slides": lastChanged.sorted().map { $0 + 1 },
            "memo_count": memos.count, "generating": generatingHold,
        ]
        if let t = displayedTime { d["updated_at"] = Self.iso.string(from: t) }
        if let t = previousTime { d["previous_version_at"] = Self.iso.string(from: t) }
        return d
    }

    /// 1 始まりの番号を 0 始まりに。範囲外は失敗
    func slideIndex(_ number: Int?) throws -> Int {
        guard slideCount > 0 else { throw ExternalError.notReady }
        let n = number ?? (currentSlide + 1)
        guard n >= 1, n <= slideCount else { throw ExternalError.badSlide(n) }
        return n - 1
    }

    func externalSlide(_ i: Int, includeText: Bool = true) -> [String: Any] {
        guard let deck = displayedDeck else { return [:] }
        let done = MemoStore.done(for: fileURL)
        var d: [String: Any] = [
            "number": i + 1, "title": slideTitle(i),
            "hidden": i < deck.hidden.count && deck.hidden[i],
            "changed_in_last_update": lastChanged.contains(i),
        ]
        if includeText {
            d["text"] = deck.bodyText(at: i)
            d["notes"] = deck.notes(at: i)
        }
        if let m = memos[i] { d["memo"] = m; d["memo_done"] = done.contains(i) }
        return d
    }

    func externalSlides(from: Int?, to: Int?, includeText: Bool) throws -> [[String: Any]] {
        guard slideCount > 0 else { throw ExternalError.notReady }
        let a = max(1, from ?? 1), b = min(slideCount, to ?? slideCount)
        guard a <= b else { return [] }
        return (a...b).map { externalSlide($0 - 1, includeText: includeText) }
    }

    /// 裏の表示で 1 枚を画像にする（サムネイル作りと順番を分け合う）
    func externalRender(_ index: Int, pixelWidth: CGFloat, jpeg: Bool) async throws -> (data: Data, width: Int, height: Int) {
        guard let snapshot = displayedSnapshot, let deck = displayedDeck else { throw ExternalError.notReady }
        let gen = displayedGeneration
        return try await withCheckedThrowingContinuation { cont in
            enqueuePriorityWork { [weak self] in
                guard let self else { cont.resume(throwing: ExternalError.notReady); return }
                guard await self.ensureThumbLoaded(generation: gen, snapshot: snapshot, aspect: deck.aspect) else { cont.resume(throwing: ExternalError.notReady); return }
                let w = Self.copyWidth
                self.thumbWeb.frame = NSRect(x: 0, y: 24, width: w, height: (w * CGFloat(deck.aspect)).rounded())
                defer {
                    let tw = Self.thumbSize.width
                    self.thumbWeb.frame = NSRect(x: 0, y: 24, width: tw, height: (tw * CGFloat(deck.aspect)).rounded())
                    self.releaseThumbWebIfIdle()
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.thumbWeb.goTo(index, forSnapshot: true)
                guard let img = await self.thumbWeb.snapshotWhole(pixelWidth: pixelWidth),
                      let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.88] : [:]) else {
                    cont.resume(throwing: ExternalError.failed("画像にできませんでした")); return
                }
                cont.resume(returning: (data, rep.pixelsWide, rep.pixelsHigh))
            }
        }
    }

    /// 描いた結果から、枠からはみ出した文字・スライドの外に出た文字・重なった文字を拾う
    func externalCheckLayout(_ indices: [Int]) async throws -> [[String: Any]] {
        guard let snapshot = displayedSnapshot, let deck = displayedDeck else { throw ExternalError.notReady }
        let gen = displayedGeneration
        let widthIn = Double(deck.slideSizePoints.width) / 72
        return try await withCheckedThrowingContinuation { cont in
            enqueuePriorityWork { [weak self] in
                guard let self else { cont.resume(throwing: ExternalError.notReady); return }
                guard await self.ensureThumbLoaded(generation: gen, snapshot: snapshot, aspect: deck.aspect) else { cont.resume(throwing: ExternalError.notReady); return }
                let w = Self.copyWidth
                self.thumbWeb.frame = NSRect(x: 0, y: 24, width: w, height: (w * CGFloat(deck.aspect)).rounded())
                defer {
                    let tw = Self.thumbSize.width
                    self.thumbWeb.frame = NSRect(x: 0, y: 24, width: tw, height: (tw * CGFloat(deck.aspect)).rounded())
                    self.releaseThumbWebIfIdle()
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                var out: [[String: Any]] = []
                for i in indices {
                    guard gen == self.displayedGeneration else { break }
                    await self.thumbWeb.goTo(i)
                    let r = await self.thumbWeb.evaluateJSON("return window.ppv.layoutIssues(\(widthIn))")
                    for var issue in (r as? [[String: Any]]) ?? [] {
                        issue["slide"] = i + 1
                        out.append(issue)
                    }
                }
                cont.resume(returning: out)
            }
        }
    }

    func externalChanges() -> [String: Any] {
        var d: [String: Any] = ["changed_slides": lastChanged.sorted().map { $0 + 1 }]
        if let t = displayedTime { d["updated_at"] = Self.iso.string(from: t) }
        guard let cur = displayedDeck else { return d }
        guard let prev = previousDeck else { d["note"] = "まだ一度も書き換わっていません"; return d }
        if let t = previousTime { d["previous_version_at"] = Self.iso.string(from: t) }
        d["slide_count"] = ["before": prev.slideParts.count, "after": cur.slideParts.count]
        var details: [[String: Any]] = []
        for i in lastChanged.sorted() {
            let j = previousIndex(for: i)
            let before = j < prev.slideParts.count ? prev.bodyText(at: j) : ""
            let after = cur.bodyText(at: i)
            var item: [String: Any] = ["slide": i + 1, "title": slideTitle(i)]
            if before == after { item["text_changed"] = false; item["note"] = "文字は同じ（図形・位置・色などが変わった）" }
            else {
                item["text_changed"] = true
                let a = Set(before.split(separator: "\n").map(String.init)), b = Set(after.split(separator: "\n").map(String.init))
                item["removed_lines"] = before.split(separator: "\n").map(String.init).filter { !b.contains($0) }
                item["added_lines"] = after.split(separator: "\n").map(String.init).filter { !a.contains($0) }
            }
            details.append(item)
        }
        d["details"] = details
        return d
    }

    func externalMemos(includeDone: Bool) -> [[String: Any]] {
        let done = MemoStore.done(for: fileURL)
        return memos.keys.sorted().compactMap { i -> [String: Any]? in
            let isDone = done.contains(i)
            if isDone && !includeDone { return nil }
            return ["slide": i + 1, "title": slideTitle(i), "memo": memos[i] ?? "", "done": isDone]
        }
    }

    func externalResolveMemo(_ i: Int, done: Bool) throws {
        guard memos[i] != nil else { throw ExternalError.failed("スライド \(i + 1) にメモはありません") }
        MemoStore.setDone(done, at: i, for: fileURL)
        refreshMemoMarks()
        setStatus("スライド \(i + 1) のメモを\(done ? "済にしました（Claude）" : "未済に戻しました（Claude）")")
    }

    func externalGoTo(_ i: Int, activate: Bool) {
        goToSlide(i)
        if activate { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    /// Claude が生成を始める／終える。始めている間は描き直さず、終えたら一度だけ描き直す。
    /// 終わりの知らせが来なくても、timeout 秒たったら自動で解く
    func externalSetGenerating(_ on: Bool, message: String?, timeout: Double) {
        generatingTimer?.invalidate()
        generatingTimer = nil
        if on {
            generatingHold = true
            genBanner.stringValue = (message?.isEmpty == false ? message! : "Claude が生成中…") + " ・ 終わると描き直します"
            genBannerBox.isHidden = false
            generatingTimer = Timer.scheduledTimer(withTimeInterval: max(10, timeout), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.externalSetGenerating(false, message: nil, timeout: 0) }
            }
        } else {
            let wasPending = generatingPending
            generatingHold = false
            generatingPending = false
            genBannerBox.isHidden = true
            if wasPending { fileChanged(force: false) }
        }
    }

    // MARK: - スライドショー

    private var slideShow: SlideShowController?
    var slideShowActive: Bool { slideShow != nil }

    /// ⇧⌘↩: 別の全画面ウインドウで 1 枚ずつ。Esc か ⇧⌘↩ で戻る。見ていたスライドから始め、終わったらそこへ戻す
    @objc func toggleSlideShow(_ sender: Any?) {
        if let show = slideShow { show.finish(); return }
        guard let snapshot = displayedSnapshot, slideCount > 0 else { NSSound.beep(); return }
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let show = SlideShowController(screen: screen)
        show.onSlideChange = { [weak self] i in
            guard let self, i != self.currentSlide, i >= 0, i < self.slideCount else { return }
            self.currentSlide = i
            Task { await self.webSlides.goTo(i) }
            self.syncSlideUI()
        }
        show.onClose = { [weak self] in
            guard let self else { return }
            self.slideShow = nil
            self.window?.makeKeyAndOrderFront(nil)
            // 全画面に覆われていたあいだ、WebKit は描画を休んでいることがある。戻ったら描き直させる
            let i = self.currentSlide
            Task { await self.webSlides.goTo(i) }
            self.debugLog("slideshow off")
        }
        slideShow = show
        debugLog("slideshow on")
        Task { await show.start(snapshot: snapshot, slide: currentSlide) }
    }

    func windowWillClose(_ notification: Notification) {
        slideShow?.finish()
        MemoStore.saveNow()
        remember()
        job?.cancel()
        watcher?.stop()
        try? FileManager.default.removeItem(at: workRoot)
        onClose?(self)
    }
}

/// 右下のスライド番号を載せるバー。ウインドウの背景色で塗り、区切り線を引く。
final class StatusBarView: NSView {
    var separatorAtBottom = false
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: separatorAtBottom ? 0 : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
