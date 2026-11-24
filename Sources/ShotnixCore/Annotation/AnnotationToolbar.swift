import AppKit
import UniformTypeIdentifiers

// MARK: – Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    static let toolGroups: [[AnnotationTool]] = [
        [.select, .arrow, .rectangle, .ellipse, .line, .freehand],
        [.text, .callout, .highlighter, .scanText],
        [.pixelate, .spotlight, .crop],
    ]
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 48
    static let railWidth: CGFloat = 60
    static let sheetInset: CGFloat = 8
    static let canvasInset: CGFloat = 12
    static let minimumWidth: CGFloat = 580
    static let minimumHeight: CGFloat = 520
    static let buttonRadius: CGFloat = 6
    private static let optionsWidth: CGFloat = 216
    private static let actionFont = NSFont.systemFont(ofSize: 12)
    private static let prominentActionFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onBoldChanged: ((Bool) -> Void)?
    var onOutlineChanged: ((Bool) -> Void)?
    var onRedactionStrengthChanged: ((CGFloat) -> Void)?
    var onRoundedCornersChanged: ((Bool) -> Void)?
    var onSpotlightShapeChanged: ((_ ellipse: Bool) -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onResetCrop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onActualSize: (() -> Void)?
    var onFit: (() -> Void)?

    private var toolButtons: [AnnotationTool: EditorChromeButton] = [:]
    let toolRail = NSView()
    private let header = NSView()
    private let footer = NSView()
    private let sheet = NSView()
    private var toolDividers: [NSView] = []
    private(set) weak var viewport: NSView?
    private var selectedTool: AnnotationTool = .arrow
    private let windowTitle = NSTextField(labelWithString: L("Screenshot Editor"))
    private let toolTitle = NSTextField(labelWithString: "")
    private let colorButton = EditorChromeButton(title: "")
    private let colorSwatch = EditorColorSwatch()
    private let undoButton = EditorChromeButton(symbol: "arrow.uturn.backward", label: L("Undo"))
    private let redoButton = EditorChromeButton(symbol: "arrow.uturn.forward", label: L("Redo"))
    private let copyButton = EditorChromeButton(title: L("Copy"))
    private let saveButton = EditorChromeButton(title: L("Save"))
    private let zoomOutButton = EditorChromeButton(symbol: "minus", label: L("Zoom Out"))
    private let zoomInButton = EditorChromeButton(symbol: "plus", label: L("Zoom In"))
    private let zoomPercentButton = EditorChromeButton(title: "100%")
    private let fitButton = EditorChromeButton(symbol: "viewfinder", label: L("Fit to Window"))
    private var currentColor: NSColor = .systemRed
    private var colorPopover: NSPopover?
    private(set) var options = AnnotationToolOptions()
    private var screenshotTextLoading = false

    // Contextual options
    private let optionsContainer = NSView()
    private let sizeLabel = NSTextField(labelWithString: L("Size"))
    private let lineWidthSlider = NSSlider(value: 3, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let roundedCornersButton = ToolbarToggleButton(symbol: "app", label: L("Rounded corners"), toolTip: L("Rounded Corners (\u{2325}R)"))
    private let fontSizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = ToolbarToggleButton(symbol: "bold", label: L("Bold"), toolTip: L("Bold"))
    private let outlineButton = ToolbarToggleButton(image: AnnotationToolbar.outlineSymbol, label: L("Outline"), toolTip: L("Outline"))
    private let strengthLabel = NSTextField(labelWithString: L("Strength"))
    private let strengthSlider = NSSlider(
        value: Double(AnnotationRedaction.defaultStrength),
        minValue: Double(AnnotationRedaction.strengthRange.lowerBound),
        maxValue: Double(AnnotationRedaction.strengthRange.upperBound),
        target: nil, action: nil
    )
    private let shapeLabel = NSTextField(labelWithString: L("Shape"))
    private let spotlightShapeControl = NSSegmentedControl()
    private let applyCropButton = EditorChromeButton(title: L("Apply"))
    private let resetCropButton = EditorChromeButton(title: L("Reset"))
    private let hintLabel = NSTextField(labelWithString: "")

    static let fontSizes: [Int] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 80, 96]

    /// The shared color panel talks to one toolbar at a time.
    private static weak var colorPanelClient: AnnotationToolbar?

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        wantsLayer = true
        themed { $0.layer?.backgroundColor = AnnotationEditorColors.frame.cgColor }
        toolRail.setAccessibilityRole(.toolbar)
        toolRail.setAccessibilityLabel(L("Annotation tools"))
        toolRail.setAccessibilityElement(true)

        addSubview(header)
        addSubview(toolRail)
        addSubview(sheet)
        addSubview(footer)
        sheet.wantsLayer = true
        sheet.layer?.cornerRadius = 16
        sheet.layer?.cornerCurve = .continuous
        sheet.layer?.borderWidth = 1
        sheet.themed { sheet in
            sheet.layer?.backgroundColor = AnnotationEditorColors.well.cgColor
            sheet.layer?.borderColor = ShotnixColors.editorChromeBorder.cgColor
        }
        windowTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        windowTitle.lineBreakMode = .byTruncatingTail
        header.addSubview(windowTitle)

        install(undoButton, in: header, action: #selector(undoTapped), help: L("Undo") + " (⌘Z)")
        install(redoButton, in: header, action: #selector(redoTapped), help: L("Redo") + " (⇧⌘Z)")
        install(copyButton, in: header, action: #selector(copyTapped), help: L("Copy (⌘C)"))
        install(saveButton, in: header, action: #selector(saveTapped), help: L("Save (⌘S)"))
        saveButton.font = Self.prominentActionFont
        saveButton.emphasis = .primary
        setHistoryAvailability(canUndo: false, canRedo: false)

        for (index, group) in Self.toolGroups.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.themed { $0.layer?.backgroundColor = ShotnixColors.editorChromeBorder.cgColor }
                toolRail.addSubview(divider)
                toolDividers.append(divider)
            }
            for tool in group {
                let button = makeToolButton(tool: tool)
                toolRail.addSubview(button)
                toolButtons[tool] = button
            }
        }

        toolTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        toolTitle.lineBreakMode = .byTruncatingTail
        footer.addSubview(toolTitle)
        install(colorButton, in: footer, action: #selector(showColorPopover(_:)), help: L("Color"))
        colorButton.setAccessibilityLabel(L("Color"))
        colorSwatch.frame = NSRect(x: 7, y: 6, width: 18, height: 18)
        colorSwatch.wantsLayer = true
        colorSwatch.layer?.cornerRadius = 9
        colorSwatch.layer?.borderWidth = 1
        colorSwatch.themed { $0.layer?.borderColor = ShotnixColors.editorChromeBorder.cgColor }
        colorButton.addSubview(colorSwatch)
        setColorExternally(currentColor)
        footer.addSubview(optionsContainer)
        buildOptionControls()

        install(zoomOutButton, in: footer, action: #selector(zoomOutTapped), help: L("Zoom Out") + " (⌘−)")
        install(zoomPercentButton, in: footer, action: #selector(actualSizeTapped), help: L("Actual Size") + " (⌘0)")
        zoomPercentButton.setAccessibilityLabel(L("Actual Size"))
        zoomPercentButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        install(zoomInButton, in: footer, action: #selector(zoomInTapped), help: L("Zoom In") + " (⌘+)")
        install(fitButton, in: footer, action: #selector(fitTapped), help: L("Fit to Window"))

        selectTool(.arrow)
        showOptions(options)
    }

    private func install(_ button: EditorChromeButton, in container: NSView, action: Selector, help: String) {
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityHelp(help)
        container.addSubview(button)
    }

    func installViewport(_ view: NSView) {
        viewport = view
        sheet.addSubview(view)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let bodyTop = height - Self.headerHeight
        let sheetWidth = max(0, width - Self.railWidth - Self.sheetInset)
        let sheetHeight = max(0, bodyTop - Self.footerHeight)
        header.frame = NSRect(x: 0, y: bodyTop, width: width, height: Self.headerHeight)
        toolRail.frame = NSRect(x: 0, y: 0, width: Self.railWidth, height: max(0, bodyTop))
        footer.frame = NSRect(x: Self.railWidth, y: 0, width: sheetWidth, height: Self.footerHeight)
        sheet.frame = NSRect(x: Self.railWidth, y: Self.footerHeight, width: sheetWidth, height: sheetHeight)
        viewport?.frame = NSRect(x: Self.canvasInset, y: Self.canvasInset,
                                 width: max(0, sheetWidth - 2 * Self.canvasInset),
                                 height: max(0, sheetHeight - 2 * Self.canvasInset))
        layoutHeader(width: width)
        layoutRail(height: max(0, bodyTop))
        layoutFooter(width: sheetWidth)
    }

    private func layoutHeader(width: CGFloat) {
        var right = width - 12
        for button in [saveButton, copyButton, redoButton, undoButton] {
            let buttonWidth = button.image == nil
                ? max(64, Self.textWidth(button.title, font: button.font ?? Self.actionFont) + 22)
                : 34
            right -= buttonWidth
            button.frame = NSRect(x: right, y: 11, width: buttonWidth, height: 30)
            right -= button === copyButton ? 12 : 4
        }
        windowTitle.frame = NSRect(x: 84, y: 17, width: max(0, right - 96), height: 18)
    }

    private func layoutRail(height: CGFloat) {
        let count = CGFloat(toolButtons.count)
        let gap: CGFloat = 8
        let pitch = min(32, max(0, (height - 2 * Self.sheetInset - CGFloat(toolDividers.count) * gap) / count))
        var top = height - Self.sheetInset
        for (index, tools) in Self.toolGroups.enumerated() {
            if index > 0 {
                toolDividers[index - 1].frame = NSRect(x: 17, y: top - 4, width: 26, height: 1)
                top -= gap
            }
            for tool in tools {
                top -= pitch
                toolButtons[tool]?.frame = NSRect(x: 10, y: top + 1, width: 40, height: max(0, pitch - 2))
            }
        }
    }

    private func layoutFooter(width: CGFloat) {
        let zoomWidth: CGFloat = 152
        var x = width - zoomWidth
        let zoomItems: [(EditorChromeButton, CGFloat)] = [
            (zoomOutButton, 32), (zoomPercentButton, 52), (zoomInButton, 32), (fitButton, 36),
        ]
        for (button, buttonWidth) in zoomItems {
            button.frame = NSRect(x: x, y: 9, width: buttonWidth, height: 30)
            x += buttonWidth
        }

        let colorVisible = !colorButton.isHidden
        let titleSpace = width - zoomWidth - Self.optionsWidth - (colorVisible ? 64 : 24)
        let titleWidth = min(160, max(64, titleSpace), max(64, ceil(toolTitle.intrinsicContentSize.width) + 4))
        toolTitle.frame = NSRect(x: 12, y: 15, width: titleWidth, height: 18)
        x = toolTitle.frame.maxX + 8
        colorButton.frame = NSRect(x: x, y: 9, width: 32, height: 30)
        if colorVisible { x += 40 }
        optionsContainer.frame = NSRect(x: x, y: -1, width: Self.optionsWidth, height: 50)
    }

    func setHistoryAvailability(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    func setZoom(_ magnification: CGFloat, canZoomOut: Bool, canZoomIn: Bool) {
        let percent = Double(magnification).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
        if zoomPercentButton.accessibilityValue() as? String != percent {
            zoomPercentButton.setCaption(percent)
            zoomPercentButton.setAccessibilityValue(percent)
        }
        if zoomOutButton.isEnabled != canZoomOut { zoomOutButton.isEnabled = canZoomOut }
        if zoomInButton.isEnabled != canZoomIn { zoomInButton.isEnabled = canZoomIn }
    }

    private func buildOptionControls() {
        for label in [sizeLabel, strengthLabel, shapeLabel] {
            label.font = .systemFont(ofSize: 11)
            optionsContainer.addSubview(label)
        }

        lineWidthSlider.target = self
        lineWidthSlider.action = #selector(lineWidthChanged(_:))
        lineWidthSlider.toolTip = L("Line width")
        lineWidthSlider.setAccessibilityLabel(L("Line width"))
        optionsContainer.addSubview(lineWidthSlider)

        roundedCornersButton.target = self
        roundedCornersButton.action = #selector(roundedCornersToggled(_:))
        optionsContainer.addSubview(roundedCornersButton)

        fontSizePopUp.font = .systemFont(ofSize: 11)
        fontSizePopUp.target = self
        fontSizePopUp.action = #selector(fontSizeChanged(_:))
        fontSizePopUp.toolTip = L("Text size")
        fontSizePopUp.setAccessibilityLabel(L("Text size"))
        rebuildFontSizeItems(selecting: options.fontSize)
        optionsContainer.addSubview(fontSizePopUp)

        boldButton.target = self
        boldButton.action = #selector(boldToggled(_:))
        optionsContainer.addSubview(boldButton)

        outlineButton.target = self
        outlineButton.action = #selector(outlineToggled(_:))
        optionsContainer.addSubview(outlineButton)

        strengthSlider.target = self
        strengthSlider.action = #selector(strengthChanged(_:))
        strengthSlider.toolTip = L("How strongly blur and pixelate hide what's under them")
        strengthSlider.setAccessibilityLabel(L("Redaction strength"))
        optionsContainer.addSubview(strengthSlider)

        spotlightShapeControl.segmentCount = 2
        spotlightShapeControl.trackingMode = .selectOne
        spotlightShapeControl.setImage(NSImage(systemSymbolName: "rectangle", accessibilityDescription: L("Rectangle")), forSegment: 0)
        spotlightShapeControl.setImage(NSImage(systemSymbolName: "circle", accessibilityDescription: L("Ellipse")), forSegment: 1)
        spotlightShapeControl.setToolTip(L("Rectangle"), forSegment: 0)
        spotlightShapeControl.setToolTip(L("Ellipse"), forSegment: 1)
        spotlightShapeControl.selectedSegment = 0
        spotlightShapeControl.target = self
        spotlightShapeControl.action = #selector(spotlightShapeChanged(_:))
        spotlightShapeControl.setAccessibilityLabel(L("Spotlight shape"))
        optionsContainer.addSubview(spotlightShapeControl)

        applyCropButton.target = self
        applyCropButton.action = #selector(applyCropTapped)
        applyCropButton.font = Self.prominentActionFont
        applyCropButton.emphasis = .bordered
        applyCropButton.toolTip = L("Apply the crop (Return)")
        applyCropButton.setAccessibilityLabel(L("Apply crop"))
        optionsContainer.addSubview(applyCropButton)

        resetCropButton.target = self
        resetCropButton.action = #selector(resetCropTapped)
        resetCropButton.font = Self.actionFont
        resetCropButton.toolTip = L("Show the whole screenshot again")
        resetCropButton.setAccessibilityLabel(L("Reset crop"))
        optionsContainer.addSubview(resetCropButton)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        optionsContainer.addSubview(hintLabel)
    }

    private var optionControls: [NSView] {
        [sizeLabel, lineWidthSlider, roundedCornersButton, fontSizePopUp, boldButton, outlineButton,
         strengthLabel, strengthSlider, shapeLabel, spotlightShapeControl,
         applyCropButton, resetCropButton, hintLabel]
    }

    /// Shows the controls for the current tool or selection with its values.
    func showOptions(_ newOptions: AnnotationToolOptions) {
        options = newOptions
        let visible: [NSView]
        let end = Self.optionsWidth
        switch newOptions.context {
        case .stroke:
            let label = Self.labelWidth(sizeLabel, atLeast: 30)
            sizeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            lineWidthSlider.frame = NSRect(x: label + 2, y: 11, width: end - label - 2, height: 28)
            visible = [sizeLabel, lineWidthSlider]
        case .rectangle:
            let label = Self.labelWidth(sizeLabel, atLeast: 30)
            sizeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            lineWidthSlider.frame = NSRect(x: label + 2, y: 11, width: end - 38 - label - 2, height: 28)
            roundedCornersButton.frame = NSRect(x: end - 30, y: 10, width: 30, height: 30)
            visible = [sizeLabel, lineWidthSlider, roundedCornersButton]
        case .text:
            fontSizePopUp.frame = NSRect(x: 0, y: 11, width: 84, height: 28)
            boldButton.frame = NSRect(x: 88, y: 10, width: 30, height: 30)
            outlineButton.frame = NSRect(x: 122, y: 10, width: 30, height: 30)
            visible = newOptions.canOutline ? [fontSizePopUp, boldButton, outlineButton] : [fontSizePopUp, boldButton]
        case .redaction:
            let label = Self.labelWidth(strengthLabel, atLeast: 50)
            strengthLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            strengthSlider.frame = NSRect(x: label + 2, y: 11, width: end - label - 2, height: 28)
            visible = [strengthLabel, strengthSlider]
        case .spotlight:
            let label = Self.labelWidth(shapeLabel, atLeast: 38)
            shapeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            spotlightShapeControl.frame = NSRect(x: label + 4, y: 13, width: 84, height: 24)
            visible = [shapeLabel, spotlightShapeControl]
        case .crop:
            let apply = max(70, Self.textWidth(applyCropButton.title, font: Self.prominentActionFont) + 16)
            let reset = max(64, Self.textWidth(resetCropButton.title, font: Self.actionFont) + 16)
            applyCropButton.frame = NSRect(x: 0, y: 10, width: apply, height: 30)
            resetCropButton.frame = NSRect(x: apply + 6, y: 10, width: reset, height: 30)
            visible = [applyCropButton, resetCropButton]
        case .none:
            let hint = screenshotTextLoading ? L("Recognizing text…") : L("Select text, then press ⌘C")
            showHint(selectedTool == .scanText ? hint : L("Click an annotation to edit it"), width: end)
            visible = [hintLabel]
        }
        switch newOptions.context {
        case .stroke, .rectangle, .text: colorButton.isHidden = false
        case .none: colorButton.isHidden = selectedTool == .scanText
        case .redaction, .spotlight, .crop: colorButton.isHidden = true
        }
        needsLayout = true
        let copyHelp = selectedTool == .scanText ? L("Copy recognized text (OCR)") : L("Copy (\u{2318}C)")
        copyButton.toolTip = copyHelp
        copyButton.setAccessibilityHelp(copyHelp)
        for control in optionControls {
            control.isHidden = !visible.contains(where: { $0 === control })
        }

        lineWidthSlider.doubleValue = Double(newOptions.lineWidth)
        roundedCornersButton.state = newOptions.roundedCorners ? .on : .off
        rebuildFontSizeItems(selecting: newOptions.fontSize)
        boldButton.state = newOptions.isBold ? .on : .off
        outlineButton.state = newOptions.isOutlined ? .on : .off
        strengthSlider.doubleValue = Double(newOptions.redactionStrength)
        spotlightShapeControl.selectedSegment = newOptions.spotlightEllipse ? 1 : 0
        applyCropButton.isEnabled = newOptions.canApplyCrop
        resetCropButton.isEnabled = newOptions.canResetCrop
    }

    func setScreenshotTextLoading(_ loading: Bool) {
        screenshotTextLoading = loading
        showOptions(options)
    }

    /// A label's design width, or the width its translation needs plus a
    /// small gap before the control beside it.
    private static func labelWidth(_ label: NSTextField, atLeast minimum: CGFloat) -> CGFloat {
        max(minimum, ceil(label.intrinsicContentSize.width) + 4)
    }

    /// One line where the hint fits, as it always does in English; a longer
    /// translation wraps to two lines, centered the same way.
    private func showHint(_ text: String, width: CGFloat) {
        hintLabel.stringValue = text
        let fits = Self.textWidth(text, font: hintLabel.font ?? Self.actionFont) + 1 <= width
        hintLabel.cell?.wraps = !fits
        hintLabel.cell?.truncatesLastVisibleLine = !fits
        hintLabel.maximumNumberOfLines = fits ? 0 : 2
        hintLabel.lineBreakMode = fits ? .byTruncatingTail : .byWordWrapping
        hintLabel.frame = fits
            ? NSRect(x: 0, y: 17, width: width, height: 16)
            : NSRect(x: 0, y: 11, width: width, height: 28)
    }

    /// Standard sizes, plus the exact size of the selection when a resize
    /// left it between them.
    private func rebuildFontSizeItems(selecting size: CGFloat) {
        let rounded = Int(size.rounded())
        var sizes = Self.fontSizes
        if !sizes.contains(rounded) {
            sizes.append(rounded)
            sizes.sort()
        }
        if fontSizePopUp.itemArray.map(\.tag) != sizes {
            fontSizePopUp.removeAllItems()
            for value in sizes {
                // Point sizes as plain digits.
                fontSizePopUp.addItem(withTitle: L("\(String(value)) pt"))
                fontSizePopUp.lastItem?.tag = value
            }
        }
        fontSizePopUp.selectItem(withTag: rounded)
    }

    private func makeToolButton(tool: AnnotationTool) -> EditorChromeButton {
        let btn = EditorChromeButton(symbol: tool.icon, label: tool.name)
        btn.toolTip = tool.tooltip
        btn.target = self
        btn.action = #selector(toolTapped(_:))
        btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
        // Tools are mutually exclusive: VoiceOver reads them as radio buttons.
        btn.setAccessibilityRole(.radioButton)
        btn.setAccessibilityLabel(tool.name)
        btn.setAccessibilityHelp(tool.tooltip)
        btn.setAccessibilityValue(NSNumber(value: 0))
        return btn
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        selectTool(tool)
        onToolChanged?(tool)
    }

    private func selectTool(_ tool: AnnotationTool) {
        toolButtons[selectedTool]?.emphasis = .plain
        toolButtons[selectedTool]?.setAccessibilityValue(NSNumber(value: 0))
        selectedTool = tool
        toolButtons[tool]?.emphasis = .selected
        toolButtons[tool]?.setAccessibilityValue(NSNumber(value: 1))
        toolTitle.stringValue = tool == .scanText ? L("Select Text") : tool.name
        toolTitle.toolTip = tool.tooltip
        needsLayout = true
    }

    func selectToolExternally(_ tool: AnnotationTool) {
        selectTool(tool)
    }

    func setColorExternally(_ color: NSColor) {
        currentColor = color
        colorSwatch.layer?.backgroundColor = color.cgColor(in: self)
        colorButton.setAccessibilityValue(Self.colorName(color))
    }

    /// Accessibility helpers for tests: the control a VoiceOver user reaches.
    func toolButton(for tool: AnnotationTool) -> NSButton? { toolButtons[tool] }
    var colorControl: NSButton? { colorButton }
    var visibleOptionControls: [NSView] { optionControls.filter { !$0.isHidden } }

    static func colorName(_ color: NSColor) -> String {
        let names: [(NSColor, String)] = [
            (.systemRed, L("Red")), (.systemOrange, L("Orange")), (.systemYellow, L("Yellow")), (.systemGreen, L("Green")),
            (.systemBlue, L("Blue")), (.systemPurple, L("Purple")), (.white, L("White")), (.black, L("Black")),
        ]
        if let match = names.first(where: { $0.0 == color }) { return match.1 }
        guard let rgb = color.usingColorSpace(.sRGB) else { return L("Custom color") }
        let hex = String(format: "%02X%02X%02X",
                         Int((rgb.redComponent * 255).rounded()),
                         Int((rgb.greenComponent * 255).rounded()),
                         Int((rgb.blueComponent * 255).rounded()))
        return L("Custom color #\(hex)")
    }

    // MARK: Color

    @objc private func showColorPopover(_ sender: NSButton) {
        let controller = ColorPopoverController(currentColor: currentColor)
        controller.onColorPicked = { [weak self] color in
            self?.applyPickedColor(color)
        }
        controller.onCustomColorRequested = { [weak self] in
            self?.showColorPanel()
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        colorPopover = popover
    }

    private func applyPickedColor(_ color: NSColor) {
        setColorExternally(color)
        onColorChanged?(color)
    }

    /// The system color panel, targeting this toolbar and kept above the
    /// editor window so it can't open behind it.
    func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.color = currentColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        Self.colorPanelClient = self
        if let window, panel.level.rawValue <= window.level.rawValue {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        applyPickedColor(sender.color)
    }

    /// Stops the shared color panel from messaging this toolbar once its
    /// editor closes.
    func detachColorPanel() {
        guard Self.colorPanelClient === self else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        Self.colorPanelClient = nil
    }

    // MARK: Options actions

    @objc private func lineWidthChanged(_ sender: NSSlider) { onLineWidthChanged?(CGFloat(sender.doubleValue)) }

    @objc private func roundedCornersToggled(_ sender: NSButton) {
        roundedCornersButton.refreshAppearance()
        onRoundedCornersChanged?(sender.state == .on)
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag > 0 else { return }
        onFontSizeChanged?(CGFloat(tag))
    }

    @objc private func boldToggled(_ sender: NSButton) {
        boldButton.refreshAppearance()
        onBoldChanged?(sender.state == .on)
    }

    @objc private func outlineToggled(_ sender: NSButton) {
        outlineButton.refreshAppearance()
        onOutlineChanged?(sender.state == .on)
    }

    /// An "A" inside a ring, for the outline toggle; SF Symbols has no
    /// outlined letter. Stroking the glyph's own contours would show where
    /// they overlap, so the ring is a thick stroke with the middle cleared.
    static let outlineSymbol: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let font = NSFont.systemFont(ofSize: 12, weight: .heavy)
            let letter = "A" as NSString
            let size = letter.size(withAttributes: [.font: font])
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            // `reach` is how far past the letter the shape goes.
            func drawLetter(reach: CGFloat) {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                if reach > 0 {
                    attributes[.strokeColor] = NSColor.black
                    attributes[.strokeWidth] = -2 * reach / font.pointSize * 100
                }
                letter.draw(at: origin, withAttributes: attributes)
            }
            ctx.setLineJoin(.round)
            drawLetter(reach: 2.4)
            ctx.setBlendMode(.clear)
            drawLetter(reach: 1.2)
            ctx.setBlendMode(.normal)
            drawLetter(reach: 0)
            return true
        }
        image.isTemplate = true
        return image
    }()

    @objc private func strengthChanged(_ sender: NSSlider) { onRedactionStrengthChanged?(CGFloat(sender.doubleValue)) }

    @objc private func spotlightShapeChanged(_ sender: NSSegmentedControl) {
        onSpotlightShapeChanged?(sender.selectedSegment == 1)
    }

    @objc private func applyCropTapped() { onApplyCrop?() }
    @objc private func resetCropTapped() { onResetCrop?() }

    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
    @objc private func undoTapped()       { onUndo?() }
    @objc private func redoTapped()       { onRedo?() }
    @objc private func zoomOutTapped()    { onZoomOut?() }
    @objc private func zoomInTapped()     { onZoomIn?() }
    @objc private func actualSizeTapped() { onActualSize?() }
    @objc private func fitTapped()        { onFit?() }
}

/// Icon toggle in the options area, tinted like a selected tool while on.
@MainActor
final class ToolbarToggleButton: NSButton {
    convenience init(symbol: String, label: String, toolTip: String) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label), label: label, toolTip: toolTip)
    }

    convenience init(image: NSImage?, label: String, toolTip: String) {
        self.init(frame: .zero)
        self.image = image
        setButtonType(.pushOnPushOff)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        self.toolTip = toolTip
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = AnnotationToolbar.buttonRadius
        layer?.cornerCurve = .continuous
    }

    override var state: NSControl.StateValue {
        didSet { refreshAppearance() }
    }

    func refreshAppearance() {
        layer?.backgroundColor = state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor : nil
        contentTintColor = state == .on ? .controlAccentColor : nil
    }
}

// MARK: - Per-image background popover

@MainActor
final class BackgroundPopoverController: NSViewController {
    var onChange: ((ScreenshotBackgroundOptions) -> Void)?
    weak var popover: NSPopover?

    private var options: ScreenshotBackgroundOptions
    private let enabledButton = NSButton(checkboxWithTitle: L("Apply background to this image"), target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let uploadImageButton = NSButton(title: L("Upload Custom Image"), target: nil, action: nil)
    private let paddingSlider = NSSlider()
    private let radiusSlider = NSSlider()
    private let shadowSlider = NSSlider()
    private let paddingValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let shadowValue = NSTextField(labelWithString: "")
    private var styleLabel: NSTextField?
    private var presetLabel: NSTextField?
    private var paddingLabel: NSTextField?
    private var radiusLabel: NSTextField?
    private var shadowLabel: NSTextField?
    private var imagePresetButtons: [NSButton] = []
    private let popoverWidth: CGFloat = 300
    private let compactPopoverHeight: CGFloat = 250
    private let imagePopoverHeight: CGFloat = 452

    // `name` identifies a preset (it's stored in the options); `title` is shown.
    private let solidPresets: [(name: String, title: String, hex: String)] = [
        ("Porcelain", L("Porcelain"), "#f4eadb"),
        ("Graphite", L("Graphite"), "#111827"),
        ("Bone", L("Bone"), "#eee7d6"),
        ("Silver", L("Silver"), "#d8dde7"),
        ("Space Gray", L("Space Gray"), "#2b3038"),
        ("Moss", L("Moss"), "#243528"),
        ("Clay", L("Clay"), "#7c3f2d")
    ]
    private let gradientPresets: [(name: String, title: String, start: String, end: String, accents: [String])] = [
        ("Neo Pop", L("Neo Pop"), "#6a2cff", "#ffd36a", ["#ff7ac8", "#6af7ff", "#fff6b0"]),
        ("Polar Dawn", L("Polar Dawn"), "#07131e", "#6db8ff", ["#e9f6ff", "#173c63", "#a8d8ff"]),
        ("Aurora Blue", L("Aurora Blue"), "#050816", "#67d7ff", ["#7c3aed", "#38f8d4", "#d8f7ff"]),
        ("Tahoe Ice", L("Tahoe Ice"), "#eaf4ff", "#1b6fe0", ["#ffffff", "#8dd7ff", "#3155d4"]),
        ("Lavender Glass", L("Lavender Glass"), "#f7f2ff", "#5b56f5", ["#ffb7e8", "#a3e8ff", "#ffffff"]),
        ("Sunset Coral", L("Sunset Coral"), "#fff0d8", "#ea4e79", ["#ffb86b", "#ffd1df", "#7c2d12"]),
        ("Coastal Haze", L("Coastal Haze"), "#071722", "#89e8f2", ["#0e5a78", "#e8fbff", "#2dd4bf"]),
        ("Midnight Graphite", L("Midnight Graphite"), "#090b10", "#404c67", ["#99a4c7", "#1f2937", "#dbe4ff"]),
        ("Ember Fog", L("Ember Fog"), "#160c0a", "#f4b06a", ["#6c2d1e", "#ffe7c8", "#ff6b3d"]),
        ("Moss Glow", L("Moss Glow"), "#0e1b16", "#7fd3a0", ["#235543", "#eaf9f0", "#d4a95a"])
    ]

    init(options: ScreenshotBackgroundOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: imagePopoverHeight))
        var y: CGFloat = 416

        enabledButton.frame = NSRect(x: 16, y: y, width: 268, height: 22)
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        container.addSubview(enabledButton)

        y -= 38
        styleLabel = addLabel(L("Style"), x: 16, y: y + 4, to: container)
        stylePopup.frame = NSRect(x: 106, y: y, width: 170, height: 26)
        stylePopup.addItems(withTitles: [L("Gradient"), L("Solid Color"), L("Image")])
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        container.addSubview(stylePopup)

        y -= 36
        presetLabel = addLabel(L("Preset"), x: 16, y: y + 4, to: container)
        presetPopup.frame = NSRect(x: 106, y: y, width: 170, height: 26)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        container.addSubview(presetPopup)

        uploadImageButton.frame = NSRect(x: 16, y: 302, width: 260, height: 30)
        uploadImageButton.bezelStyle = .rounded
        uploadImageButton.font = .systemFont(ofSize: 12, weight: .semibold)
        uploadImageButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        uploadImageButton.imagePosition = .imageLeading
        uploadImageButton.target = self
        uploadImageButton.action = #selector(uploadCustomImage)
        container.addSubview(uploadImageButton)

        addImagePresetGrid(to: container)

        y = 124
        paddingLabel = addSliderRow(L("Padding"), slider: paddingSlider, valueLabel: paddingValue, y: y, min: 0, max: 240, to: container)
        y -= 38
        radiusLabel = addSliderRow(L("Radius"), slider: radiusSlider, valueLabel: radiusValue, y: y, min: 0, max: 36, to: container)
        y -= 38
        shadowLabel = addSliderRow(L("Shadow"), slider: shadowSlider, valueLabel: shadowValue, y: y, min: 0, max: 1, to: container)

        view = container
        syncControls()
    }

    @discardableResult
    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to view: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.frame = NSRect(x: x, y: y, width: 80, height: 16)
        view.addSubview(label)
        return label
    }

    private func addImagePresetGrid(to view: NSView) {
        let buttonSize = NSSize(width: 42, height: 34)
        let gap: CGFloat = 10
        let startX: CGFloat = 16
        let startY: CGFloat = 256
        let columns = 5

        for (index, preset) in ScreenshotBackgroundOptions.imagePresets.enumerated() {
            let row = index / columns
            let col = index % columns
            let button = NSButton(frame: NSRect(
                x: startX + CGFloat(col) * (buttonSize.width + gap),
                y: startY - CGFloat(row) * (buttonSize.height + gap),
                width: buttonSize.width,
                height: buttonSize.height
            ))
            button.image = ScreenshotBackgroundComposer.previewImage(options: imageOptions(for: preset), size: NSSize(width: 84, height: 68))
            button.imageScaling = .scaleAxesIndependently
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = preset.title
            button.tag = index
            button.target = self
            button.action = #selector(imagePresetTapped(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.cornerCurve = .continuous
            button.layer?.masksToBounds = true
            view.addSubview(button)
            imagePresetButtons.append(button)
        }
    }

    @discardableResult
    private func addSliderRow(_ title: String, slider: NSSlider, valueLabel: NSTextField, y: CGFloat, min: Double, max: Double, to view: NSView) -> NSTextField {
        let label = addLabel(title, x: 16, y: y + 6, to: view)
        slider.minValue = min
        slider.maxValue = max
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.frame = NSRect(x: 106, y: y, width: 126, height: 26)
        view.addSubview(slider)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 236, y: y + 5, width: 40, height: 16)
        view.addSubview(valueLabel)
        return label
    }

    private func layoutControls() {
        let isImageStyle = options.style == .image
        let height = isImageStyle ? imagePopoverHeight : compactPopoverHeight
        let size = NSSize(width: popoverWidth, height: height)
        view.setFrameSize(size)
        preferredContentSize = size
        popover?.contentSize = size

        let enabledY = height - 36
        let styleY = enabledY - 38
        let presetY = styleY - 36
        let uploadY = presetY - 40
        let imageGridStartY = uploadY - 46
        let sliderY = isImageStyle ? CGFloat(124) : presetY - 48

        enabledButton.frame = NSRect(x: 16, y: enabledY, width: 268, height: 22)
        styleLabel?.frame = NSRect(x: 16, y: styleY + 4, width: 80, height: 16)
        stylePopup.frame = NSRect(x: 106, y: styleY, width: 170, height: 26)
        presetLabel?.frame = NSRect(x: 16, y: presetY + 4, width: 80, height: 16)
        presetPopup.frame = NSRect(x: 106, y: presetY, width: 170, height: 26)
        uploadImageButton.frame = NSRect(x: 16, y: uploadY, width: 260, height: 30)
        layoutImagePresetButtons(startY: imageGridStartY)
        layoutSliderRow(label: paddingLabel, slider: paddingSlider, valueLabel: paddingValue, y: sliderY)
        layoutSliderRow(label: radiusLabel, slider: radiusSlider, valueLabel: radiusValue, y: sliderY - 38)
        layoutSliderRow(label: shadowLabel, slider: shadowSlider, valueLabel: shadowValue, y: sliderY - 76)
        view.needsDisplay = true
    }

    private func layoutImagePresetButtons(startY: CGFloat) {
        let buttonSize = NSSize(width: 42, height: 34)
        let gap: CGFloat = 10
        let startX: CGFloat = 16
        let columns = 5

        for (index, button) in imagePresetButtons.enumerated() {
            let row = index / columns
            let col = index % columns
            button.frame = NSRect(
                x: startX + CGFloat(col) * (buttonSize.width + gap),
                y: startY - CGFloat(row) * (buttonSize.height + gap),
                width: buttonSize.width,
                height: buttonSize.height
            )
        }
    }

    private func layoutSliderRow(label: NSTextField?, slider: NSSlider, valueLabel: NSTextField, y: CGFloat) {
        label?.frame = NSRect(x: 16, y: y + 6, width: 80, height: 16)
        slider.frame = NSRect(x: 106, y: y, width: 126, height: 26)
        valueLabel.frame = NSRect(x: 236, y: y + 5, width: 40, height: 16)
    }

    private func syncControls() {
        enabledButton.state = options.isEnabled ? .on : .off
        switch options.style {
        case .gradient: stylePopup.selectItem(at: 0)
        case .solid: stylePopup.selectItem(at: 1)
        case .image: stylePopup.selectItem(at: 2)
        }
        paddingSlider.doubleValue = Double(options.padding)
        radiusSlider.doubleValue = Double(options.cornerRadius)
        shadowSlider.doubleValue = Double(options.shadow)
        rebuildPresetPopup()
        updateStyleVisibility()
        updateValueLabels()
        updateImagePresetSelection()
    }

    private func rebuildPresetPopup() {
        presetPopup.removeAllItems()
        switch options.style {
        case .solid:
            presetPopup.addItems(withTitles: solidPresets.map(\.title))
            if let index = solidPresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .gradient:
            presetPopup.addItems(withTitles: gradientPresets.map(\.title))
            if let index = gradientPresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .image:
            presetPopup.addItems(withTitles: ScreenshotBackgroundOptions.imagePresets.map(\.title))
            if let index = ScreenshotBackgroundOptions.imagePresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        }
    }

    private func updateStyleVisibility() {
        let isImageStyle = options.style == .image
        layoutControls()
        presetLabel?.isHidden = isImageStyle
        presetPopup.isHidden = isImageStyle
        uploadImageButton.isHidden = !isImageStyle
        imagePresetButtons.forEach { $0.isHidden = !isImageStyle }
        uploadImageButton.title = options.customImageName.map { L("Custom: \($0)") } ?? L("Upload Custom Image")
    }

    private func updateImagePresetSelection() {
        for (index, button) in imagePresetButtons.enumerated() {
            let preset = ScreenshotBackgroundOptions.imagePresets[index]
            let selected = options.style == .image && options.customImageData == nil && preset.name == options.presetName
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : ShotnixTheme.inkColor(0.18).cgColor(in: button)
        }
    }

    private func updateValueLabels() {
        // Point sizes as plain digits.
        paddingValue.stringValue = String(Int(options.padding))
        radiusValue.stringValue = String(Int(options.cornerRadius))
        shadowValue.stringValue = L("\(Int(options.shadow * 100))%")
    }

    private func emitChange() {
        updateStyleVisibility()
        updateImagePresetSelection()
        updateValueLabels()
        onChange?(options)
    }

    @objc private func enabledChanged() {
        options.isEnabled = enabledButton.state == .on
        emitChange()
    }

    @objc private func styleChanged() {
        switch stylePopup.indexOfSelectedItem {
        case 1:
            options.style = .solid
        case 2:
            options.style = .image
            options.isEnabled = true
            if options.customImageData == nil,
               !ScreenshotBackgroundOptions.imagePresets.contains(where: { $0.name == options.presetName }) {
                let preset = ScreenshotBackgroundOptions.imagePresets[0]
                options.presetName = preset.name
                options.gradientStartHex = preset.startHex
                options.gradientEndHex = preset.endHex
                options.accentHexes = preset.accentHexes
            }
        default:
            options.style = .gradient
        }
        rebuildPresetPopup()
        if options.style == .image {
            emitChange()
        } else {
            presetChanged()
        }
    }

    @objc private func presetChanged() {
        let index = max(0, presetPopup.indexOfSelectedItem)
        switch options.style {
        case .solid:
            let preset = solidPresets[min(index, solidPresets.count - 1)]
            options.presetName = preset.name
            options.colorHex = preset.hex
            options.accentHexes = []
        case .gradient:
            let preset = gradientPresets[min(index, gradientPresets.count - 1)]
            options.presetName = preset.name
            options.gradientStartHex = preset.start
            options.gradientEndHex = preset.end
            options.accentHexes = preset.accents
            options.customImageData = nil
            options.customImageName = nil
        case .image:
            let preset = ScreenshotBackgroundOptions.imagePresets[min(index, ScreenshotBackgroundOptions.imagePresets.count - 1)]
            applyImagePreset(preset)
        }
        emitChange()
    }

    @objc private func imagePresetTapped(_ sender: NSButton) {
        let preset = ScreenshotBackgroundOptions.imagePresets[min(sender.tag, ScreenshotBackgroundOptions.imagePresets.count - 1)]
        applyImagePreset(preset)
        emitChange()
    }

    @objc private func uploadCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url),
              NSImage(data: data) != nil else { return }

        options.isEnabled = true
        options.style = .image
        options.presetName = "Custom Image"
        options.customImageData = data
        options.customImageName = url.lastPathComponent
        stylePopup.selectItem(at: 2)
        emitChange()
    }

    private func applyImagePreset(_ preset: ScreenshotBackgroundImagePreset) {
        options.isEnabled = true
        options.style = .image
        options.presetName = preset.name
        options.gradientStartHex = preset.startHex
        options.gradientEndHex = preset.endHex
        options.accentHexes = preset.accentHexes
        options.customImageData = nil
        options.customImageName = nil
    }

    private func imageOptions(for preset: ScreenshotBackgroundImagePreset) -> ScreenshotBackgroundOptions {
        var preview = options
        preview.isEnabled = true
        preview.style = .image
        preview.presetName = preset.name
        preview.gradientStartHex = preset.startHex
        preview.gradientEndHex = preset.endHex
        preview.accentHexes = preset.accentHexes
        preview.customImageData = nil
        preview.customImageName = nil
        return preview
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        if sender === paddingSlider { options.padding = CGFloat(sender.doubleValue.rounded()) }
        if sender === radiusSlider { options.cornerRadius = CGFloat(sender.doubleValue.rounded()) }
        if sender === shadowSlider { options.shadow = CGFloat(sender.doubleValue) }
        emitChange()
    }
}


