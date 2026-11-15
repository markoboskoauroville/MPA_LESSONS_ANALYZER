// v27 (15.11.2026, Marko: "It's cut out. I don't see the whole text and I cannot resize it"): SHOOT is a standard macOS window
// (titled, resizable from every edge, frame remembered), not a sheet; its first place is the MacBook screen. And the recording
// overlay on the BenQ over Imaging Edge Remote (Marko: "some text ... that it is recorded right now and some kind of timer").
import AppKit
import SwiftUI

@MainActor
final class ShootWindow: NSObject, NSWindowDelegate {
    static let shared = ShootWindow()
    private var window: NSWindow?
    static let defaultSize = NSSize(width: 720, height: 520)
    static let minSize = NSSize(width: 420, height: 360)

    static var builtIn: NSScreen? { NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") } }
    static var external: NSScreen? { NSScreen.screens.first { !$0.localizedName.localizedCaseInsensitiveContains("built-in") } }

    func sync(_ open: Bool) { open ? show() : close() }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Second Take · SHOOT"
            w.contentMinSize = Self.minSize
            w.collectionBehavior = [.fullScreenPrimary]        // Marko: "I need to see it also in full screen" (green button, ⌃⌘F, FULL SCREEN)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: ShootView().environmentObject(Store.shared))
            if !w.setFrameUsingName("SecondTakeShoot") {
                let v = (Self.builtIn ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                w.setFrame(NSRect(x: v.midX - Self.defaultSize.width / 2, y: v.midY - Self.defaultSize.height / 2,
                                  width: Self.defaultSize.width, height: Self.defaultSize.height), display: false)
            }
            w.setFrameAutosaveName("SecondTakeShoot")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { if let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }; window?.orderOut(nil) }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func front() { if Shoot.shared.open { show() } }

    func windowWillClose(_ notification: Notification) { if Shoot.shared.open { Shoot.shared.open = false } }

    /// for the size check (POST /shoot/size): set the content size, then screenshot it
    func setSize(_ w: Double, _ h: Double) {
        guard let win = window else { return }
        var f = win.frame
        let c = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(w, Self.minSize.width), height: max(h, Self.minSize.height)))
        f.origin.y += f.height - c.height; f.size = c.size
        win.setFrame(f, display: true)
    }
    var info: [String: Any] {
        guard let w = window else { return ["open": false] }
        return ["open": w.isVisible, "frame": [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height], "windowNumber": w.windowNumber, "screen": w.screen?.localizedName ?? ""]
    }
}

/// buttons that do not fit go to the next row (never cut)
struct FlowLayout: Layout {
    var spacing: CGFloat = 18
    var lineSpacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += line + lineSpacing; x = b.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

// MARK: the recording overlay on the BenQ: click-through, never takes the focus, top strip and the two side edges only

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecOverlay: ObservableObject {
    static let shared = RecOverlay()
    @Published var simulated: Date? = nil       // POST /overlay/test: the recording look without a recording
    private var panel: OverlayPanel?

    var recording: Bool { Shoot.shared.recording || simulated != nil }

    func show() {
        guard let scr = ShootWindow.external ?? NSScreen.main else { return }
        if panel == nil {
            let p = OverlayPanel(contentRect: scr.visibleFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: RecOverlayView())
            panel = p
        }
        panel?.setFrame(scr.visibleFrame, display: true)
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    var info: [String: Any] {
        ["visible": panel?.isVisible ?? false, "screen": (ShootWindow.external ?? NSScreen.main)?.localizedName ?? "", "simulated": simulated != nil,
         "windowNumber": panel?.windowNumber ?? 0]
    }
}

struct RecOverlayView: View {
    @ObservedObject private var o = RecOverlay.shared
    @ObservedObject private var sh = Shoot.shared
    @ObservedObject private var remote = SonyRemote.shared

    private var title: String {
        guard let c = sh.current else { return "" }
        return "Shot \(c.n)" + (c.code.isEmpty ? "" : " · \(c.code)") + " · \(c.title)"
    }
    private func clock(_ now: Date) -> String {
        if let s = o.simulated { return fmtTime(now.timeIntervalSince(s)) }
        let cam = remote.counterSeconds
        return fmtTime(cam > 0 ? Double(cam) : now.timeIntervalSince(sh.recSince))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            ZStack {
                if o.recording {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.red).frame(width: 6)
                        Spacer()
                        Rectangle().fill(Color.red).frame(width: 6)
                    }
                }
                VStack {
                    HStack(spacing: 18) {
                        if o.recording {
                            Circle().fill(Color.red).frame(width: 22, height: 22)
                            Text("RECORDING").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                            Text(clock(ctx.date)).font(.system(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                        } else {
                            Text("STANDBY").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                        }
                        Text(title).font(.system(size: o.recording ? 22 : 16)).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(o.recording ? 0.6 : 0.35)))
                    .padding(.top, 14).padding(.horizontal, 40)
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }
}
