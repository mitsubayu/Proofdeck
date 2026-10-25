import AppKit
import Quartz

/// Finder のスペースキー（Quick Look）で pptx を描く。描画はアプリ本体と同じ JavaScript のページを使う。
/// 左にサムネイルの帯を出し、クリックか矢印キーでスライドを移れる。
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var slides: WebSlideView!

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let v = MainActor.assumeIsolated { WebSlideView(frame: NSRect(x: 0, y: 0, width: 960, height: 600)) }
        slides = v
        view = v
        preferredContentSize = NSSize(width: 960, height: 600)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let slides = self.slides!
        Task { @MainActor in
            let n = await slides.load(deckURL: url, slide: 0, thumbnails: true)
            handler(n == nil ? NSError(domain: "Proofdeck.Preview", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "この pptx を描けませんでした"]) : nil)
        }
    }
}
