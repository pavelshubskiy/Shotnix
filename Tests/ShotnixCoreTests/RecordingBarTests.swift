import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The recording bar before Record: usable from the keyboard and VoiceOver,
/// Return records, and pressing Record changes no settings.
@MainActor
final class RecordingBarTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.RecordingBar.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        super.tearDown()
    }

    private func makeBar(target: RecordingTargetKind = .area, isPermissionGranted: @escaping (RecordingPermission) -> Bool = { _ in true }, onPermissions: @escaping () -> Void = {}, onRecord: @escaping () -> Void = {}) throws -> RecordingControlsWindow {
        let screen = try XCTUnwrap(NSScreen.main)
        let bar = RecordingControlsWindow(screen: screen, target: target, anchor: .zero, startHandler: onRecord,
                                          isPermissionGranted: isPermissionGranted, permissionsHandler: onPermissions, closeHandler: {})
        bar.setFrameOrigin(RecordingUITestSupport.offscreen)
        bar.orderFrontRegardless()
        return bar
    }

    private func toggles(in bar: NSWindow) throws -> [NSButton] {
        let root = try XCTUnwrap(bar.contentView)
        return RecordingUITestSupport.allSubviews(of: root)
            .compactMap { $0 as? NSButton }
            .filter { $0.accessibilityRole() == .checkBox }
    }

    func testTogglesWorkFromKeyboardVoiceOverAndMouse() throws {
        let bar = try makeBar()
        defer { bar.closeControls() }
        let all = try toggles(in: bar)
        XCTAssertEqual(Set(all.compactMap { $0.accessibilityLabel() }), ["Record system audio", "Record microphone", "Show cursor", "Record camera"])
        let systemAudio = try XCTUnwrap(all.first { $0.accessibilityLabel() == "Record system audio" })
        XCTAssertEqual(systemAudio.accessibilityValue() as? NSNumber, 0)

        // Space with keyboard focus goes through performClick.
        systemAudio.performClick(nil)
        XCTAssertEqual(systemAudio.accessibilityValue() as? NSNumber, 1)
        XCTAssertTrue(Settings.recordingSystemAudio)

        // VoiceOver presses the button.
        XCTAssertTrue(systemAudio.accessibilityPerformPress())
        XCTAssertEqual(systemAudio.accessibilityValue() as? NSNumber, 0)
        XCTAssertFalse(Settings.recordingSystemAudio)

        // A mouse click toggles exactly once.
        RecordingUITestSupport.click(systemAudio, in: bar)
        XCTAssertTrue(Settings.recordingSystemAudio)
        XCTAssertEqual(systemAudio.accessibilityValue() as? NSNumber, 1)
    }

    func testReturnContinuesWithoutStoringDefaults() throws {
        var recorded = 0
        let bar = try makeBar { recorded += 1 }
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("recording") }
        let returnKey = try XCTUnwrap(RecordingUITestSupport.keyDown("\r", keyCode: 36, in: bar))
        XCTAssertTrue(bar.performKeyEquivalent(with: returnKey))
        XCTAssertEqual(recorded, 1)
        // Saving the menus' values on Record is what kept most people on the
        // old 30 fps default.
        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("recording") }
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
        XCTAssertNil(defaults.object(forKey: "recordingFPS"))
        XCTAssertNil(defaults.object(forKey: "recordingQuality"))
    }

    func testNewPanelKeepsRequestedSourceAndRoutesMissingPermission() throws {
        var permissionVisits = 0
        let blocked = try makeBar(isPermissionGranted: { $0 != .camera }, onPermissions: { permissionVisits += 1 })
        let camera = try XCTUnwrap(toggles(in: blocked).first { $0.accessibilityLabel() == "Record camera" })
        camera.performClick(nil)
        XCTAssertEqual(permissionVisits, 1)
        XCTAssertTrue(Settings.recordingCamera)
        XCTAssertFalse(blocked.isVisible)

        let next = try makeBar(isPermissionGranted: { $0 != .camera }, onPermissions: { permissionVisits += 1 }) {
            XCTFail("A remembered camera without access must go to permissions")
        }
        defer { next.closeControls() }
        let remembered = try XCTUnwrap(toggles(in: next).first { $0.accessibilityLabel() == "Record camera" })
        XCTAssertEqual(remembered.accessibilityValue() as? NSNumber, 1)
        let proceed = try XCTUnwrap(RecordingUITestSupport.button(labelled: "Continue", in: next))
        proceed.performClick(nil)
        XCTAssertEqual(permissionVisits, 2)
    }

    func testOptionsAreReachable() throws {
        let bar = try makeBar()
        defer { bar.closeControls() }
        let options = try XCTUnwrap(RecordingUITestSupport.button(labelled: "More recording options", in: bar))
        XCTAssertFalse(options.isHidden)
        XCTAssertEqual(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Continue", in: bar)).keyEquivalent, "\r")
    }

    func testOptionsMenuOffersWhatARecordingHides() throws {
        let bar = try makeBar(target: .fullscreen)
        defer { bar.closeControls() }
        func item(_ title: String) -> NSMenuItem? { bar.optionsMenu().items.first { $0.title == title } }

        let header = try XCTUnwrap(item("Hide While Recording"))
        XCTAssertFalse(header.isEnabled, "a heading, like Camera")
        let desktop = try XCTUnwrap(item("Desktop Icons"))
        XCTAssertEqual(desktop.state, .off)
        XCTAssertEqual(desktop.indentationLevel, 1)
        XCTAssertFalse((desktop.toolTip ?? "").isEmpty)
        _ = desktop.target?.perform(desktop.action)
        XCTAssertTrue(Settings.recordingHidesDesktopIcons)
        XCTAssertEqual(item("Desktop Icons")?.state, .on, "the menu is built fresh each time it opens")
        _ = desktop.target?.perform(desktop.action)
        XCTAssertFalse(Settings.recordingHidesDesktopIcons)

        // Before macOS 26 there's no leaving the menu bar's icons out.
        guard RecordingMenuBar.controlCenterHostsEveryItem else {
            XCTAssertNil(item("Menu Bar Icons"))
            return
        }
        let menuBar = try XCTUnwrap(item("Menu Bar Icons"))
        XCTAssertEqual(menuBar.state, .off)
        _ = menuBar.target?.perform(menuBar.action)
        XCTAssertTrue(Settings.recordingHidesMenuBarIcons)
        XCTAssertFalse(Settings.recordingHidesDesktopIcons, "one doesn't switch the other")
        XCTAssertEqual(item("Menu Bar Icons")?.state, .on)
    }

    func testAnAreaRecordingOffersThemAndAWindowRecordingDoesNot() throws {
        let area = try makeBar(target: .area)
        defer { area.closeControls() }
        XCTAssertNotNil(area.optionsMenu().items.first { $0.title == "Desktop Icons" })

        // A window recording shows neither the menu bar nor the desktop.
        let window = try makeBar(target: .window)
        defer { window.closeControls() }
        let titles = window.optionsMenu().items.map(\.title)
        XCTAssertFalse(titles.contains("Hide While Recording"))
        XCTAssertFalse(titles.contains("Menu Bar Icons"))
        XCTAssertFalse(titles.contains("Desktop Icons"))
        XCTAssertTrue(titles.contains("Countdown"), "the rest of the menu is there")
        // No two separators in a row where the section would have been.
        let items = window.optionsMenu().items
        for (first, second) in zip(items, items.dropFirst()) {
            XCTAssertFalse(first.isSeparatorItem && second.isSeparatorItem)
        }
    }

    func testRendersTheBar() throws {
        Settings.recordingMicrophone = true
        Settings.recordingSystemAudio = true
        let bar = try makeBar()
        defer { bar.closeControls() }
        try RecordingUITestSupport.writeSnapshot(of: bar, name: "recording-bar")
    }

    func testRendersTheRecordingSettings() throws {
        Settings.recordingCountdownSeconds = 3
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 1340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = TestAppearance.appearance
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        // The Preferences window draws a dark stage behind the panes.
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 1340))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = ShotnixColors.editorStageTop.cgColor
        let hosting = NSHostingView(rootView: RecordingSettingsView())
        hosting.frame = stage.bounds
        stage.addSubview(hosting)
        window.contentView = stage
        window.setFrameOrigin(RecordingUITestSupport.offscreen)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RecordingUITestSupport.spinRunLoop(0.2)
        try RecordingUITestSupport.writeSnapshot(of: window, name: "recording-settings")
    }

    /// The countdown before a recording can be called off (Esc, a click, or
    /// the Stop Recording shortcut, which cancels setup).
    func testRecordingCountdownCanBeCancelled() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        var outcome: Bool?
        let countdown = CountdownWindow(seconds: 3, on: screen) { finished in outcome = finished }
        countdown.start()
        countdown.cancel()
        RecordingUITestSupport.spinRunLoop(0.2)
        XCTAssertEqual(outcome, false)
        XCTAssertFalse(countdown.isVisible)
        countdown.cancel()
        RecordingUITestSupport.spinRunLoop(0.1)
        XCTAssertEqual(outcome, false, "reported once")
    }

}
