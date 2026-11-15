import Foundation
import AVFoundation
import AppKit
import SwiftUI

struct Take: Identifiable {
    var id: String { path }
    var shot: Int
    var path: String
    var duration: Double
    var kept: Bool
    var note: String
    // v23: a take recorded on the Sony's card by remote control: path = the Mac's guide track (.guide.m4a)
    var camera: Bool = false
    var camStart: String = ""      // ISO 8601 wall clock of the camera's REC (counter subtracted)
    var camSecs: Double = 0        // the camera's counter at STOP
    var cameraFile: String = ""    // the clip on the card, filled by tools/secondtake-match
    var cameraOffset: Double = 0   // seconds: guide time = camera time + offset (match tool)
    var said: String = ""          // the guide track's words (Voice to Text)
    var heard: Int = 0             // the shot the words sound like (0 = not checked)
}

/// Records the microphone until Marko stops talking (1.5 s of silence after speech, 30 s at most) into a temp WAV.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var started = false
    private var lastLoud = Date()
    private let t0 = Date()
    private var finished = false
    private var done: ((URL?) -> Void)?
    let url: URL

    init() { url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mpa-talk-\(getpid())-\(Int(Date().timeIntervalSince1970)).wav") }

    func start(_ done: @escaping (URL?) -> Void) {
        self.done = done
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, let f = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { done(nil); return }
        file = f
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let s = self, !s.finished else { return }
            try? s.file?.write(from: buf)
            var sum: Float = 0
            let n = Int(buf.frameLength)
            if let ch = buf.floatChannelData?[0], n > 0 { for i in 0..<n { sum += ch[i] * ch[i] }; sum = (sum / Float(n)).squareRoot() }
            let loud = sum > 0.012
            let now = Date()
            if loud { s.started = true; s.lastLoud = now }
            let elapsed = now.timeIntervalSince(s.t0)
            if (s.started && now.timeIntervalSince(s.lastLoud) > 1.5) || elapsed > 30 || (!s.started && elapsed > 8) {
                s.finish()
            }
        }
        do { try engine.start() } catch { done(nil) }
    }

    func finish() {
        if finished { return }
        finished = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let spoke = started
        file = nil
        DispatchQueue.main.async { [done, url] in done?(spoke ? url : nil) }
    }
}

@MainActor
final class Shoot: ObservableObject {
    static let shared = Shoot()
    @Published var open = false
    @Published var index = 0
    @Published var takes: [Take] = []
    @Published var skipped: Set<Int> = []
    @Published var edits: [Int: String] = [:]
    @Published var status = ""
    @Published var recording = false
    @Published var talking = false
    @Published var log: [String] = []
    @Published var finished = false
    @Published var pending: Take?          // a take just recorded, not yet kept
    private var recStart = Date()
    private var mic: MicCapture?
    private var store: Store { Store.shared }

    var shots: [Shot] { store.shots }
    var current: Shot? { shots.indices.contains(index) ? shots[index] : nil }
    var takesPath: String { store.base + ".takes.json" }
    var finishPath: String { store.base + ".finish.md" }

    func say(_ s: String) { status = s }