extension CALayer {
    /// A scale about the layer's center, whatever its anchor point. Layers of
    /// layer-backed views anchor at a corner, so a plain scale would pull a
    /// button toward that corner.
    func scaledAboutCenter(_ scale: CGFloat) -> CATransform3D {
        let dx = bounds.width * (0.5 - anchorPoint.x)
        let dy = bounds.height * (0.5 - anchorPoint.y)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}

private final class EditorColorSwatch: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum AnnotationEditorColors {
    static let frame = NSColor(name: "annotationFrame") { appearance in
        ShotnixTheme.isDark(appearance)
            ? NSColor(white: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.953, green: 0.96, blue: 0.97, alpha: 1)
    }

    static let well = NSColor(name: "annotationWell") { appearance in
        ShotnixTheme.isDark(appearance)
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.927, green: 0.936, blue: 0.947, alpha: 1)
    }
}

@MainActor
private final class EditorChromeButton: NSButton {
    enum Emphasis { case plain, selected, bordered, primary }

    var emphasis: Emphasis = .plain {
        didSet { updateChrome() }
    }

    private var pointerTracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        font = .systemFont(ofSize: 12)
        wantsLayer = true
        layer?.cornerRadius = AnnotationToolbar.buttonRadius
        themed { $0.updateChrome() }
    }

    convenience init(title: String) {
        self.init(frame: .zero)
        setCaption(title)
    }

    func setCaption(_ title: String) {
        self.title = title
        updateChrome()
    }

    convenience init(symbol: String, label: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        imagePosition = .imageOnly
        setAccessibilityLabel(label)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateChrome()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateChrome()
    }

    override var isEnabled: Bool {
        didSet { updateChrome() }
    }

    private func updateChrome() {
        let pressed = isEnabled && isHighlighted
        let hovered = isEnabled && self.hovered
        let ink = NSColor.labelColor
        let dark = ShotnixTheme.isDark(effectiveAppearance)
        let controlInk = NSColor(white: dark ? 0.79 : 0.30, alpha: 1)
        switch emphasis {
        case .plain:
            layer?.backgroundColor = ink.withAlphaComponent(pressed ? 0.17 : hovered ? 0.075 : 0).cgColor(in: self)
        case .selected:
            layer?.backgroundColor = ink.withAlphaComponent(pressed ? 0.24 : 0.14).cgColor(in: self)
        case .bordered:
            layer?.backgroundColor = ink.withAlphaComponent(pressed ? 0.16 : hovered ? 0.10 : 0.05).cgColor(in: self)
        case .primary:
            let white: CGFloat = dark ? (pressed ? 0.74 : hovered ? 0.85 : 0.92)
                : (pressed ? 0.26 : hovered ? 0.22 : 0.14)
            layer?.backgroundColor = NSColor(white: white, alpha: 1).cgColor
        }
        if image != nil {
            contentTintColor = emphasis == .selected ? .labelColor : controlInk
        } else if !title.isEmpty {
            let titleColor = emphasis == .primary ? (dark ? NSColor.black : .white) : controlInk
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? .systemFont(ofSize: 12),
                .foregroundColor: isEnabled ? titleColor : titleColor.withAlphaComponent(0.45),
            ])
        }
        layer?.borderWidth = emphasis == .bordered ? 1 : 0
        layer?.borderColor = ShotnixColors.editorChromeBorder.cgColor(in: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if emphasis == .selected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: bounds.midY - 7, width: 2, height: 14), xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - Color Presets Popover

