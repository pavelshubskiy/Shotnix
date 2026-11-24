import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI
import ServiceManagement

enum PreferencesTab: Int, CaseIterable {
    case general = 0
    case shortcuts = 1
    case screenshots = 2
    case recording = 3
    case about = 4

    var title: String {
        switch self {
        case .general: return L("General")
        case .shortcuts: return L("Shortcuts")
        case .screenshots: return L("Screenshots")
        case .recording: return L("Recording")
        case .about: return L("About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .screenshots: return "camera"
        case .recording: return "record.circle"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class PreferencesSelectionModel: ObservableObject {
    @Published var selectedTab: PreferencesTab = .general
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    
    static let shared = PreferencesWindowController()

    private let selection = PreferencesSelectionModel()
    
    private init() {
        let hostingController = NSHostingController(rootView: PreferencesRootView(selection: selection))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L("Shotnix Preferences")
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ShotnixTheme.stageTopColor
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 560, height: 620))
        window.minSize = NSSize(width: 520, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        window.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func show(tab: PreferencesTab = .general) {
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)

        selection.selectedTab = tab
        window?.makeKeyAndOrderFront(nil)
    }
    
    func windowWillClose(_ notification: Notification) {
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: - SwiftUI Views

struct PreferencesRootView: View {
    @ObservedObject var selection: PreferencesSelectionModel

    var body: some View {
        ZStack {
            ShotnixHUDBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                PreferencesTabStrip(selectedTab: $selection.selectedTab)

                Divider()
                    .overlay(ShotnixTheme.ink(0.08))

                Group {
                    switch selection.selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .shortcuts:
                        ShortcutsSettingsView()
                    case .screenshots:
                        ScreenshotsSettingsView()
                    case .recording:
                        RecordingSettingsView()
                    case .about:
                        AboutSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 620)
    }
}

struct PreferencesTabStrip: View {
    @Binding var selectedTab: PreferencesTab

    var body: some View {
        GeometryReader { proxy in
            let available = max(320, proxy.size.width - 118)
            let tabWidth = Self.tabWidth(fitting: available)
            let count = CGFloat(PreferencesTab.allCases.count)
            HStack(spacing: 8) {
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    PreferencesTabButton(
                        tab: tab,
                        width: tabWidth,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
            }
            .frame(width: min(count * tabWidth + (count - 1) * 8, available))
            .position(x: proxy.size.width / 2, y: 46)
        }
        .frame(height: 86)
        .background(ShotnixTheme.shade(0.12))
    }

    /// 74 pt per tab as designed. When a translated title needs more, every
    /// tab widens as far as the window allows (titles still shrink to fit).
    static func tabWidth(fitting available: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let widest = PreferencesTab.allCases
            .map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        let count = CGFloat(PreferencesTab.allCases.count)
        let room = (available - 8 * (count - 1)) / count
        return max(74, min(widest + 4, room))
    }
}

private struct PreferencesTabButton: View {
    let tab: PreferencesTab
    let width: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 20)

                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : ShotnixTheme.ink(0.62))
            .frame(width: width, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? ShotnixTheme.ink(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

private struct PreferencesPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(maxWidth: 560, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct PreferencesPaneWithFooter<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            PreferencesPane {
                content
            }

            Divider()
                .overlay(ShotnixTheme.ink(0.08))

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShotnixTheme.shade(0.18))
        }
    }
}

struct PreferenceSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ShotnixTheme.ink(0.86))

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShotnixTheme.ink(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ShotnixTheme.ink(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferenceRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShotnixTheme.ink(0.88))
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ShotnixTheme.ink(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            trailing
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: detail == nil ? 44 : 50, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

struct PreferenceDivider: View {
    var body: some View {
        Divider()
            .overlay(ShotnixTheme.ink(0.08))
            .padding(.leading, 12)
    }
}

struct PreferenceFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ShotnixTheme.ink(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

struct PreferenceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

struct PreferenceMenuSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PreferenceOption<Value>]
    var width: CGFloat = 156
    var isEnabled = true

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? options.first?.title ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 6)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ShotnixTheme.ink(isEnabled ? 0.44 : 0.22))
            }
            .foregroundStyle(ShotnixTheme.ink(isEnabled ? 0.86 : 0.34))
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ShotnixTheme.ink(isEnabled ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ShotnixTheme.ink(isEnabled ? 0.10 : 0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

extension PreferenceMenuSelector {
    /// Wide enough for the longest title, as a pop-up button sizes itself to
    /// its menu, and never narrower than the other selectors.
    static func width(fitting options: [PreferenceOption<Value>], minimum: CGFloat = 156) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let widest = options.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        // The padding, the gaps and spacer before the chevron, the chevron.
        return max(minimum, widest + 52)
    }
}

struct PreferenceSegmentedSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PreferenceOption<Value>]
    var width: CGFloat = 156

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(option.value == selection ? Color.white : ShotnixTheme.ink(0.58))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option.value == selection ? Color.accentColor.opacity(0.95) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(ShotnixTheme.ink(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ShotnixTheme.ink(0.10), lineWidth: 1)
        )
    }
}

struct GeneralSettingsView: View {
    @AppStorage("playSounds") var playSounds = true
    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("hideDesktopIconsWhileCapturing") var hideDesktopIcons = false
    @AppStorage("afterCaptureShowOverlay") var showOverlay = true
    @AppStorage("afterCaptureSaveAutomatically") var saveAutomatically = true
    @AppStorage("overlayTimeout") var overlayTimeout: Double = 6.0
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage().choice
    @State private var appearance = ShotnixAppearance.current

