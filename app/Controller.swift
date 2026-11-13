import Foundation

/// First come, first served: the first remote that talks to the LAN listener owns the session; others get 423 until it is silent for 30 s
/// or RELEASE is pressed. Loopback callers (local tools, Claude, Queen) are never blocked.
@MainActor
final class Controller: ObservableObject {
    static let shared = Controller()
    @Published var ownerName: String? = nil
    private var ownerId: String?
    private var lastSeen = Date.distantPast
    private var timer: Timer?

    func admit(_ id: String, _ name: String) -> (Bool, String) {
        if ownerId != nil, Date().timeIntervalSince(lastSeen) > 30 { release() }
        if ownerId == nil { ownerId = id; ownerName = name; startTimer() }
        guard ownerId == id else { return (false, ownerName ?? "another remote") }
        lastSeen = Date()
        return (true, ownerName ?? name)
    }

    func release() { ownerId = nil; ownerName = nil; timer?.invalidate(); timer = nil }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let s = self else { return }
                if s.ownerId != nil, Date().timeIntervalSince(s.lastSeen) > 30 { s.release() }
            }
        }
    }
}
