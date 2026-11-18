import AppKit
import CDisplayPrivate

/// The status item and its menu, rebuilt from live state each time it opens
/// (and in place while open, when displays change).
final class MenuController: NSObject, NSMenuDelegate {
    static let width: CGFloat = 310

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private(set) var isOpen = false
    private var sliders: [(display: Display, code: VCP?, view: SliderRowView)] = []

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "DisplayBar")
            button.image?.isTemplate = true
            button.toolTip = "DisplayBar"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: .displaysChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(valuesChanged), name: .displayValuesChanged, object: nil)
    }

    func open() { statusItem.button?.performClick(nil) }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { rebuild() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = true
        DisplayManager.shared.refreshLiveValues()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = false
        // Free the views, submenus and MonitorPanel objects while the menu is closed; it is
        // rebuilt on every open anyway. Delayed so a clicked item's action still runs first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.menu.removeAllItems()
            self.sliders.removeAll()
            DBMonitorPanel.reload()
            Memory.trimSoon()
        }
    }

    @objc private func displaysChanged() {
        updateIcon()
        if isOpen { rebuild() }
    }

    @objc private func valuesChanged() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        for entry in sliders {
            entry.view.setValue(value(entry.display, entry.code))
            if entry.code == .volume { entry.view.setSymbol(Self.volumeSymbol(entry.display)) }
        }
    }

    private func updateIcon() {
        let anyOff = !DisplayManager.shared.off.isEmpty
        statusItem.button?.image = NSImage(systemSymbolName: anyOff ? "display.and.arrow.down" : "display", accessibilityDescription: "DisplayBar")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "DisplayBar")
        statusItem.button?.image?.isTemplate = true
    }

    private static func volumeSymbol(_ d: Display) -> String {
        guard let v = d.vcp[.volume] else { return "speaker.wave.2.fill" }
        return d.mutedVolume != nil || v.current == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private func value(_ d: Display, _ code: VCP?) -> Float? {
        guard let code else { return Brightness.get(d) }
        guard let v = d.vcp[code] else { return nil }
        return Float(v.current) / Float(max(1, v.max))
    }

    // MARK: Building

    func rebuild() {
        menu.removeAllItems()
        sliders.removeAll()
        let manager = DisplayManager.shared
        let ordered = manager.displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.isVirtual != b.isVirtual { return !a.isVirtual }
            return (a.bounds.minX, a.bounds.minY) < (b.bounds.minX, b.bounds.minY)
        }
        for (index, d) in ordered.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: d)
        }
        if !manager.off.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Turned Off"))
            for o in manager.off { addOffRow(o) }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Turn All Displays On", symbol: "power", shortcut: Shortcuts.shortcut(for: .turnOnAll),
                                enabled: !manager.off.isEmpty || !manager.ddcAsleep.isEmpty) {
            Actions.perform(.turnOnAll) // same debounced path as the hotkey
        })
        menu.addItem(ActionItem("Arrange Displays…", symbol: "rectangle.3.group", shortcut: Shortcuts.shortcut(for: .arrange),
                                enabled: manager.displays.count > 1) { ArrangeWindowController.show() })
        menu.addItem(.submenu("Virtual Displays", symbol: "rectangle.dashed", virtualMenu()))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…", symbol: "gearshape") { SettingsWindowController.show() }.withKey(","))
        menu.addItem(ActionItem("Quit DisplayBar", symbol: "xmark.rectangle") { NSApp.terminate(nil) }.withKey("q"))
    }

    private func addSection(for d: Display) {
        let manager = DisplayManager.shared
        let canTurnOff = manager.canTurnOff([d.id])
        let header = DisplayHeaderView(width: Self.width, symbol: d.symbol, title: d.name, subtitle: manager.subtitle(d),
                                       isOn: true, canToggle: canTurnOff)
        if !canTurnOff { header.toggle.toolTip = "This is the only screen left, so it stays on." }
        header.onToggle = { [weak self] on in
            guard !on else { return }
            // Close the menu first: it may be drawn on the display that's going away.
            self?.menu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                DisplayManager.shared.turnOff([d.id], feedback: true)
            }
        }
        menu.addItem(.view(header))

        if Brightness.kind(d) != nil {
            let slider = SliderRowView(width: Self.width, symbol: "sun.max.fill", accessibility: "Brightness of \(d.name)")
            slider.setValue(Brightness.get(d))
            slider.onChange = { Brightness.set(d, $0) }
            sliders.append((d, nil, slider))
            menu.addItem(.view(slider))
        }
        if d.vcp[.volume] != nil {
            let slider = SliderRowView(width: Self.width, symbol: Self.volumeSymbol(d), accessibility: "Volume of \(d.name)")
            slider.setValue(value(d, .volume))
            slider.onChange = { DisplayManager.shared.setVolume(d, fraction: $0) }
            slider.onIconClick = { DisplayManager.shared.toggleMute(d) }
            slider.iconToolTip = "Mute / unmute"
            sliders.append((d, .volume, slider))
            menu.addItem(.view(slider))
        }

        if let current = manager.currentMode(d.id) {
            let title = current.resolutionTitle + (current.hiDPI ? " HiDPI" : "")
            menu.addItem(.submenu(title, symbol: "aspectratio", resolutionMenu(for: d)))
        }
        menu.addItem(.submenu("Display Options", symbol: "slider.horizontal.3", optionsMenu(for: d)))
    }

    private func addOffRow(_ o: OffDisplay) {
        let header = DisplayHeaderView(width: Self.width, symbol: Display.symbol(builtin: o.isBuiltin, virtual: o.isVirtual),
                                       title: o.name, subtitle: "Off", isOn: false, canToggle: true)
        header.onToggle = { on in
            if on { DisplayManager.shared.turnOn([o.id]) }
        }
        menu.addItem(.view(header))
    }

    private func resolutionMenu(for d: Display) -> NSMenu {
        let manager = DisplayManager.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = manager.currentMode(d.id)
        var previousHiDPI: Bool?
        for choice in manager.resolutionChoices(d.id, showAll: Prefs.showAllModes) {
            if let previous = previousHiDPI, previous != choice.hiDPI { menu.addItem(.separator()) }
            previousHiDPI = choice.hiDPI
            let item = ActionItem("", checked: current?.resolutionKey == choice.resolutionKey) {
                manager.setMode(d.id, choice.mode)
            }
            item.attributedTitle = choice.attributedTitle
            menu.addItem(item)
        }
        let rates = manager.refreshChoices(d.id)
        if rates.count > 1 {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Refresh Rate"))
            for rate in rates {
                menu.addItem(ActionItem(rate.refreshTitle, checked: rate.refreshKey == current?.refreshKey) {
                    manager.setMode(d.id, rate.mode)
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show All Resolutions", checked: Prefs.showAllModes) {
            Prefs.showAllModes.toggle()
        })
        return menu
    }

    private func optionsMenu(for d: Display) -> NSMenu {
        let manager = DisplayManager.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Picture
        if DBMonitorPanel.canRotate(d.id) {
            let rotation = Int(CGDisplayRotation(d.id).rounded())
            let sub = NSMenu()
            for degrees in [0, 90, 180, 270] {
                sub.addItem(ActionItem(degrees == 0 ? "Standard" : "\(degrees)°", checked: rotation == degrees) {
                    manager.setRotation(degrees, of: d.id)
                })
            }
            menu.addItem(.submenu("Rotation", symbol: "rotate.right", sub))
        }
        if DBMonitorPanel.hasHDR(d.id) {
            let enabled = DBMonitorPanel.isHDREnabled(d.id)
            menu.addItem(ActionItem("High Dynamic Range", symbol: "sparkles", checked: enabled) {
                DBMonitorPanel.setHDR(!enabled, on: d.id)
                manager.scheduleRefresh(after: 1)
            })
        }
        let presets = DBMonitorPanel.presetNames(d.id)
        if !presets.isEmpty {
            let active = DBMonitorPanel.activePresetIndex(d.id)
            let sub = NSMenu()
            for (index, name) in presets.enumerated() {
                sub.addItem(ActionItem(name, checked: index == active) { DBMonitorPanel.setPreset(index, on: d.id) })
            }
            menu.addItem(.submenu("Preset", symbol: "paintpalette", sub))
        }

        // Monitor controls (DDC)
        if d.ddc != nil {
            var addedHeader = false
            func header() {
                if !addedHeader { menu.addItem(.separator()); menu.addItem(.sectionHeader(title: "Monitor")); addedHeader = true }
            }
            for (code, symbol, label) in [(VCP.contrast, "circle.lefthalf.filled", "Contrast")]
                where d.vcp[code] != nil {
                header()
                let slider = SliderRowView(width: 260, symbol: symbol, accessibility: "\(label) of \(d.name)")
                slider.setValue(value(d, code))
                slider.onChange = { manager.setVCP(code, fraction: $0, on: d) }
                sliders.append((d, code, slider))
                menu.addItem(.view(slider))
            }
            if !d.vcpUnsupported.contains(.input) {
                header()
                let current = d.vcp[.input]?.current
                let sub = NSMenu()
                for source in InputSource.allCases {
                    sub.addItem(ActionItem(source.title, checked: current.map { $0 & 0xFF == source.rawValue } ?? false) {
                        manager.setInput(source, on: d)
                    })
                }
                menu.addItem(.submenu("Input Source", symbol: "cable.connector", sub))
            }
            if manager.ddcAsleep.contains(d.id) {
                header()
                menu.addItem(ActionItem("Wake Monitor", symbol: "sun.max") { manager.ddcWake(d) })
            } else {
                header()
                menu.addItem(ActionItem("Sleep Monitor (stays connected)", symbol: "moon", enabled: manager.canTurnOff([d.id])) {
                    manager.ddcSleep(d)
                })
            }
        }

        // Arrangement
        menu.addItem(.separator())
        menu.addItem(ActionItem("Use as Main Display", symbol: "menubar.rectangle", checked: d.isMain, enabled: !d.isMain) {
            manager.makeMain(d.id)
        })
        let others = manager.displays.filter { $0.id != d.id }
        if !others.isEmpty {
            let master = CGDisplayMirrorsDisplay(d.id)
            let sub = NSMenu()
            sub.addItem(ActionItem("Off", checked: master == kCGNullDirectDisplay) { manager.mirror(d.id, of: nil) })
            sub.addItem(.separator())
            for other in others {
                sub.addItem(ActionItem("Show \(other.name)", checked: master == other.id) { manager.mirror(d.id, of: other.id) })
            }
            menu.addItem(.submenu("Mirror", symbol: "rectangle.on.rectangle", sub))
        }
        menu.addItem(ActionItem("Rename…", symbol: "pencil") { Self.rename(d) })

        // Power
        menu.addItem(.separator())
        menu.addItem(ActionItem("Turn Off", symbol: "power", shortcut: Shortcuts.shortcut(forDisplay: d.uuid),
                                enabled: manager.canTurnOff([d.id])) {
            Actions.toggleDisplay(uuid: d.uuid) // debounced: the hotkey may fire too
        })
        if let spec = VirtualDisplays.shared.spec(for: d.id) {
            menu.addItem(ActionItem("Remove Virtual Display", symbol: "trash") {
                VirtualDisplays.shared.remove(serial: spec.serial)
            })
        }
        return menu
    }

    private func virtualMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let virtuals = VirtualDisplays.shared
        if !virtuals.specs.isEmpty {
            for spec in virtuals.specs {
                menu.addItem(ActionItem("Remove \(spec.title)", symbol: "minus.circle") {
                    virtuals.remove(serial: spec.serial)
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "New Virtual Display"))
        for preset in VirtualSpec.presets {
            menu.addItem(ActionItem(preset.title) { virtuals.create(preset) })
        }
        return menu
    }

    private static func rename(_ d: Display) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename \(d.name)"
        alert.informativeText = "Leave empty to use the name macOS reports (\(d.systemName))."
        let field = NSTextField(string: Prefs.customNames[d.uuid] ?? "")
        field.placeholderString = d.systemName
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var names = Prefs.customNames
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        names[d.uuid] = name.isEmpty ? nil : name
        Prefs.customNames = names
        DisplayManager.shared.refresh(probe: false)
    }
}

private extension NSMenuItem {
    func withKey(_ key: String) -> NSMenuItem {
        keyEquivalent = key
        keyEquivalentModifierMask = .command
        return self
    }
}
