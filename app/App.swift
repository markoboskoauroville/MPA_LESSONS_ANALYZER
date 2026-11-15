import SwiftUI
import AppKit

let VERSION = 24

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in Store.shared.startServer() }
    }
    /// never quit in the middle of a take
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ Shoot.shared.recording }) {
            NSSound.beep()
            MainActor.assumeIsolated { Shoot.shared.status = "Recording: press STOP first, the app will not quit in the middle of a take." }
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
}

@main
struct MPAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    var body: some Scene {
        WindowGroup("MPA Lessons Analyzer (Mantra)") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, idealWidth: 1000, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 820, maxHeight: .infinity)
        }
        .defaultSize(width: 1000, height: 820)
        .windowResizability(.contentMinSize)
    }
}