    /// System Default, named after the Mac's language, then each language in
    /// its own words.
    static func languageOptions(system: String = AppLanguage.systemLanguage()) -> [PreferenceOption<String?>] {
        [PreferenceOption(value: nil, title: L("System Default (\(AppLanguage.localizedName(system)))"))]
            + AppLanguage.all.map { PreferenceOption(value: $0, title: AppLanguage.endonym($0)) }
    }

    var body: some View {
        PreferencesPane {
            PreferenceSection(L("Shotnix appearance")) {
                HStack(spacing: 12) {
                    Text(L("Shotnix appearance"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ShotnixTheme.ink(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    PreferenceAppearancePicker(selection: Binding(get: { appearance }, set: chooseAppearance))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }

            PreferenceFootnote(text: L("Auto follows your Mac's appearance."))

            PreferenceSection(L("Language")) {
                PreferenceRow(L("Language")) {
                    let options = Self.languageOptions()
                    PreferenceMenuSelector(
                        selection: Binding(get: { language }, set: chooseLanguage),
                        options: options,
                        width: PreferenceMenuSelector.width(fitting: options)
                    )
                }
            }
            // Coming back from System Settings, where Shotnix's language can be set too.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                language = AppLanguage().choice
            }

            PreferenceFootnote(text: L("Shotnix restarts to switch languages. You can also set it in System Settings → General → Language & Region → Applications."))

            PreferenceSection(L("Startup")) {
                PreferenceRow(L("Launch Shotnix at login")) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin.toggle()
                            }
                        }
                }
            }

            PreferenceSection(L("Sounds")) {
                PreferenceRow(L("Play capture sound")) {
                    Toggle("", isOn: $playSounds)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceSection(L("Menu Bar")) {
                PreferenceRow(L("Show menu bar icon")) {
                    Toggle("", isOn: $showMenuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showMenuBarIcon) { newValue in
                            guard !newValue else { return }
                            DispatchQueue.main.async {
                                confirmHideMenuBarIcon()
                            }
                        }
                }

                PreferenceDivider()

                PreferenceRow(L("Hide desktop icons in screenshots")) {
                    Toggle("", isOn: $hideDesktopIcons)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceSection(L("After Capture")) {
                PreferenceRow(L("Show Quick Access Overlay")) {
                    Toggle("", isOn: $showOverlay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow(L("Save automatically")) {
                    Toggle("", isOn: $saveAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow(L("Auto-dismiss overlay")) {
                    PreferenceMenuSelector(
                        selection: $overlayTimeout,
                        options: [
                            PreferenceOption(value: 3.0, title: L("\(3) seconds")),
                            PreferenceOption(value: 6.0, title: L("\(6) seconds")),
                            PreferenceOption(value: 10.0, title: L("\(10) seconds")),
                            PreferenceOption(value: 30.0, title: L("\(30) seconds")),
                            PreferenceOption(value: -1.0, title: L("Never"))
                        ]
                    )
                }
            }

            PreferenceFootnote(text: L("Choose what happens immediately after taking a screenshot."))
        }
    }

    /// Every open window turns light or dark at once.
    private func chooseAppearance(_ choice: ShotnixAppearance) {
        appearance = choice
        ShotnixAppearance.current = choice
        ShotnixAppearance.apply(choice)
    }

    /// Stored at once; Shotnix shows it after a restart, now or at the next launch.
    private func chooseLanguage(_ choice: String?) {
        language = choice
        AppLanguage().choice = choice
        guard let next = AppLanguage.languageAfterRestart(with: choice) else { return }
        DispatchQueue.main.async {
            offerRestart(toUse: next)
        }
    }

    private func offerRestart(toUse language: String) {
        let alert = NSAlert()
        alert.messageText = L("Restart Shotnix to use \(AppLanguage.endonym(language))?")
        alert.informativeText = L("Otherwise, Shotnix switches languages the next time it opens.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later")).keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn {
            AppRelaunch.restart(reopeningSettings: true)
        }
    }

    /// The status item is the app's only entry point — confirm before hiding it
    /// and explain how to get back (relaunching Shotnix reopens Preferences).
    private func confirmHideMenuBarIcon() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Hide the Menu Bar Icon?")
        alert.informativeText = L("The menu bar icon is Shotnix's main entry point. While it is hidden, open Shotnix again from Finder, Launchpad, or Spotlight to bring these Preferences back.")
        alert.addButton(withTitle: L("Hide Icon"))
        alert.addButton(withTitle: L("Cancel"))

        if alert.runModal() != .alertFirstButtonReturn {
            showMenuBarIcon = true
        }
    }
}
struct ShortcutsSettingsView: View {
    private var screenshotShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .screenshots }
    }

    private var toolShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .tools }
    }

    private var recordingShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .recording }
    }

