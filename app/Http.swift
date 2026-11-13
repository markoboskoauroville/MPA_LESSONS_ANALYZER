import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 only (Network.framework). First free port from `from` upward.
final class Http: @unchecked Sendable {
    var onReady: ((UInt16) -> Void)?
    var handler: ((String, String, Data, Bool) async -> (Int, Data))?
    /// LAN listener (all interfaces, Bonjour): every call needs a paired code in X-Pair-Code
    var lan = false
    var bonjour: String?
    var auth: ((String?) async -> Bool)?
    private var listener: NWListener?

    func start(_ p: UInt16, tries: Int = 16) {
        guard tries > 0, let port = NWEndpoint.Port(rawValue: p) else { return }
        do {
            let params = NWParameters.tcp
            if !lan { params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port) }
            let l = try NWListener(using: params, on: port)
            if let t = bonjour { l.service = NWListener.Service(name: "Second Take", type: t) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.onReady?(p)
                case .failed: l.cancel(); self?.start(p + 1, tries: tries - 1)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: .global())
            listener = l
        } catch { start(p + 1, tries: tries - 1) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self else { c.cancel(); return }
            var buf = acc
            if let d = data { buf.append(d) }
            if let (m, p, body, code0) = Http.parse(buf) {
                Task {
                    if self.lan, !(await self.auth?(code0) ?? false) {
                        Http.send(c, 401, Data("{\"error\":\"pair: a code is shown on the Mac screen; send it in X-Pair-Code\"}".utf8)); return
                    }
                    let (code, out) = await self.handler?(m, p, body, self.lan) ?? (500, Data())
                    Http.send(c, code, out)
                }
            } else if done || err != nil { c.cancel() }
            else { self.receive(c, buf) }
        }
    }

    static func parse(_ buf: Data) -> (String, String, Data, String?)? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var len = 0
        var pair: String? = nil
        for l in lines.dropFirst() {
            let lo = l.lowercased()
            if lo.hasPrefix("content-length:") { len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if lo.hasPrefix("x-pair-code:") { pair = l.dropFirst(12).trimmingCharacters(in: .whitespaces) }
        }
        let body = buf[r.upperBound...]
        if body.count < len { return nil }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return (String(parts[0]), path, Data(body.prefix(len)), pair)
    }

    static func send(_ c: NWConnection, _ code: Int, _ body: Data) {
        let text = [200: "OK", 202: "Accepted", 401: "Unauthorized", 400: "Bad Request", 404: "Not Found", 409: "Conflict"][code] ?? "Error"
        var out = Data("HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
