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
    func isKept(_ n: Int) -> Bool { takes.contains { $0.shot == n && $0.kept } }
    func state(_ n: Int) -> String { isKept(n) ? "kept" : (skipped.contains(n) ? "skipped" : (takes.contains { $0.shot == n } ? "recorded" : "pending")) }
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
        tell("Shot \(s.n): \(s.title). Watch the source, or record?")
    }

    func loadTakes() {
        guard takes.isEmpty, let d = FileManager.default.contents(atPath: takesPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        takes = (o["takes"] as? [[String: Any]] ?? []).map {
            Take(shot: Int(num($0["shot"])), path: $0["path"] as? String ?? "", duration: num($0["duration"]), kept: $0["kept"] as? Bool ?? false, note: $0["note"] as? String ?? "")
        }
        skipped = Set((o["skipped"] as? [Any] ?? []).map { Int(num($0)) })
        for (k, v) in (o["edits"] as? [String: String] ?? [:]) { if let n = Int(k) { edits[n] = v } }
    }

    func saveTakes() {
        let o: [String: Any] = [
            "video": store.videoName,
            "takes": takes.map { ["shot": $0.shot, "path": $0.path, "duration": $0.duration, "kept": $0.kept, "note": $0.note] as [String: Any] },
            "skipped": skipped.sorted(),
            "edits": Dictionary(uniqueKeysWithValues: edits.map { (String($0.key), $0.value) }),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: takesPath)) }
    }

    func takesJSON() -> Data {
        loadTakes()
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
        let k = takes.filter { $0.shot == s.n }.count + 1
        return "\(lessonLabel) · shot \(s.n)" + (s.code.isEmpty ? "" : " · \(s.code)") + " · take \(k)"
    }
    var recSince: Date { recStart }
    @Published var cameraInfo = ""
    var currentTakePath = ""

    /// Opens the built-in camera (the Sony first) and waits, bounded, until frames arrive. Returns an error text or nil.
    func prepareCamera() async -> String? {
        cameraInfo = "Opening the camera..."
        if let e = await CameraEngine.shared.start() { cameraInfo = e; status = e; return e }
        if let e = await CameraEngine.shared.waitForFrames() { cameraInfo = e; status = e; return e }
        cameraInfo = "\(CameraEngine.shared.cameraName) · sound: \(CameraEngine.shared.micName)"
        return nil
    }

    func focus(shot n: Int) { if let i = shots.firstIndex(where: { $0.n == n }) { index = i } }

    func startRecording() async {
        guard let s = current, !recording else { return }
        if let err = await prepareCamera() { log.append("camera: " + err); await speak("The camera is not ready."); return }
        let (url, err) = await CameraEngine.shared.startRecord(title: takeTitle(s))
        guard let u = url else { status = err; log.append("record: " + err); return }
        currentTakePath = u.path
        recording = true; recStart = Date()
        status = "Recording shot \(s.n)."
        WatchScreen.shared.showLive(shot: s.n)
    }

    func stopRecording() async {
        guard recording, let s = current else { return }
        let (p, d, err) = await CameraEngine.shared.stopRecord()
        recording = false
        guard let path = p else { status = "The take failed: \(err)"; return }
        let t = Take(shot: s.n, path: path, duration: d, kept: false, note: "")
        takes.append(t); pending = t; saveTakes()
        log.append("take \(s.n): \(path) (\(Int(d)) s)")
        status = "Take saved, \(Int(d.rounded())) seconds: \((path as NSString).lastPathComponent)"
        if open { await speak("Take saved, \(Int(d.rounded())) seconds. Keep it, or again?") }
    }

    // MARK: actions
    func toggleRecord() { Task { if recording { await stopRecording() } else { await startRecording() } } }

    func watch() { if let s = current { store.watchShot(s.n); status = "Watching the source clips of shot \(s.n)." } }

    func again() {
        Task {
            if recording { await stopRecording() }
            if let p = pending, let i = takes.firstIndex(where: { $0.path == p.path }) { takes[i].note += (takes[i].note.isEmpty ? "" : " ") + "(discarded)"; saveTakes() }
            pending = nil
            await startRecording()
        }
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

    func finishPrompt() -> String {
        loadTakes()
        var s = "# FINISH PROMPT: MPA Lesson 2\n\nSource lesson: \(store.videoName)\nExport folder: \(exportDir)\n\n"
        let kept = shots.compactMap { sh in takes.last(where: { $0.shot == sh.n && $0.kept }).map { (sh, $0) } }
        for (sh, t) in kept {
            s += "## Lesson 2 · \(sh.n) \(sh.title)\n- Take: \(t.path) (\(Int(t.duration)) s)\n- Lab code: \(sh.code.isEmpty ? "-" : sh.code)\n- Said: \(sayText(sh))\n"
            if !t.note.isEmpty { s += "- Marko's note: \(t.note)\n" }
            s += "- Actions: 1. DaVinci Resolve: import the take, apply his film-look grade, trim the start and end silence. 2. Export H.265 vertical (9:16) to \(exportDir) as \"Lesson 2 · \(sh.n) \(sh.title)\". 3. Upload the export. 4. Update the website lesson: the video, its text, and the Lab sequencer link for \(sh.code.isEmpty ? "this exercise (create the Lab item if missing)" : sh.code).\n\n"
        }
        let sk = shots.filter { skipped.contains($0.n) }
        if !sk.isEmpty { s += "Skipped shots: " + sk.map { "\($0.n) \($0.title)" }.joined(separator: ", ") + "\n\n" }
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

struct ShootView: View {
    @ObservedObject var sh = Shoot.shared
    @EnvironmentObject var s: Store
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sh.current.map { "SHOT \($0.n) OF \(sh.shots.count)" } ?? "SHOOT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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