    var body: some View {
        PreferencesPaneWithFooter {
            ShortcutSection(title: L("Screenshots"), shortcuts: screenshotShortcuts)

            PreferenceFootnote(text: L("Hotkeys are system-wide and active while Shotnix is running. The ⌘⇧3 default works best after Apple's screenshot shortcut is disabled."))

            ShortcutSection(title: L("Recording"), shortcuts: recordingShortcuts)

            PreferenceFootnote(text: L("Recording shortcuts are unassigned by default — click a field to set one. Stop Recording also cancels recording setup. While recording, \(RecordingStopHotkey.displayText) always stops it, from any app."))

            ShortcutSection(title: L("Advanced Tools"), shortcuts: toolShortcuts)

            PreferenceFootnote(text: L("Capture Text and Scrolling Capture come without shortcuts, so ⌘⇧O and ⌘⇧S keep meaning Open and Save As in your other apps — click a field to set your own. Pressing the Scrolling Capture shortcut again finishes a scrolling capture."))
        } footer: {
            HStack {
                Button(L("Reset Defaults")) {
                    HotkeyManager.resetDefaults()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(L("Restore Apple Shortcuts")) {
                    if NativeShortcutManager.restoreNativeShortcuts() {
                        ToastWindow.show(message: L("Apple screenshot shortcuts restored."))
                    } else {
                        ToastWindow.show(message: L("Could not restore Apple shortcuts."))
                        NativeShortcutManager.openKeyboardSettings()
                    }
                }
                .buttonStyle(.bordered)
                .help(L("Re-enable Apple's ⌘⇧3/4/5 screenshot shortcuts"))
            }
        }
    }
}

private struct ShortcutSection: View {
    let title: String
    let shortcuts: [ShotnixShortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ShotnixTheme.ink(0.86))

            VStack(spacing: 0) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRecorderRow(shortcut: shortcut)

                    if shortcut.id != shortcuts.last?.id {
                        Divider()
                            .padding(.leading, 14)
                            .overlay(ShotnixTheme.ink(0.08))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShotnixTheme.ink(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ShotnixTheme.ink(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutRecorderRow: View {
    let shortcut: ShotnixShortcut

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ShotnixTheme.ink(0.88))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            KeyboardShortcuts.Recorder("", name: shortcut.name)
                .frame(width: 134)
        }
        .frame(height: 42)
        .padding(.horizontal, 14)
    }
}
struct ScreenshotsSettingsView: View {
    @AppStorage("screenshotFormat") var screenshotFormat = "png"
    @AppStorage("jpegQuality") var jpegQuality: Double = 0.95
    @AppStorage("afterCaptureCopyToClipboard") var copyToClipboard = true
    @AppStorage("autoSaveLocation") var autoSaveLocation = ""
    @AppStorage("filenameTemplate") var filenameTemplate = Settings.defaultFilenameTemplate
    @AppStorage("windowCaptureShadow") var windowCaptureShadow = true

    /// The folder, from the stored value this view watches: the row then
    /// shows a new folder the moment it's chosen. Read straight from
    /// `Settings`, it kept the old one until the tab was opened again.
    var displayLocation: String {
        Settings.autoSaveLocation(stored: autoSaveLocation)
    }

