import AppKit

@MainActor
extension NSApplication {
    func restoreBackgroundOnlyActivationPolicyIfNeeded(excluding closingWindow: NSWindow? = nil) {
        // Never drop to background while an editor is open (even minimized) — it must keep its
        // Dock icon / ⌘-Tab entry so the user can return to it. See `ShotnixEditorActivation`.
        if AnnotationWindowController.hasOpenEditors {
            // Transient UI (menu, capture overlay, a panel) may have run in
            // the meantime — make sure the editors kept their Dock presence.
            ShotnixEditorActivation.sync()
            return
        }
        guard !hasVisiblePersistentWindow(excluding: closingWindow) else {
            return
        }

        setActivationPolicy(.prohibited)
    }

    /// Whether Shotnix stays the active app once its transient UI closes: an
    /// editor is open (minimized counts) or another lasting window is up.
    /// macOS then brings one of those forward instead of going back to the
    /// app the user was in (see `CaptureFocus`).
    func staysInFrontAfterTransientUI() -> Bool {
        AnnotationWindowController.hasOpenEditors
            || hasVisiblePersistentWindow(excluding: nil)
    }

    /// Lets a menu-bar-only Shotnix show transient UI (menu, capture
    /// overlay, panels). Never demotes a regular app — while an editor is
    /// open that would hide its Dock icon and drop it behind other apps.
    func ensureForegroundCapable() {
        if activationPolicy() == .prohibited {
            setActivationPolicy(.accessory)
        }
    }

    private func hasVisiblePersistentWindow(excluding closingWindow: NSWindow?) -> Bool {
        windows.contains { window in
            if let closingWindow, window === closingWindow {
                return false
            }

            guard window.isVisible, !window.isMiniaturized else {
                return false
            }

            if window is PinnedWindow {
                return true
            }

            let persistentMasks: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
            return !window.styleMask.intersection(persistentMasks).isEmpty
        }
    }
}


/// Coordinates the Dock icon while a screenshot editor window is
/// open, Shotnix runs as a regular app (Dock icon + ⌘-Tab) so the user can always return to it;
/// once the last editor closes, it drops back to accessory (menu-bar-only).
@MainActor
enum ShotnixEditorActivation {
    static func sync() {
        let editing = AnnotationWindowController.hasOpenEditors
        let policy: NSApplication.ActivationPolicy = editing ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
