import Foundation

// Proofdeck の MCP サーバー。Claude Code などと標準入出力で MCP（JSON-RPC 2.0、1 行 1 件）を話し、
// 起動中のビューアに Unix ソケットで取り次ぐ。ビューアが起動していなければ裏で起動する。

let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Proofdeck/control.sock").path
let bundleID = "com.mitsuba.proofdeck"
let serverVersion = "0.2.1"

// MARK: - ビューアとの話

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

/// ビューアの場所。このプログラムがアプリに同梱されていれば、その .app。無ければバンドル ID で探す
func viewerAppPath() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var u = exe
    for _ in 0..<4 {
        u = u.deletingLastPathComponent()
        if u.pathExtension == "app" { return u.path }
    }
    return nil
}

func launchViewer() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = viewerAppPath() { p.arguments = ["-g", "-a", app, "--args", "--background"] }
    else { p.arguments = ["-g", "-b", bundleID, "--args", "--background"] }
    try? p.run()
    p.waitUntilExit()
}

var viewerFD: Int32? = nil

func viewerConnection() -> Int32? {
    if let fd = viewerFD { return fd }
    if let fd = connectSocket() { viewerFD = fd; return fd }
    launchViewer()
    for _ in 0..<100 {
        usleep(100_000)
        if let fd = connectSocket() { viewerFD = fd; return fd }
    }
    return nil
}

var requestSeq = 0
enum ViewerError: Error { case unavailable, message(String) }

func callViewer(_ method: String, _ params: [String: Any]) throws -> Any {
    for attempt in 0..<2 {
        guard let fd = viewerConnection() else { throw ViewerError.unavailable }
        requestSeq += 1
        var line = try JSONSerialization.data(withJSONObject: ["id": requestSeq, "method": method, "params": params])
        line.append(0x0A)
        let wrote = line.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < p.count { let w = write(fd, p.baseAddress! + off, p.count - off); if w <= 0 { return false }; off += w }
            return true
        }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var ok = wrote
        while ok, buf.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { ok = false; break }
            buf.append(contentsOf: chunk[0..<n])
        }
        if !ok {
            // ビューアが終了・再起動していた。つなぎ直して一度だけやり直す
            close(fd); viewerFD = nil
            if attempt == 0 { continue }
            throw ViewerError.unavailable
        }
        let nl = buf.firstIndex(of: 0x0A)!
        guard let obj = try JSONSerialization.jsonObject(with: buf[buf.startIndex..<nl]) as? [String: Any] else { throw ViewerError.message("ビューアの返事を読めませんでした") }
        if let e = obj["error"] as? String { throw ViewerError.message(e) }
        return obj["result"] ?? NSNull()
    }
    throw ViewerError.unavailable
}

// MARK: - 道具の定義

func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    var s: [String: Any] = ["type": "object", "properties": props]
    if !required.isEmpty { s["required"] = required }
    return s
}
let pathProp: [String: Any] = ["type": "string", "description": "資料の場所（フルパス、またはファイル名だけ）。省略すると、ビューアで最後に前に出ていた資料"]
let slideProp: [String: Any] = ["type": "integer", "minimum": 1, "description": "スライド番号（1 から）。省略すると、ビューアでいま見ているスライド"]

