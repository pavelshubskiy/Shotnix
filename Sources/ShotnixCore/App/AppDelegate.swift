import AppKit
import KeyboardShortcuts
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var captureEngine: CaptureEngine!
    var hotkeyManager: HotkeyManager!
    var historyManager: HistoryManager!
    private let welcomeController = WelcomeWindowController()
    private let menuPresenter = ShotnixModernMenuPresenter()
    private var updateController: AppUpdateController!
    private var didRegisterHotkeys = false
    private var recordingIndicatorTimer: Timer?
    private var idleStatusIcon: NSImage?

    // Clicking the Dock icon (shown while an editor is open) restores a buried or minimized editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if AnnotationWindowController.hasOpenEditors {
                AnnotationWindowController.bringOpenEditorsToFront()
            }
        }
        // Escape hatch: the status item is the app's only entry point. While it
        // is hidden, launching Shotnix again (Finder, Spotlight, Launchpad)
        // lands here — show Preferences so the user can turn the icon back on.
        if !Settings.showMenuBarIcon {
            PreferencesWindowController.shared.show(tab: .general)
        } else if !statusItemIsEffectivelyVisible {
            // Icon enabled but macOS hid it (menu bar full) — relaunching the
            // app is the natural user move, so answer it with the menu itself.
            openCommandCenterFromAnywhere()
        }
        return true
    }

    /// Reviews unsaved screenshot edits and lets an active recording finish.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppTermination.confirmQuit() else { return .terminateCancel }
        guard AnnotationWindowController.hasUnsavedChanges else {
            return AppTermination.finishThenQuit(sender)
        }
        // The review brings editors forward: a recording pauses meanwhile so
        // they stay out of it, and carries on if the quit is cancelled.
        let pausedRecording = captureEngine?.pauseRecordingIfRunning() ?? false
        AnnotationWindowController.reviewUnsavedChangesBeforeQuitting { [weak self] canQuit in
            guard canQuit else {
                if pausedRecording { self?.captureEngine?.resumePausedRecording() }
                return sender.reply(toApplicationShouldTerminate: false)
            }
            // Saving an edit queues History writes; those finish first too.
            AppTermination.finishAll { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Quitting is certain now: when it's a restart (a new language or a new
    /// permission), the new Shotnix starts, and waits for this one to exit.
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.endSession()
        AppRelaunch.launchNewInstanceIfRestarting()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After a restart, the previous Shotnix finishes quitting before this
        // one takes the hotkeys, the menu bar, and History.
        AppRelaunch.waitForPreviousInstance()
        // Light or dark, as picked in Settings, before any window opens.
        ShotnixAppearance.apply()
        // Before anything that could crash: the next launch can tell a crash
        // from a normal quit.
        CrashReporter.startSession()
        Settings.migrateOnboardingFlagIfNeeded()
        // Before the welcome window marks this install as launched.
        Settings.migrateCaptureSettingsIfNeeded()
        Settings.migrateRecordingFPSIfNeeded()
        updateController = AppUpdateController()
        captureEngine = CaptureEngine()
        captureEngine.recordingStateChangedHandler = { [weak self] in
            self?.recordingStateDidChange()
        }
        hotkeyManager = HotkeyManager()
        historyManager = HistoryManager()
        setupMainMenu()
        setupStatusItem()
        registerHotkeys()
        recoverInterruptedRecording()
        CaptureEngine.warmCaptureSound()
        // Pre-build the command center's SwiftUI tree so the first menu open
        // is as instant as every later one.
        menuPresenter.warmUp()
        // Give the status bar a moment to lay out, then check whether the
        // icon actually made it on screen; re-check when displays change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.warnIfMenuBarIconHidden()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.warnIfMenuBarIconHidden()
            }
        }
        let promptForNativeShortcuts = { [weak self] in
            NativeShortcutManager.promptIfNeeded {
                self?.registerHotkeys()
                self?.showReadyToastIfNeeded(delay: 2.2)
            }
        }
        welcomeController.testCaptureHandler = { [weak self] in self?.captureArea() }
        let welcomeCloseHandler = { [weak self] in
            promptForNativeShortcuts()
            // Point at where Shotnix actually lives — a menu bar app with no
            // dock icon is otherwise invisible after the welcome window closes.
            if let button = self?.statusItem.button {
                let message = Settings.onboardingCompleted
                    ? L("You're all set — Shotnix lives here")
                    : L("Shotnix lives here — setup continues next launch")
                ToastWindow.show(message: message, duration: 4.0, anchorView: button)
            }
        }
        if !welcomeController.showIfNeeded(onClose: welcomeCloseHandler) {
            promptForNativeShortcuts()
            // Never during a recording: it waits for the Stop.
            CrashReporter.offerReportIfNeeded { [weak self] in
                guard let engine = self?.captureEngine else { return false }
                return engine.recordingElapsedSeconds != nil || engine.recordingIsSaving
            }
            // Escape hatch on cold launch: applicationShouldHandleReopen only
            // fires for an already-running app, so with the status item hidden
            // a fresh launch would otherwise be completely invisible. After a
            // restart for a new language, Settings comes back where it was.
            if !Settings.showMenuBarIcon || AppRelaunch.reopensSettings() {
                PreferencesWindowController.shared.show(tab: .general)
            }
        }
    }

    // MARK: – Recording indicator

    /// A recording cut short by a crash or power loss is still on disk (it's
    /// written in fragments): point the user at it.
    private func recoverInterruptedRecording() {
        Task { @MainActor in
            guard let url = await RecordingRecovery.recoverInterruptedRecording() else { return }
            Settings.lastRecordingPath = url.path
            ToastWindow.show(
                message: L("Recovered your interrupted recording “\(url.lastPathComponent)”. Click to show it in Finder."),
                duration: 7,
                action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            )
        }
    }

    /// While recording, the status item becomes a red dot + elapsed timer and
    /// a left click stops the recording (right click still opens the menu).
    /// Paused shows a pause glyph; after Stop it reads "Saving…" until the
    /// file is ready.
    private func recordingStateDidChange() {
        if captureEngine.recordingElapsedSeconds != nil || captureEngine.recordingIsSaving {
            updateRecordingIndicator()
            guard recordingIndicatorTimer == nil else { return }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecordingIndicator() }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingIndicatorTimer = timer
        } else {
            recordingIndicatorTimer?.invalidate()
            recordingIndicatorTimer = nil
            restoreIdleStatusItem()
        }
    }

    private func updateRecordingIndicator() {
        guard let button = statusItem.button else { return }
        guard let elapsed = captureEngine.recordingElapsedSeconds else {
            if captureEngine.recordingIsSaving {
                statusItem.length = NSStatusItem.variableLength
                button.image = nil
                button.attributedTitle = NSAttributedString(string: L("Saving…"), attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                button.toolTip = L("Saving the recording")
            } else {
                restoreIdleStatusItem()
            }
            return
        }
        let total = Int(elapsed)
        let time = String(format: "%d:%02d", total / 60, total % 60)
        let paused = captureEngine.recordingIsPaused
        statusItem.length = NSStatusItem.variableLength
        button.image = nil
        let title = NSMutableAttributedString(
            string: paused ? "❚❚ " : "● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: paused ? 9 : 10, weight: .bold),
                .foregroundColor: paused ? NSColor.systemYellow : NSColor.systemRed,
                .baselineOffset: 1.5,
            ]
        )
        title.append(NSAttributedString(
            string: time,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        button.attributedTitle = title
        let stopKey = RecordingStopHotkey.displayText
        button.toolTip = paused
            ? L("Recording paused — click to stop (\(stopKey))")
            : L("Recording — click to stop (\(stopKey))")
    }

    private func restoreIdleStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        button.image = idleStatusIcon
        button.toolTip = nil
    }

    private func registerHotkeys() {
        hotkeyManager.register(captureEngine: captureEngine, historyManager: historyManager) { [weak self] in
            self?.openCommandCenterFromAnywhere()
        }
        didRegisterHotkeys = true
    }

    // MARK: – Menu bar overflow rescue

    /// A crowded menu bar makes macOS hide status icons outright (worse on
    /// notched MacBooks) — users think the app didn't launch. Detect it so
    /// reopening the app, the rescue toast, and the assignable shortcut can
    /// present the command center without the icon.
    private var statusItemIsEffectivelyVisible: Bool {
        guard Settings.showMenuBarIcon,
              let button = statusItem.button,
              let window = button.window else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        guard let screen = window.screen ?? NSScreen.main else { return true }
        return screen.frame.intersects(window.frame)
    }

    /// Opens the command center anchored to the icon when it's visible, or as
    /// a floating top-center panel when the menu bar has swallowed the icon.
    func openCommandCenterFromAnywhere() {
        if menuPresenter.isShown {
            menuPresenter.dismiss()
            return
        }
        if statusItemIsEffectivelyVisible, let button = statusItem.button {
            menuPresenter.showCommandCenter(
                sections: commandCenterSections(),
                healthRows: ShotnixHealthModel.rows(snapshot: .live(updatesConfigured: AppUpdateConfiguration.current != nil)),
                healthActions: healthActions(),
                relativeTo: button
            )
        } else {
            menuPresenter.showCommandCenterDetached(
                sections: commandCenterSections(),
                healthRows: ShotnixHealthModel.rows(snapshot: .live(updatesConfigured: AppUpdateConfiguration.current != nil)),
                healthActions: healthActions()
            )
        }
    }

    private var didWarnHiddenIcon = false

    /// One toast per launch when the icon can't be seen: tells the user the
    /// app IS running, that hotkeys work, and offers the menu on click.
    private func warnIfMenuBarIconHidden() {
        guard !didWarnHiddenIcon,
              Settings.showMenuBarIcon,
              !statusItemIsEffectivelyVisible else { return }
        didWarnHiddenIcon = true
        ToastWindow.show(
            message: Self.hiddenIconMessage(captureAreaShortcut: ShotnixShortcut.captureArea.displayShortcut),
            duration: 7.0,
            action: { [weak self] in self?.openCommandCenterFromAnywhere() }
        )
    }

    /// Names the user's real Capture Area shortcut — or none, if unassigned.
    static func hiddenIconMessage(captureAreaShortcut: String?) -> String {
        if let captureAreaShortcut {
            return L("Menu bar is full, so macOS hid the Shotnix icon — \(captureAreaShortcut) still captures. Click here for the menu.")
        }
        return L("Menu bar is full, so macOS hid the Shotnix icon — your shortcuts still work. Click here for the menu.")
    }

    private func showReadyToastIfNeeded(delay: TimeInterval = 0) {
        let show = { @MainActor in
            guard Settings.hasLaunchedBefore,
                  !Settings.didShowReadyToast,
                  PermissionsManager.hasScreenRecordingPermission,
                  !NativeShortcutManager.nativeShortcutsEnabled else { return }

            Settings.didShowReadyToast = true
            ToastWindow.show(message: L("Shotnix is ready to use!"), duration: 3.0, anchorView: self.statusItem.button)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                show()
            }
        } else {
            show()
        }
    }

    // MARK: – Status bar

    private func setupMainMenu() {
        // The app menu's title is always the app's name.
        let mainMenu = NSMenu(title: "Shotnix") // l10n-ignore

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Shotnix") // l10n-ignore
        let preferencesItem = NSMenuItem(title: L("Settings…"), action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L("Quit Shotnix"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("File"))
        fileMenu.addItem(menuItem(L("Close Window"), action: #selector(closeKeyWindow(_:)), key: "w", modifiers: [.command]))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Standard Edit menu — LSUIElement apps get no default menus, so without
        // it ⌘X/C/V/A/Z have no responder route (breaking paste into text
        // annotation fields and save-panel filename fields). The items target
        // the app delegate instead of using plain nil-target standard selectors:
        // a matching menu item consumes its key equivalent even while disabled,
        // so nil-target items would starve the keyDown-based shortcuts in
        // custom windows (annotation canvas ⌘Z/⌘C, quick access overlay ⌘C).
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(menuItem(L("Undo"), action: #selector(editUndo(_:)), key: "z", modifiers: [.command]))
        editMenu.addItem(menuItem(L("Redo"), action: #selector(editRedo(_:)), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(menuItem(L("Cut"), action: #selector(editCut(_:)), key: "x", modifiers: [.command]))
        editMenu.addItem(menuItem(L("Copy"), action: #selector(editCopy(_:)), key: "c", modifiers: [.command]))
        editMenu.addItem(menuItem(L("Paste"), action: #selector(editPaste(_:)), key: "v", modifiers: [.command]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(menuItem(L("Select All"), action: #selector(editSelectAll(_:)), key: "a", modifiers: [.command]))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Minimal Window menu with the standard window-management commands.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(responderMenuItem(L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(responderMenuItem(L("Zoom"), action: #selector(NSWindow.performZoom(_:)), key: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(responderMenuItem(L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), key: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// Menu item with no explicit target — the action resolves through the
    /// responder chain (text fields, editors, key window).
    private func responderMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = Settings.showMenuBarIcon
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
        let icon = NSImage(systemSymbolName: "crop", accessibilityDescription: "Shotnix")?
            .withSymbolConfiguration(config)
        icon?.isTemplate = true
        idleStatusIcon = icon
        button.image = icon
        button.target = self
        button.action = #selector(toggleCommandCenter)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Keep the icon in sync with the "Show menu bar icon" preference,
        // which is toggled live from the General preferences pane.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        // Posted on whichever thread wrote the defaults (Sparkle writes from
        // background queues); NSStatusItem must only be touched on main.
        if Thread.isMainThread {
            updateStatusItemVisibility()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItemVisibility()
            }
        }
    }

    private func updateStatusItemVisibility() {
        guard let statusItem else { return }
        let shouldShow = Settings.showMenuBarIcon
        guard statusItem.isVisible != shouldShow else { return }
        statusItem.isVisible = shouldShow
    }

    // MARK: – Actions

    @objc func captureArea()         { Task { await captureEngine.startAreaCapture(historyManager: historyManager) } }
    @objc func captureWindow()       { Task { await captureEngine.startWindowCapture(historyManager: historyManager) } }
    @objc func captureFullscreen()   { Task { await captureEngine.captureFullscreen(historyManager: historyManager) } }
    @objc func captureAllDisplays()  { Task { await captureEngine.captureAllDisplays(historyManager: historyManager) } }
    @objc func captureScrolling()    { Task { await captureEngine.startScrollingCapture(historyManager: historyManager) } }
    @objc func recordArea()          { Task { await captureEngine.startAreaRecording() } }
    @objc func recordWindow()        { Task { await captureEngine.startWindowRecording() } }
    @objc func recordFullscreen()    { Task { await captureEngine.startFullscreenRecording() } }
    @objc func stopRecording()       { captureEngine.stopRecording() }
    @objc func captureText()         { Task { await captureEngine.startOCRCapture(historyManager: historyManager) } }
    @objc func scanQRCode()          { Task { await captureEngine.startQRCodeCapture() } }
    @objc func showEditor()          { AnnotationWindowController.bringOpenEditorsToFront() }
    @objc func annotateLastScreenshot() {
        guard let last = historyManager.items.first else { return }
        AnnotationWindowController.open(image: last.fullImage, historyItem: last, historyManager: historyManager)
    }
    @objc func openHistory()         { HistoryPanelController.shared.show(historyManager: historyManager) }
    @objc func toggleDesktopIcons()  { DesktopIconsManager.toggle() }
    @objc func openPreferences()     { PreferencesWindowController.shared.show(tab: .general) }
    @objc func openShortcutsPreferences() { PreferencesWindowController.shared.show(tab: .shortcuts) }
    @objc func openAbout()           { PreferencesWindowController.shared.show(tab: .about) }
    @objc func checkForUpdates(_ sender: Any?) { updateController?.checkForUpdates(sender) }
    /// ⌘W: closes whichever Shotnix window is key — editors, history, pins,
    /// Settings, the post-capture thumbnail.
    @objc func closeKeyWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        switch Self.closeAction(for: window) {
        case .custom(let closable): closable.closeFromCommand()
        case .performClose: window.performClose(sender)
        case .none: NSSound.beep()
        }
    }

    enum CloseAction {
        case custom(ShotnixCommandClosable)
        case performClose
        case none
    }

    /// Borderless panels (pins, the thumbnail) close themselves so their
    /// cleanup runs; titled windows go through performClose (unsaved-change
    /// prompts included). Capture overlays refuse: ⌘W mid-selection must not
    /// tear the selection down from under the capture.
    static func closeAction(for window: NSWindow) -> CloseAction {
        if let closable = window as? ShotnixCommandClosable { return .custom(closable) }
        if window.styleMask.contains(.closable) { return .performClose }
        return .none
    }

    // MARK: – Edit menu routing
    //
    // AppKit consumes a menu item's key equivalent even when the item is
    // disabled, so plain nil-target Edit items would swallow ⌘Z/⌘C before the
    // keyDown-based shortcuts in custom windows (annotation canvas, quick
    // access overlay) ever see them. These handlers try
    // the focused responder first and then fall back to app-specific handling.

    @objc func editUndo(_ sender: Any?) {
        // Focused text contexts (field editors, save panels) win.
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canUndo {
            undoManager.undo()
            return
        }
        // Windows with keyDown-based undo (annotation canvas) get the raw event.
        replayKeyEquivalent(characters: "z", keyCode: 6, modifiers: [.command])
    }

    @objc func editRedo(_ sender: Any?) {
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canRedo {
            undoManager.redo()
            return
        }
        replayKeyEquivalent(characters: "z", keyCode: 6, modifiers: [.command, .shift])
    }

    @objc func editCut(_ sender: Any?)       { dispatchEditAction(#selector(NSText.cut(_:)), characters: "x", keyCode: 7) }
    @objc func editCopy(_ sender: Any?)      { dispatchEditAction(#selector(NSText.copy(_:)), characters: "c", keyCode: 8) }
    @objc func editPaste(_ sender: Any?)     { dispatchEditAction(#selector(NSText.paste(_:)), characters: "v", keyCode: 9) }
    @objc func editSelectAll(_ sender: Any?) {
        dispatchEditAction(#selector(NSText.selectAll(_:)), characters: "a", keyCode: 0)
    }

    /// Sends a standard editing action through the responder chain (text views,
    /// field editors). If nothing claims it, replays the shortcut as a plain
    /// keyDown so custom windows keep their keyDown-based ⌘-key handling.
    private func dispatchEditAction(_ action: Selector, characters: String, keyCode: UInt16) {
        if NSApp.sendAction(action, to: nil, from: nil) { return }
        replayKeyEquivalent(characters: characters, keyCode: keyCode, modifiers: [.command])
    }

    /// Re-delivers a shortcut to the key window's first responder as a keyDown.
    ///
    /// TWO guards against infinite recursion, both load-bearing: NSWindow's
    /// own `keyDown` re-enters menu key-equivalent routing, so when a window
    /// is its OWN first responder (the hover-focused post-capture overlay,
    /// the detached command center) the replay came straight back here —
    /// ⌘X/⌘C with one of those focused livelocked the main thread until the
    /// app had to be force-killed. Never replay into a window-as-responder,
    /// and never replay while already replaying.
    private var isReplayingKeyEquivalent = false

    private func replayKeyEquivalent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard !isReplayingKeyEquivalent else { return }
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder,
              !(responder is NSWindow),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: modifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: characters,
                  charactersIgnoringModifiers: characters,
                  isARepeat: false,
                  keyCode: keyCode
              ) else { return }
        isReplayingKeyEquivalent = true
        defer { isReplayingKeyEquivalent = false }
        responder.keyDown(with: event)
    }

    @objc private func toggleCommandCenter(_ sender: Any?) {
        // While recording, a left click on the red timer stops the recording
        // immediately; the menu stays reachable via right click.
        if captureEngine.recordingElapsedSeconds != nil, NSApp.currentEvent?.type == .leftMouseUp {
            stopRecording()
            return
        }
        if menuPresenter.isShown {
            menuPresenter.dismiss()
            return
        }

        guard let button = statusItem.button else { return }
        menuPresenter.showCommandCenter(
            sections: commandCenterSections(),
            healthRows: ShotnixHealthModel.rows(snapshot: .live(updatesConfigured: AppUpdateConfiguration.current != nil)),
            healthActions: healthActions(),
            relativeTo: button
        )
    }

    func commandCenterSections(screenCount: Int = NSScreen.screens.count) -> [ShotnixMenuSection] {
        // Capture Fullscreen shoots the display you're on; "Capture All
        // Displays" gets its own row only when there's more than one.
        var captureActions = [
            action(id: "capture.area", title: L("Capture Area"), symbol: "rectangle.dashed", shortcut: .shotnixCaptureArea, role: .primary) { [weak self] in self?.captureArea() },
            action(id: "capture.window", title: L("Capture Window"), symbol: "macwindow", shortcut: .shotnixCaptureWindow) { [weak self] in self?.captureWindow() },
            action(id: "capture.fullscreen", title: L("Capture Fullscreen"), symbol: "rectangle.on.rectangle", shortcut: .shotnixCaptureFullscreenNative) { [weak self] in self?.captureFullscreen() },
        ]
        if screenCount > 1 {
            captureActions.append(action(id: "capture.all-displays", title: L("Capture All Displays"), symbol: "rectangle.3.group", shortcut: .shotnixCaptureAllDisplays) { [weak self] in self?.captureAllDisplays() })
        }
        captureActions.append(action(id: "capture.scrolling", title: L("Scrolling Capture"), symbol: "scroll", shortcut: .shotnixCaptureScrolling) { [weak self] in self?.captureScrolling() })

        return [
            ShotnixMenuSection(id: "capture", title: L("Capture"), actions: captureActions),
            ShotnixMenuSection(id: "record", title: L("Recording"), actions: {
                var recordActions = [
                    action(id: "record.area", title: L("Record Area"), symbol: "record.circle", shortcut: .shotnixRecordArea, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordArea() },
                    action(id: "record.window", title: L("Record Window"), symbol: "macwindow.badge.plus", shortcut: .shotnixRecordWindow, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordWindow() },
                    action(id: "record.fullscreen", title: L("Record Fullscreen"), symbol: "rectangle.fill.on.rectangle.fill", shortcut: .shotnixRecordFullscreen, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordFullscreen() },
                ]
                if captureEngine?.recordingElapsedSeconds != nil {
                    let paused = captureEngine?.recordingIsPaused == true
                    recordActions.append(action(
                        id: "record.pause",
                        title: paused ? L("Resume Recording") : L("Pause Recording"),
                        symbol: paused ? "play.circle" : "pause.circle",
                        shortcut: .shotnixPauseRecording
                    ) { [weak self] in self?.captureEngine.togglePauseRecording() })
                }
                // Stop/Cancel only exists while there is something to stop —
                // a permanently visible disabled red row was pure noise.
                if captureEngine?.recordingStopEnabled == true {
                    recordActions.append(action(
                        id: "record.stop",
                        title: captureEngine?.recordingStopTitle ?? L("Stop Recording"),
                        symbol: "stop.circle",
                        shortcut: .shotnixStopRecording,
                        role: .destructive
                    ) { [weak self] in self?.stopRecording() })
                }
                return recordActions
            }()),
            ShotnixMenuSection(id: "tools", title: L("Tools"), actions: [
                action(id: "tools.ocr", title: L("Capture Text"), symbol: "text.viewfinder", shortcut: .shotnixCaptureText) { [weak self] in self?.captureText() },
                action(id: "tools.qr", title: L("Scan QR Code"), symbol: "qrcode.viewfinder") { [weak self] in self?.scanQRCode() },
                action(id: "tools.annotate-last", title: L("Annotate Last Screenshot"), symbol: "pencil.tip.crop.circle", isEnabled: !(historyManager?.items.isEmpty ?? true)) { [weak self] in self?.annotateLastScreenshot() },
            ]),
            ShotnixMenuSection(id: "utility", title: L("Utility"), actions: {
                var utilityActions = [
                    action(id: "utility.history", title: L("Open History"), symbol: "clock.arrow.circlepath") { [weak self] in self?.openHistory() },
                ]
                if let recording = Settings.lastRecordingURL {
                    utilityActions.append(action(
                        id: "utility.last-recording",
                        title: L("Show Last Recording in Finder"),
                        symbol: "film"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([recording])
                    })
                }
                // Editor-window rows only exist while an editor is open —
                // disabled rows earn no space.
                if AnnotationWindowController.hasOpenEditors {
                    utilityActions.append(action(id: "utility.editor", title: L("Show Editor"), symbol: "pencil.and.outline") { [weak self] in self?.showEditor() })
                }
                utilityActions.append(action(id: "utility.desktop-icons", title: DesktopIconsManager.desktopIconsVisible ? L("Hide Desktop Icons") : L("Show Desktop Icons"), symbol: DesktopIconsManager.desktopIconsVisible ? "eye.slash" : "eye") { [weak self] in self?.toggleDesktopIcons() })
                return utilityActions
            }()),
            ShotnixMenuSection(id: "settings", title: L("Settings"), actions: [
                action(id: "settings.preferences", title: L("Preferences"), symbol: "gearshape", shortcutText: "⌘,") { [weak self] in self?.openPreferences() },
                action(id: "settings.about", title: L("About Shotnix"), symbol: "info.circle") { [weak self] in self?.openAbout() },
                action(id: "settings.update", title: L("Check for Updates"), symbol: "arrow.triangle.2.circlepath", isEnabled: updateController?.canCheckForUpdates ?? false) { [weak self] in self?.checkForUpdates(nil) },
                action(id: "settings.quit", title: L("Quit Shotnix"), symbol: "power", shortcutText: "⌘Q", role: .destructive) { NSApp.terminate(nil) },
            ]),
        ]
    }

    private func healthActions() -> [ShotnixHealthKind: () -> Void] {
        [
            .screenRecording: { PermissionsManager.openScreenRecordingSettings() },
            .nativeShortcuts: {
                if NativeShortcutManager.disableNativeShortcuts() {
                    ToastWindow.show(message: L("Apple screenshot shortcuts disabled."))
                } else {
                    NativeShortcutManager.openKeyboardSettings()
                }
            },
            .updates: { [weak self] in self?.checkForUpdates(nil) },
            .autoSave: { [weak self] in self?.chooseAutoSaveFolder() },
            .shortcuts: { [weak self] in self?.openShortcutsPreferences() }
        ]
    }

    private func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Settings.setAutoSaveLocation(url.path) {
            ToastWindow.show(message: L("Save folder updated."))
        } else {
            ToastWindow.show(message: L("Choose a writable folder."))
        }
    }

    private func action(
        id: String,
        title: String,
        symbol: String,
        shortcut: KeyboardShortcuts.Name? = nil,
        shortcutText: String? = nil,
        isEnabled: Bool = true,
        role: ShotnixMenuRole = .normal,
        handler: @escaping () -> Void
    ) -> ShotnixMenuAction {
        ShotnixMenuAction(
            id: id,
            title: title,
            symbolName: symbol,
            shortcut: shortcutText ?? shortcut.flatMap(shortcutDisplay),
            isEnabled: isEnabled,
            role: role,
            handler: handler
        )
    }

    private func shortcutDisplay(for name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
