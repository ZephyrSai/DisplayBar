import AppKit

/// Menu command backed by a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, shortcut: Shortcut? = nil, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let shortcut, let key = shortcut.menuKeyEquivalent {
            keyEquivalent = key
            keyEquivalentModifierMask = shortcut.flags
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenuItem {
    static func view(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.submenu = menu
        return item
    }
}

/// Display name, current mode and an on/off switch: the switch is the "turn off" control.
final class DisplayHeaderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    var onToggle: ((Bool) -> Void)?

    static let height: CGFloat = 46

    init(width: CGFloat, symbol: String, title text: String, subtitle detail: String, isOn: Bool, canToggle: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = isOn ? .labelColor : .tertiaryLabelColor
        icon.frame = NSRect(x: 14, y: (Self.height - 24) / 2, width: 24, height: 24)

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.isEnabled = canToggle
        toggle.target = self
        toggle.action = #selector(toggled)
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: width - 14 - size.width, y: (Self.height - size.height) / 2, width: size.width, height: size.height)

        let textX: CGFloat = 46
        let textWidth = toggle.frame.minX - 10 - textX
        title.stringValue = text
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = isOn ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: 23, width: textWidth, height: 17)
        subtitle.stringValue = detail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: textX, y: 7, width: textWidth, height: 15)

        [icon, title, subtitle, toggle].forEach(addSubview)
        setAccessibilityElement(false)
        toggle.setAccessibilityLabel(isOn ? "Turn off \(text)" : "Turn on \(text)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { onToggle?(toggle.state == .on) }
}

/// Icon + continuous slider + percentage, for brightness / contrast / volume.
final class SliderRowView: NSView {
    let slider = NSSlider()
    private let icon = NSButton()
    private let label = NSTextField(labelWithString: "")
    var onChange: ((Float) -> Void)?
    /// Makes the icon a button (volume: click to mute).
    var onIconClick: (() -> Void)? { didSet { (icon.cell as? NSButtonCell)?.highlightsBy = onIconClick == nil ? [] : .contentsCellMask } }
    var iconToolTip: String? {
        get { icon.toolTip }
        set { icon.toolTip = newValue }
    }

    init(width: CGFloat, symbol: String, accessibility: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.isBordered = false
        icon.imagePosition = .imageOnly
        (icon.cell as? NSButtonCell)?.highlightsBy = []
        icon.target = self
        icon.action = #selector(iconClicked)
        icon.frame = NSRect(x: 16, y: 4, width: 22, height: 20)

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        slider.frame = NSRect(x: 44, y: 4, width: width - 44 - 54, height: 20)
        slider.setAccessibilityLabel(accessibility)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.frame = NSRect(x: width - 50, y: 7, width: 36, height: 14)
        [icon, slider, label].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ value: Float?) {
        if let value {
            slider.isEnabled = true
            slider.floatValue = value
            label.stringValue = "\(Int((value * 100).rounded()))%"
        } else {
            slider.isEnabled = false
            label.stringValue = "…"
        }
    }

    func setSymbol(_ symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: icon.image?.accessibilityDescription)
    }

    @objc private func iconClicked() {
        onIconClick?()
    }

    @objc private func changed() {
        label.stringValue = "\(Int((slider.floatValue * 100).rounded()))%"
        onChange?(slider.floatValue)
    }
}
