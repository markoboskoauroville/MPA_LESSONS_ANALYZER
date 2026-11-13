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
        lang = o["lang"] as? String ?? ""
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

    private func runTranscription(_ url: URL) async throws {
        phase = "Extracting audio (ffmpeg)"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MPA Lessons Analyzer (Mantra)")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let wav = caches.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".wav")
        try await Self.ffmpeg(["-y", "-loglevel", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path])
        try Task.checkCancellation()
        phase = "Splitting audio into 300 s chunks"
        let chunkDir = caches.appendingPathComponent("chunks")
        try? FileManager.default.removeItem(at: chunkDir)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        try await Self.ffmpeg(["-y", "-loglevel", "error", "-i", wav.path, "-f", "segment", "-segment_time", "300", "-c", "copy", "-reset_timestamps", "1", chunkDir.appendingPathComponent("c_%04d.wav").path])
        let chunks = try FileManager.default.contentsOfDirectory(atPath: chunkDir.path).filter { $0.hasSuffix(".wav") }.sorted()
        guard !chunks.isEmpty else { throw NSError(domain: "mpa", code: 4, userInfo: [NSLocalizedDescriptionKey: "No audio chunks were made"]) }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1800
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg)
        var allWords: [[String: Any]] = []
        var fallback: [Seg] = []
        var fullText: [String] = []
        var l = ""
        for (i, name) in chunks.enumerated() {
            try Task.checkCancellation()
            phase = "Transcribing chunk \(i + 1) / \(chunks.count) (local Whisper)"
            let off = Double(i) * 300
            var req = URLRequest(url: URL(string: "http://127.0.0.1:8837/hear?lang=auto&words=1")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["path": chunkDir.appendingPathComponent(name).path])
            req.timeoutInterval = 1800
            let (data, _) = try await session.data(for: req)
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "mpa", code: 1, userInfo: [NSLocalizedDescriptionKey: "Whisper answered with something that is not JSON"]) }
            if let e = o["error"] as? String { throw NSError(domain: "mpa", code: 2, userInfo: [NSLocalizedDescriptionKey: "Whisper, chunk \(i + 1): \(e)"]) }
            if l.isEmpty { l = o["lang"] as? String ?? "" }
            let text = o["text"] as? String ?? ""
            if !text.isEmpty { fullText.append(text) }
            if let w = o["words"] as? [[String: Any]], !w.isEmpty {
                for x in w { var y = x; y["t"] = num(x["t"]) + off; y["d"] = num(x["d"]) + off; allWords.append(y) }
            } else if !text.isEmpty {
                fallback.append(Seg(id: 0, start: off, end: off + 300, text: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        var result: [Seg] = allWords.isEmpty ? fallback : segmentWords(allWords)
        if result.isEmpty && !fullText.isEmpty { result = [Seg(id: 0, start: 0, end: 0, text: fullText.joined(separator: " "))] }
        for i in result.indices { result[i].id = i }
        try? FileManager.default.removeItem(at: chunkDir)
        let o: [String: Any] = ["text": fullText.joined(separator: " "), "words": allWords, "lang": l]
        guard !result.isEmpty else { throw NSError(domain: "mpa", code: 3, userInfo: [NSLocalizedDescriptionKey: "No speech found"]) }
        let out: [String: Any] = [
            "video": url.lastPathComponent, "lang": l, "text": o["text"] as? String ?? "",
            "segments": result.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
            "words": o["words"] as? [[String: Any]] ?? []
        ]
        let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: transcriptPath))
        segs = result; lang = l; rebuild()
        phase = "Transcribed: \(result.count) segments in \(fmtTime(Date().timeIntervalSince(t0)))"
    }

    nonisolated private static func ffmpeg(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { pr in
                if pr.terminationStatus == 0 { c.resume() }
                else { c.resume(throwing: NSError(domain: "mpa", code: 10, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed (exit \(pr.terminationStatus))"])) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
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
