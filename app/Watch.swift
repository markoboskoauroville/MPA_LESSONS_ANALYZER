import SwiftUI
import AVKit
import AVFoundation
import AppKit

final class WatchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct FullPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.videoGravity = .resizeAspect
        v.controlsStyle = .none
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// WATCH full screen: a borderless window over the display that has the menu bar (the BenQ), the lesson's clips as video only,
/// the sound goes where the Mac's output already is. Esc or the end returns; RECORD (bottom centre) is replaced by STOP in the same place.
@MainActor
final class WatchScreen: ObservableObject {
    static let shared = WatchScreen()
    @Published var visible = false
    @Published var live = false
    @Published var pairCode: String? = nil
    private var pairOnly = false
    @Published var lastMove = Date()
    private var window: WatchWindow?
    private var keyMon: Any?
    private var moveMon: Any?
    var shotN = 0

    /// the display of the full-screen view: the one chosen in Settings or by POST /screen {"name"|"index"}; default the display with the menu bar (the BenQ)
    var screen: NSScreen {
        let want = UserDefaults.standard.string(forKey: "viewScreen") ?? ""
        if !want.isEmpty, let s = NSScreen.screens.first(where: { $0.localizedName == want }) { return s }
        return NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
    }
    static var screenNames: [String] { NSScreen.screens.map { $0.localizedName } }
    /// almost-maximized, as Rectangle's almost-maximize: the visible frame less 5 % around
    var frameOnScreen: NSRect { let v = screen.visibleFrame; return v.insetBy(dx: v.width * 0.025, dy: v.height * 0.025) }

    /// The live Sony picture full screen, without recording (framing).
    func showLive(shot n: Int? = nil) {
        if let n = n { shotN = n } else if shotN == 0 { shotN = Shoot.shared.current?.n ?? 0 }
        // v26: by remote control the "live picture" is the real Imaging Edge Remote, brought to the front (sonycam front)
        if Capture.remote {
            Shoot.shared.focus(shot: shotN)
            Task { if await Shoot.shared.prepareRemote() == nil { await SonyRemote.shared.bringFront() } }
            return
        }
        live = true
        present()
        Task {
            // reconnects by itself the moment the camera appears
            while self.live && self.visible {
                if await Shoot.shared.prepareCamera() == nil { break }
                if !Shoot.shared.cameraMissing { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func show(shot n: Int) {
        shotN = n
        live = false          // v28: watching never changes the current shot of the session
        present()
    }

    private func present() {
        if window == nil {
            // v26: a normal window, almost the whole visible area (menu bar, Dock and other apps stay reachable), never full screen
            let w = WatchWindow(contentRect: frameOnScreen, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isOpaque = true; w.backgroundColor = .black
            w.title = "Second Take"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
            w.level = .normal
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WatchView())
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.setFrame(frameOnScreen, display: true) }
        w.orderFrontRegardless()
        w.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        visible = true
        lastMove = Date()
        installKeys()
    }

    func showPair(_ code: String) {
        pairCode = code
        if !visible { pairOnly = true; live = false; present() }
    }
    func clearPair() {
        pairCode = nil
        if pairOnly { pairOnly = false; hide() }
    }

    func hide(keepPolling: Bool = false) {
        guard visible else { return }
        window?.orderOut(nil)
        pairCode = nil; pairOnly = false
        visible = false; live = false
        CameraEngine.shared.stop()
        if !keepPolling && !Shoot.shared.recording { SonyRemote.shared.stopPolling() }
        if let k = keyMon { NSEvent.removeMonitor(k); keyMon = nil }
        if let m = moveMon { NSEvent.removeMonitor(m); moveMon = nil }
    }

    /// Esc ends the watching and goes back; while the camera records only STOP ends it.
    func escape() {
        if Shoot.shared.recording { return }
        Store.shared.stopPlayback()
        hide()
    }

    func recordPressed() {
        Store.shared.stopPlayback()
        live = true
        Shoot.shared.focus(shot: shotN)
        Shoot.shared.toggleRecord()
    }

    func watchAgain() { live = false; Store.shared.watchShot(shotN) }

    var mode: String { Shoot.shared.recording ? "recording" : (!visible ? "idle" : (live ? "live" : (Store.shared.watchingShot != nil || Store.shared.playingAll ? "watch" : "idle"))) }

    private func installKeys() {
        if keyMon == nil {
            keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let s = self, s.visible else { return e }
                if e.keyCode == 53 { Task { @MainActor in s.escape() }; return nil }
                return e
            }
        }
        if moveMon == nil {
            moveMon = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] e in
                Task { @MainActor in self?.lastMove = Date() }
                return e
            }
        }
        window?.acceptsMouseMovedEvents = true
    }

    func info() -> [String: Any] {
        let f = screen.frame
        return ["mode": mode, "screens": WatchScreen.screenNames, "chosen": UserDefaults.standard.string(forKey: "viewScreen") ?? "", "visible": visible, "shot": shotN, "recording": Shoot.shared.recording,
                "screen": screen.localizedName, "frame": [f.origin.x, f.origin.y, f.size.width, f.size.height]]
    }
}

struct WatchView: View {
    @ObservedObject private var w = WatchScreen.shared
    @ObservedObject private var sh = Shoot.shared
    @ObservedObject private var st = Store.shared
    @ObservedObject private var remote = SonyRemote.shared
    @State private var hover = false

