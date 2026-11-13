import Foundation

/// A phone is accepted only with a code that was shown on the Mac's screen (Second Take protocol, X-Pair-Code); paired codes are remembered.
@MainActor
final class Pairing {
    static let shared = Pairing()
    private var pending: String?
    private var shownAt = Date.distantPast
    private var paired: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pairedCodes") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "pairedCodes") }
    }

    func check(_ code: String?) -> Bool {
        if let c = code, !c.isEmpty {
            if paired.contains(c) { return true }
            if let p = pending, c == p, Date().timeIntervalSince(shownAt) < 600 {
                paired.insert(c); pending = nil
                WatchScreen.shared.clearPair()
                return true
            }
        }
        // a stranger (or an unpaired phone) knocks: show a new code, at most one per 20 seconds
        if pending == nil || Date().timeIntervalSince(shownAt) > 20 {
            let p = String(format: "%06d", Int.random(in: 0...999_999))
            pending = p; shownAt = Date()
            WatchScreen.shared.showPair(p)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if self?.pending == p { self?.pending = nil; WatchScreen.shared.clearPair() }
            }
        }
        return false
    }
}
