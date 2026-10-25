import AppKit

/// アプリのアイコンを、見るに足る大きさで。
///
/// `NSApp.applicationIconImage` は 128 px の表現を一つ返すだけなので、それより大きく描くとぼやける。
/// 名前で引くと全段の表現（最大 2048 px）が付いてきて、描く大きさに合うものを AppKit が選ぶ。
@MainActor
enum AppIconImage {
    static let full: NSImage = NSImage(named: NSImage.applicationIconName)
        ?? NSApp.applicationIconImage
}