@MainActor
final class ColorPopoverController: NSViewController {
    var onColorPicked: ((NSColor) -> Void)?
    /// "Custom…" — the toolbar opens the system color panel.
    var onCustomColorRequested: (() -> Void)?
    private var currentColor: NSColor

    private let presets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    init(currentColor: NSColor = .systemRed) {
        self.currentColor = currentColor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 160
        let btnSize: CGFloat = 28
        let gap: CGFloat = 8
        let padding: CGFloat = 12
        let rows = 2
        let cols = 4
        let gridH = CGFloat(rows) * btnSize + CGFloat(rows - 1) * gap
        let height = padding * 2 + gridH + 8 + 24

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var y = height - padding
        for row in 0..<rows {
            y -= btnSize
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < presets.count else { break }
                let x = padding + CGFloat(col) * (btnSize + gap)
                let btn = NSButton(frame: NSRect(x: x, y: y, width: btnSize, height: btnSize))
                btn.title = ""
                btn.alternateTitle = ""
                btn.attributedTitle = NSAttributedString(string: "")
                btn.imagePosition = .noImage
                btn.wantsLayer = true
                btn.layer?.cornerRadius = btnSize / 2
                btn.layer?.backgroundColor = presets[idx].cgColor
                btn.layer?.borderWidth = presets[idx] == .white ? 1 : 0
                btn.layer?.borderColor = NSColor.separatorColor.cgColor
                btn.isBordered = false
                btn.bezelStyle = .regularSquare
                btn.tag = idx
                btn.target = self
                btn.action = #selector(presetTapped(_:))
                let name = AnnotationToolbar.colorName(presets[idx])
                btn.toolTip = name
                btn.setAccessibilityLabel(name)
                container.addSubview(btn)
            }
            y -= gap
        }

        y -= 2
        let customBtn = NSButton(title: L("Custom\u{2026}"), target: self, action: #selector(customTapped))
        customBtn.bezelStyle = .inline
        customBtn.font = .systemFont(ofSize: 11)
        customBtn.frame = NSRect(x: padding, y: y - 20, width: width - padding * 2, height: 20)
        customBtn.setAccessibilityLabel(L("Custom color"))
        container.addSubview(customBtn)

        self.view = container
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let color = presets[sender.tag]
        currentColor = color
        onColorPicked?(color)
        dismiss(nil)
    }

    @objc private func customTapped() {
        dismiss(nil)
        onCustomColorRequested?()
    }
}
