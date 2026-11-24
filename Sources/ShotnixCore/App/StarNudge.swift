import AppKit

/// One-time "Enjoying Shotnix? Star it on GitHub" nudge.
enum StarNudge {
    static let repositoryURL = URL(string: "https://github.com/OMARVII/Shotnix")!
    static let captureThreshold = 10

    enum State: String {
        /// Still counting captures.
        case pending
        /// The ask was made (the raw value dates from when a toast was the
        /// only way); the reminder lines are visible.
        case toastShown
        /// The user chose "Not now".
        case dismissed
        /// The user opened the repository from the nudge.
        case starred
    }

    static var state: State {
        get { State(rawValue: Settings.starNudgeState) ?? .pending }
        set { Settings.starNudgeState = newValue.rawValue }
    }

    /// Pure bookkeeping, no UI. Returns true exactly once: on the capture
    /// that crosses the threshold while the nudge is still pending.
    @discardableResult
    static func recordCapture() -> Bool {
        Settings.captureCount += 1
        guard state == .pending, Settings.captureCount >= captureThreshold else { return false }
        state = .toastShown
        return true
    }

    static var shouldShowInHistoryPanel: Bool { state == .toastShown }

    static func markStarred() { state = .starred }
    static func markDismissed() { state = .dismissed }
}

@MainActor
extension StarNudge {
    /// Opens a link in the browser. Tests replace it.
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Call from every successful screenshot pipeline. On the threshold
    /// capture, shows the one-time toast on the capture's screen, a beat after
    /// the quick-access overlay lands so the two don't compete for attention.
    static func captureDidFinish(rect: CGRect) {
        guard recordCapture() else { return }
        let screen = NSScreen.screenContaining(rect: rect) ?? NSScreen.main
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showToast(on: screen)
        }
    }

    private static func showToast(on screen: NSScreen?) {
        ToastWindow.show(
            message: L("Enjoying Shotnix? Click to star it on GitHub ★"),
            duration: 6,
            on: screen
        ) {
            openRepository()
        }
    }

    /// Opens the repository in the browser and retires the nudge everywhere.
    static func openRepository() {
        markStarred()
        open(repositoryURL)
    }
}
