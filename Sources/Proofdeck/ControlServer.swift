import Foundation

/// MCP サーバー（proofdeck-mcp）からの頼みを受ける窓口。
/// ~/Library/Application Support/Proofdeck/control.sock に Unix ソケットを開く（権限は本人だけ 0600）。
/// 1 行に 1 つの JSON: {"id":1,"method":"current","params":{...}} → {"id":1,"result":...} または {"id":1,"error":"..."}
final class ControlServer: @unchecked Sendable {
    static let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Proofdeck/control.sock").path
    typealias Handler = @MainActor (String, [String: Any]) async throws -> Any
    private let handler: Handler
    private var listenFD: Int32 = -1

    init(handler: @escaping Handler) { self.handler = handler }

    func start() {
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); return }
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "ControlServer.accept"
        t.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if errno == EINTR { continue }; break }
            let t = Thread { [weak self] in self?.serve(c) }
            t.name = "ControlServer.conn"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                let reply = respond(to: Data(line))
                var out = reply
                out.append(0x0A)
                out.withUnsafeBytes { p in
                    var off = 0
                    while off < p.count {
                        let w = write(fd, p.baseAddress! + off, p.count - off)
                        if w <= 0 { return }
                        off += w
                    }
                }
            }
        }
    }

    /// 1 件ぶん。処理はメインスレッドで行い、このスレッドは結果を待つ
    private func respond(to line: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = obj["method"] as? String else {
            return (try? JSONSerialization.data(withJSONObject: ["error": "bad request"])) ?? Data()
        }
        let id = obj["id"] ?? NSNull()
        let params = obj["params"] as? [String: Any] ?? [:]
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Any?
        nonisolated(unsafe) var failure: String?
        let handler = self.handler
        Task { @MainActor in
            do { result = try await handler(method, params) } catch { failure = error.localizedDescription }
            sem.signal()
        }
        sem.wait()
        var reply: [String: Any] = ["id": id]
        if let failure { reply["error"] = failure } else { reply["result"] = result ?? NSNull() }
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"error\":\"encode\"}".utf8)
    }
}
