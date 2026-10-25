import Foundation
import CoreGraphics

/// pptx のスライド構成（表示順のスライドパーツ名）と、変更スライドの判定・抜き出し。
struct Deck {
    let archive: ZipArchive
    /// 表示順のスライドパーツ名（例: "ppt/slides/slide3.xml"）
    let slideParts: [String]
    /// 表示順の非表示フラグ（<p:sld show="0">）
    let hidden: [Bool]
    /// スライドの縦横比（高さ ÷ 幅）。<p:sldSz> から。無ければ 16:9
    let aspect: Double
    /// presentation.xml の <p:sldId .../> 要素（表示順）
    let sldIdElements: [String]
    let presentationXML: String
    /// presentation.xml.rels の Id → パーツ名
    let presentationTargets: [String: String]

    init(url: URL) throws {
        archive = try ZipArchive(url: url)
        guard let pres = try archive.readString("ppt/presentation.xml"),
              let rels = try archive.readString("ppt/_rels/presentation.xml.rels") else {
            throw ZipArchive.ZipError.corrupt
        }
        presentationXML = pres
        var targets: [String: String] = [:]
        for rel in rels.matches(of: /<Relationship\b[^>]*>/) {
            let tag = String(rel.output)
            guard let id = tag.firstMatch(of: /\bId="([^"]+)"/)?.output.1,
                  let target = tag.firstMatch(of: /\bTarget="([^"]+)"/)?.output.1 else { continue }
            targets[String(id)] = Deck.normalize(String(target))
        }
        var parts: [String] = []
        var elems: [String] = []
        if let list = pres.firstMatch(of: /<p:sldIdLst>([\s\S]*?)<\/p:sldIdLst>/) {
            for m in String(list.output.1).matches(of: /<p:sldId\b[^>]*\/>/) {
                let tag = String(m.output)
                guard let rid = tag.firstMatch(of: /r:id="([^"]+)"/)?.output.1,
                      let part = targets[String(rid)] else { continue }
                parts.append(part); elems.append(tag)
            }
        }
        slideParts = parts
        sldIdElements = elems
        presentationTargets = targets
        if let m = pres.firstMatch(of: /<p:sldSz\b[^>]*\bcx="(\d+)"[^>]*\bcy="(\d+)"/), let cx = Double(m.output.1), let cy = Double(m.output.2), cx > 0 {
            aspect = cy / cx
        } else {
            aspect = 9.0 / 16.0
        }
        let arc = archive
        hidden = parts.map { part in
            guard let xml = try? arc.readString(part),
                  let tag = xml.firstMatch(of: /<p:sld\b[^>]*>/) else { return false }
            return tag.output.contains("show=\"0\"")
        }
    }

    /// スライドの大きさ（ポイント）。<p:sldSz> の EMU を 12700 で割る。無ければ 16:9 の 960×540
    var slideSizePoints: CGSize {
        if let m = presentationXML.firstMatch(of: /<p:sldSz\b[^>]*\bcx="(\d+)"[^>]*\bcy="(\d+)"/), let cx = Double(m.output.1), let cy = Double(m.output.2), cx > 0 {
            return CGSize(width: cx / 12700, height: cy / 12700)
        }
        return CGSize(width: 960, height: 540)
    }

    /// 指定のスライドだけを残した pptx を書き出す（描画の不具合を報告するとき用）。
    /// ほかのスライドの本文・ノート・それにしか使われていない画像は取り除くので、関係ない内容は入らない。
    func writeSingleSlide(_ index: Int, to url: URL) throws {
        guard index >= 0, index < slideParts.count else { throw ZipArchive.ZipError.corrupt }
        let keep = slideParts[index]
        func relsName(_ part: String) -> String {
            "\((part as NSString).deletingLastPathComponent)/_rels/\((part as NSString).lastPathComponent).rels"
        }
        func targets(ofRels name: String) -> [String] {
            guard let xml = try? archive.readString(name) else { return [] }
            let base = String(((name as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent)
            return xml.matches(of: /<Relationship\b[^>]*>/).compactMap { m -> String? in
                let tag = String(m.output)
                if tag.contains("TargetMode=\"External\"") { return nil }
                guard let t = tag.firstMatch(of: /\bTarget="([^"]+)"/)?.output.1 else { return nil }
                return Deck.normalize(String(t), base: base)
            }
        }
        // 消すもの: ほかのスライドと、その関係ファイル、そのノート
        var removing = Set<String>()
        for part in slideParts where part != keep {
            removing.insert(part)
            removing.insert(relsName(part))
            for t in targets(ofRels: relsName(part)) where t.hasPrefix("ppt/notesSlides/") {
                removing.insert(t); removing.insert(relsName(t))
            }
        }
        // 残る部品から参照されていない画像・埋め込みも消す
        let remainingRels = archive.entries.map(\.name).filter { $0.hasSuffix(".rels") && !removing.contains($0) }
        let referenced = Set(remainingRels.flatMap { targets(ofRels: $0) })
        for e in archive.entries where (e.name.hasPrefix("ppt/media/") || e.name.hasPrefix("ppt/embeddings/")) && !referenced.contains(e.name) {
            removing.insert(e.name)
        }
        // presentation.xml: スライド一覧を 1 枚に
        var pres = presentationXML
        if let r = pres.firstRange(of: /<p:sldIdLst>[\s\S]*?<\/p:sldIdLst>/) {
            pres.replaceSubrange(r, with: "<p:sldIdLst>\(sldIdElements[index])</p:sldIdLst>")
        }
        // presentation.xml.rels: 消したスライドへの関係を外す
        var presRels = (try? archive.readString("ppt/_rels/presentation.xml.rels")) ?? ""
        for m in presRels.matches(of: /<Relationship\b[^>]*\/>/).reversed() {
            let tag = String(m.output)
            if let t = tag.firstMatch(of: /\bTarget="([^"]+)"/)?.output.1, removing.contains(Deck.normalize(String(t))) {
                presRels.replaceSubrange(m.range, with: "")
            }
        }
        // [Content_Types].xml: 消した部品の宣言を外す
        var types = (try? archive.readString("[Content_Types].xml")) ?? ""
        for m in types.matches(of: /<Override\b[^>]*\/>/).reversed() {
            let tag = String(m.output)
            if let n = tag.firstMatch(of: /\bPartName="\/([^"]+)"/)?.output.1, removing.contains(String(n)) {
                types.replaceSubrange(m.range, with: "")
            }
        }
        try archive.write(to: url, replacing: [
            "ppt/presentation.xml": Data(pres.utf8),
            "ppt/_rels/presentation.xml.rels": Data(presRels.utf8),
            "[Content_Types].xml": Data(types.utf8),
        ], removing: removing)
    }

    /// スライドごとの中身の指紋（スライド本文と、その関係ファイルの CRC）。前の版と比べて、変わったスライドを知るのに使う
    var slideSignatures: [String] {
        slideParts.map { part in
            let file = (part as NSString).lastPathComponent
            let dir = (part as NSString).deletingLastPathComponent
            let a = archive.byName[part], r = archive.byName["\(dir)/_rels/\(file).rels"]
            return "\(a?.crc ?? 0)-\(a?.size ?? 0)-\(r?.crc ?? 0)"
        }
    }

    /// スライドの見出し。いちばん大きな文字の段落を選ぶ（数字だけ・英大文字の札だけの段落は除く）
    func title(at index: Int) -> String {
        guard index >= 0, index < slideParts.count, let xml = try? archive.readString(slideParts[index]) else { return "" }
        var best = ""
        var bestSize = -1
        for p in xml.matches(of: /<a:p>([\s\S]*?)<\/a:p>/) {
            let body = String(p.output.1)
            var text = ""
            for t in body.matches(of: /<a:t>([\s\S]*?)<\/a:t>/) { text += Deck.unescape(String(t.output.1)) }
            let trimmed = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/／・-–—")))
            guard trimmed.count >= 2 else { continue }
            if trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "/" }) { continue }
            if trimmed.allSatisfy({ ($0.isASCII && ($0.isUppercase || $0.isNumber)) || " /&≠:-+".contains($0) }) { continue }
            let sizes = body.matches(of: /\bsz="(\d+)"/).compactMap { Int($0.output.1) }
            let size = sizes.max() ?? 1800
            if size > bestSize { bestSize = size; best = trimmed }
        }
        return best.count > 40 ? String(best.prefix(40)) + "…" : best
    }

    /// スライドの本文（段落ごとに改行。空の段落は落とす）
    func bodyText(at index: Int) -> String {
        guard index >= 0, index < slideParts.count, let xml = try? archive.readString(slideParts[index]) else { return "" }
        var lines: [String] = []
        for p in xml.matches(of: /<a:p>([\s\S]*?)<\/a:p>/) {
            var line = ""
            for t in String(p.output.1).matches(of: /<a:t>([\s\S]*?)<\/a:t>/) { line += Deck.unescape(String(t.output.1)) }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// スライドごとの検索用の文字（本文とノート）
    func searchableText(at index: Int) -> String {
        bodyText(at: index) + "\n\n" + notes(at: index)
    }

    static func normalize(_ target: String, base: String = "ppt") -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var comps = base.split(separator: "/").map(String.init)
        for c in target.split(separator: "/") {
            if c == ".." { if !comps.isEmpty { comps.removeLast() } } else if c != "." { comps.append(String(c)) }
        }
        return comps.joined(separator: "/")
    }

    enum Change { case none, slides([Int]), structural }

    /// 前回表示した版と比べて、どのスライドが変わったかを返す。
    /// スライド本文とその関係ファイル以外（レイアウト・マスター・テーマ・既存画像など）が変わったら structural。
    func changes(since old: Deck) -> Change {
        guard old.slideParts == slideParts else { return .structural }
        var changedParts = Set<String>()
        let names = Set(archive.byName.keys).union(old.archive.byName.keys)
        for name in names {
            let a = old.archive.byName[name], b = archive.byName[name]
            if let a, let b, a.crc == b.crc, a.size == b.size { continue }
            if name.hasPrefix("docProps/") || name == "[Content_Types].xml" || name.hasPrefix("ppt/notesSlides/") { continue }
            if name.hasPrefix("ppt/media/") && a == nil { continue }  // 新しく足された画像は、それを参照するスライド側の変更で拾える
            if let m = name.wholeMatch(of: /ppt\/slides\/(slide\d+\.xml)/) {
                changedParts.insert("ppt/slides/" + m.output.1); continue
            }
            if let m = name.wholeMatch(of: /ppt\/slides\/_rels\/(slide\d+\.xml)\.rels/) {
                changedParts.insert("ppt/slides/" + m.output.1); continue
            }
            return .structural
        }
        let idx = slideParts.enumerated().filter { changedParts.contains($0.element) }.map(\.offset)
        return idx.isEmpty ? .none : .slides(idx)
    }

    /// 発表者ノートの本文。ノートページの本文の枠（<p:ph type="body">）の文字を、段落ごとに改行して返す
    func notes(at index: Int) -> String {
        guard index >= 0, index < slideParts.count else { return "" }
        let part = slideParts[index]
        let dir = (part as NSString).deletingLastPathComponent          // ppt/slides
        let file = (part as NSString).lastPathComponent                 // slideN.xml
        guard let rels = try? archive.readString("\(dir)/_rels/\(file).rels") else { return "" }
        var target: String?
        for rel in rels.matches(of: /<Relationship\b[^>]*>/) {
            let tag = String(rel.output)
            guard tag.contains("/relationships/notesSlide\""),
                  let t = tag.firstMatch(of: /\bTarget="([^"]+)"/)?.output.1 else { continue }
            target = Deck.normalize(String(t), base: dir)
        }
        guard let target, let xml = try? archive.readString(target) else { return "" }
        var paragraphs: [String] = []
        for sp in xml.matches(of: /<p:sp>[\s\S]*?<\/p:sp>/) {
            let shape = String(sp.output)
            guard shape.contains("<p:ph type=\"body\"") else { continue }
            for para in shape.matches(of: /<a:p>([\s\S]*?)<\/a:p>|<a:p\/>/) {
                var text = ""
                let inner = para.output.1.map(String.init) ?? ""
                for piece in inner.matches(of: /<a:t>([\s\S]*?)<\/a:t>|<a:t\/>|<a:br\/>|<a:br>[\s\S]*?<\/a:br>/) {
                    if let t = piece.output.1 { text += Deck.unescape(String(t)) }
                    else if piece.output.0.hasPrefix("<a:br") { text += "\n" }
                }
                paragraphs.append(text)
            }
        }
        // 末尾の空行は落とす
        while paragraphs.last?.isEmpty == true { paragraphs.removeLast() }
        return paragraphs.joined(separator: "\n")
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
