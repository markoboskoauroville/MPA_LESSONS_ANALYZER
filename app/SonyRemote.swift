// v23 (15.11.2026, Marko: "we are not recording with web camera, we are recording by remote control. That's the only change"):
// the take is recorded on the Sony α7 V body. RECORD/STOP drive the existing hand `sonycam start|stop` (MACRO_SKILLS tools/sonycam,
// Imaging Edge Remote over USB); its REC/STBY and time counter (AX text of Remote's live window, `sonycam status`) are mirrored here;
// the live view is Remote's own window, captured with ScreenCaptureKit (one window, as OBS's window capture; the capture calls are
// Macro Recorder's Capture.swift) and shown full screen in Second Take; the Mac's microphone writes a small AAC guide track per take
// (~/Movies/<take>.guide.m4a) for the transcription, the exercise check and the match with the camera clip afterwards
// (tools/secondtake-match: start times, then audio cross-correlation).
import Foundation
import AVFoundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import SwiftUI

enum Capture {
    /// "remote" (default since v23): the Sony records on its card by remote control; "webcam": the built-in capture of v8-v22
    static var remote: Bool { (UserDefaults.standard.string(forKey: "capture") ?? "remote") != "webcam" }
    static func set(remote: Bool) { UserDefaults.standard.set(remote ? "remote" : "webcam", forKey: "capture") }
    static var screenAllowed: Bool { CGPreflightScreenCaptureAccess() }
    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var permissionsMissing: Bool { remote ? (!screenAllowed || !micAllowed) : CameraEngine.permissionsMissing }
    static func openPermissions() {
        guard remote else { CameraEngine.openPermissions(); return }
        let pane = !screenAllowed ? "Privacy_ScreenCapture" : "Privacy_Microphone"
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
    @Published var picture = false          // frames of Remote's window are arriving
    @Published var pictureError = ""
    @Published var lastLine = ""
    let layer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    private let output = WindowFrames()
    private var pollTask: Task<Void, Never>?
    private(set) var busy = false           // a sonycam click is running: polling waits

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        output.layer = layer
        output.onFrame = { [weak self] in Task { @MainActor in if self?.picture == false { self?.picture = true } } }
    }

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

    /// a click through sonycam: Second Take's full-screen window lets the click through (it may lie over Remote's window),
    /// then Second Take takes the front back
    func click(_ arg: String) async -> (Int32, String) {
        busy = true
        WatchScreen.shared.passClicks(true)
        let r = await Self.run(arg)
        WatchScreen.shared.passClicks(false)
        busy = false
        parse(r.1)
        WatchScreen.shared.refront()
        return r
    }

    /// polling every second while the full-screen view is up (mirrors REC and the counter; a REC or STOP pressed on the camera
    /// or in Remote is followed by Second Take)
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await self.poll()
                await Shoot.shared.cameraStateChanged(self.state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    // MARK: the picture: Remote's live window by ScreenCaptureKit
    func startView() async {
        guard stream == nil else { return }
        guard Capture.screenAllowed else {
            pictureError = "SCREEN RECORDING IS NOT ALLOWED for Second Take: System Settings, Privacy & Security, Screen Recording."
            _ = CGRequestScreenCaptureAccess()          // adds the app to the list; Marko switches it on himself
            return
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            pictureError = "ScreenCaptureKit gave no answer."; return
        }
        // Remote's live window is the big one (the device list is smaller, 800 wide at most)
        let wins = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.sony.Remote" && $0.windowLayer == 0 && $0.frame.width >= 300 }
        guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            pictureError = "Imaging Edge Remote has no window open."; return
        }
        let f = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let s = CGFloat(f.pointPixelScale)
        cfg.width = max(2, Int(f.contentRect.width * s)); cfg.height = max(2, Int(f.contentRect.height * s))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.queueDepth = 4
        let st = SCStream(filter: f, configuration: cfg, delegate: output)
        do {
            try st.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await st.startCapture()
            stream = st; pictureError = ""
        } catch { pictureError = "The Remote window cannot be captured: \(error.localizedDescription)" }
    }

    func stopView() {
        let st = stream; stream = nil; picture = false
        Task { try? await st?.stopCapture() }
        layer.flushAndRemoveImage()
    }

    func info() -> [String: Any] {
        ["state": state, "counter": counter, "picture": picture, "pictureError": pictureError, "line": lastLine,
         "screenRecordingAllowed": Capture.screenAllowed, "micAllowed": Capture.micAllowed]
    }
}

/// receives the frames of the captured window and shows the complete ones
final class WindowFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "secondtake.remotewindow")
    var layer: AVSampleBufferDisplayLayer?
    var onFrame: (() -> Void)?
    private var told = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = a.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if let m = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            m.first?.setValue(true, forKey: kCMSampleAttachmentKey_DisplayImmediately as String)
        }
        layer?.enqueue(sb)
        if !told { told = true; onFrame?() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        told = false
        Task { @MainActor in SonyRemote.shared.picture = false; SonyRemote.shared.pictureError = "The Remote window capture stopped: \(error.localizedDescription)" }
    }
}

final class RemoteHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
        MainActor.assumeIsolated { layer?.addSublayer(SonyRemote.shared.layer) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); MainActor.assumeIsolated { SonyRemote.shared.layer.frame = bounds } }
}

struct RemoteLiveView: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoteHostView { RemoteHostView(frame: .zero) }
    func updateNSView(_ v: RemoteHostView, context: Context) {}
}
