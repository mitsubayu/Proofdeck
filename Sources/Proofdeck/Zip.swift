import Foundation
import Compression

/// pptx（ZIP）の中央ディレクトリを読む最小実装。
/// 差分検出（どのスライドが変わったか）と、スライドを絞り込んだ pptx の書き出しに使う。
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error { case notZip, unsupported, corrupt }

    let data: Data
    let entries: [Entry]
    let byName: [String: Entry]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.data = data
        let n = data.count
        guard n >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = n - 22
        let lower = max(0, n - 22 - 65_535)
        while i >= lower {
            if data[i] == 0x50, data[i+1] == 0x4b, data[i+2] == 0x05, data[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(data.u16(eocd + 10))
        let cdOffset = Int(data.u32(eocd + 16))
        guard count != 0xFFFF, cdOffset != 0xFFFF_FFFF else { throw ZipError.unsupported }
        var list: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= n, data.u32(p) == 0x02014b50 else { throw ZipError.corrupt }
            let nameLen = Int(data.u16(p + 28)), extraLen = Int(data.u16(p + 30)), commentLen = Int(data.u16(p + 32))
            guard p + 46 + nameLen <= n else { throw ZipError.corrupt }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            list.append(Entry(name: name,
                              method: data.u16(p + 10),
                              crc: data.u32(p + 16),
                              compressedSize: Int(data.u32(p + 20)),
                              size: Int(data.u32(p + 24)),
                              localHeaderOffset: Int(data.u32(p + 42))))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
        byName = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func dataRange(of e: Entry) throws -> Range<Int> {
        let p = e.localHeaderOffset
        guard p + 30 <= data.count, data.u32(p) == 0x04034b50 else { throw ZipError.corrupt }
        let start = p + 30 + Int(data.u16(p + 26)) + Int(data.u16(p + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt }
        return start..<(start + e.compressedSize)
    }

    func read(_ name: String) throws -> Data? {
        guard let e = byName[name] else { return nil }
        let raw = data[try dataRange(of: e)]
        switch e.method {
        case 0: return Data(raw)
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let written = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw ZipError.corrupt }
            return out
        default: throw ZipError.unsupported
        }
    }

    func readString(_ name: String) throws -> String? {
        try read(name).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 一部のエントリを差し替えた ZIP を書き出す。他のエントリは圧縮済みデータをそのまま写す。
    func write(to url: URL, replacing: [String: Data], removing: Set<String> = []) throws {
        var out = Data()
        var central = Data()
        var written = 0
        func add(name: String, method: UInt16, crc: UInt32, comp: Int, size: Int, body: Data) {
            let nameData = Data(name.utf8)
            let offset = out.count
            out.append32(0x04034b50); out.append16(20); out.append16(0x0800); out.append16(method)
            out.append16(0); out.append16(0x21)
            out.append32(crc); out.append32(UInt32(comp)); out.append32(UInt32(size))
            out.append16(UInt16(nameData.count)); out.append16(0)
            out.append(nameData); out.append(body)
            central.append32(0x02014b50); central.append16(20); central.append16(20); central.append16(0x0800)
            central.append16(method); central.append16(0); central.append16(0x21)
            central.append32(crc); central.append32(UInt32(comp)); central.append32(UInt32(size))
            central.append16(UInt16(nameData.count)); central.append16(0); central.append16(0)
            central.append16(0); central.append16(0); central.append32(0); central.append32(UInt32(offset))
            central.append(nameData)
            written += 1
        }
        for e in entries where !removing.contains(e.name) {
            if let rep = replacing[e.name] {
                add(name: e.name, method: 0, crc: CRC32.checksum(rep), comp: rep.count, size: rep.count, body: rep)
            } else {
                add(name: e.name, method: e.method, crc: e.crc, comp: e.compressedSize, size: e.size,
                    body: Data(data[try dataRange(of: e)]))
            }
        }
        let cdOffset = out.count
        out.append(central)
        out.append32(0x06054b50); out.append16(0); out.append16(0)
        out.append16(UInt16(written)); out.append16(UInt16(written))
        out.append32(UInt32(central.count)); out.append32(UInt32(cdOffset)); out.append16(0)
        try out.write(to: url)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func checksum(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | (UInt16(self[i+1]) << 8) }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | (UInt32(u16(i + 2)) << 16) }
    mutating func append16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func append32(_ v: UInt32) { append16(UInt16(v & 0xFFFF)); append16(UInt16(v >> 16)) }
}