    /// Asks for a folder, starting in `current`. Nil when the person
    /// cancels. Tests answer in their place.
    static var chooseFolder: @MainActor (_ current: String) -> URL? = { current in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: current)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private var filenamePreview: String {
        let trimmed = filenameTemplate.trimmingCharacters(in: .whitespaces)
        let template = trimmed.isEmpty ? Settings.defaultFilenameTemplate : filenameTemplate
        return "\(ImageExporter.renderFilenameTemplate(template)).\(screenshotFormat)"
    }

    var body: some View {
        PreferencesPane {
            PreferenceSection(L("Export Format")) {
                PreferenceRow(L("Format")) {
                    // WebP is only offered where macOS can actually write it.
                    PreferenceMenuSelector(
                        selection: $screenshotFormat,
                        options: ImageExporter.availableFormats.map { format in
                            PreferenceOption(value: format, title: ["png": "PNG", "jpeg": "JPEG", "webp": "WebP"][format] ?? format.uppercased())
                        }
                    )
                }

                if screenshotFormat == "jpeg" {
                    PreferenceDivider()

                    PreferenceRow(L("JPEG Quality")) {
                        HStack(spacing: 8) {
                            Slider(value: $jpegQuality, in: 0.1...1.0)
                                .frame(width: 140)

                            Text(L("\(Int(jpegQuality * 100))%"))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ShotnixTheme.ink(0.56))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }

            PreferenceSection(L("Clipboard")) {
                PreferenceRow(L("Copy screenshots to clipboard")) {
                    Toggle("", isOn: $copyToClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceFootnote(text: L("New screenshots are copied automatically. Turn this off if you only want to use the overlay or history actions."))

            CaptureSelectionPreferences()

            PreferenceSection(L("Window Capture")) {
                PreferenceRow(L("Shadow and transparent padding")) {
                    Toggle("", isOn: $windowCaptureShadow)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceFootnote(text: L("Window captures are isolated — nothing overlapping shows through. With this on they get transparent padding and a soft drop shadow."))

            TextRecognitionPreferences()

            PreferenceSection(L("Save Location")) {
                PreferenceRow(L("Auto-save folder"), detail: displayLocation) {
                    Button(L("Choose...")) {
                        guard let url = Self.chooseFolder(displayLocation) else { return }
                        if Settings.setAutoSaveLocation(url.path) {
                            autoSaveLocation = Settings.autoSaveLocation
                        } else {
                            ToastWindow.show(message: L("Choose a writable folder for auto-save."))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            PreferenceFootnote(text: L("Directory where screenshots are saved if Auto-Save is enabled."))

            PreferenceSection(L("File Name")) {
                PreferenceRow(L("Template")) {
                    TextField("", text: $filenameTemplate, prompt: Text(Settings.defaultFilenameTemplate))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShotnixTheme.ink(0.86))
                        .padding(.horizontal, 10)
                        .frame(width: 230, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ShotnixTheme.ink(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(ShotnixTheme.ink(0.10), lineWidth: 1)
                        )
                }

                PreferenceDivider()

                PreferenceRow(L("Preview")) {
                    Text(filenamePreview)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ShotnixTheme.ink(0.56))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            PreferenceFootnote(text: L("Used for screenshots and recordings. Tokens: %y year, %m month, %d day, %H hour, %M minute, %S second. Leave empty to restore the default."))

            HistoryPreferences()
        }
    }
}

private struct MicrophoneOption: Identifiable {
    let id: String
    let name: String
}

private enum MicrophoneDeviceProvider {
    static var options: [MicrophoneOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        .map { MicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
    }
}

struct RecordingSettingsView: View {
    @AppStorage("recordingFPS") var fps = 60
    @AppStorage("recordingQuality") var quality = "high"
    @AppStorage("recordingShowsCursor") var showsCursor = true
    @AppStorage("recordingSystemAudio") var systemAudio = false
    @AppStorage("recordingMicrophone") var microphone = false
    @AppStorage("recordingMicrophoneDeviceID") var microphoneDeviceID = ""
    @AppStorage("recordingCamera") var camera = false
    @AppStorage("recordingCameraDeviceID") var cameraDeviceID = ""
    @AppStorage("recordingCountdownSeconds") var countdown = 0
    @AppStorage("recordingHidesMenuBarIcons") var hidesMenuBarIcons = false
    @AppStorage("recordingHidesDesktopIcons") var hidesDesktopIcons = false

    private var microphones: [MicrophoneOption] { MicrophoneDeviceProvider.options }

    /// A full-display recording of the main screen at the chosen settings.
    private var sizeEstimate: String {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let bytes = RecordingSizeEstimate.bytesPerMinute(
            pixelWidth: Int(size.width * scale),
            pixelHeight: Int(size.height * scale),
            fps: fps,
            quality: RecordingQuality(rawValue: quality) ?? .high,
            systemAudio: systemAudio,
            microphone: microphone
        )
        return L("Full screen: \(RecordingSizeEstimate.label(bytesPerMinute: bytes))")
    }

    var body: some View {
        PreferencesPane {
            PreferenceSection(L("Video")) {
                PreferenceRow(L("Quality"), detail: sizeEstimate) {
                    PreferenceMenuSelector(
                        selection: $quality,
                        options: [
                            PreferenceOption(value: "balanced", title: L("Balanced")),
                            PreferenceOption(value: "high", title: L("High")),
                            PreferenceOption(value: "max", title: L("Max"))
                        ]
                    )
                }

                PreferenceDivider()

                PreferenceRow(L("Frame rate")) {
                    PreferenceSegmentedSelector(
                        selection: $fps,
                        options: [
                            PreferenceOption(value: 30, title: "30 fps"), // l10n-ignore: fps is never translated
                            PreferenceOption(value: 60, title: "60 fps") // l10n-ignore
                        ]
                    )
                }

                PreferenceDivider()

                PreferenceRow(L("Countdown")) {
                    PreferenceMenuSelector(
                        selection: $countdown,
                        options: Settings.recordingCountdownChoices.map {
                            PreferenceOption(value: $0, title: $0 == 0 ? L("Off") : L("\($0) seconds"))
                        }
                    )
                }

                PreferenceDivider()

                PreferenceRow(L("Show cursor")) {
                    Toggle("", isOn: $showsCursor)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

            }

            PreferenceFootnote(text: L("The countdown gives you a moment after pressing Record; Esc cancels it."))
            PreferenceFootnote(text: L("Stop a recording with \(RecordingStopHotkey.displayText) from any app — plain Esc stays with the app you're recording."))

            PreferenceSection(L("Audio")) {
                PreferenceRow(L("Record system audio")) {
                    Toggle("", isOn: $systemAudio)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow(L("Record microphone")) {
                    Toggle("", isOn: $microphone)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow(L("Microphone")) {
                    PreferenceMenuSelector(
                        selection: $microphoneDeviceID,
                        options: [PreferenceOption(value: "", title: L("System Default"))]
                            + microphones.map { PreferenceOption(value: $0.id, title: $0.name) },
                        width: 190,
                        isEnabled: microphone
                    )
                }
            }

            PreferenceFootnote(text: L("Microphone recording requires macOS microphone permission. System audio excludes Shotnix sounds to avoid feedback."))

            PreferenceSection(L("Camera")) {
                PreferenceRow(L("Record camera")) {
                    Toggle("", isOn: $camera)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow(L("Camera")) {
                    PreferenceMenuSelector(
                        selection: $cameraDeviceID,
                        options: [PreferenceOption(value: "", title: L("System Default"))]
                            + CameraCapture.devices.map { PreferenceOption(value: $0.uniqueID, title: $0.localizedName) },
                        width: 190,
                        isEnabled: camera
                    )
                }
            }

            PreferenceFootnote(text: L("Your camera is recorded as its own layer: a live bubble shows while you record (it never appears in the screen capture), and the editor lets you move, resize, and restyle it — or hide it — afterwards."))

            PreferenceSection(L("Privacy")) {
                // Before macOS 26 other apps' menu bar icons are their own
                // windows: there's no leaving them out as one.
                if RecordingMenuBar.controlCenterHostsEveryItem {
                    PreferenceRow(L("Hide menu bar icons")) {
                        Toggle("", isOn: $hidesMenuBarIcons)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    PreferenceDivider()
                }

                PreferenceRow(L("Hide desktop icons")) {
                    Toggle("", isOn: $hidesDesktopIcons)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceFootnote(text: RecordingMenuBar.controlCenterHostsEveryItem
                ? L("Hide menu bar icons leaves the icons and the clock on the right of the menu bar out of the video, while you still see them on your screen. Hide desktop icons covers the files, folders and widgets on the display you record until the recording stops. The recording timer in the menu bar and the purple indicator beside it are always left out.")
                : L("Hide desktop icons covers the files, folders and widgets on the display you record until the recording stops."))


        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        PreferencesPane {
            Text(verbatim: "Shotnix fork by Shubskiy") // l10n-ignore: app name and credit
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
