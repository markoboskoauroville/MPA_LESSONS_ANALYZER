import Foundation
import AVKit
import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var videoURL: URL?
    @Published var segs: [Seg] = []
    @Published var analysis = Analysis()
    @Published var hasAnalysis = false
    @Published var items: [Item] = []
    @Published var phase = "Open a lesson video"
    @Published var busy = false
    @Published var elapsed = 0.0
    @Published var error = ""
    @Published var now = 0.0
    @Published var port = 0
    @Published var lang = ""

    let player = AVPlayer()
    private var task: Task<Void, Never>?
    private var t0 = Date()
    private var ticker: Timer?
    private var analysisStamp: Date?
    private var timeObserver: Any?
    private let http = Http()

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.now = t.seconds }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAnalysis() }
        }
    }

    // MARK: files
    var base: String { videoURL.map { $0.deletingPathExtension().path } ?? "" }
    var transcriptPath: String { base + ".transcript.json" }
    var analysisPath: String { base + ".analysis.json" }
    var videoName: String { videoURL?.lastPathComponent ?? "" }

    func chooseVideo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audio]
        p.allowsMultipleSelection = false
        p.message = "Choose the lesson video"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { error = "File not found: \(url.path)"; return false }
        task?.cancel(); busy = false; stopTicker()
        videoURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        segs = []; analysis = Analysis(); hasAnalysis = false; analysisStamp = nil; error = ""; lang = ""
        if let d = FileManager.default.contents(atPath: transcriptPath) { loadTranscript(d) }
        phase = segs.isEmpty ? "Opened. Next: 2 Transcribe" : "Opened, transcript found (\(segs.count) segments)"
        pollAnalysis(force: true)
        rebuild()
        return true
    }

    func loadTranscript(_ d: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["segments"] as? [[String: Any]] else { return }
        segs = arr.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: $0.element["text"] as? String ?? "") }
        lang = o["language"] as? String ?? o["lang"] as? String ?? ""
    }

    func rebuild() { items = buildItems(segs, analysis) }

    func pollAnalysis(force: Bool = false) {
        guard videoURL != nil else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: analysisPath)
        let m = attrs?[.modificationDate] as? Date
        if m == nil { if hasAnalysis { hasAnalysis = false; analysis = Analysis(); rebuild() }; analysisStamp = nil; return }
        if !force && m == analysisStamp { return }
        analysisStamp = m
        if let d = FileManager.default.contents(atPath: analysisPath), let a = parseAnalysis(d) {
            analysis = a; hasAnalysis = true; error = ""
            rebuild()
        } else { error = "The analysis file could not be read (not valid JSON)." }
    }

    func analyze() {
        pollAnalysis(force: true)
        phase = hasAnalysis ? "Analysis loaded: \(analysis.sections.count) sections, \(analysis.remarks.count) remarks"
                            : "Waiting for \((analysisPath as NSString).lastPathComponent), written by Claude Code or Queen"
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: transcribe
    func startTicker() {
        t0 = Date(); elapsed = 0
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let s = self else { return }; s.elapsed = Date().timeIntervalSince(s.t0) }
        }
    }
    func stopTicker() { ticker?.invalidate(); ticker = nil }

    func transcribeOrStop() {
        if busy { task?.cancel(); return }
        transcribe()
    }

    func transcribe() {
        guard let url = videoURL, !busy else { return }
        busy = true; error = ""; startTicker()
        task = Task { [weak self] in
            guard let self = self else { return }
            do { try await self.runTranscription(url) }
            catch is CancellationError { self.phase = "Stopped" }
            catch let e as URLError where e.code == .cancelled { self.phase = "Stopped" }
            catch { self.error = "\(error)"; self.phase = "Transcription failed" }
            self.busy = false; self.stopTicker()
        }
    }

    /// Voice to Text (Mantra)'s local API port: the setting, else the registry, else its row in APPS AND SERVERS.md.
    func voiceToTextPort() -> Int? {
        let ud = UserDefaults.standard.integer(forKey: "voiceToTextPort")
        if ud > 0 { return ud }
        let reg = NSHomeDirectory() + "/.config/mantra-ports.json"
        if let d = FileManager.default.contents(atPath: reg),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in o {
                let key = k.lowercased()
                if key.contains("voice") && key.contains("text"), let m = v as? [String: Any], let p = m["port"] as? Int { return p }
            }
        }
        let md = NSHomeDirectory() + "/Downloads/API/APPS AND SERVERS.md"
        if let t = try? String(contentsOfFile: md, encoding: .utf8) {
            for line in t.components(separatedBy: "\n") where line.contains("Voice to Text") && line.contains("127.0.0.1:") {
                if let r = line.range(of: "127\\.0\\.0\\.1:[0-9]+", options: .regularExpression) {
                    return Int(line[r].dropFirst(10))
                }
            }
        }
        return nil
    }

    private func runTranscription(_ url: URL) async throws {
        guard let port = voiceToTextPort() else {
            throw NSError(domain: "mpa", code: 5, userInfo: [NSLocalizedDescriptionKey: "Voice to Text (Mantra) API port not found. Set it in Settings."])
        }
        let base = "http://127.0.0.1:\(port)"
        phase = "Sending the video to Voice to Text (Mantra)"
        var req = URLRequest(url: URL(string: base + "/transcribe")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": url.path])
        req.timeoutInterval = 60
        let (d0, _) = try await URLSession.shared.data(for: req)
        guard let o0 = try JSONSerialization.jsonObject(with: d0) as? [String: Any] else {
            throw NSError(domain: "mpa", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voice to Text did not answer with JSON"])
        }
        if let e = o0["error"] as? String { throw NSError(domain: "mpa", code: 2, userInfo: [NSLocalizedDescriptionKey: "Voice to Text: \(e)"]) }
        guard let id = (o0["id"] ?? o0["job"] ?? o0["job_id"]).map({ "\($0)" }) else {
            throw NSError(domain: "mpa", code: 6, userInfo: [NSLocalizedDescriptionKey: "Voice to Text gave no job id"])
        }
        var fails = 0
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var jr = URLRequest(url: URL(string: base + "/job/\(id)")!)
            jr.timeoutInterval = 30
            guard let (d, _) = try? await URLSession.shared.data(for: jr),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                fails += 1
                if fails > 30 { throw NSError(domain: "mpa", code: 7, userInfo: [NSLocalizedDescriptionKey: "Voice to Text stopped answering"]) }
                continue
            }
            fails = 0
            let status = ((o["status"] ?? o["state"]) as? String ?? "").lowercased()
            var prog = ""
            if let p = o["progress"] as? Double { prog = p <= 1 ? " \(Int(p * 100)) %" : " \(Int(p)) %" }
            else if let p = o["progress"] as? String { prog = " " + p }
            phase = "Voice to Text: \(status.isEmpty ? "working" : status)\(prog)"
            if ["error", "failed", "failure"].contains(status) {
                throw NSError(domain: "mpa", code: 8, userInfo: [NSLocalizedDescriptionKey: "Voice to Text: \(o["error"] as? String ?? o["message"] as? String ?? "failed")"])
            }
            let finished = ["done", "finished", "complete", "completed", "ready", "ok"].contains(status)
            if finished {
                if let f = FileManager.default.contents(atPath: transcriptPath) { loadTranscript(f) }
                if segs.isEmpty, let sg = o["segments"] as? [[String: Any]] {
                    segs = sg.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: ($0.element["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)) }
                    let out: [String: Any] = ["source": url.lastPathComponent, "engine": o["engine"] as? String ?? "", "language": o["language"] as? String ?? "",
                        "segments": segs.map { ["start": $0.start, "end": $0.end, "text": $0.text] }]
                    if let j = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                        try? j.write(to: URL(fileURLWithPath: transcriptPath))
                    }
                }
                guard !segs.isEmpty else { throw NSError(domain: "mpa", code: 3, userInfo: [NSLocalizedDescriptionKey: "Voice to Text finished but gave no segments"]) }
                rebuild()
                phase = "Transcribed: \(segs.count) segments in \(fmtTime(Date().timeIntervalSince(t0)))"
                return
            }
        }
    }

    // MARK: settings
    var exportFolder: String {
        UserDefaults.standard.string(forKey: "exportFolder") ?? (NSHomeDirectory() + "/Desktop")
    }

    // MARK: API
    func startServer() {
        guard port == 0 else { return }
        http.onReady = { [weak self] p in
            Task { @MainActor in
                self?.port = Int(p)
                try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.mantra/ports", withIntermediateDirectories: true)
                try? "\(p)\n".write(toFile: NSHomeDirectory() + "/.mantra/ports/mpa-lessons-analyzer", atomically: true, encoding: .utf8)
            }
        }
        http.handler = { method, path, body in
            await MainActor.run { Store.shared.route(method, path, body) }
        }
        http.start(8965)
    }

    func status() -> [String: Any] {
        ["app": "MPA Lessons Analyzer (Mantra)", "version": VERSION, "port": port,
         "video": videoURL?.path ?? "", "busy": busy, "phase": phase, "elapsed": Int(elapsed),
         "segments": segs.count, "hasAnalysis": hasAnalysis, "sections": analysis.sections.count,
         "remarks": analysis.remarks.count, "error": error, "lang": lang,
         "transcriptFile": videoURL == nil ? "" : transcriptPath, "analysisFile": videoURL == nil ? "" : analysisPath,
         "exportFolder": exportFolder]
    }

    func route(_ method: String, _ path: String, _ body: Data) -> (Int, Data) {
        switch (method, path) {
        case ("GET", "/status"), ("GET", "/"):
            return (200, jsonData(status()))
        case ("POST", "/open"):
            guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let p = o["path"] as? String
            else { return (400, jsonData(["error": "send {\"path\": \"...\"}"])) }
            let ok = open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            return (ok ? 200 : 404, jsonData(status()))
        case ("POST", "/transcribe"):
            guard videoURL != nil else { return (409, jsonData(["error": "no video open"])) }
            if busy { return (409, jsonData(["error": "already transcribing"])) }
            transcribe()
            return (202, jsonData(["started": true]))
        case ("GET", "/transcript"):
            if let d = FileManager.default.contents(atPath: transcriptPath) { return (200, d) }
            return (404, jsonData(["error": "no transcript yet"]))
        case ("GET", "/analysis"):
            if let d = FileManager.default.contents(atPath: analysisPath) { return (200, d) }
            return (404, jsonData(["error": "no analysis file yet"]))
        case ("POST", "/reload"):
            pollAnalysis(force: true)
            if let d = FileManager.default.contents(atPath: transcriptPath), segs.isEmpty { loadTranscript(d); rebuild() }
            return (200, jsonData(status()))
        default:
            return (404, jsonData(["error": "GET /status, POST /open, POST /transcribe, GET /transcript, GET /analysis, POST /reload"]))
        }
    }
}

func jsonData(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
}
