// Resources/AppIcon.svg（1024 四方、背景まで描いた原画）から Resources/AppIcon.icns を作る。
//   swift scripts/make-icon.swift
// 原画は四隅まで塗った正方形。macOS のアイコンの決まり（1024 の中に 824 の角丸、余白 100）に合わせて
// 縮めて角丸で切り抜く。この形でないと、macOS 26 は灰色の角丸の枠に入れて表示する。
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appendingPathComponent("Resources/AppIcon.svg")
let out = root.appendingPathComponent("Resources/AppIcon.icns")
guard let art = NSImage(contentsOf: svg) else { fatalError("cannot read \(svg.path)") }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let k = CGFloat(px) / 1024
    let box = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    NSBezierPath(roundedRect: box, xRadius: 185.4 * k, yRadius: 185.4 * k).addClip()
    art.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try! render(s).write(to: set.appendingPathComponent("icon_\(s)x\(s).png"))
    try! render(s * 2).write(to: set.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
