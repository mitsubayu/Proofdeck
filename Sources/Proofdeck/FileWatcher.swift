import Foundation

/// 監視対象ファイルの変化を検出する。
/// - 別アプリによる上書き保存、アトミック置換（一時ファイル→rename）の両方に対応するため、
///   パスに対して stat を定期的に取り、inode・サイズ・更新時刻の組で変化を判定する。
/// - 書き込み途中のファイルを読まないよう、同じシグネチャが 2 回続き、かつ ZIP の終端レコードが
///   揃っているときだけ「変更あり」として通知する。
final class FileWatcher {
    struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
        let ctimeSec: Int
        let ctimeNsec: Int
    }

    let url: URL
    private let onChange: (Signature) -> Void
    private var timer: DispatchSourceTimer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var delivered: Signature?
    private var pending: Signature?
    private let queue = DispatchQueue(label: "FileWatcher", qos: .userInitiated)
    /// App Nap で裏のアプリのタイマーが間引かれると検知が止まるので、監視中は止めておく
    private var activity: NSObjectProtocol?

    init(url: URL, initial: Signature?, onChange: @escaping (Signature) -> Void) {
        self.url = url
        self.delivered = initial
        self.onChange = onChange
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "ファイルの更新を監視しています")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // 親ディレクトリの変化（rename による置換など）を即座に拾うための補助。
        // デスクトップなど守られたフォルダでは、初回に macOS が許可を求め、返事があるまで open が返らない。
        // 画面が固まらないよう、監視用の列で開く
        queue.async { [weak self] in self?.openDirectorySource() }
    }

    private func openDirectorySource() {
        dirFD = open(url.deletingLastPathComponent().path, O_EVTONLY)
        // 許可を待っているあいだに監視が止められていたら、開いたものを閉じて終わる
        if timer == nil { if dirFD >= 0 { close(dirFD); dirFD = -1 }; return }
        if dirFD >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: queue)
            // 置き換え直後は書き込みが落ち着くのを待って、少し後にもう一度確かめる
            s.setEventHandler { [weak self] in
                self?.tick()
                self?.queue.asyncAfter(deadline: .now() + 0.15) { self?.tick() }
            }
            let fd = dirFD
            s.setCancelHandler { close(fd) }
            s.resume()
            dirSource = s
        }
    }

    func stop() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        // 止める対象を先に手元に取る（deinit から呼ばれても確実に片付くように）。
        // フォルダを開く途中なら、開き終えたところで timer が無いのを見て閉じる
        let t = timer, d = dirSource
        timer = nil; dirSource = nil
        queue.async { t?.cancel(); d?.cancel() }
    }

    deinit { stop() }

    static func signature(of url: URL) -> Signature? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Signature(
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
            ctimeSec: st.st_ctimespec.tv_sec, ctimeNsec: st.st_ctimespec.tv_nsec
        )
    }

    private func tick() {
        guard let sig = FileWatcher.signature(of: url) else { pending = nil; return }
        if sig == delivered { pending = nil; return }
        if sig == pending, FileWatcher.looksLikeCompleteZip(url) {
            delivered = sig
            pending = nil
            onChange(sig)
        } else {
            pending = sig
        }
    }

    /// pptx は ZIP。末尾に End of Central Directory (PK\x05\x06) があれば書き込みは完了しているとみなす。
    static func looksLikeCompleteZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end >= 22 else { return false }
        let tail = min(end, 66_000)
        try? h.seek(toOffset: end - tail)
        guard let data = try? h.read(upToCount: Int(tail)), data.count >= 22 else { return false }
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var i = data.count - 22
        while i >= 0 {
            if data[i] == sig[0] && data[i+1] == sig[1] && data[i+2] == sig[2] && data[i+3] == sig[3] { return true }
            i -= 1
        }
        return false
    }
}
