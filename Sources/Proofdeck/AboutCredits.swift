import AppKit

/// 標準の About ウインドウに出す文。著作権表示を Info.plist の NSHumanReadableCopyright ではなく
/// ここに置くのは、あのキーが素の文字列で、リンクを持てるのが credits だけだから。
enum AboutCredits {
    static let authorURL = URL(string: "https://x.com/mitsuba_yu")!
    static let authorName = "mitsubayu"

    /// 短く、静かに。About は名刺であって説明書ではない。説明はヘルプに置く。
    static func attributedString() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 10

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            // 二行の釣り合いを手で取る。パネルの幅まかせで折り返させない
            string: "A .pptx viewer that reloads the deck\nwhenever another app rewrites it.\n",
            attributes: body))
        credits.append(NSAttributedString(
            string: "Designed and built by \(authorName) with claude.\n",
            attributes: quiet))
        credits.append(NSAttributedString(string: "© 2026 ", attributes: quiet))
        // 下線は引かない。リンクの色で足りるし、一行の脚に下線はうるさい
        credits.append(NSAttributedString(string: authorName, attributes: quiet.merging([
            .link: authorURL,
            .foregroundColor: NSColor.linkColor,
        ]) { _, new in new }))
        return credits
    }
}