let tools: [[String: Any]] = [
    ["name": "list_open_decks",
     "description": "Proofdeck で開いている pptx の一覧。各資料の枚数、いま見ているスライド番号、直前の更新で変わったスライド、メモの数、最終更新の時刻を返す。最初に呼ぶとよい。",
     "inputSchema": schema([:])],
    ["name": "open_deck",
     "description": "pptx を Proofdeck で開く（すでに開いていればその資料を返す）。生成した pptx をユーザーに見せたいときに使う。",
     "inputSchema": schema(["path": ["type": "string", "description": "pptx のフルパス"], "activate": ["type": "boolean", "description": "ビューアを前に出すか（既定 false）"]], required: ["path"])],
    ["name": "get_current_slide",
     "description": "ユーザーがいまビューアで見ているスライドの番号・見出し・本文・ノート・メモを返す。「このスライド」と言われたときはこれで特定する。",
     "inputSchema": schema(["path": pathProp])],
    ["name": "get_slides",
     "description": "スライドごとの番号・見出し・本文・ノート・非表示か・直前の更新で変わったか・メモを返す。from/to で範囲を絞れる。",
     "inputSchema": schema(["path": pathProp, "from": ["type": "integer", "minimum": 1], "to": ["type": "integer", "minimum": 1],
                            "include_text": ["type": "boolean", "description": "本文とノートも返すか（既定 true）。見出しだけでよければ false"]])],
    ["name": "render_slide",
     "description": "スライドを、ユーザーが見ているのと同じ描画で画像にして返す。生成・修正した結果を自分の目で確かめるのに使う。",
     "inputSchema": schema(["path": pathProp, "slide": slideProp,
                            "width": ["type": "integer", "minimum": 320, "maximum": 3840, "description": "画像の横幅（ピクセル、既定 1600）"],
                            "format": ["type": "string", "enum": ["png", "jpeg"], "description": "既定 png。枚数が多いときは jpeg が軽い"]])],
    ["name": "check_layout",
     "description": "描いた結果を測って、枠からはみ出した文字（text_overflows_box）、スライドの外に出た文字（text_off_slide）、重なった文字（text_overlaps_text）を返す。量はインチ。slides を省くと全スライド（1 枚 0.2 秒ほど）。",
     "inputSchema": schema(["path": pathProp, "slides": ["type": "array", "items": ["type": "integer", "minimum": 1], "description": "調べるスライド番号"]])],
    ["name": "get_changes",
     "description": "直前の更新（ファイルの書き換え）で変わったスライドと、そのスライドの文字の増減を返す。直したつもりの所だけが変わったかを確かめるのに使う。",
     "inputSchema": schema(["path": pathProp])],
    ["name": "get_memos",
     "description": "ユーザーがビューアのメモ欄に書いた、スライドごとのフィードバックを返す。既定では未済のものだけ。",
     "inputSchema": schema(["path": pathProp, "include_done": ["type": "boolean", "description": "済にしたメモも返すか（既定 false）"]])],
    ["name": "resolve_memo",
     "description": "メモへの対応が終わったら済にする（ビューアの一覧で緑の印になる）。ユーザーがメモを書き直すと自動で未済に戻る。",
     "inputSchema": schema(["path": pathProp, "slide": ["type": "integer", "minimum": 1], "done": ["type": "boolean", "description": "false で未済に戻す（既定 true）"]], required: ["slide"])],
    ["name": "goto_slide",
     "description": "ビューアを指定のスライドへ移す。「12 枚目を直しました」と伝えるときに、そのスライドを見せる。",
     "inputSchema": schema(["path": pathProp, "slide": ["type": "integer", "minimum": 1], "activate": ["type": "boolean", "description": "ビューアを前に出すか（既定 false）"]], required: ["slide"])],
    ["name": "set_generating",
     "description": "pptx の生成を始める前に on=true、書き終えたら on=false を送る。その間ビューアは「生成中」の帯を出し、途中の版を描き直さず、終わったら一度だけ描き直す。知らせ忘れても timeout_sec（既定 600）で解ける。",
     "inputSchema": schema(["path": pathProp, "on": ["type": "boolean"], "message": ["type": "string", "description": "帯に出す言葉（既定「Claude が生成中…」）"],
                            "timeout_sec": ["type": "number", "minimum": 10]], required: ["on"])],
]

// MARK: - 道具の実行

func textContent(_ value: Any) -> [[String: Any]] {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
}

func callTool(_ name: String, _ args: [String: Any]) throws -> [[String: Any]] {
    switch name {
    case "list_open_decks": return textContent(try callViewer("decks", [:]))
    case "open_deck": return textContent(try callViewer("open", args))
    case "get_current_slide": return textContent(try callViewer("current", args))
    case "get_slides": return textContent(try callViewer("slides", args))
    case "render_slide":
        guard let r = try callViewer("render", args) as? [String: Any], let data = r["data"] as? String else { throw ViewerError.message("画像を受け取れませんでした") }
        let caption = "スライド \(r["slide"] ?? "?")「\(r["title"] ?? "")」 \(r["width"] ?? "?")×\(r["height"] ?? "?")"
        return [["type": "image", "data": data, "mimeType": r["mime"] as? String ?? "image/png"], ["type": "text", "text": caption]]
    case "check_layout": return textContent(try callViewer("check_layout", args))
    case "get_changes": return textContent(try callViewer("changes", args))
    case "get_memos": return textContent(try callViewer("memos", args))
    case "resolve_memo": return textContent(try callViewer("resolve_memo", args))
    case "goto_slide": return textContent(try callViewer("goto", args))
    case "set_generating": return textContent(try callViewer("generating", args))
    default: throw ViewerError.message("知らない道具: \(name)")
    }
}

// MARK: - MCP（JSON-RPC 2.0、標準入出力、1 行 1 件）

func send(_ obj: [String: Any]) {
    guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    d.append(0x0A)
    FileHandle.standardOutput.write(d)
}

func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id else { return }   // 通知（notifications/initialized など）には返事をしない
    switch method {
    case "initialize":
        let version = params["protocolVersion"] as? String ?? "2025-06-18"
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "proofdeck", "version": serverVersion],
            "instructions": "Proofdeck は、ユーザーが pptx を見ているビューア。資料を生成・修正するときは、書き込みの前に set_generating(on: true)、書き終えたら set_generating(on: false)。修正のあとは render_slide で見た目を、check_layout で文字のはみ出しを確かめる。ユーザーのフィードバックは get_memos で読み、対応したら resolve_memo で済にする。「このスライド」は get_current_slide で特定する。",
        ]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            send(["jsonrpc": "2.0", "id": id, "result": ["content": try callTool(name, args), "isError": false]])
        } catch ViewerError.unavailable {
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "Proofdeck に接続できませんでした。~/Applications/Proofdeck.app があるか確かめてください。"]], "isError": true]])
        } catch ViewerError.message(let m) {
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": m]], "isError": true]])
        } catch {
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "\(error)"]], "isError": true]])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}

signal(SIGPIPE, SIG_IGN)
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    handle(msg)
}
