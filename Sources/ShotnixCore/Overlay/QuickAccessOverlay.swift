import AppKit
import CoreImage
import QuartzCore

/// Post-capture floating thumbnail with quick action buttons.
/// Area captures can anchor it to the pointer; other captures use the corner stack.
@MainActor
final class QuickAccessOverlay {

    /// - Parameter autoSaving: Save automatically is writing this capture;
    ///   the card hears the result through `autoSaveFinished`.
    @discardableResult
    static func show(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager, autoSaving: Bool = false, anchor: CGPoint? = nil) -> QuickAccessWindow {
        let window = QuickAccessWindow(image: image, historyItem: historyItem, historyManager: historyManager, anchor: anchor)
        window.autoSaveState = autoSaving ? .writing : .none
        window.show()
        return window
    }

    /// Once, and only while captures aren't saved to a folder by themselves.
    static func shouldShowHistoryTip() -> Bool {
        !Settings.didShowHistoryTip && !Settings.afterCaptureSaveAutomatically
    }

    /// Post-save toast text: the file actually written, its folder, and the
    /// reveal affordance hint.
    static func savedMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        let file = url.lastPathComponent
        return L("Saved \(file) to \(destination) — click to reveal in Finder")
    }
}

enum QuickAccessPointerLayout {
    static func origin(near point: CGPoint, visibleFrame: CGRect, cardSize: CGSize) -> CGPoint {
        let gap: CGFloat = 12
        let right = point.x + gap
        let left = point.x - gap - cardSize.width
        let below = point.y - gap - cardSize.height
        let above = point.y + gap

        let maxX = visibleFrame.maxX - cardSize.width
        let maxY = visibleFrame.maxY - cardSize.height
        let x = right <= maxX ? right : left
        let y = below >= visibleFrame.minY ? below : above
        return CGPoint(x: max(visibleFrame.minX, min(x, maxX)),
                       y: max(visibleFrame.minY, min(y, maxY)))
    }
}

/// Where post-capture thumbnails stack on a screen: a column rising from
/// above the Dock line, never reaching under the menu bar.
enum QuickAccessStackLayout {
    /// Vertical gap between stacked thumbnails.
    static let gap: CGFloat = 12
    static let sideMargin: CGFloat = 36
    /// Sits noticeably above the bottom edge (Dock line) — comfortable to
    /// glance at without looking "docked" to the corner.
    static let bottomMargin: CGFloat = 84
    static let topMargin: CGFloat = 12
    /// More than this per screen and the oldest card is dismissed.
    static let maxCards = 5

    /// Cards that fit between the Dock line and the menu bar — fewer than
    /// five on a small screen.
    static func capacity(visibleFrame: CGRect, cardHeight: CGFloat) -> Int {
        let usable = visibleFrame.height - bottomMargin - topMargin
        let fitting = Int(floor((usable + gap) / (cardHeight + gap)))
        return max(1, min(maxCards, fitting))
    }

    /// Slot 0 is the anchor at the bottom (the oldest card).
    static func origin(slot: Int, visibleFrame: CGRect, cardSize: CGSize, onLeft: Bool) -> CGPoint {
        let x = onLeft ? visibleFrame.minX + sideMargin : visibleFrame.maxX - cardSize.width - sideMargin
        let y = visibleFrame.minY + bottomMargin + CGFloat(slot) * (cardSize.height + gap)
        let highest = visibleFrame.maxY - cardSize.height - topMargin
        return CGPoint(x: x, y: max(visibleFrame.minY, min(y, highest)))
    }
}

/// Non-activating panel: the overlay appears without stealing focus from the
/// app the user is working in — they keep typing, the thumbnail just slides
/// in. Keyboard shortcuts engage on hover, when the panel takes key status
/// without activating the app (the Spotlight mechanism). Internal so tests
/// can photograph it; the app opens it through `QuickAccessOverlay.show`.
@MainActor
final class QuickAccessWindow: NSPanel, ShotnixCommandClosable {

    /// Keep strong refs so ARC doesn't deallocate while visible.
    private static var openWindows: [QuickAccessWindow] = []
    private static let previewSize = CGSize(width: 240, height: 150)
    private static let toolbarHeight: CGFloat = 38
    private static let progressHeight: CGFloat = 2

    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    private let historyItem: HistoryItem
    private let historyManager: HistoryManager
    private let image: NSImage
    private var anchor: CGPoint?
    private weak var timeoutProgressLayer: CALayer?
    private var isHovered = false
    private var mouseInsideOverlay = false
    private var swipeAccumX: CGFloat = 0

