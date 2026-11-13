import AVFoundation
import AppKit
import SwiftUI

// Built-in camera (13.11.2026, Marko: "copy paste the code from web recorder to this app so it's built in"): the capture session,
// the vertical slice, the recorder and the camera list come from Webcam Recorder (Mantra) (repo web-cam-viewer, own code).
// One session: the camera (the Sony ILCE-7M5 first), the chosen microphone, 1080p, whole frame rate; the picture is the middle 9:16
// strip (Slicer), shown by an AVSampleBufferDisplayLayer and written by Recorder (HEVC, AAC, time code track).

enum Cameras {
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
            .sorted { a, b in
                let asn = isSony(a), bsn = isSony(b)
                if asn != bsn { return asn }
                let ai = a.deviceType == .builtInWideAngleCamera, bi = b.deviceType == .builtInWideAngleCamera
                return ai != bi ? ai : a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
            }
    }
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
    static func isSony(_ d: AVCaptureDevice) -> Bool { d.localizedName.uppercased().hasPrefix("ILCE") || d.manufacturer.uppercased().contains("SONY") }
}

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = CameraEngine()
    let layer = AVSampleBufferDisplayLayer()
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "secondtake.session")
    private let captureQueue = DispatchQueue(label: "secondtake.capture")
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private let slicer = Slicer()
    private var videoIn: AVCaptureDeviceInput?
    private var audioIn: AVCaptureDeviceInput?
    private var recorder: Recorder?
    private var lastAudioFormat: CMFormatDescription?
    private var fps: Int32 = 30
    private let lock = NSLock()
    private var _frames = 0
    private(set) var cameraName = ""
    private(set) var micName = ""
    private(set) var recStart: Date?
    private(set) var lastError = ""

    var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    var running: Bool { session.isRunning }
    var isRecording: Bool { recStart != nil }

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: captureQueue)
        audioOut.setSampleBufferDelegate(self, queue: captureQueue)
    }

    // MARK: permissions
    static func cameraStatus() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static func micStatus() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var permissionsMissing: Bool { cameraStatus() != .authorized || micStatus() != .authorized }

    static func openPermissions() {
        let pane = cameraStatus() != .authorized ? "Privacy_Camera" : "Privacy_Microphone"
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    /// asks (a macOS prompt the first time) and returns whether the camera is allowed
    func askPermissions() async -> Bool {
        var cam = Self.cameraStatus() == .authorized
        if Self.cameraStatus() == .notDetermined { cam = await AVCaptureDevice.requestAccess(for: .video) }
        if Self.micStatus() == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return cam
    }

    // MARK: choice (remembered)
    var wantedCamera: String {
        get { UserDefaults.standard.string(forKey: "cameraName") ?? "ILCE" }
        set { UserDefaults.standard.set(newValue, forKey: "cameraName") }
    }
    var wantedMic: String {
        get { UserDefaults.standard.string(forKey: "micName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "micName") }
    }

    func list() -> [String: Any] {
        ["cameras": Cameras.all().map { ["name": $0.localizedName, "id": $0.uniqueID, "sony": Cameras.isSony($0)] as [String: Any] },
         "microphones": Cameras.microphones().map { ["name": $0.localizedName, "id": $0.uniqueID] },
         "camera": cameraName, "microphone": micName, "wantedCamera": wantedCamera, "wantedMic": wantedMic,
         "cameraAllowed": Self.cameraStatus() == .authorized, "micAllowed": Self.micStatus() == .authorized,
         "running": running, "frames": frames, "fps": Int(fps), "size": "\(Slicer.outW)x\(Slicer.outH)", "recording": isRecording, "error": lastError]
    }

    // MARK: session
    /// opens the wanted camera (the Sony first) and the microphone; nil when running, else the reason
    func start() async -> String? {
        guard await askPermissions() else { lastError = "The camera is not allowed (System Settings, Privacy, Camera)."; return lastError }
        let w = wantedCamera.lowercased()
        let cams = Cameras.all()
        guard let cam = cams.first(where: { $0.localizedName.lowercased().contains(w) }) ?? cams.first(where: { Cameras.isSony($0) }) ?? cams.first else {
            lastError = "No camera is connected. Plug in the Sony (USB) and switch it on."; return lastError
        }
        var mic: AVCaptureDevice? = nil
        if Self.micStatus() == .authorized {
            let m = wantedMic.lowercased()
            let mics = Cameras.microphones()
            mic = (m.isEmpty ? nil : mics.first(where: { $0.localizedName.lowercased().contains(m) })) ?? AVCaptureDevice.default(for: .audio)
        }
        if session.isRunning, videoIn?.device.uniqueID == cam.uniqueID, audioIn?.device.uniqueID == mic?.uniqueID { return nil }
        let err: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async {
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.videoIn = nil; self.audioIn = nil
                var e: String? = nil
                do {
                    let input = try AVCaptureDeviceInput(device: cam)
                    if self.session.canAddInput(input) { self.session.addInput(input); self.videoIn = input } else { e = "\(cam.localizedName) cannot be added." }
                } catch { e = "\(cam.localizedName) cannot be opened: \(error.localizedDescription)" }
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : (self.session.canSetSessionPreset(.high) ? .high : .medium)
                if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }
                if let mic, let a = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(a) {
                    self.session.addInput(a); self.audioIn = a
                    if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }
                }
                self.session.commitConfiguration()
                self.fps = Self.wholeFrameRate(cam)
                self.captureQueue.async { self.lastAudioFormat = nil }
                if e == nil, !self.session.isRunning { self.session.startRunning() }
                c.resume(returning: e)
            }
        }
        if let e = err { lastError = e; return e }
        cameraName = cam.localizedName; micName = mic?.localizedName ?? "none"
        lock.lock(); _frames = 0; lock.unlock()
        lastError = ""
        return nil
    }

    /// waits (bounded) until frames have arrived; nil when they do, else the reason
    func waitForFrames(seconds: Double = 8) async -> String? {
        let start = frames
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if frames > start + 5 { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        lastError = "\(cameraName) is open but delivers no frames. Check the USB cable and that the Sony is on (USB Streaming)."
        return lastError
    }

    func stop() {
        guard !isRecording else { return }
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        layer.flushAndRemoveImage()
    }

    private static func wholeFrameRate(_ d: AVCaptureDevice) -> Int32 {
        let ranges = d.activeFormat.videoSupportedFrameRateRanges
        for r in [30.0, 25, 24, 60, 50] where ranges.contains(where: { $0.minFrameRate <= r && r <= $0.maxFrameRate }) {
            if (try? d.lockForConfiguration()) != nil {
                d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(r))
                d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(r))
                d.unlockForConfiguration()
            }
            return Int32(r)
        }
        let dur = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        return dur > 0 ? Int32(max(1, min(120, (1 / dur).rounded()))) : 30
    }

    // MARK: recording
    func startRecord(title: String) async -> (URL?, String) {
        guard session.isRunning else { return (nil, "The camera is not running.") }
        let fps = self.fps
        return await withCheckedContinuation { c in
            captureQueue.async {
                do {
                    let r = try Recorder(fps: fps, vertical: true, title: title, audioFormat: self.audioIn == nil ? nil : self.lastAudioFormat)
                    self.recorder = r
                    DispatchQueue.main.async { self.recStart = Date() }
                    c.resume(returning: (r.url, ""))
                } catch { c.resume(returning: (nil, "Cannot record: \(error.localizedDescription)")) }
            }
        }
    }

    func stopRecord() async -> (String?, Double, String) {
        var r: Recorder?
        captureQueue.sync { r = recorder; recorder = nil }
        let started = recStart
        await MainActor.run { self.recStart = nil }
        guard let r else { return (nil, 0, "not recording") }
        let dur = Date().timeIntervalSince(started ?? Date())
        return await withCheckedContinuation { c in
            r.finish { r in c.resume(returning: r.failed == nil ? (r.url.path, dur, "") : (nil, 0, r.failed ?? "the take failed")) }
        }
    }

    // MARK: samples (capture queue)
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if o === audioOut {
            lastAudioFormat = CMSampleBufferGetFormatDescription(sb)
            recorder?.appendAudio(sb)
        } else {
            lock.lock(); _frames &+= 1; lock.unlock()
            if let v = slicer.slice(sb) {
                if let a = CMSampleBufferGetSampleAttachmentsArray(v, createIfNecessary: true) as? [NSMutableDictionary] {
                    a.first?.setValue(true, forKey: kCMSampleAttachmentKey_DisplayImmediately as String)
                }
                layer.enqueue(v)
                recorder?.appendVideo(v)
            }
        }
    }
}

/// hosts the engine's display layer (the vertical picture, aspect fit, black around)
final class CameraHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(CameraEngine.shared.layer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); CameraEngine.shared.layer.frame = bounds }
}

struct LiveView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraHostView { CameraHostView(frame: .zero) }
    func updateNSView(_ v: CameraHostView, context: Context) {}
}
