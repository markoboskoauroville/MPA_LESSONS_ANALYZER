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
    @Published var strokes: [Stroke] = []
    @Published var playerReady = false
    @Published var lessonOnly: Bool = (UserDefaults.standard.object(forKey: "lessonOnly") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(lessonOnly, forKey: "lessonOnly"); rebuild() }
    }
    @Published var pickLang: String = UserDefaults.standard.string(forKey: "transcribeLang") ?? "en" {
        didSet { UserDefaults.standard.set(pickLang, forKey: "transcribeLang") }
    }
    private var itemObs: NSKeyValueObservation?
    private var proc: Process?

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
    var transcriptPath: String { base + ".transcript.json" }       // lesson only (cut ranges applied)
    var fullPath: String { base + ".transcript.full.json" }        // everything that was said
    var voicePath: String { base + ".voice.wav" }
    var drumsPath: String { base + ".drums.wav" }
    var strokesPath: String { base + ".strokes.json" }
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
        attachVideo(url)
        segs = []; analysis = Analysis(); hasAnalysis = false; analysisStamp = nil; error = ""; lang = ""; strokes = []
        loadTranscripts()
        loadStrokes()
        phase = segs.isEmpty ? "Opened. Next: 2 Transcribe" : "Opened, transcript found (\(segs.count) segments)"
        pollAnalysis(force: true)
        rebuild()
        return true
    }

    /// The player is attached to the view only when its item is ready (a portrait H.264 file showed just the QuickTime icon before).
    func attachVideo(_ url: URL) {
        playerReady = false
        itemObs?.invalidate()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        itemObs = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let s = self else { return }
                if it.status == .readyToPlay { s.playerReady = true }
                else if it.status == .failed { s.error = "The video cannot be played: \(it.error?.localizedDescription ?? "unknown error")" }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    /// The full transcript is the source of truth; .transcript.json is derived from it with the analysis' cut ranges.
    func loadTranscripts() {
        let fm = FileManager.default
        if let d = fm.contents(atPath: fullPath) { loadTranscript(d) }
        else if let d = fm.contents(atPath: transcriptPath) {
            loadTranscript(d)
            let flag = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["lessonOnly"] as? Bool ?? false
            if !flag { try? d.write(to: URL(fileURLWithPath: fullPath)) }
        }
    }

    func loadStrokes() {
        guard let d = FileManager.default.contents(atPath: strokesPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["strokes"] as? [[String: Any]] else { strokes = []; return }
        strokes = arr.map { Stroke(t: num($0["t"]), db: num($0["db"]), cls: $0["cls"] as? String ?? "") }.sorted { $0.t < $1.t }
    }

    /// Writes <video>.transcript.json = the full transcript without the rows that start inside a cut range.
    func writeLessonOnly() {
        guard !segs.isEmpty, let d = FileManager.default.contents(atPath: fullPath),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["segments"] as? [[String: Any]] else { return }
        let kept = arr.enumerated().filter { hasAnalysis ? cutWhy(Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: ""), analysis) == nil : true }.map { $0.element }
        o["segments"] = kept
        o["lessonOnly"] = hasAnalysis
        o["full"] = (fullPath as NSString).lastPathComponent
        if let j = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? j.write(to: URL(fileURLWithPath: transcriptPath))
        }
    }

    func loadTranscript(_ d: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["segments"] as? [[String: Any]] else { return }
        segs = arr.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: $0.element["text"] as? String ?? "") }
        lang = o["language"] as? String ?? o["lang"] as? String ?? ""
    }

    func rebuild() { items = buildItems(segs, analysis, strokes, lessonOnly: lessonOnly) }
    var shownSegs: Int { lessonOnly && hasAnalysis ? segs.filter { cutWhy($0, analysis) == nil }.count : segs.count }

    func pollAnalysis(force: Bool = false) {
        guard videoURL != nil else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: analysisPath)
        let m = attrs?[.modificationDate] as? Date
        if m == nil { if hasAnalysis { hasAnalysis = false; analysis = Analysis(); rebuild() }; analysisStamp = nil; return }
        if !force && m == analysisStamp { return }
        analysisStamp = m
        if let d = FileManager.default.contents(atPath: analysisPath), let a = parseAnalysis(d) {
            analysis = a; hasAnalysis = true; error = ""
            writeLessonOnly()
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

    func drumsplitURL() -> URL? {
        var c: [String] = []
        if let e = Bundle.main.executableURL { c.append(e.deletingLastPathComponent().appendingPathComponent("drumsplit").path) }
        c += [NSHomeDirectory() + "/.local/bin/drumsplit", "/usr/local/bin/drumsplit", "/opt/homebrew/bin/drumsplit"]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func splitOrStop() {
        if busy { task?.cancel(); proc?.terminate(); return }
        split()
    }

    func split() {
        guard let url = videoURL, !busy else { return }
        busy = true; error = ""; startTicker()
        task = Task { [weak self] in
            guard let self = self else { return }
            do { try await self.runSplit(url) }
            catch is CancellationError { self.phase = "Stopped" }
            catch { self.error = "\(error)"; self.phase = "Split failed" }
            self.busy = false; self.stopTicker()
        }
    }

    /// Runs the drumsplit tool (Supertone Clear, offline): <name>.voice.wav, <name>.drums.wav, <name>.strokes.json next to the video.
    private func runSplit(_ url: URL) async throws {
        guard let tool = drumsplitURL() else {
            throw NSError(domain: "mpa", code: 20, userInfo: [NSLocalizedDescriptionKey: "drumsplit was not found inside the app (Contents/MacOS/drumsplit) or in ~/.local/bin."])
        }
        phase = "Splitting voice and drums (Clear)"
        let p = Process()
        p.executableURL = tool
        p.arguments = [url.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        var tail = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
            let lines = t.split(whereSeparator: \.isNewline).map(String.init)
            guard let last = lines.last else { return }
            tail = (tail + "\n" + t).suffix(600).description
            Task { @MainActor in self?.phase = "Split: " + last }
        }
        proc = p
        let code: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        proc = nil
        try Task.checkCancellation()
        if code != 0 {
            throw NSError(domain: "mpa", code: 21, userInfo: [NSLocalizedDescriptionKey: "drumsplit failed (\(code)): \(tail.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        loadStrokes(); rebuild()
        phase = "Split done: \(strokes.count) strokes in \(fmtTime(Date().timeIntervalSince(t0)))"
    }

    func transcribe() {
        guard let url = videoURL, !busy else { return }
        busy = true; error = ""; startTicker()
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                if !FileManager.default.fileExists(atPath: self.voicePath) { try await self.runSplit(url) }
                try await self.runTranscription(url)
            }
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
        phase = "Sending the voice track to Voice to Text (Mantra), Groq large-v3"
        var req = URLRequest(url: URL(string: base + "/transcribe")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": voicePath, "engine": "groq_v3", "language": pickLang])
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
                importVoiceTranscript(url)
                if segs.isEmpty, let sg = o["segments"] as? [[String: Any]] {
                    segs = sg.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: ($0.element["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)) }
                    let out: [String: Any] = ["source": url.lastPathComponent, "engine": o["engine"] as? String ?? "", "language": o["language"] as? String ?? "",
                        "segments": segs.map { ["start": $0.start, "end": $0.end, "text": $0.text] }]
                    if let j = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                        try? j.write(to: URL(fileURLWithPath: fullPath))
                    }
                    writeLessonOnly()
                }
                guard !segs.isEmpty else { throw NSError(domain: "mpa", code: 3, userInfo: [NSLocalizedDescriptionKey: "Voice to Text finished but gave no segments"]) }
                rebuild()
                phase = "Transcribed: \(segs.count) segments in \(fmtTime(Date().timeIntervalSince(t0)))"
                return
            }
        }
    }

    /// Voice to Text names its result after the voice file (<name>.voice.transcript.json): keep it as <video>.transcript.full.json,
    /// then derive <video>.transcript.json (lesson only) from it.
    func importVoiceTranscript(_ url: URL) {
        let vt = base + ".voice.transcript.json"
        guard let d = FileManager.default.contents(atPath: vt),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        o["source"] = url.lastPathComponent
        o["voice"] = (voicePath as NSString).lastPathComponent
        o["lessonOnly"] = false
        if let j = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? j.write(to: URL(fileURLWithPath: fullPath))
        }
        loadTranscript(FileManager.default.contents(atPath: fullPath) ?? d)
        writeLessonOnly()
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
         "segments": segs.count, "segmentsShown": shownSegs, "lessonOnly": lessonOnly, "language": pickLang,
         "strokes": strokes.count, "voiceFile": voicePath, "drumsFile": drumsPath, "strokesFile": strokesPath,
         "fullTranscriptFile": fullPath, "hasAnalysis": hasAnalysis, "sections": analysis.sections.count,
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
        case ("POST", "/split"):
            if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let p = o["path"] as? String {
                _ = open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            }
            guard videoURL != nil else { return (409, jsonData(["error": "no video open; send {\"path\": \"...\"} or POST /open first"])) }
            if busy { return (409, jsonData(["error": "busy"])) }
            split()
            return (202, jsonData(["started": true, "outputs": [voicePath, drumsPath, strokesPath]]))
        case ("GET", "/strokes"):
            if let d = FileManager.default.contents(atPath: strokesPath) { return (200, d) }
            return (404, jsonData(["error": "no strokes yet; POST /split"]))
        case ("GET", "/transcript/full"):
            if let d = FileManager.default.contents(atPath: fullPath) { return (200, d) }
            return (404, jsonData(["error": "no full transcript yet"]))
        case ("GET", "/transcript"):
            if let d = FileManager.default.contents(atPath: transcriptPath) { return (200, d) }
            return (404, jsonData(["error": "no transcript yet"]))
        case ("GET", "/analysis"):
            if let d = FileManager.default.contents(atPath: analysisPath) { return (200, d) }
            return (404, jsonData(["error": "no analysis file yet"]))
        case ("POST", "/reload"):
            pollAnalysis(force: true)
            if segs.isEmpty { loadTranscripts() }
            loadStrokes(); rebuild()
            return (200, jsonData(status()))
        default:
            return (404, jsonData(["error": "GET /status, POST /open, POST /split, GET /strokes, POST /transcribe, GET /transcript/full, GET /transcript, GET /analysis, POST /reload"]))
        }
    }
}

func jsonData(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
}