    private var playing: Bool { st.watchingShot != nil || st.playingAll || st.playingClip != nil }
    private var title: String {
        guard let s = sh.shots.first(where: { $0.n == w.shotN }) else { return "" }
        return "Shot \(s.n)" + (s.code.isEmpty ? "" : " · \(s.code)") + " · \(s.title)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let showControls = (!playing && !w.live && !sh.recording) || ctx.date.timeIntervalSince(w.lastMove) < 3
            ZStack {
                Color.black
                if (w.live || sh.recording) && !sh.cameraMissing && !Capture.remote { LiveView() } else { FullPlayer(player: st.player) }
                if sh.cameraMissing {
                    VStack(spacing: 16) {
                        Text(Capture.remote ? "CAMERA NOT CONNECTED" : "SONY NOT CONNECTED").font(.system(size: 64, weight: .bold)).foregroundStyle(.red)
                        Text(Capture.remote ? "Imaging Edge Remote shows no live view. This screen continues by itself." : "Switch it on, USB Streaming. This screen continues by itself.").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                if Capture.remote && (w.live || sh.recording) && !sh.cameraMissing {
                    VStack(spacing: 10) {
                        Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        if let c = sh.shots.first(where: { $0.n == w.shotN }) {
                            Text(sh.sayText(c)).font(.system(size: 22)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 1100)
                        }
                        Spacer()
                    }
                    .padding(.top, 90).padding(.horizontal, 48)
                }
                if !Capture.remote && w.live && !sh.recording && !sh.cameraInfo.isEmpty && !sh.cameraMissing {
                    VStack { Text(sh.cameraInfo).font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)).padding(.top, 36); Spacer() }
                }
                if sh.recording {
                    VStack {
                        HStack(spacing: 10) {
                            Circle().fill(Color.red).frame(width: 16, height: 16)
                            Text(Capture.remote ? "CAMERA REC  \(remote.counter)" : fmtTime(ctx.date.timeIntervalSince(sh.recSince))).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.leading, 40).padding(.top, 36)
                        Spacer()
                    }
                }
                VStack(spacing: 0) {
                    if !playing && !sh.recording && !w.live {
                        Text(title).font(.system(size: 26)).foregroundStyle(.white.opacity(0.85)).padding(.top, 48)
                    }
                    Spacer()
                    VStack(spacing: 18) {
                        if !sh.status.isEmpty && !playing && !w.live && !sh.recording {
                            Text(sh.status).font(.system(size: 20)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button { w.recordPressed() } label: {
                            Text(sh.recording ? "STOP" : "RECORD")
                                .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                .frame(width: 420, height: 104)
                                .background(RoundedRectangle(cornerRadius: 52).fill(sh.recording ? Color.gray.opacity(hover ? 0.9 : 0.7) : Color.red.opacity(hover ? 1 : 0.85)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hover = $0 }
                        .accessibilityLabel(sh.recording ? "STOP" : "RECORD")
                        if !sh.recording {
                            HStack(spacing: 36) {
                                Button("WATCH AGAIN") { w.watchAgain() }.buttonStyle(.plain)
                                Button { st.muted.toggle() } label: {
                                    HStack(spacing: 8) { Image(systemName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"); Text(st.muted ? "UNMUTE" : "MUTE") }
                                }.buttonStyle(.plain)
                                Button("CLOSE  (Esc)") { w.escape() }.buttonStyle(.plain)
                            }
                            .font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .opacity(showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: showControls)
                    .padding(.horizontal, 48).padding(.bottom, 56)
                }
                if let code = w.pairCode {
                    ZStack {
                        Color.black.opacity(0.92)
                        VStack(spacing: 28) {
                            Text("A phone wants to connect").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
                            Text(code).font(.system(size: 220, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            Text("Type this code on the phone").font(.system(size: 28)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
