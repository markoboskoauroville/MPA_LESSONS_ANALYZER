import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 only (Network.framework). First free port from `from` upward.
final class Http: @unchecked Sendable {
    var onReady: ((UInt16) -> Void)?
    var handler: ((String, String, Data, Bool) async -> (Int, Data))?
    /// LAN listener (all interfaces, Bonjour): only private local networks and Tailscale may call, and only the protocol's shooting actions
    var lan = false
    var bonjour: String?
    private var listener: NWListener?

    func start(_ p: UInt16, tries: Int = 16) {
        guard tries > 0, let port = NWEndpoint.Port(rawValue: p) else { return }
        do {
            let params = NWParameters.tcp
            if !lan { params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port) }
            let l = lan ? try NWListener(using: params, on: port) : try NWListener(using: params)
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

    /// loopback, 10/8, 172.16/12, 192.168/16, link-local, Tailscale 100.64/10 (and fd7a:115c:a1e0::/48), nothing else
    static func sourceOK(_ c: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = c.endpoint else { return false }
        switch host {
        case .ipv4(let a): return v4OK(Array(a.rawValue))
        case .ipv6(let a):
            let b = Array(a.rawValue)
            if b.count == 16 {
                if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return v4OK(Array(b[12..<16])) }   // ::ffff:a.b.c.d
                if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }                                   // ::1
                if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                                              // fe80::/10
                if (b[0] & 0xfe) == 0xfc { return true }                                                              // fc00::/7 (includes Tailscale fd7a:...)
            }
            return false
        default: return false
        }
    }
    private static func v4OK(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1]))
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
                    if self.lan {
                        guard Http.sourceOK(c) else { c.cancel(); return }
                        let ok: Set<String> = ["GET /status", "GET /shots", "POST /watch", "POST /live", "POST /record", "POST /stop", "POST /next", "POST /again", "POST /shot", "POST /mute"]
                        guard ok.contains("\(m) \(p)") else { Http.send(c, 404, Data("{\"error\":\"not part of the Second Take protocol\"}".utf8)); return }
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
