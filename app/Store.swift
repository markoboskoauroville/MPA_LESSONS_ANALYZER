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
    @Published var playerNote = ""
    @Published var lessonSegs: [Seg]? = nil     // .transcript.json written by someone else with "lessonOnly": true: shown as it is
    private var proxyProc: Process?
    @Published var lessonOnly: Bool = (UserDefaults.standard.object(forKey: "lessonOnly") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(lessonOnly, forKey: "lessonOnly"); rebuild() }
    }
    @Published var pickLang: String = UserDefaults.standard.string(forKey: "transcribeLang") ?? "en" {
        didSet { UserDefaults.standard.set(pickLang, forKey: "transcribeLang") }
    }
    @Published var playingClip: Int? = nil
    @Published var playingAll = false
    @Published var watchingShot: Int? = nil
    private var queue: [Int] = []
    private var qpos = 0
    private var boundary: Any?
    private var queueTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var itemObs: NSKeyValueObservation?
    private var proc: Process?

    let player = AVPlayer()
    /// clips start muted (remembered); the remote and the full-screen window toggle it
    @Published var muted: Bool = (UserDefaults.standard.object(forKey: "clipMuted") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(muted, forKey: "clipMuted"); player.isMuted = muted }
    }
    private var ducked = false
    /// while the Mac voice speaks (MANTRA_VOICE :8837 /speaking phase playing) the clip is silent, so two voices never overlap
    private func pollVoice() {
        guard let u = URL(string: "http://127.0.0.1:8837/speaking") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 0.6
        URLSession.shared.dataTask(with: r) { [weak self] d, _, _ in
            let speaking = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["phase"] as? String) == "playing"
            Task { @MainActor in
                guard let s = self, s.ducked != speaking else { return }
                s.ducked = speaking; s.player.volume = speaking ? 0 : 1
            }
        }.resume()
    }
    private var task: Task<Void, Never>?
    private var t0 = Date()
    private var ticker: Timer?
    private var analysisStamp: Date?
    private var timeObserver: Any?
    private let http = Http()
    private let lan = Http()

    // MARK: playlist: clips are time codes of the original video; nothing is cut or exported
    var clips: [Clip] { analysis.clips }

    private func clearBoundary() { if let b = boundary { player.removeTimeObserver(b); boundary = nil } }

    func playRange(_ a: Double, _ b: Double, clip: Int?) {
        guard videoURL != nil, b > a else { return }
        queueTask?.cancel()
        playingClip = clip
        run(a, b)
    }

    private func run(_ a: Double, _ b: Double) {
        clearBoundary()
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: b, preferredTimescale: 600))], queue: .main) { [weak self] in
            Task { @MainActor in self?.rangeEnded() }
        }
        player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.player.play() }
        }
    }

    private func rangeEnded() {
        player.pause(); clearBoundary()
        if playingAll, qpos + 1 < queue.count {
            qpos += 1
            let next = queue[qpos]
            queueTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self?.playNumber(next)
            }
        } else { playingAll = false; playingClip = nil; watchingShot = nil; queue = [] }
    }

    func playIndex(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        playRange(clips[i].start, clips[i].end, clip: clips[i].n)
    }

    private func playNumber(_ n: Int) {
        guard let i = clips.firstIndex(where: { $0.n == n }) else { return }
        playIndex(i)
    }

    /// One clip, or (all) that clip and the following ones in order.
    func playClip(_ n: Int, all: Bool = false) {
        guard let i = clips.firstIndex(where: { $0.n == n }) else { return }
        watchingShot = nil
        if all { startQueue(clips[i...].map { $0.n }) } else { queue = []; playingAll = false; playIndex(i) }
    }

    func startQueue(_ ns: [Int], shot: Int? = nil) {
        let ok = ns.filter { n in clips.contains { $0.n == n } }
        guard let f = ok.first else { return }
        queue = ok; qpos = 0; playingAll = true; watchingShot = shot
        playNumber(f)
    }

    /// WATCH: the shot's clips of the original video in order, start to end, no file is cut.
    func watchShot(_ n: Int) {
        guard let sh = analysis.shots.first(where: { $0.n == n }) else { return }
        if watchingShot == n { stopPlayback(); return }
        startQueue(sh.watch, shot: n)
        WatchScreen.shared.show(shot: n)
    }

    func playAllClips() { if playingAll { stopPlayback() } else if let f = clips.first { playClip(f.n, all: true) } }
    var shots: [Shot] { analysis.shots }

    func stopPlayback() {
        queueTask?.cancel(); clearBoundary(); player.pause(); playingClip = nil; playingAll = false; watchingShot = nil; queue = []
    }

    func stepClip(_ d: Int) {
        guard !clips.isEmpty else { return }
        let cur = playingClip.flatMap { n in clips.firstIndex(where: { $0.n == n }) }
        let i = cur.map { min(max($0 + d, 0), clips.count - 1) } ?? (d > 0 ? 0 : clips.count - 1)
        playingAll = false; watchingShot = nil; queue = []
        playIndex(i)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); queueTask?.cancel() } else { player.play() }
    }

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.intersection([.command, .control, .option]) != [] { return e }
            if NSApp.keyWindow?.attachedSheet != nil || NSApp.keyWindow?.firstResponder is NSText { return e }
            guard let s = self else { return e }
            switch e.keyCode {
            case 49: Task { @MainActor in s.togglePlay() }
            case 123, 126: Task { @MainActor in s.stepClip(-1) }
            case 124, 125: Task { @MainActor in s.stepClip(1) }
            default: return e
            }
            return nil
        }
    }

    init() {
        installKeys()
        player.isMuted = muted
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollVoice() } }
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
        UserDefaults.standard.set(url.path, forKey: "lastVideo")
        attachVideo(url)
        segs = []; analysis = Analysis(); hasAnalysis = false; analysisStamp = nil; error = ""; lang = ""; strokes = []
        loadTranscripts()
        loadStrokes()
        phase = segs.isEmpty ? "Opened. Next: 2 Transcribe" : "Opened, transcript found (\(segs.count) segments)"
        pollAnalysis(force: true)
        rebuild()
        Shoot.shared.recoverTakes()
        return true
    }

    /// The player is attached to the view only when its item is ready (a portrait H.264 file showed just the QuickTime icon before).
    func attachVideo(_ url: URL) {
        playerReady = false; playerNote = "Checking the video..."
        itemObs?.invalidate(); proxyProc?.terminate()
        Task { [weak self] in
            guard let self = self else { return }
            let playable = await self.canPlay(url)
            if playable { self.playerNote = ""; self.attachItem(url); return }
            if let proxy = await self.makeProxy(url) { self.playerNote = ""; self.attachItem(proxy) }
            else if self.playerNote.isEmpty || self.playerNote.hasPrefix("Preparing") { self.playerNote = "No playable picture: macOS cannot decode this video and the ffmpeg copy failed." }
        }
    }

    /// AVFoundation can play H.264/HEVC + AAC; the class file from the browser is AV1 + Opus (a QuickTime icon, no picture).
    private func canPlay(_ url: URL) async -> Bool {
        let a = AVURLAsset(url: url)
        guard (try? await a.load(.isPlayable)) == true else { return false }
        guard let vt = try? await a.loadTracks(withMediaType: .video), let v = vt.first, (try? await v.load(.isDecodable)) == true else { return false }
        if let at = try? await a.loadTracks(withMediaType: .audio) {
            for t in at where (try? await t.load(.isDecodable)) != true { return false }
        }
        return true
    }

    /// A playback copy (H.264 + AAC, same timeline) in ~/Library/Caches, never next to the lesson file.
    private func makeProxy(_ url: URL) async -> URL? {
        let dir = NSHomeDirectory() + "/Library/Caches/MPA Lessons Analyzer"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(attrs?[.size] as? Int ?? 0)-\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let out = URL(fileURLWithPath: dir + "/" + url.deletingPathExtension().lastPathComponent + "-" + key + ".proxy.mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let ff = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            playerNote = "macOS cannot play this video (AV1/Opus) and ffmpeg is not installed."; return nil
        }
        playerNote = "Preparing a playback copy: this file is AV1 + Opus, which macOS cannot play. Once only."
        let tmp = out.deletingLastPathComponent().appendingPathComponent("part-" + out.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-nostdin", "-y", "-v", "error", "-i", url.path, "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
                       "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-f", "mp4", tmp.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        proxyProc = p
        let code: Int32 = await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
        proxyProc = nil
        guard code == 0, (try? FileManager.default.moveItem(at: tmp, to: out)) != nil else { try? FileManager.default.removeItem(at: tmp); return nil }
        return out
    }

    private func attachItem(_ url: URL) {
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
        lessonSegs = nil
        let lessonData = fm.contents(atPath: transcriptPath)
        let lo = lessonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let isLesson = lo?["lessonOnly"] as? Bool ?? false
        if let d = fm.contents(atPath: fullPath) { loadTranscript(d) }
        else if let d = lessonData {
            loadTranscript(d)
            if !isLesson { try? d.write(to: URL(fileURLWithPath: fullPath)) }
        }
        // a lesson-only file written by someone else (Claude, Queen) is shown as it is; the app's own copy is derived again
        if isLesson, lo?["by"] as? String != "app", let d = lessonData { lessonSegs = parseSegs(d) }
    }

    func loadStrokes() {
        guard let d = FileManager.default.contents(atPath: strokesPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["strokes"] as? [[String: Any]] else { strokes = []; return }
        strokes = arr.map { Stroke(t: num($0["t"]), db: num($0["db"]), cls: $0["cls"] as? String ?? "") }.sorted { $0.t < $1.t }
    }

    /// Writes <video>.transcript.json = the full transcript without the rows that start inside a cut range.
    func writeLessonOnly() {
        if let cur = FileManager.default.contents(atPath: transcriptPath),
           let co = try? JSONSerialization.jsonObject(with: cur) as? [String: Any], co["lessonOnly"] as? Bool == true, co["by"] as? String != "app" { return }
        guard !segs.isEmpty, let d = FileManager.default.contents(atPath: fullPath),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["segments"] as? [[String: Any]] else { return }
        let kept = arr.enumerated().filter { hasAnalysis ? cutWhy(Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: ""), analysis) == nil && !isHallucination($0.element["text"] as? String ?? "") : !isHallucination($0.element["text"] as? String ?? "") }.map { $0.element }
        o["segments"] = kept
        o["lessonOnly"] = hasAnalysis
        o["by"] = "app"
        o["full"] = (fullPath as NSString).lastPathComponent
        if let j = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? j.write(to: URL(fileURLWithPath: transcriptPath))
        }
    }

    func parseSegs(_ d: Data) -> [Seg] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let arr = o["segments"] as? [[String: Any]] else { return [] }
        return arr.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: $0.element["text"] as? String ?? "") }
    }

    func loadTranscript(_ d: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["segments"] as? [[String: Any]] else { return }
        segs = arr.enumerated().map { Seg(id: $0.offset, start: num($0.element["start"]), end: num($0.element["end"]), text: $0.element["text"] as? String ?? "") }
        lang = o["language"] as? String ?? o["lang"] as? String ?? ""
    }

    func rebuild() {
        if lessonOnly, let l = lessonSegs { items = buildItems(l, analysis, strokes, lessonOnly: true, filterRows: false) }
        else { items = buildItems(segs, analysis, strokes, lessonOnly: lessonOnly, filterRows: true) }
    }
    var shownSegs: Int {
        if !lessonOnly { return segs.count }
        if let l = lessonSegs { return l.count }
        return segs.filter { !isHallucination($0.text) && (!hasAnalysis || cutWhy($0, analysis) == nil) }.count
    }

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
        queueTask?.cancel(); clearBoundary(); playingClip = nil; playingAll = false; watchingShot = nil; queue = []
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
        http.handler = { method, path, body, _ in
            await MainActor.run { Store.shared.route(method, path, body, lan: false) }
        }
        http.start(8965)
        lan.lan = true
        lan.bonjour = "_secondtake._tcp"
        lan.handler = { method, path, body, isLan in
            await MainActor.run { Store.shared.route(method, path, body, lan: isLan) }
        }
        lan.onFailed = { [weak self] p in
            Task { @MainActor in self?.error = "PORT \(p) IS TAKEN: the Second Take remote cannot connect. Find it with: lsof -iTCP:\(p) -sTCP:LISTEN, quit that process, restart this app." }
        }
        lan.start(8966, tries: 1)
        if videoURL == nil, let p = UserDefaults.standard.string(forKey: "lastVideo"), FileManager.default.fileExists(atPath: p) { _ = open(URL(fileURLWithPath: p)) }
    }

    func status() -> [String: Any] {
        ["app": "MPA Lessons Analyzer (Mantra)", "version": VERSION, "port": port,
         "video": videoURL?.path ?? "", "busy": busy, "phase": phase, "elapsed": Shoot.shared.recording ? Int(Date().timeIntervalSince(Shoot.shared.recSince)) : Int(elapsed),
         "segments": segs.count, "segmentsShown": shownSegs, "lessonOnly": lessonOnly, "language": pickLang,
         "strokes": strokes.count, "clips": clips.count, "shots": shots.count, "playingClip": playingClip.map { $0 as Any } ?? NSNull(), "voiceFile": voicePath, "drumsFile": drumsPath, "strokesFile": strokesPath,
         "fullTranscriptFile": fullPath, "hasAnalysis": hasAnalysis, "sections": analysis.sections.count,
         "remarks": analysis.remarks.count, "error": error, "lang": lang,
         "transcriptFile": videoURL == nil ? "" : transcriptPath, "analysisFile": videoURL == nil ? "" : analysisPath,
         "exportFolder": exportFolder, "protocol": 1, "name": "MPA Lessons Analyzer (Mantra)", "discarded": Shoot.shared.takes.filter { $0.shot == (Shoot.shared.current?.n ?? 0) && $0.note.contains("(discarded)") }.count, "message": Shoot.shared.status, "controller": Controller.shared.ownerName ?? "", "shot": Shoot.shared.current?.n ?? 0, "takes": Shoot.shared.takes.filter { $0.shot == (Shoot.shared.current?.n ?? 0) }.count, "mode": WatchScreen.shared.mode, "camera": CameraEngine.shared.wantedPresent() ? "ok" : "missing", "muted": muted, "clipVolume": Double(player.volume), "ducked": ducked, "recording": Shoot.shared.recording, "currentShot": Shoot.shared.current?.n ?? 0, "recElapsed": Shoot.shared.recording ? Int(Date().timeIntervalSince(Shoot.shared.recSince)) : 0, "cameraInfo": Shoot.shared.cameraInfo]
    }

    func route(_ method: String, _ path: String, _ body: Data, lan: Bool = false) -> (Int, Data) {
        switch (method, path) {
        case ("GET", "/status") where lan:
            let sh = Shoot.shared
            let n = sh.current?.n ?? 0
            let k = sh.takes.filter { $0.shot == n }.count
            return (200, jsonData(["protocol": 1, "name": "MPA Lessons Analyzer (Mantra)", "mode": WatchScreen.shared.mode, "shot": n, "shots": shots.count,
                                   "takes": k, "take": k + 1, "elapsed": sh.recording ? Int(Date().timeIntervalSince(sh.recSince)) : 0,
                                   "muted": muted, "camera": CameraEngine.shared.wantedPresent() ? "ok" : "missing", "controller": Controller.shared.ownerName ?? "", "discarded": sh.takes.filter { $0.shot == n && $0.note.contains("(discarded)") }.count, "message": sh.status, "recording": sh.recording, "cameraInfo": sh.cameraInfo, "status": sh.status]))
        case ("GET", "/shots") where lan:
            let c = shots.map { ["n": $0.n, "title": $0.title, "code": $0.code, "say": $0.say, "secs": $0.secs] as [String: Any] }
            return (200, (try? JSONSerialization.data(withJSONObject: c)) ?? Data("[]".utf8))
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
        case ("GET", "/clips"):
            let c = clips.map { ["n": $0.n, "title": $0.title, "start": $0.start, "end": $0.end, "code": $0.code, "shoot": $0.shoot] as [String: Any] }
            return (200, jsonData(["clips": c, "playing": playingClip.map { $0 as Any } ?? NSNull(), "playingAll": playingAll]))
        case ("POST", "/play"):
            guard videoURL != nil else { return (409, jsonData(["error": "no video open"])) }
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if o["n"] != nil {
                let n = Int(num(o["n"]))
                guard clips.contains(where: { $0.n == n }) else { return (404, jsonData(["error": "no clip \(n)"])) }
                playClip(n, all: (o["all"] as? Bool) ?? false)
            } else if o["all"] as? Bool == true {
                guard let f = clips.first else { return (404, jsonData(["error": "no clips in the analysis"])) }
                playClip(f.n, all: true)
            } else if o["start"] != nil, o["end"] != nil {
                let a = num(o["start"]), b = num(o["end"])
                guard b > a else { return (400, jsonData(["error": "end must be after start"])) }
                playingAll = false
                playRange(a, b, clip: nil)
            } else { return (400, jsonData(["error": "send {\"n\"}, {\"start\",\"end\"} or {\"all\":true}"])) }
            return (200, jsonData(["playing": true]))
        case ("GET", "/shots"):
            let c = shots.map { ["n": $0.n, "title": $0.title, "watch": $0.watch, "secs": $0.secs, "code": $0.code, "say": $0.say] as [String: Any] }
            return (200, jsonData(["shots": c, "watching": watchingShot.map { $0 as Any } ?? NSNull()]))
        case ("POST", "/watch"):
            guard videoURL != nil else { return (409, jsonData(["error": "no video open"])) }
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let n = o["n"] != nil ? Int(num(o["n"])) : (Shoot.shared.current?.n ?? 0)
            guard shots.contains(where: { $0.n == n }) else { return (404, jsonData(["error": "no shot \(n); GET /shots"])) }
            if Shoot.shared.recording { return (409, jsonData(["error": "recording"])) }
            if watchingShot != n { watchShot(n) }
            return (200, jsonData(["watching": n]))
        case ("POST", "/release"):
            Controller.shared.release()
            return (200, jsonData(["ok": true]))
        case ("POST", "/shot"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let n = Int(num(o["n"]))
            guard o["n"] != nil, shots.contains(where: { $0.n == n }) else { return (400, jsonData(["error": "send {\"n\": <a shot number from GET /shots>}"])) }
            if !Shoot.shared.recording { stopPlayback(); Shoot.shared.focus(shot: n) }
            return (200, jsonData(["ok": true, "shot": Shoot.shared.current?.n ?? 0]))
        case ("POST", "/mute"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            muted = (o["on"] as? Bool) ?? !muted
            return (200, jsonData(["ok": true, "muted": muted]))
        case ("GET", "/camera"):
            return (200, jsonData(CameraEngine.shared.list()))
        case ("POST", "/camera"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if let n = o["name"] as? String { CameraEngine.shared.wantedCamera = n }
            if let m = o["mic"] as? String { CameraEngine.shared.wantedMic = m }
            return (200, jsonData(CameraEngine.shared.list()))
        case ("POST", "/live"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if (o["on"] as? Bool) == false { if !Shoot.shared.recording { WatchScreen.shared.hide() } }
            else { stopPlayback(); WatchScreen.shared.showLive(shot: o["shot"].map { Int(num($0)) }) }
            return (200, jsonData(WatchScreen.shared.info()))
        case ("POST", "/record"), ("POST", "/record/start"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if let n = o["shot"].map({ Int(num($0)) }) { Shoot.shared.focus(shot: n) }
            if !CameraEngine.shared.wantedPresent() { return (409, jsonData(["error": "SONY NOT CONNECTED: switch it on, USB Streaming", "camera": "missing"])) }
            stopPlayback()
            Shoot.shared.dryRun = (o["dryRun"] as? Bool) ?? false
            if !Shoot.shared.recording { Shoot.shared.toggleRecord() }
            return (200, jsonData(["starting": true, "dryRun": Shoot.shared.dryRun, "shot": Shoot.shared.current?.n ?? 0]))
        case ("POST", "/record/stop"):
            if Shoot.shared.recording { Shoot.shared.toggleRecord() }
            return (200, jsonData(["stopping": true]))
        case ("POST", "/next"):
            Shoot.shared.perform("next")
            return (200, jsonData(["current": Shoot.shared.current?.n ?? 0]))
        case ("POST", "/again"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            Shoot.shared.again(dry: (o["dryRun"] as? Bool) ?? false)
            return (200, jsonData(["ok": true, "ready": true, "dryRun": (o["dryRun"] as? Bool) ?? false, "current": Shoot.shared.current?.n ?? 0]))
        case ("POST", "/screen"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            var name = (o["name"] as? String) ?? ""
            if o["index"] != nil { let i = Int(num(o["index"])); name = i == 0 ? "" : (WatchScreen.screenNames.indices.contains(i) ? WatchScreen.screenNames[i] : "") }
            UserDefaults.standard.set(name, forKey: "viewScreen")
            return (200, jsonData(WatchScreen.shared.info()))
        case ("POST", "/finish/run"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if Shoot.shared.finishRunning { return (200, jsonData(["started": false, "running": true])) }
            Shoot.shared.finishRun(unkept: (o["unkept"] as? Bool) ?? false, dry: (o["dryRun"] as? Bool) ?? false)
            return (200, jsonData(["started": true]))
        case ("GET", "/finish/result"):
            let sh = Shoot.shared
            var r: [String: Any] = ["running": sh.finishRunning, "summary": sh.finishSummary]
            if let j = sh.finishJSON { r["result"] = j }
            return (200, jsonData(r))
        case ("POST", "/takes/delete"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard let p = o["path"] as? String else { return (400, jsonData(["error": "send {path, trash?}"])) }
            Shoot.shared.loadTakes()
            let ok = Shoot.shared.deleteTake(path: p, trash: (o["trash"] as? Bool) ?? false)
            return (ok ? 200 : 404, jsonData(["deleted": ok]))
        case ("GET", "/screen"):
            return (200, jsonData(WatchScreen.shared.info()))
        case ("POST", "/stop"):
            if Shoot.shared.recording { Shoot.shared.toggleRecord() }
            else { stopPlayback(); WatchScreen.shared.hide() }
            return (200, jsonData(["playing": false]))
        case ("POST", "/shoot/start"):
            guard videoURL != nil, !shots.isEmpty else { return (409, jsonData(["error": "open the video; the analysis needs shots"])) }
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            Shoot.shared.begin(shot: o["shot"].map { Int(num($0)) })
            return (200, jsonData(["shoot": true, "current": Shoot.shared.current?.n ?? 0]))
        case ("POST", "/shoot/action"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard let a = o["action"] as? String else { return (400, jsonData(["error": "send {\"action\": \"watch|record|stop|again|skip|next|note|edit_shot|add_say\", \"shot\"?, \"text\"?}"])) }
            Shoot.shared.perform(a, text: o["text"] as? String, shot: o["shot"].map { Int(num($0)) })
            return (200, jsonData(["done": a, "current": Shoot.shared.current?.n ?? 0, "status": Shoot.shared.status]))
        case ("POST", "/takes/add"):
            let o = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard o["shot"] != nil, let p = o["path"] as? String, !p.isEmpty else { return (400, jsonData(["error": "send {shot, path, duration?, kept?}"])) }
            let sh = Shoot.shared
            sh.loadTakes()
            let t = Take(shot: Int(num(o["shot"])), path: p, duration: num(o["duration"]), kept: (o["kept"] as? Bool) ?? false, note: (o["note"] as? String) ?? "")
            if !sh.takes.contains(where: { $0.path == p }) { sh.takes.append(t) }
            else if let i = sh.takes.firstIndex(where: { $0.path == p }) { sh.takes[i] = t }
            sh.saveTakes()
            return (200, sh.takesJSON())
        case ("GET", "/takes"):
            return (200, Shoot.shared.takesJSON())
        case ("GET", "/finish"):
            return (200, jsonData(["markdown": Shoot.shared.finishPrompt(), "file": Shoot.shared.finishPath]))
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
            return (404, jsonData(["error": "GET /status, POST /open, POST /split, GET /strokes, GET /clips, POST /play, GET /shots, POST /watch, GET /screen, POST /live, POST /finish/run, GET /finish/result, POST /screen, POST /takes/delete, POST /takes/add, POST /shot, POST /mute, GET /camera, POST /camera, POST /record, POST /record/stop, POST /next, POST /again, POST /shoot/start, POST /shoot/action, GET /takes, GET /finish, POST /stop, POST /transcribe, GET /transcript/full, GET /transcript, GET /analysis, POST /reload"]))
        }
    }
}

func jsonData(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
}