    init(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager, anchor: CGPoint? = nil) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager
        self.anchor = anchor

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.previewSize.width,
                                height: Self.previewSize.height + Self.toolbarHeight + Self.progressHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The action bar uses the same dark appearance as the other capture HUDs.
        staysDark()
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buildContent()
        positionOverlay()
        installEventMonitors()
    }

    override var canBecomeKey: Bool { true }

    func closeFromCommand() {
        dismissAction()
    }

    // MARK: – Keyboard (direct override — works when window IS key)

    override func keyDown(with event: NSEvent) {
        guard !isClosing else { return }
        _ = handleShortcut(event)
    }

    /// ⌘C / ⌘S / ⌘E / Esc. Letters go through ShortcutKeyMatching so they
    /// work on Cyrillic, Greek, and other non-Latin layouts too.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            dismissAction()
            return true
        }
        // Caps Lock (and the fn/keypad bits) don't change which shortcut it is.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad]) == .command else { return false }
        switch ShortcutKeyMatching.latinLetter(for: event) {
        case "c": copyAction()
        case "s": saveAction()
        case "e": editAction()
        default: return false
        }
        return true
    }

    // MARK: – Event Monitors (bypass view hierarchy entirely)

    private func installEventMonitors() {
        // Keyboard: catches ⌘C/⌘S/⌘E/Escape at the app level — no key window needed
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            // Only handle if mouse is over our window
            guard self.frame.contains(NSEvent.mouseLocation) else { return event }
            return self.handleShortcut(event) ? nil : event
        }

        // Global mouse: hover tracking while the app is inactive. On enter the
        // nonactivating panel takes key status for ⌘C/⌘S/⌘E/Esc WITHOUT
        // activating the app; on exit it hands keyboard focus straight back to
        // whatever app the user is working in.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            guard inside != self.mouseInsideOverlay else { return }
            self.mouseInsideOverlay = inside
            DispatchQueue.main.async {
                self.setHovered(inside)
                if inside {
                    self.makeKeyAndOrderFront(nil)
                    self.makeFirstResponder(self)
                } else if self.isKeyWindow {
                    // Ordering out drops key status back to the user's app;
                    // both calls land in one transaction, so no visible blink.
                    self.orderOut(nil)
                    self.orderFrontRegardless()
                }
            }
        }

        // Local mouse: keeps window key while hovering + tracks hover state
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            self.setHovered(inside)
            if inside && !self.isKeyWindow {
                self.makeKey()
            }
            return event
        }

        // Swipe-to-dismiss: trackpad swipe toward nearest screen edge closes overlay
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            guard self.frame.contains(NSEvent.mouseLocation) else { return event }

            self.swipeAccumX += event.scrollingDeltaX
            let threshold: CGFloat = 60
            if abs(self.swipeAccumX) > threshold {
                let direction = self.swipeAccumX > 0 ? CGFloat(1) : CGFloat(-1)
                self.swipeAccumX = 0
                self.swipeDismiss(direction: direction)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let view = contentView else { return }
        ShotnixContextMenu.show(
            sections: [
                ShotnixMenuSection(id: "quick.primary", title: L("Capture"), actions: [
                    ShotnixMenuAction(id: "quick.copy", title: L("Copy"), symbolName: "doc.on.doc", shortcut: "⌘C", role: .primary) { [weak self] in self?.copyAction() },
                    ShotnixMenuAction(id: "quick.copytext", title: L("Copy Text"), symbolName: "text.viewfinder") { [weak self] in self?.copyTextAction() },
                    ShotnixMenuAction(id: "quick.save", title: L("Save"), symbolName: "square.and.arrow.down", shortcut: "⌘S") { [weak self] in self?.saveAction() },
                    ShotnixMenuAction(id: "quick.edit", title: L("Edit"), symbolName: "pencil", shortcut: "⌘E") { [weak self] in self?.editAction() },
                    ShotnixMenuAction(id: "quick.pin", title: L("Pin"), symbolName: "pin") { [weak self] in self?.pinAction() },
                ]),
                ShotnixMenuSection(id: "quick.manage", title: L("Manage"), actions: [
                    ShotnixMenuAction(id: "quick.delete", title: L("Delete"), symbolName: "trash", role: .destructive) { [weak self] in self?.deleteAction() },
                    ShotnixMenuAction(id: "quick.close", title: L("Close"), symbolName: "xmark") { [weak self] in self?.dismissAction() },
                ])
            ],
            at: event,
            in: view
        )
    }

    /// Renders the capture scaled to FILL the given point size — center-
    /// cropping overflow and upscaling small captures — with high-quality
    /// interpolation. The GPU's default layer scaling softens small text;
    /// pre-scaling on the CPU keeps UI captures (menus, dialogs) crisp.
    /// Preserves the source's RGB color space so ICC-correct captures don't
    /// shift. Falls back to the original image on any failure.
    private func crispPreviewImage(for source: NSImage, filling size: NSSize) -> NSImage {
        guard size.width > 1, size.height > 1, let cgImage = source.bestCGImage else { return source }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetWidth = Int((size.width * scale).rounded())
        let targetHeight = Int((size.height * scale).rounded())
        guard targetWidth > 0, targetHeight > 0 else { return source }
        let colorSpace = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .high
        let fillScale = max(CGFloat(targetWidth) / CGFloat(max(cgImage.width, 1)), CGFloat(targetHeight) / CGFloat(max(cgImage.height, 1)))
        let drawWidth = CGFloat(cgImage.width) * fillScale
        let drawHeight = CGFloat(cgImage.height) * fillScale
        context.draw(cgImage, in: CGRect(
            x: (CGFloat(targetWidth) - drawWidth) / 2,
            y: (CGFloat(targetHeight) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        ))
        guard let scaled = context.makeImage() else { return source }
        return NSImage(cgImage: scaled, size: size)
    }

    private func buildContent() {
        let container = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.55
        container.layer?.shadowRadius = 30
        container.layer?.shadowOffset = CGSize(width: 0, height: -10)
        contentView = container

        // Clip subviews so content respects corner radius while shadow remains visible
        let clipView = NSView(frame: container.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 12
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        // Subtle dark tint — frames content, visible at rounded corners and behind image
        clipView.layer?.backgroundColor = ShotnixColors.overlayTint.hudCGColor
        container.addSubview(clipView)

        // White border — primary edge definition on light wallpapers (shadow handles dark)
        let borderView = PassthroughView(frame: container.bounds)
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 12
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.borderWidth = 1.5
        borderView.layer?.borderColor = ShotnixColors.overlayBorder.hudCGColor
        container.addSubview(borderView)

        // The whole preview is the drag target. Actions live below it.
        let thumbFrame = NSRect(origin: CGPoint(x: 0, y: Self.toolbarHeight + Self.progressHeight),
                                size: Self.previewSize)
        let thumb = DraggableImageView(frame: thumbFrame)
        thumb.image = crispPreviewImage(for: image, filling: thumbFrame.size)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.imageAlignment = .alignCenter
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = ShotnixColors.overlayContainerFill.hudCGColor
        thumb.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        thumb.dragImage = image
        thumb.dragFileProvider = { [weak self] in self?.makeDragFile() }
        thumb.setAccessibilityLabel(L("Screenshot thumbnail"))
        thumb.setAccessibilityHelp(L("Double-click to edit, or drag into another app. Command-C copies, Command-S saves, Escape dismisses."))
        thumb.onDoubleClick = { [weak self] in self?.editAction() }
        thumb.onDragStarted = { [weak self] in self?.dismissTimer?.invalidate() }
        thumb.onDragCompleted = { [weak self] in self?.animatedClose() }
        clipView.addSubview(thumb)

        clipView.addSubview(makeToolbar())

        // Progress bar at the very bottom — thin, bright accent line
        let timeout = Settings.overlayTimeout
        if timeout > 0 {
            let progressBg = NSView(frame: NSRect(x: 0, y: 0, width: Self.previewSize.width, height: Self.progressHeight))
            progressBg.wantsLayer = true
            progressBg.layer?.backgroundColor = ShotnixColors.progressBackground.hudCGColor
            clipView.addSubview(progressBg)

            let progressFill = NSView(frame: progressBg.bounds)
            progressFill.wantsLayer = true
            progressFill.layer?.backgroundColor = NSColor.controlAccentColor.hudCGColor
            progressFill.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
            progressFill.layer?.position = CGPoint(x: 0, y: Self.progressHeight / 2)
            progressBg.addSubview(progressFill)
            timeoutProgressLayer = progressFill.layer

            animateTimeoutProgress(duration: timeout)

            dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.closeAfterTimeout() }
            }
        }
    }

    private func makeToolbar() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: Self.progressHeight, width: Self.previewSize.width, height: Self.toolbarHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = ShotnixColors.overlayContainerFill.withAlphaComponent(1).hudCGColor

        let actions: [(symbol: String, label: String, selector: Selector)] = [
            ("doc.on.doc", L("Copy image to clipboard"), #selector(copyAction)),
            ("square.and.arrow.down", L("Save screenshot to disk"), #selector(saveAction)),
            ("pencil", L("Edit"), #selector(editAction)),
            ("text.viewfinder", L("Copy recognized text (OCR)"), #selector(copyTextAction)),
            ("pin", L("Pin"), #selector(pinAction)),
            ("trash", L("Delete"), #selector(deleteAction)),
            ("xmark", L("Close"), #selector(dismissAction)),
        ]
        let symbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let buttonWidth: CGFloat = 30
        let gap: CGFloat = 2
        let groupGap: CGFloat = 6
        let rowWidth = CGFloat(actions.count) * buttonWidth + CGFloat(actions.count - 1) * gap + groupGap
        var x = (bar.bounds.width - rowWidth) / 2
        for (index, action) in actions.enumerated() {
            if index == 5 {
                let divider = PassthroughView(frame: NSRect(x: x + 2, y: 11, width: 1, height: 16))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = ShotnixColors.overlayBorder.hudCGColor
                bar.addSubview(divider)
                x += groupGap
            }
            let button = OverlayToolbarButton(frame: NSRect(x: x, y: 3, width: buttonWidth, height: 32))
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbol)
            button.setAccessibilityLabel(action.label)
            button.toolTip = action.label
            button.target = self
            button.action = action.selector
            bar.addSubview(button)
            x += buttonWidth + gap
        }
        return bar
    }

    /// Pauses the dismiss timer while the pointer is over the panel.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered

        // Pause/resume auto-dismiss timer on hover
        if hovered {
            dismissTimer?.invalidate()
            timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        } else {
            let remaining = Settings.overlayTimeout
            if remaining > 0 {
                animateTimeoutProgress(duration: remaining)
                dismissTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.closeAfterTimeout() }
                }
            }
        }
    }

    private func animateTimeoutProgress(duration: TimeInterval) {
        guard let layer = timeoutProgressLayer else { return }
        layer.removeAnimation(forKey: "timeoutProgress")
        layer.transform = CATransform3DIdentity
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = 1.0
        shrink.toValue = 0.0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "timeoutProgress")
    }

    /// The pointer's display, the captured display, or the main display.
    private var captureScreen: NSScreen? {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            return screen
        }
        if let rect = historyItem.captureRect?.cgRect,
           let screen = NSScreen.screenContaining(rect: rect) {
            return screen
        }
        return NSScreen.main
    }

    // MARK: – Stack layout (multiple captures pile into a column)

    /// Origin for a given stack slot on this window's screen. Slot 0 is the
    /// anchor at the bottom (the oldest card); new captures land on TOP of
    /// the pile, and cards drop down a slot when one below them leaves.
    private func slotOrigin(index: Int) -> NSPoint? {
        guard let screen = captureScreen else { return nil }
        return QuickAccessStackLayout.origin(slot: index, visibleFrame: screen.visibleFrame, cardSize: frame.size, onLeft: Settings.overlayOnLeft)
    }

    /// How many cards this window's screen can stack without the column
    /// reaching the menu bar.
    private var stackCapacity: Int {
        guard let screen = captureScreen else { return QuickAccessStackLayout.maxCards }
        return QuickAccessStackLayout.capacity(visibleFrame: screen.visibleFrame, cardHeight: frame.height)
    }

    private var screenKey: CGDirectDisplayID {
        (captureScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// Slides every open card to its slot: oldest at the bottom anchor,
    /// newer cards on top. Runs when a card leaves — the cards above drop
    /// down into the freed space. (Arrivals don't move anyone: the newcomer
    /// simply lands on top of the pile.)
    private static func relayoutStacks(animated: Bool) {
        let active = openWindows.filter { !$0.isClosing && $0.anchor == nil }
        let byScreen = Dictionary(grouping: active, by: { $0.screenKey })

        for (_, group) in byScreen {
            // openWindows is oldest→newest; oldest keeps the bottom anchor.
            for (index, window) in group.enumerated() {
                guard let target = window.slotOrigin(index: index),
                      window.frame.origin != target else { continue }
                if animated {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.35
                        // Fast start, soft landing — the "drop" feel.
                        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                        // NSWindow only animates `frame` — animator().setFrameOrigin
                        // is silently swallowed (not an animatable key).
                        window.animator().setFrame(NSRect(origin: target, size: window.frame.size), display: true)
                    }, completionHandler: {
                        // A card that moved under (or away from) a stationary
                        // cursor gets no mouse event — re-evaluate hover so
                        // its dismiss timer pauses/resumes correctly.
                        Task { @MainActor in
                            guard !window.isClosing else { return }
                            window.setHovered(window.frame.contains(NSEvent.mouseLocation))
                        }
                    })
                } else {
                    window.setFrameOrigin(target)
                }
            }
        }
    }

    /// Keeps each screen's pile manageable — beyond the cap (fewer cards on
    /// a small screen), the oldest card animates out (its history entry is
    /// untouched).
    private static func enforceStackLimit() {
        let active = openWindows.filter { !$0.isClosing }
        let byScreen = Dictionary(grouping: active, by: { $0.screenKey })
        for (_, group) in byScreen {
            let capacity = group.last?.stackCapacity ?? QuickAccessStackLayout.maxCards
            guard group.count > capacity else { continue }
            for window in group.prefix(group.count - capacity) {
                window.animatedClose()
            }
        }
    }

    private func positionOverlay() {
        if let anchor, let screen = captureScreen {
            setFrameOrigin(QuickAccessPointerLayout.origin(near: anchor, visibleFrame: screen.visibleFrame, cardSize: frame.size))
        } else {
            // The newcomer lands above the existing corner cards.
            let key = screenKey
            let slot = Self.openWindows.filter { !$0.isClosing && $0.anchor == nil && $0.screenKey == key }.count
            guard let origin = slotOrigin(index: slot) else { return }
            setFrameOrigin(origin)
        }
        // Start at final position (slide-up is handled by scale spring, not position offset)
        alphaValue = 0

        // Order front WITHOUT activating or taking key — the user keeps typing
        // in their app. Hover engages keyboard via the nonactivating panel.
        orderFrontRegardless()
        setHovered(frame.contains(NSEvent.mouseLocation))

        // Scale entrance: start at 92% and spring to 100%
        if let layer = contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.position = CGPoint(x: frame.width / 2, y: 0)

            let scaleAnim = CASpringAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.92
            scaleAnim.toValue = 1.0
            scaleAnim.mass = 1.0
            scaleAnim.stiffness = 300
            scaleAnim.damping = 18
            scaleAnim.initialVelocity = 0
            scaleAnim.duration = scaleAnim.settlingDuration
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            layer.add(scaleAnim, forKey: "entranceScale")
        }

        // Fade in (scale spring handles the motion)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Swipe-dismiss: slide overlay off-screen toward the swipe direction
    private func swipeDismiss(direction: CGFloat) {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()
        // Cards above drop down while this one slides away.
        Self.relayoutStacks(animated: true)

        let slideDistance: CGFloat = frame.width + 40
        let targetX = frame.origin.x + (direction * slideDistance)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            // setFrame, not setFrameOrigin: origin alone isn't an animatable
            // NSWindow key, so the slide silently never happened.
            self.animator().setFrame(NSRect(x: targetX, y: self.frame.origin.y, width: self.frame.width, height: self.frame.height), display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    private var isClosing = false
    private var skipPolicyReset = false

    private func animatedClose() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()
        // Cards above drop down while this one fades out.
        Self.relayoutStacks(animated: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            if let layer = self.contentView?.layer {
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.toValue = 0.95
                scaleAnim.duration = 0.12
                scaleAnim.fillMode = .forwards
                scaleAnim.isRemovedOnCompletion = false
                layer.add(scaleAnim, forKey: "exitScale")
            }
            
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    private var didCleanup = false

    private func forceCleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        removeEventMonitors()
        orderOut(nil)
        QuickAccessWindow.openWindows.removeAll { $0 === self }
        // Idempotent safety net: close paths relayout at close start, but a
        // window torn down without animating (e.g. app-level cleanup) still
        // frees its slot for the cards above.
        QuickAccessWindow.relayoutStacks(animated: true)
        // Restore background-only policy so app doesn't appear in Cmd-Tab
        // (skip when transitioning to another window like editor or pin)
        if QuickAccessWindow.openWindows.isEmpty && !skipPolicyReset {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    // MARK: – Actions

    @objc private func copyAction() {
        // The encode runs off the main thread; the checkmark waits for it.
        ImageExporter.copyToClipboardAsync(image: image) { [weak self] copied in
            guard let self, !self.isClosing else { return }
            guard copied else {
                ToastWindow.show(message: L("Could not copy the screenshot"), on: self.captureScreen)
                return
            }
            self.showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
        }
    }

    // MARK: – Save automatically

    enum AutoSaveState: Equatable {
        case none
        case writing
        case saved(URL)
    }

    /// What Save automatically did with this capture. Once it wrote a
    /// file, Save points at that file instead of writing a second copy,
    /// and Delete moves it to the Trash along with the History entry.
    var autoSaveState = AutoSaveState.none
    private var saveAfterAutoSave = false
    private var deleteAfterAutoSave = false

    func autoSaveFinished(_ url: URL?) {
        autoSaveState = url.map(AutoSaveState.saved) ?? .none
        if deleteAfterAutoSave {
            deleteAfterAutoSave = false
            trashAutoSavedFile()
        } else if saveAfterAutoSave {
            saveAfterAutoSave = false
            saveAction()
        }
    }

    private func trashAutoSavedFile() {
        guard case .saved(let url) = autoSaveState else { return }
        autoSaveState = .none
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @objc private func saveAction() {
        switch autoSaveState {
        case .saved(let url):
            confirmSaved(url)
            return
        case .writing:
            saveAfterAutoSave = true
            return
        case .none:
            break
        }
        let directory = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        ImageExporter.autoSave(image: image, in: directory) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                ToastWindow.show(
                    message: ImageExporter.autoSaveFailureMessage(for: error, directory: directory),
                    duration: 6,
                    on: self.captureScreen,
                    action: { PreferencesWindowController.shared.show(tab: .screenshots) }
                )
            case .success(let savedURL):
                self.confirmSaved(savedURL)
            }
        }
    }

    private func confirmSaved(_ savedURL: URL) {
        showConfirmation(icon: "checkmark") { [weak self] in
            guard let self else { return }
            self.animatedClose()
            // Clickable toast — reveals the file actually written (its
            // name may have gained " 2", or .png for an unwritable WebP).
            ToastWindow.show(
                message: QuickAccessOverlay.savedMessage(for: savedURL),
                duration: 3.0,
                on: self.captureScreen,
                action: { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
            )
        }
    }

    /// The drag hands over the history PNG itself (a clone: instant, tags and
    /// metadata intact) named for when the capture was taken. Only a drag in
    /// the split second before that file lands encodes a fresh copy.
    private func makeDragFile() -> URL? {
        let name = ImageExporter.captureName(for: historyItem.createdAt)
        if let stored = historyManager.storedImageURL(for: historyItem) {
            return ImageExporter.dragFile(copying: stored, named: name)
        }
        guard let png = ImageExporter.pngData(from: image) else { return nil }
        return ImageExporter.dragFile(data: png, named: name)
    }

    @objc private func copyTextAction() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await OCREngine.recognize(in: self.image)
                // Only touch the pasteboard when there is actual text —
                // never clobber the user's clipboard for an empty result.
                if result.isEmpty {
                    ToastWindow.show(message: L("No text found in this selection"), on: self.captureScreen)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    OCRResultWindow.showCopiedToast(for: result, on: self.captureScreen)
                    self.animatedClose()
                }
            } catch {
                print("[Shotnix] OCR failed: \(error)")
                ToastWindow.show(message: L("Text recognition failed"), on: self.captureScreen)
            }
        }
    }

    /// Flash a confirmation icon over the thumbnail before closing
    private func showConfirmation(icon: String, then completion: @escaping () -> Void) {
        guard let clip = contentView?.subviews.first else { completion(); return }
        let size: CGFloat = 36
        let badge = NSImageView(frame: NSRect(
            x: (clip.bounds.width - size) / 2,
            y: Self.toolbarHeight + Self.progressHeight + (Self.previewSize.height - size) / 2,
            width: size, height: size
        ))
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        badge.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badge.layer?.cornerRadius = size / 2
        badge.layer?.cornerCurve = .continuous
        badge.alphaValue = 0
        let popStart = badge.layer?.scaledAboutCenter(0.7) ?? CATransform3DIdentity
        badge.layer?.transform = popStart
        clip.addSubview(badge)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            badge.animator().alphaValue = 1
            
            // Pops from its center (a plain scale grows from a corner).
            let scaleAnim = CABasicAnimation(keyPath: "transform")
            scaleAnim.fromValue = NSValue(caTransform3D: popStart)
            scaleAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scaleAnim.duration = 0.12
            badge.layer?.add(scaleAnim, forKey: "pop")
            badge.layer?.transform = CATransform3DIdentity
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion()
            }
        })
    }

    @objc private func editAction() {
        skipPolicyReset = true
        animatedClose()
        // Open after a short delay so cleanup doesn't kill activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image, historyItem, historyManager] in
            AnnotationWindowController.open(image: image, historyItem: historyItem, historyManager: historyManager)
        }
    }

    @objc private func pinAction() {
        skipPolicyReset = true
        showConfirmation(icon: "pin") { [weak self] in
            guard let self else { return }
            self.animatedClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image = self.image, rect = self.historyItem.captureRect?.cgRect] in
                PinnedWindow.pin(image: image, at: rect)
            }
        }
    }

    @objc private func deleteAction() {
        historyManager.delete(historyItem)
        if autoSaveState == .writing {
            deleteAfterAutoSave = true
        } else {
            trashAutoSavedFile()
        }
        animatedClose()
    }

    @objc private func dismissAction() {
        animatedClose()
    }

    /// The card left on its own, so the shot may look gone to someone used
    /// to finding a file afterwards. The first time, say where it went.
    private func closeAfterTimeout() {
        guard !isClosing else { return }
        animatedClose()
        guard QuickAccessOverlay.shouldShowHistoryTip() else { return }
        Settings.didShowHistoryTip = true
        ToastWindow.show(
            message: L("Kept in History, not saved as a file. Click to open History, or turn on Save automatically in Settings."),
            duration: 8,
            on: captureScreen,
            action: { [historyManager] in HistoryPanelController.shared.show(historyManager: historyManager) }
        )
    }

    func show() {
        if anchor != nil {
            // Keep the newest card at the pointer and move overlapping older cards into the stack.
            for window in Self.openWindows where !window.isClosing && window.anchor != nil && window.frame.intersects(frame) {
                window.anchor = nil
            }
        }
        QuickAccessWindow.openWindows.append(self)
        Self.relayoutStacks(animated: true)
        Self.enforceStackLimit()
        // VoiceOver users otherwise get no sign the capture happened.
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: L("Screenshot captured"), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}

// MARK: – Draggable thumbnail (drag-and-drop to Finder and other apps)

@MainActor
private final class DraggableImageView: NSImageView, NSDraggingSource {

    var dragImage: NSImage?
    /// Supplies the file handed to the drag (see ImageExporter.dragFile).
    var dragFileProvider: (() -> URL?)?
    var onDoubleClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragCompleted: (() -> Void)?

    private var dragOrigin: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let dragImg = dragImage else { return }
        let current = event.locationInWindow
        let dx = abs(current.x - origin.x)
        let dy = abs(current.y - origin.y)
        guard dx > 3 || dy > 3 else { return }

        dragOrigin = nil

        guard let fileURL = dragFileProvider?() else { return }

        onDragStarted?()

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: dragImg)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in
            self?.onDragCompleted?()
        }
    }
}

// MARK: – Content view that accepts first mouse + right-click

@MainActor
private final class OverlayContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class OverlayToolbarButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .white
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            mouseEntered(with: event)
        } else {
            mouseExited(with: event)
        }
    }
}
