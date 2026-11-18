import AppKit

/// Small on-screen indicator (brightness level, "display is off", errors) in the
/// top-right corner of the target screen, like the system's own HUDs on macOS 26.
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, title text: String, subtitle detail: String?, level: Float? = nil, on screen: NSScreen? = nil) {
        let panel = panel ?? makePanel()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = text
        subtitle.stringValue = detail ?? ""
        subtitle.isHidden = detail == nil
        bar.isHidden = level == nil
        bar.level = CGFloat(level ?? 0)

        let width: CGFloat = 280
        let height: CGFloat = (level != nil || detail != nil) ? 64 : 48
        layout(width: width, height: height, hasSecondLine: level != nil || detail != nil)

        guard let target = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = target.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - width - 14, y: frame.maxY - height - 14, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     panel?.orderOut(nil)
                                                     self?.releasePanel()
                                                 })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail != nil ? 2.6 : 1.4), execute: work)
    }

    /// The HUD window is recreated on demand; nothing stays allocated while it's hidden.
    private func releasePanel() {
        guard let panel, panel.alphaValue == 0 else { return }
        [icon, title, subtitle, bar].forEach { $0.removeFromSuperview() }
        panel.contentView = nil
        self.panel = nil
        Memory.trimSoon()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .labelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        [icon, title, subtitle, bar].forEach(background.addSubview)
        self.panel = panel
        return panel
    }

    private func layout(width: CGFloat, height: CGFloat, hasSecondLine: Bool) {
        icon.frame = NSRect(x: 16, y: (height - 28) / 2, width: 28, height: 28)
        let x: CGFloat = 54, textWidth = width - x - 16
        if hasSecondLine {
            title.frame = NSRect(x: x, y: height - 30, width: textWidth, height: 17)
            subtitle.frame = NSRect(x: x, y: 14, width: textWidth, height: 15)
            bar.frame = NSRect(x: x, y: 17, width: textWidth, height: 6)
        } else {
            title.frame = NSRect(x: x, y: (height - 17) / 2, width: textWidth, height: 17)
        }
    }
}

final class LevelBar: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * min(1, max(0, level))), height: bounds.height)
        NSColor.labelColor.withAlphaComponent(level > 0 ? 0.85 : 0).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
