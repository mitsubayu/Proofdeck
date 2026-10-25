import AppKit

/// 左側のスライド一覧（番号つきサムネイル）。PowerPoint の標準表示の左ペインに相当する。
/// サムネイルの画像は外から 1 枚ずつ渡される（JavaScript 側で描いたものを撮る）。
@MainActor
final class SlideListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = SlideTableView()
    /// ⌘C と右クリックの「画像としてコピー」
    var onCopy: ((Int) -> Void)?
    private(set) var count = 0
    private var aspect: CGFloat = 9.0 / 16.0
    private var hidden: [Bool] = []
    private var thumbnails: [Int: NSImage] = [:]
    /// 直前の更新で変わったスライド（番号の下に丸印）
    private var changed = Set<Int>()
    /// メモのあるスライド（番号の下に吹き出し）。済のものは緑の印
    private var memos = Set<Int>()
    private var memosDone = Set<Int>()
    private(set) var current = 0
    var onSelect: ((Int) -> Void)?
    private var syncing = false

    override init() {
        super.init()
        let col = NSTableColumn(identifier: .init("slide"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.onCopy = { [weak self] row in self?.onCopy?(row) }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tableView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widthChanged() }
        }
    }

    /// サムネイル 1 枚の表示幅（ポイント）
    var thumbWidthPoints: CGFloat { max(0, tableView.bounds.width - SlideCell.thumbLeading - SlideCell.thumbTrailing) }

    private var lastWidth: CGFloat = 0
    private func widthChanged() {
        guard abs(tableView.bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = tableView.bounds.width
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    private func quietly(_ body: () -> Void) {
        syncing = true
        body()
        syncing = false
    }

    /// 枚数や並びが変わった。サムネイルは全部捨てる
    func setSlides(count: Int, aspect: CGFloat, hidden: [Bool]) {
        self.count = count
        self.aspect = aspect
        self.hidden = hidden
        thumbnails.removeAll()
        // 描き直しても、一覧のスクロール位置は保つ
        let offset = scrollView.contentView.bounds.origin
        quietly { tableView.reloadData() }
        tableView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: offset.x, y: min(offset.y, max(0, tableView.bounds.height - scrollView.contentView.bounds.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        select(min(current, max(0, count - 1)), scroll: false)
    }

    /// 一部のスライドだけ変わった。そのサムネイルだけ捨てる（届き次第、差し替わる）
    func invalidate(_ indices: [Int], hidden: [Bool]) {
        self.hidden = hidden
        for i in indices { thumbnails.removeValue(forKey: i) }
        reload(rows: indices)
    }

    func setThumbnail(_ image: NSImage, at index: Int) {
        thumbnails[index] = image
        reload(rows: [index])
    }

    func hasThumbnail(_ index: Int) -> Bool { thumbnails[index] != nil }

    func setChanged(_ rows: Set<Int>) {
        let affected = changed.union(rows)
        changed = rows
        reload(rows: Array(affected))
    }

    func setMemos(_ rows: Set<Int>, done: Set<Int> = []) {
        let affected = memos.symmetricDifference(rows).union(memosDone.symmetricDifference(done))
        memos = rows
        memosDone = done
        reload(rows: Array(affected))
    }

    private func reload(rows: [Int]) {
        let set = IndexSet(rows.filter { $0 >= 0 && $0 < tableView.numberOfRows })
        guard !set.isEmpty else { return }
        quietly { tableView.reloadData(forRowIndexes: set, columnIndexes: IndexSet(integer: 0)) }
    }

    /// 表示が変わったので、一覧の選択を合わせる
    func select(_ index: Int, scroll: Bool) {
        let old = current
        current = index
        quietly {
            reload(rows: [old, index])
            if scroll, index < tableView.numberOfRows { tableView.scrollRowToVisible(index) }
            if index < tableView.numberOfRows { tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        }
    }

    // MARK: - DataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let w = max(60, tableView.bounds.width - SlideCell.thumbLeading - SlideCell.thumbTrailing)
        return (w * aspect).rounded() + SlideCell.verticalPadding * 2
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: SlideCell.id, owner: nil) as? SlideCell) ?? SlideCell()
        cell.configure(number: row + 1, image: thumbnails[row], current: row == current,
                       hidden: row < hidden.count && hidden[row], changed: changed.contains(row), memo: memos.contains(row), memoDone: memosDone.contains(row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelect?(row)
    }
}

final class SlideCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SlideCell")
    static let thumbLeading: CGFloat = 40
    static let thumbTrailing: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    private let number = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private let changedDot = NSView()
    private let memoIcon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        number.font = .systemFont(ofSize: 13)
        number.alignment = .right
        number.textColor = .secondaryLabelColor
        number.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        changedDot.wantsLayer = true
        changedDot.layer?.cornerRadius = 3.5
        changedDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        changedDot.translatesAutoresizingMaskIntoConstraints = false
        changedDot.toolTip = "直前の更新で変わったスライド"
        memoIcon.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "メモあり")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        memoIcon.contentTintColor = .systemBlue
        memoIcon.translatesAutoresizingMaskIntoConstraints = false
        memoIcon.toolTip = "メモあり"
        addSubview(number); addSubview(thumb); addSubview(changedDot); addSubview(memoIcon)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            number.widthAnchor.constraint(equalToConstant: Self.thumbLeading - 12),
            number.topAnchor.constraint(equalTo: thumb.topAnchor),
            changedDot.widthAnchor.constraint(equalToConstant: 7),
            changedDot.heightAnchor.constraint(equalToConstant: 7),
            changedDot.trailingAnchor.constraint(equalTo: number.trailingAnchor, constant: -1),
            changedDot.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 4),
            memoIcon.trailingAnchor.constraint(equalTo: number.trailingAnchor),
            memoIcon.topAnchor.constraint(equalTo: changedDot.bottomAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.thumbLeading),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.thumbTrailing),
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            thumb.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(number n: Int, image: NSImage?, current: Bool, hidden: Bool, changed: Bool, memo: Bool, memoDone: Bool) {
        changedDot.isHidden = !changed
        memoIcon.isHidden = !memo
        memoIcon.image = NSImage(systemSymbolName: memoDone ? "checkmark.bubble.fill" : "text.bubble.fill", accessibilityDescription: memoDone ? "メモ（済）" : "メモあり")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        memoIcon.contentTintColor = memoDone ? .systemGreen : .systemBlue
        memoIcon.toolTip = memoDone ? "メモあり（Claude が済にした）" : "メモあり"
        thumb.image = image
        // まだ画像が無いあいだは、薄い板を置く
        thumb.layer?.backgroundColor = image == nil ? NSColor.quaternaryLabelColor.cgColor : nil
        thumb.alphaValue = hidden ? 0.45 : 1
        let color: NSColor = current ? .labelColor : .secondaryLabelColor
        let para = NSMutableParagraphStyle(); para.alignment = .right
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: para]
        if hidden { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }  // 非表示スライドは番号に打ち消し線
        number.attributedStringValue = NSAttributedString(string: "\(n)", attributes: attrs)
        if current {
            thumb.layer?.borderWidth = 3
            thumb.layer?.borderColor = NSColor(calibratedRed: 0.91, green: 0.42, blue: 0.29, alpha: 1).cgColor
        } else {
            thumb.layer?.borderWidth = 1
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// 一覧の表。⌘C でその行のスライドを画像としてコピーし、右クリックにも同じ項目を出す
final class SlideTableView: NSTableView {
    var onCopy: ((Int) -> Void)?

    @objc func copy(_ sender: Any?) {
        let row = clickedRow >= 0 ? clickedRow : selectedRow
        guard row >= 0 else { NSSound.beep(); return }
        onCopy?(row)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 || clickedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let menu = NSMenu()
        let item = NSMenuItem(title: "スライド \(row + 1) を画像としてコピー", action: #selector(copyClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = row
        menu.addItem(item)
        return menu
    }

    @objc private func copyClicked(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? Int { onCopy?(row) }
    }
}