    // MARK: Beatrice
    /// Beatrice speaks through langsay (Speechify); the tool renders the audio, never this app.
    func speak(_ text: String, wait: Bool = false) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/langsay")
        p.arguments = ["en", text]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard FileManager.default.isExecutableFile(atPath: p.executableURL!.path) else { return }
        if wait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume() }
            }
        } else { try? p.run() }
    }
    func tell(_ text: String) { status = text; Task { await speak(text) } }

    // MARK: state
    /// in camera mode only the camera takes count (the webcam takes of 13-14.11.2026 stay listed, but the shot is still to do)
    func counts(_ t: Take) -> Bool { !Capture.remote || t.camera }
    func isKept(_ n: Int) -> Bool { takes.contains { $0.shot == n && $0.kept && counts($0) } }
    func state(_ n: Int) -> String { isKept(n) ? "kept" : (skipped.contains(n) ? "skipped" : (takes.contains { $0.shot == n && counts($0) } ? "recorded" : "pending")) }
    func sayText(_ s: Shot) -> String { edits[s.n] ?? s.say }

    func begin(shot: Int? = nil) {
        guard !shots.isEmpty else { status = "The analysis has no shots yet."; return }
        loadTakes()
        if let n = shot, let i = shots.firstIndex(where: { $0.n == n }) { index = i }
        else if let i = shots.firstIndex(where: { state($0.n) == "pending" || state($0.n) == "recorded" }) { index = i }
        open = true
        introduce()
    }

    func introduce() {
        guard let s = current else { return }
        tell(s.watch.isEmpty ? "Shot \(s.n): \(s.title), from the lesson plan. Record when you are ready." : "Shot \(s.n): \(s.title). Watch the source, or record?")
    }

    func loadTakes() {
        guard takes.isEmpty, let d = FileManager.default.contents(atPath: takesPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        takes = (o["takes"] as? [[String: Any]] ?? []).map {
            Take(shot: Int(num($0["shot"])), path: $0["path"] as? String ?? "", duration: num($0["duration"]), kept: $0["kept"] as? Bool ?? false, note: $0["note"] as? String ?? "",
                 camera: $0["camera"] as? Bool ?? false, camStart: $0["camStart"] as? String ?? "", camSecs: num($0["camSecs"]),
                 cameraFile: $0["cameraFile"] as? String ?? "", cameraOffset: num($0["cameraOffset"]), said: $0["said"] as? String ?? "", heard: Int(num($0["heard"])))
        }
        takes.removeAll { !$0.path.isEmpty && !FileManager.default.fileExists(atPath: $0.path) }   // moved or deleted files do not linger
        skipped = Set((o["skipped"] as? [Any] ?? []).map { Int(num($0)) })
        ignored = Set((o["ignored"] as? [String] ?? []))
        for (k, v) in (o["edits"] as? [String: String] ?? [:]) { if let n = Int(k) { edits[n] = v } }
    }

    func saveTakes() {
        // the match tool may have written cameraFile/cameraOffset into the file meanwhile: keep them
        if let d = FileManager.default.contents(atPath: takesPath), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for x in o["takes"] as? [[String: Any]] ?? [] {
                guard let p = x["path"] as? String, let f = x["cameraFile"] as? String, !f.isEmpty,
                      let i = takes.firstIndex(where: { $0.path == p && $0.cameraFile.isEmpty }) else { continue }
                takes[i].cameraFile = f; takes[i].cameraOffset = num(x["cameraOffset"])
            }
        }
        let o: [String: Any] = [
            "video": store.videoName,
            "takes": takes.map { t -> [String: Any] in
                var o: [String: Any] = ["shot": t.shot, "path": t.path, "duration": t.duration, "kept": t.kept, "note": t.note]
                if t.camera { o["camera"] = true; o["camStart"] = t.camStart; o["camSecs"] = t.camSecs; o["cameraFile"] = t.cameraFile; o["cameraOffset"] = t.cameraOffset }
                if !t.said.isEmpty { o["said"] = t.said; o["heard"] = t.heard }
                return o
            },
            "capture": Capture.remote ? "remote" : "webcam",
            "skipped": skipped.sorted(),
            "ignored": ignored.sorted(),
            "edits": Dictionary(uniqueKeysWithValues: edits.map { (String($0.key), $0.value) }),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: takesPath)) }
    }

    /// at start: take files of this lesson in ~/Movies that takes.json does not list (a restart in the middle of a take) are listed again as "recovered";
    /// the current shot returns to the shot of the newest take
    func recoverTakes() {
        loadTakes()
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = lessonLabel + " · shot "
        var newest: (Date, Int)? = nil
        var changed = false
        for n in names where n.hasPrefix(prefix) && (n.hasSuffix(".mov") || n.hasSuffix(".guide.m4a")) {
            let path = dir.appendingPathComponent(n).path
            let rest = n.dropFirst(prefix.count)
            guard let shot = Int(rest.prefix { $0.isNumber }) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mod = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            if newest == nil || mod > newest!.0 { newest = (mod, shot) }
            if takes.contains(where: { $0.path == path }) || ignored.contains(path) { continue }
            let dur = CMTimeGetSeconds(AVURLAsset(url: URL(fileURLWithPath: path)).duration)
            var t = Take(shot: shot, path: path, duration: dur.isFinite ? dur : 0, kept: false, note: "recovered")
            if n.hasSuffix(".guide.m4a") { t.camera = true; t.camStart = iso((attrs?[.creationDate] as? Date) ?? mod) }
            takes.append(t)
            changed = true
        }
        if changed { saveTakes(); log.append("recovered takes listed again") }
        if let n = newest?.1, !recording { focus(shot: n) }
    }

    func takesJSON() -> Data {
        loadTakes()
        let n = takes.count
        takes.removeAll { !$0.path.isEmpty && !FileManager.default.fileExists(atPath: $0.path) }
        if takes.count != n { saveTakes() }
        return FileManager.default.contents(atPath: takesPath) ?? jsonData(["takes": [], "skipped": []])
    }

    // MARK: Webcam Recorder API
    func call(_ port: Int, _ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double = 20) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method; r.timeoutInterval = timeout
        if let b = body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: b) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return nil }
        var o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        o["_status"] = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return o
    }

    /// "Lesson 12.11.2026" from the video name (the date in it), else the file stem.
    var lessonLabel: String {
        let stem = (store.videoName as NSString).deletingPathExtension
        if let r = stem.range(of: "[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}", options: .regularExpression) { return "Lesson " + stem[r] }
        return stem
    }
    func takeTitle(_ s: Shot) -> String {
        let base = "\(lessonLabel) · shot \(s.n)" + (s.code.isEmpty ? "" : " · \(s.code)") + " · take "
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        var k = takes.filter { $0.shot == s.n }.count + 1
        // the first free number: no listed take and no file in ~/Movies carries it
        while takes.contains(where: { ["\(base)\(k).mov", "\(base)\(k).guide.m4a"].contains(($0.path as NSString).lastPathComponent) })
                || FileManager.default.fileExists(atPath: movies.appendingPathComponent(base + "\(k).mov").path)
                || FileManager.default.fileExists(atPath: movies.appendingPathComponent(base + "\(k).guide.m4a").path) { k += 1 }
        return base + "\(k)"
    }
    var recSince: Date { recStart }
    @Published var cameraInfo = ""
    @Published var cameraMissing = false
    var currentTakePath = ""

    /// Opens the built-in camera (the Sony first) and waits, bounded, until frames arrive. Returns an error text or nil.
    func prepareCamera() async -> String? {
        if Capture.remote { return await prepareRemote() }
        cameraInfo = "Opening the camera..."
        if let e = await CameraEngine.shared.start() { cameraInfo = e; status = e; cameraMissing = CameraEngine.shared.missing; return e }
        cameraMissing = false
        if let e = await CameraEngine.shared.waitForFrames() { cameraInfo = e; status = e; return e }
        cameraInfo = "\(CameraEngine.shared.cameraName) · sound: \(CameraEngine.shared.micName)"
        return nil
    }

    func focus(shot n: Int) { if let i = shots.firstIndex(where: { $0.n == n }) { index = i } }

    var dryRun = false
    private var dryActive = false
    var guide: GuideTrack?            // v23: the guide track of the running camera take
    var camStartDate: Date?
    var remoteBusy = false            // a camera start/stop is in progress: the poll loop does not adopt or close takes
    var lastConnectTry = Date.distantPast
    var dryNow: Bool { dryActive }
    func setDry(_ on: Bool) { dryActive = on }
    func setRecStart(_ d: Date) { recStart = d }

    func startRecording() async {
        guard let s = current, !recording else { return }
        if Capture.remote { await startRemote(s); return }
        if let err = await prepareCamera() { log.append("camera: " + err); await speak("The camera is not ready."); return }
        if dryRun {
            dryActive = true; recording = true; recStart = Date()
            status = "Dry run of shot \(s.n): everything works, no file is written."
            WatchScreen.shared.showLive(shot: s.n)
            return
        }
        let (url, err) = await CameraEngine.shared.startRecord(title: takeTitle(s))
        guard let u = url else { status = err; log.append("record: " + err); return }
        currentTakePath = u.path
        recording = true; recStart = Date()
        status = "Recording shot \(s.n)."
        WatchScreen.shared.showLive(shot: s.n)
    }

    func stopRecording() async {
        guard recording, let s = current else { return }
        if Capture.remote { await stopRemote(s, click: true); return }
        if dryActive { dryActive = false; recording = false; dryRun = false; status = "Dry run finished: no file, no take."; return }
        let (p, d, err) = await CameraEngine.shared.stopRecord()
        recording = false
        guard let path = p else { status = "The take failed: \(err)"; return }
        let t = Take(shot: s.n, path: path, duration: d, kept: false, note: "")
        takes.append(t); pending = t; saveTakes()
        log.append("take \(s.n): \(path) (\(Int(d)) s)")
        status = "Take saved, \(Int(d.rounded())) seconds: \((path as NSString).lastPathComponent)"
        if open { await speak("Take saved, \(Int(d.rounded())) seconds. Keep it, or again?") }
    }

    // MARK: FINISH: the secondtake-finish tool (trim, export mp4 H.265 + AAC, LESSON_DRAFT.md), run as a subprocess, no second server
    @Published var finishRunning = false
    @Published var finishSummary = ""
    var finishJSON: Any? = nil
    var ignored: Set<String> = []     // deleted takes: the recovery scan leaves them alone

    func finishRun(unkept: Bool = false, dry: Bool = false) {
        guard !finishRunning else { return }
        loadTakes(); saveTakes()
        finishRunning = true; finishSummary = "Finishing the lesson (trim, export)..."
        let tool = NSHomeDirectory() + "/.local/bin/secondtake-finish"
        var args = [tool, "--json", "--takes", takesPath, "--analysis", store.analysisPath,
                    "--out", ((store.exportFolder as NSString).expandingTildeInPath as NSString).appendingPathComponent("MPA Lesson 2")]
        if unkept { args.append("--unkept") }
        if dry { args.append("--dry-run") }
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3"] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.pyenv/shims:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
            p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            var out = Data()
            do { try p.run(); out = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit() } catch {}
            let obj = try? JSONSerialization.jsonObject(with: out)
            await MainActor.run {
                self.finishRunning = false
                self.finishJSON = obj
                guard let o = obj as? [String: Any] else { self.finishSummary = "PROBLEM: the finish tool gave no result (is ~/.local/bin/secondtake-finish there?)"; return }
                let clips = o["clips"] as? [[String: Any]] ?? []
                var t = (o["ok"] as? Bool ?? false) ? "ALL OK" : "PROBLEM"
                t += ": \(clips.count) clips in \(o["out"] as? String ?? "?")"
                for c in clips where ((c["verify"] as? [String: Any])?["ok"] as? Bool) != true && !dry { t += "\nPROBLEM shot \(Int(num(c["shot"]))): not verified" }
                if clips.isEmpty { t += "\nPROBLEM: no kept takes (press KEEP in SHOOT, or use unkept)" }
                self.finishSummary = t
            }
        }
    }

    // MARK: actions
    func toggleRecord() { Task { if recording { await stopRecording() } else { await startRecording() } } }

    func watch() {
        guard let s = current else { return }
        if Capture.remote && SonyRemote.shared.inFront && !recording { Task { await SonyRemote.shared.sendAway(); store.watchShot(s.n) } }
        else { store.watchShot(s.n) }
        // v23: a shot from the lesson plan has no clip in the class: the screen shows its title and text
        status = s.watch.isEmpty ? "Shot \(s.n) is from the lesson plan, there is no clip of it in the class: \(sayText(s))" : "Watching the source clips of shot \(s.n)."
    }

    /// AGAIN = ready for another take of this shot: the last take is marked discarded, the live picture is shown, nothing records until RECORD
    func again(dry: Bool = false) {
        Task {
            if recording { await stopRecording() }
            var gone = ""
            // the last take of this shot stays listed, marked (discarded), so a mistaken AGAIN loses nothing
            if !dry, let s = current, let i = takes.lastIndex(where: { $0.shot == s.n && !$0.note.contains("(discarded)") }) {
                takes[i].note += (takes[i].note.isEmpty ? "" : " ") + "(discarded)"; saveTakes()
                gone = "Take \(takes.filter { $0.shot == s.n }.count) discarded. "
            }
            if !dry { pending = nil }
            if let s = current { status = gone + "Ready for take \(takes.filter { $0.shot == s.n }.count + 1) of shot \(s.n). Press RECORD."; WatchScreen.shared.showLive(shot: s.n) }
        }
    }

    /// removes a take from the list (and, with trash, moves its file to the Trash); the take numbers stay free
    @discardableResult func deleteTake(path: String, trash: Bool) -> Bool {
        guard let i = takes.firstIndex(where: { $0.path == path }) else { return false }
        takes.remove(at: i)
        ignored.insert(path)
        if pending?.path == path { pending = nil }
        if trash, FileManager.default.fileExists(atPath: path) { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        saveTakes()
        return true
    }

    func keep() {
        guard let s = current else { return }
        if let p = pending, let i = takes.firstIndex(where: { $0.path == p.path }) { takes[i].kept = true; saveTakes() }
        else if !takes.contains(where: { $0.shot == s.n && $0.kept }), let i = takes.lastIndex(where: { $0.shot == s.n }) { takes[i].kept = true; saveTakes() }
        pending = nil
        advance()
    }

    func skip() {
        guard let s = current else { return }
        skipped.insert(s.n); pending = nil; saveTakes(); advance()
    }

    func advance() {
        if let i = shots.indices.first(where: { $0 > index && state(shots[$0].n) != "kept" && state(shots[$0].n) != "skipped" })
            ?? shots.indices.first(where: { state(shots[$0].n) != "kept" && state(shots[$0].n) != "skipped" }) {
            index = i; introduce()
        } else {
            finishAll()
        }
    }

    func note(_ text: String) {
        guard let s = current, !text.isEmpty else { return }
        if let i = takes.lastIndex(where: { $0.shot == s.n }) { takes[i].note += (takes[i].note.isEmpty ? "" : " ") + text }
        else { log.append("note for shot \(s.n): \(text)") }
        saveTakes()
    }

    func perform(_ action: String, text: String? = nil, shot: Int? = nil) {
        if let n = shot, let i = shots.firstIndex(where: { $0.n == n }), i != index, action != "edit_shot" { index = i }
        switch action.lowercased() {
        case "watch": watch()
        case "record": if !recording { toggleRecord() }
        case "stop": if recording { toggleRecord() }
        case "again": again()
        case "skip": skip()
        case "next", "keep": keep()
        case "note": note(text ?? "")
        case "edit_shot", "add_say":
            if let n = shot ?? current?.n, let t = text, !t.isEmpty {
                let add = action.lowercased() == "add_say"
                if writeSay(n, t, append: add) { Task { await speak("Shot \(n) text \(add ? "extended" : "replaced").") } }
                else { status = "Could not write the shot text into analysis.json." }
            }
        default: status = "Unknown action \(action)"
        }
    }

    /// The only change the app makes to analysis.json: the "say" text of one shot (everything else is kept as it is).
    func writeSay(_ n: Int, _ text: String, append: Bool) -> Bool {
        let path = store.analysisPath
        guard let d = FileManager.default.contents(atPath: path),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var arr = o["shots"] as? [[String: Any]],
              let i = arr.firstIndex(where: { Int(num($0["n"])) == n }) else { return false }
        let old = arr[i]["say"] as? String ?? ""
        arr[i]["say"] = append ? (old.isEmpty ? text : old + " " + text) : text
        o["shots"] = arr
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try out.write(to: URL(fileURLWithPath: path)) } catch { return false }
        store.pollAnalysis(force: true)
        return true
    }

    // MARK: TALK: his voice, Voice to Text (Groq large-v3), Queen, one JSON line back
    func talk() {
        guard !talking else { mic?.finish(); return }
        Task {
            talking = true; status = "Listening..."
            await speak("I am listening.", wait: true)
            let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            guard granted else { status = "The microphone is not allowed for this app (System Settings, Privacy, Microphone)."; talking = false; return }
            let m = MicCapture(); mic = m
            let url: URL? = await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in m.start { c.resume(returning: $0) } }
            mic = nil
            guard let wav = url else { status = "I heard nothing."; talking = false; return }
            status = "Transcribing..."
            let words = await transcribeWords(wav)
            try? FileManager.default.removeItem(at: wav)
            guard let w = words, !w.isEmpty else { status = "I could not understand."; talking = false; return }
            log.append("Marko: \(w)")
            status = "Asking Queen..."
            await askQueen(w)
            talking = false
        }
    }

    func transcribeWords(_ wav: URL) async -> String? {
        guard let port = store.voiceToTextPort() else { log.append("Voice to Text port not found"); return nil }
        guard let r0 = await call(port, "POST", "/transcribe", ["path": wav.path, "engine": "groq_v3", "language": "en"]),
              let id = (r0["id"] ?? r0["job"] ?? r0["job_id"]).map({ "\($0)" }) else { log.append("Voice to Text did not accept the file"); return nil }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let o = await call(port, "GET", "/job/\(id)") else { continue }
            let st = ((o["status"] ?? o["state"]) as? String ?? "").lowercased()
            if ["error", "failed"].contains(st) { return nil }
            if ["done", "finished", "complete", "completed", "ready", "ok"].contains(st) {
                if let t = o["text"] as? String, !t.isEmpty { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let sg = o["segments"] as? [[String: Any]] { return sg.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            }
        }
        return nil
    }

    func shotState() -> String {
        let arr = shots.map { ["n": $0.n, "title": $0.title, "secs": $0.secs, "state": state($0.n)] as [String: Any] }
        let cur: [String: Any] = ["current": current?.n ?? 0, "recording": recording, "pendingTake": pending.map { ["shot": $0.shot, "seconds": Int($0.duration)] as [String: Any] } ?? NSNull()]
        return String(data: jsonData(["shots": arr, "now": cur]), encoding: .utf8) ?? "{}"
    }

    func askQueen(_ words: String) async {
        let prompt = """
        You are Beatrice, the shooting assistant of MPA Academy Lesson 2. Shot list state as JSON: \(shotState())
        Marko said: "\(words)"
        Answer with ONE JSON line and nothing else: an array of actions in order, e.g. [{"action":"again","shot":3},{"action":"add_say","shot":3,"text":"..."}]. Actions: watch, record, again, skip, next, note, edit_shot (replace the say text), add_say (append to the say text). Fields: action, shot (optional number), text (optional: the note, the say text, or what to tell Marko). A single object is also accepted.
        """
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/chat")!)
        req.httpMethod = "POST"; req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": prompt]]])
        guard let (d, _) = try? await URLSession.shared.data(for: req) else {
            log.append("Queen: not reachable (127.0.0.1:8765)"); tell("I cannot reach Queen."); return
        }
        var text = ""
        for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let t = o["t"] as? String { text += t }
        }
        if let r = text.range(of: "</think>", options: .backwards) { text = String(text[r.upperBound...]) }
        var acts: [[String: Any]] = []
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b, a < (text.firstIndex(of: "{") ?? text.endIndex),
           let arr = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [[String: Any]] {
            acts = arr; log.append("Queen: \(text[a...b])")
        } else if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
                  let o = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] {
            acts = [o]; log.append("Queen: \(text[a...b])")
        }
        if acts.isEmpty {
            log.append("Queen: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"); status = "Queen did not answer with JSON."; return
        }
        for o in acts {
            guard let act = o["action"] as? String else { continue }
            let say = o["text"] as? String
            perform(act, text: say, shot: o["shot"].map { Int(num($0)) })
            if let t = say, !t.isEmpty, !["note", "edit_shot", "add_say"].contains(act.lowercased()) { await speak(t, wait: true) }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: finish
    var exportDir: String { store.exportFolder + "/MPA Lesson 2/" }

    /// a file name without ·, : or /, as in "Lesson 2 - 5 Hand coordination"
    func safeName(_ t: String) -> String {
        t.replacingOccurrences(of: "·", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    func finishPrompt() -> String {
        loadTakes()
        var s = "# FINISH PROMPT: \(lessonLabel)\n\nSource lesson: \(store.videoName)\nExport folder: \(exportDir)\n\n"
        // the kept take of a shot, else its latest take (marked), so the prompt is never empty while takes exist
        let used = shots.compactMap { sh -> (Shot, Take, Bool)? in
            if let t = takes.last(where: { $0.shot == sh.n && $0.kept }) { return (sh, t, true) }
            if let t = takes.last(where: { $0.shot == sh.n && !$0.note.contains("(discarded)") }) { return (sh, t, false) }
            return nil
        }
        if used.isEmpty { s += "No takes yet.\n\n" }
        for (sh, t, kept) in used {
            let name = safeName("Lesson 2 - \(sh.n) \(sh.title)")
            s += "## \(name)\n- Take: \(t.path) (\(Int(t.duration)) s)\(kept ? "" : " (not kept yet)")\n- Lab code: \(sh.code.isEmpty ? "-" : sh.code)\n- Said: \(sayText(sh))\n"
            if !t.note.isEmpty { s += "- Marko's note: \(t.note)\n" }
            s += "- Actions (one approval for 1 and 2 together): 1. Grade: his film-look grade (DaVinci Resolve), then trim the silence. 2. Export \"\(exportDir)/\(name).mp4\": .mp4 container, H.265 (tag hvc1), AAC, vertical 1080x1920. 3. Upload (one approval). 4. Website lesson page: the video, its text, the Lab sequencer link for \(sh.code.isEmpty ? "this exercise (create the Lab item if missing)" : sh.code) (one approval for the single deploy of the page, after all shots).\n\n"
        }
        let sk = shots.filter { skipped.contains($0.n) }
        if !sk.isEmpty { s += "Skipped shots: " + sk.map { "\($0.n) \($0.title)" }.joined(separator: ", ") + "\n\n" }
        s += "Silence rule: ffmpeg silencedetect at -55 dB; keep 0.15 s before the first speech and 0.3 s after the last; at -45 dB cut speech tails. Self-check before reporting: ffprobe shows hvc1 + aac, 1080x1920, the duration matches the trim, the file name has no \"·\" or \":\".\n\n"
        s += "Every change waits for the supervisor's approval in `queen pending`.\n"
        return s
    }

    func finishAll() {
        let p = finishPrompt()
        try? p.write(toFile: finishPath, atomically: true, encoding: .utf8)
        finished = true
        status = "All shots are done. The finish prompt is written: \((finishPath as NSString).lastPathComponent)"
        Task { await speak("All shots are kept or skipped. The finish prompt is ready. Shall I hand it to Queen?") }
    }

    func handToQueen() {
        let p = finishPrompt()
        try? p.write(toFile: finishPath, atomically: true, encoding: .utf8)
        Task {
            status = "Handing the finish prompt to Queen..."
            var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/chat")!)
            req.httpMethod = "POST"; req.timeoutInterval = 300
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": p + "\nPropose the tasks one by one; each waits for approval."]]])
            if (try? await URLSession.shared.data(for: req)) != nil { status = "Queen has the finish prompt; her tasks wait in `queen pending`."; log.append("Queen received the finish prompt") }
            else { status = "Queen is not reachable (127.0.0.1:8765)." }
        }
    }
}

// MARK: v23: the take on the Sony's card, by remote control (sonycam), with the Mac's guide track
extension Shoot {
    func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }

    /// the camera answers in Imaging Edge Remote (connect once, at most every 30 s); the REC mirror starts
    func prepareRemote() async -> String? {
        let r = SonyRemote.shared
        if cameraInfo.isEmpty || cameraMissing { cameraInfo = "Reading the camera (Imaging Edge Remote)..." }
        await r.poll()
        if (r.state == "NONE" || r.state == "?") && Date().timeIntervalSince(lastConnectTry) > 30 {
            lastConnectTry = Date()
            cameraInfo = "Connecting the camera in Imaging Edge Remote..."
            _ = await r.click("connect")
            await r.poll()
        }
        if r.state == "NONE" || r.state == "?" {
            cameraMissing = true
            let e = "CAMERA NOT CONNECTED: Imaging Edge Remote shows no live view."
            cameraInfo = e; status = e
            return e
        }
        cameraMissing = false
        r.startPolling()
        cameraInfo = "Sony α7 V by remote control · \(r.state) · guide sound: Mac microphone"
        return nil
    }

    /// is a camera there at all (cheap, from the last poll; unknown counts as there, RECORD then checks)
    var cameraPresent: Bool { Capture.remote ? SonyRemote.shared.state != "NONE" : CameraEngine.shared.wantedPresent() }

    func startRemote(_ s: Shot) async {
        guard !remoteBusy else { return }
        remoteBusy = true; defer { remoteBusy = false }
        let r = SonyRemote.shared
        if let err = await prepareRemote() { log.append("camera: " + err); await speak("The camera is not connected."); return }
        if dryRun {
            setDry(true); recording = true; setRecStart(Date())
            status = "Dry run of shot \(s.n): the camera is not started, no file is written."
            WatchScreen.shared.showLive(shot: s.n)
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        if !r.inFront { await r.bringFront() }          // v26: the real Remote in front on the MacBook screen while recording
        let title = takeTitle(s)
        let g = GuideTrack()
        if let e = g.start(title: title) { log.append("guide track: " + e) }      // the camera take matters more: go on without it
        if r.state != "REC" { _ = await r.click("start") }
        if r.state != "REC" { await r.poll() }
        guard r.state == "REC" else {
            let (gp, _) = g.stop()
            if let gp { try? FileManager.default.removeItem(atPath: gp) }
            await r.sendAway()
            status = "The camera did not start recording. \(r.lastLine)"
            log.append("record: " + r.lastLine)
            await speak("The camera did not start.")
            return
        }
        guide = g
        camStartDate = Date().addingTimeInterval(-Double(r.counterSeconds))
        currentTakePath = g.url?.path ?? ""
        recording = true; setRecStart(camStartDate ?? Date())
        status = "Recording shot \(s.n) on the camera."
        log.append("REC shot \(s.n) at \(iso(camStartDate ?? Date()))")
    }

    /// click = press STOP through Remote (false: the camera stopped already, by hand or by itself)
    func stopRemote(_ s: Shot, click: Bool) async {
        if dryNow { setDry(false); recording = false; dryRun = false; status = "Dry run finished: no file, no take."; return }
        guard !remoteBusy else { return }
        remoteBusy = true; defer { remoteBusy = false }
        let r = SonyRemote.shared
        let secs = Double(r.counterSeconds)
        if click, r.state == "REC" { _ = await r.click("stop") }
        try? await Task.sleep(nanoseconds: 500_000_000)       // the guide runs half a second past the camera
        let (p, d) = guide?.stop() ?? (nil, 0)
        guide = nil
        recording = false
        var t = Take(shot: s.n, path: p ?? "", duration: d > 0 ? d : secs, kept: false, note: p == nil ? "no guide track" : "")
        t.camera = true; t.camStart = iso(camStartDate ?? Date()); t.camSecs = secs
        takes.append(t); pending = t; saveTakes()
        log.append("take \(s.n) on the camera: \(Int(secs)) s, guide \((p.map { ($0 as NSString).lastPathComponent }) ?? "none")")
        if r.state == "REC" {
            status = "PROBLEM: the camera still shows REC. Press STOP once more."
            await speak("The camera is still recording.")
            return
        }
        status = "Take saved on the camera, \(Int(secs.rounded())) seconds."
        await r.sendAway()                              // v26: Remote to the other screen, Second Take in front for KEEP / AGAIN
        if open { await speak("Take saved, \(Int(secs.rounded())) seconds. Keep it, or again?") }
        if let gp = p { Task { await self.checkWords(gp) } }
    }

    /// the poll loop: STOP or REC pressed on the camera or in Remote is followed here
    func cameraStateChanged(_ st: String) async {
        guard Capture.remote, !remoteBusy, !SonyRemote.shared.busy, !dryNow else { return }
        if recording, st == "STBY", let s = current {
            log.append("the camera stopped (by hand or by itself): the take is closed")
            await stopRemote(s, click: false)
        } else if !recording, st == "REC", open || SonyRemote.shared.inFront, let s = current {
            remoteBusy = true; defer { remoteBusy = false }
            let g = GuideTrack()
            if let e = g.start(title: takeTitle(s)) { log.append("guide track: " + e) }
            guide = g
            camStartDate = Date().addingTimeInterval(-Double(SonyRemote.shared.counterSeconds))
            currentTakePath = g.url?.path ?? ""
            recording = true; setRecStart(camStartDate ?? Date())
            status = "REC was pressed on the camera: recording shot \(s.n)."
            log.append("REC by hand, shot \(s.n)")
        }
    }

    // MARK: the exercise heard in the guide track (Voice to Text, then the words against every shot's title and text)
    func checkWords(_ path: String) async {
        guard let w = await transcribeWords(URL(fileURLWithPath: path)), !w.isEmpty else { log.append("guide words: not transcribed"); return }
        let h = recognize(w)
        guard let i = takes.firstIndex(where: { $0.path == path }) else { return }
        takes[i].said = w; takes[i].heard = h; saveTakes()
        log.append("heard: \(w.prefix(140))")
        let n = takes[i].shot
        if h != 0, h != n, let other = shots.first(where: { $0.n == h }) {
            log.append("this sounds like shot \(h) (\(other.title)), not shot \(n)")
            status += " It sounds like shot \(h), \(other.title)."
        }
    }

    static func words(_ t: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "you", "your", "with", "that", "this", "from", "into", "then", "only", "for", "are", "not", "but", "like", "very", "keep", "just"]
        return Set(t.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 && !stop.contains($0) })
    }

    /// the shot whose title and text share the most words with what was said; 0 when nothing stands out
    func recognize(_ said: String) -> Int {
        let w = Self.words(said)
        guard w.count >= 3 else { return 0 }
        let scored = shots.map { sh -> (Int, Double) in
            let k = Self.words(sh.title + " " + sayText(sh))
            return (sh.n, k.isEmpty ? 0 : Double(k.intersection(w).count) / Double(k.count).squareRoot())
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.6 else { return 0 }
        if scored.count > 1, scored[1].1 > best.1 * 0.85 { return 0 }
        return best.0
    }
}

struct ShootView: View {
    @ObservedObject var sh = Shoot.shared
    @EnvironmentObject var s: Store
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sh.current.map { "SHOT \(sh.index + 1) OF \(sh.shots.count)" + ($0.n != sh.index + 1 ? " · NO. \($0.n)" : "") } ?? "SHOOT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let c = sh.current { Text(sh.state(c.n).uppercased()).font(.system(size: 11)).foregroundStyle(.orange) }
                Spacer()
                Button { sh.open = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).frame(width: 28, height: 28)
            }
            if let c = sh.current {
                Text(c.title).font(.system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if c.secs > 0 { Text("\(Int(c.secs)) sec").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                    if !c.code.isEmpty { Text(c.code).font(.system(size: 12, design: .monospaced)).foregroundStyle(.teal) }
                }
                ScrollView { Text(sh.sayText(c)).font(.system(size: 18)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
                    .frame(maxHeight: 200)
            }
            Divider()
            HStack(spacing: 22) {
                StepButton(n: "1", word: "WATCH", enabled: true) { sh.watch() }
                StepButton(n: "2", word: sh.recording ? "STOP" : "RECORD", enabled: true) { sh.toggleRecord() }
                StepButton(n: "3", word: "AGAIN", enabled: true) { sh.again() }
                StepButton(n: "4", word: "SKIP", enabled: true) { sh.skip() }
                StepButton(n: "5", word: sh.talking ? "LISTENING" : "TALK", enabled: true) { sh.talk() }
                StepButton(n: "6", word: "KEEP", enabled: sh.pending != nil || sh.current.map { c in sh.takes.contains { $0.shot == c.n } } ?? false) { sh.keep() }
            }
            Text(sh.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !sh.log.isEmpty {
                Divider()
                ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(sh.log.suffix(8).enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) } } }
                    .frame(maxHeight: 110)
            }
            if sh.finished {
                Divider()
                HStack(spacing: 22) {
                    StepButton(n: "7", word: "HAND TO QUEEN", enabled: true) { sh.handToQueen() }
                    Text((sh.finishPath as NSString).lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234567")) { p in
            switch p.characters {
            case "1": sh.watch()
            case "2": sh.toggleRecord()
            case "3": sh.again()
            case "4": sh.skip()
            case "5": sh.talk()
            case "6": sh.keep()
            case "7": if sh.finished { sh.handToQueen() }
            default: return .ignored
            }
            return .handled
        }
    }
}
