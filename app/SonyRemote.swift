// v23 (15.11.2026, Marko: "we are not recording with web camera, we are recording by remote control. That's the only change"):
// the take is recorded on the Sony α7 V body. RECORD/STOP drive the existing hand `sonycam start|stop` (MACRO_SKILLS tools/sonycam,
// Imaging Edge Remote over USB); its REC/STBY and time counter (AX text of Remote's live window, `sonycam status`) are mirrored here;
// v26 (Marko: "Simply put in front the original program while we are recording and then put it on the second when we don't need it.
// Use Rectangle"): no copy of Remote's window any more; `sonycam front` brings the real Remote to the front on the MacBook screen,
// almost-maximized (never full screen), `sonycam away` sends it to the other screen. The Mac's microphone writes a small AAC guide track per take
// (~/Movies/<take>.guide.m4a) for the transcription, the exercise check and the match with the camera clip afterwards
// (tools/secondtake-match: start times, then audio cross-correlation).
import Foundation
import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

enum Capture {
    /// "remote" (default since v23): the Sony records on its card by remote control; "webcam": the built-in capture of v8-v22
    static var remote: Bool { (UserDefaults.standard.string(forKey: "capture") ?? "remote") != "webcam" }
    static func set(remote: Bool) { UserDefaults.standard.set(remote ? "remote" : "webcam", forKey: "capture") }
    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var permissionsMissing: Bool { remote ? !micAllowed : CameraEngine.permissionsMissing }
    static func openPermissions() {
        guard remote else { CameraEngine.openPermissions(); return }
        let pane = "Privacy_Microphone"
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// The small guide track of a take: the Mac's default microphone, AAC mono 48 kHz 64 kb/s (the tiny-archive rule: speech only).
final class GuideTrack {
    private var rec: AVAudioRecorder?
    private(set) var url: URL?
    private(set) var started: Date?

    func start(title: String) -> String? {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let u = dir.appendingPathComponent(String(safe.prefix(120)) + ".guide.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        do {
            let r = try AVAudioRecorder(url: u, settings: settings)
            guard r.record() else { return "the guide track did not start (microphone)" }
            rec = r; url = u; started = Date()
            return nil
        } catch { return "the guide track cannot be written: \(error.localizedDescription)" }
    }

    /// stops and returns (path, seconds)
    func stop() -> (String?, Double) {
        guard let r = rec, let u = url else { return (nil, 0) }
        let d = r.currentTime
        r.stop(); rec = nil
        let real = CMTimeGetSeconds(AVURLAsset(url: u).duration)
        return (u.path, real.isFinite && real > 0 ? real : d)
    }
    var running: Bool { rec?.isRecording ?? false }
}

@MainActor
final class SonyRemote: NSObject, ObservableObject {
    static let shared = SonyRemote()
    /// "?" not read yet, "NONE" no live view in Remote, "STBY", "REC"
    @Published var state = "?"
    @Published var counter = "00:00:00"
    @Published var lastLine = ""
    @Published var inFront = false          // Remote was brought to the front for a take (sonycam front)
    private var pollTask: Task<Void, Never>?
    private(set) var busy = false           // a sonycam click is running: polling waits


    var counterSeconds: Int {
        let p = counter.split(separator: ":").compactMap { Int($0) }
        return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
    }

    // MARK: the hand: sonycam (bounded, never two at once)
    nonisolated static func run(_ arg: String, timeout: Double = 40) async -> (Int32, String) {
        await withCheckedContinuation { (c: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/sonycam")
                p.arguments = [arg]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                p.environment = env
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                guard FileManager.default.isExecutableFile(atPath: p.executableURL!.path) else { c.resume(returning: (127, "sonycam is not installed (~/.local/bin/sonycam)")); return }
                do { try p.run() } catch { c.resume(returning: (126, "sonycam: \(error.localizedDescription)")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                c.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
        }
    }

    /// "camera: connected, REC, time code 00:00:07" / "camera: not connected ..." -> state, counter
    func parse(_ out: String) {
        let line = out.split(separator: "\n").first { $0.hasPrefix("camera:") }.map(String.init) ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
        lastLine = line
        if line.contains("not connected") || line.hasPrefix("ERROR") { state = "NONE"; return }
        if line.contains(" REC") { state = "REC" } else if line.contains("STBY") { state = "STBY" }
        if let r = line.range(of: "[0-9]{2}:[0-9]{2}:[0-9]{2}", options: .regularExpression) { counter = String(line[r]) }
    }

    func poll() async {
        guard !busy else { return }
        let (_, out) = await Self.run("status", timeout: 15)
        if !busy { parse(out) }
    }

    /// a click through sonycam (it fronts Remote itself and clicks the record button found by Accessibility)
    func click(_ arg: String) async -> (Int32, String) {
        busy = true
        let r = await Self.run(arg)
        busy = false
        parse(r.1)
        return r
    }

    /// the real Remote in front on the MacBook screen, almost-maximized by Rectangle; Second Take's own windows step back
    func bringFront() async {
        WatchScreen.shared.hide(keepPolling: true)
        busy = true
        let (code, out) = await Self.run("front")
        busy = false
        inFront = code == 0
        lastLine = out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// v27: Remote maximized on the BenQ (Rectangle, not macOS full screen) for recording; it stays there after the take
    func bringBig() async {
        WatchScreen.shared.hide(keepPolling: true)
        busy = true
        let (code, out) = await Self.run("big")
        busy = false
        inFront = code == 0
        lastLine = out.trimmingCharacters(in: .whitespacesAndNewlines)
        RecOverlay.shared.show()
    }

    /// Remote to the other screen, Second Take back in front (its main window, never full screen)
    func sendAway() async {
        guard inFront else { return }
        busy = true
        _ = await Self.run("away")
        busy = false
        inFront = false
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.isVisible && !(w is WatchWindow) { w.makeKeyAndOrderFront(nil) }
    }

    /// polling every second while the full-screen view is up (mirrors REC and the counter; a REC or STOP pressed on the camera
    /// or in Remote is followed by Second Take)
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let sh = Shoot.shared
                if !sh.open && !sh.recording && !self.inFront { self.pollTask = nil; return }
                await self.poll()
                await Shoot.shared.cameraStateChanged(self.state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    func info() -> [String: Any] {
        ["state": state, "counter": counter, "line": lastLine, "inFront": inFront, "micAllowed": Capture.micAllowed]
    }
}

