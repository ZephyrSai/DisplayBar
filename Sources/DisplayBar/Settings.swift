import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Exists only while the window is open; closing releases the whole window.
    private(set) static var current: SettingsWindowController?

    static func show(tab: Int? = nil) {
        let controller = current ?? SettingsWindowController()
        current = controller
        controller.present(tab: tab)
    }

    private let tabs = NSTabViewController()
    private var centered = false

    private init() {
        tabs.tabStyle = .toolbar
        let general = NSTabViewItem(viewController: GeneralPane())
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let shortcuts = NSTabViewItem(viewController: ShortcutsPane())
        shortcuts.label = "Shortcuts"
        shortcuts.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(shortcuts)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func present(tab: Int?) {
        if let tab { tabs.selectedTabViewItemIndex = tab }
        (tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController as? Reloadable)?.reload()
        NSApp.activate(ignoringOtherApps: true)
        if !centered { window?.center(); centered = true }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { ShortcutRecorder.active?.stop() }
    func windowDidBecomeKey(_ notification: Notification) {
        MediaKeys.shared.update()
        (tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController as? Reloadable)?.reload()
    }

    func windowWillClose(_ notification: Notification) {
        ShortcutRecorder.active?.stop()
        DispatchQueue.main.async {
            SettingsWindowController.current = nil
            Memory.trimSoon()
        }
    }
}

protocol Reloadable: AnyObject { func reload() }

private func label(_ text: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    if bold { field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
    if secondary {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
    }
    return field
}

private func wrapping(_ text: String, width: CGFloat) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = width
    return field
}

// MARK: - General

final class GeneralPane: NSViewController, Reloadable {
    private let login = NSButton(checkboxWithTitle: "Open DisplayBar at login", target: nil, action: nil)
    private let reconnect = NSButton(checkboxWithTitle: "Turn displays back on when DisplayBar quits", target: nil, action: nil)
    private let allModes = NSButton(checkboxWithTitle: "Show all resolutions, including low-resolution modes", target: nil, action: nil)
    private let restoreVirtual = NSButton(checkboxWithTitle: "Recreate virtual displays when DisplayBar opens", target: nil, action: nil)
    private let brightnessTarget = NSPopUpButton()
    private let brightnessKeys = NSButton(checkboxWithTitle: "Brightness keys control the external display under the pointer", target: nil, action: nil)
    private let volumeKeys = NSButton(checkboxWithTitle: "Volume keys control a monitor's speakers when sound plays through it", target: nil, action: nil)
    private let keysStatus = NSTextField(wrappingLabelWithString: "")
    private let openAccessibility = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)

    override func loadView() {
        title = "General"
        [login, reconnect, allModes, restoreVirtual, brightnessKeys, volumeKeys].forEach { $0.target = self; $0.action = #selector(changed(_:)) }
        openAccessibility.target = self
        openAccessibility.action = #selector(openPrivacy)
        openAccessibility.controlSize = .small
        keysStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keysStatus.textColor = .secondaryLabelColor
        keysStatus.preferredMaxLayoutWidth = 360
        brightnessTarget.addItems(withTitles: ["The display under the pointer", "All displays"])
        brightnessTarget.target = self
        brightnessTarget.action = #selector(changed(_:))

        let grid = NSGridView(views: [
            [label("Startup:"), login],
            [label("Safety:"), reconnect],
            [NSGridCell.emptyContentView, wrapping("If turning a display off would leave no screen (for example, the external monitor is unplugged while the built-in display is off), DisplayBar turns displays back on by itself.", width: 360)],
            [label("Resolutions:"), allModes],
            [label("Brightness shortcuts:"), brightnessTarget],
            [label("Virtual displays:"), restoreVirtual],
            [label("Keyboard:"), brightnessKeys],
            [NSGridCell.emptyContentView, volumeKeys],
            [NSGridCell.emptyContentView, keysStatus],
            [NSGridCell.emptyContentView, openAccessibility],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).topPadding = -4
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            root.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = root
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        preferredContentSize = view.fittingSize
    }

    func reload() {
        guard isViewLoaded else { return }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        reconnect.state = Prefs.reconnectOnQuit ? .on : .off
        allModes.state = Prefs.showAllModes ? .on : .off
        restoreVirtual.state = Prefs.restoreVirtual ? .on : .off
        brightnessTarget.selectItem(at: Prefs.brightnessAllDisplays ? 1 : 0)
        brightnessKeys.state = Prefs.brightnessKeys ? .on : .off
        volumeKeys.state = Prefs.volumeKeys ? .on : .off
        let trusted = AXIsProcessTrusted()
        if MediaKeys.wanted && !trusted {
            keysStatus.stringValue = "Needs Accessibility permission: allow DisplayBar in Privacy & Security › Accessibility. Keys the system handles itself (the built-in screen, speakers with their own volume) keep working as usual."
        } else {
            keysStatus.stringValue = "Keys the system handles itself (the built-in screen, speakers with their own volume) keep working as usual. ⌥⇧ + key changes in quarter steps. If another app such as EQBar already handles the volume keys, leave volume off here."
        }
        openAccessibility.isHidden = !(MediaKeys.wanted && !trusted)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func changed(_ sender: NSControl) {
        switch sender {
        case login:
            do {
                if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
            reload()
        case reconnect: Prefs.reconnectOnQuit = reconnect.state == .on
        case allModes: Prefs.showAllModes = allModes.state == .on
        case restoreVirtual: Prefs.restoreVirtual = restoreVirtual.state == .on
        case brightnessTarget: Prefs.brightnessAllDisplays = brightnessTarget.indexOfSelectedItem == 1
        case brightnessKeys, volumeKeys:
            Prefs.brightnessKeys = brightnessKeys.state == .on
            Prefs.volumeKeys = volumeKeys.state == .on
            MediaKeys.shared.update(prompt: (sender as? NSButton)?.state == .on)
            reload()
        default: break
        }
    }
}

// MARK: - Shortcuts

final class ShortcutsPane: NSViewController, Reloadable {
    private let grid = NSGridView()
    private var recorders: [(ShortcutTarget, ShortcutRecorder)] = []

    override func loadView() {
        title = "Shortcuts"
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let note = wrapping("Shortcuts work in every app and need no extra permissions. Click a field and press the keys; Delete clears it, Esc cancels.", width: 470)
        let defaults = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        defaults.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        [grid, note, defaults].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            note.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            defaults.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            defaults.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            defaults.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = root
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        recorders.removeAll()

        grid.addRow(with: [label("Actions", bold: true), NSGridCell.emptyContentView])
        for action in HotkeyAction.allCases {
            addRow(action.title, target: .action(action), shortcut: Shortcuts.shortcut(for: action))
        }

        var known = Prefs.knownDisplays
        for o in DisplayManager.shared.off where !o.isVirtual { known[o.uuid] = o.name }
        if !known.isEmpty {
            let spacer = grid.addRow(with: [label("Turn a specific display off / on", bold: true), NSGridCell.emptyContentView])
            spacer.topPadding = 10
            let current = Set(DisplayManager.shared.displays.map(\.uuid) + DisplayManager.shared.off.map(\.uuid))
            for (uuid, name) in known.sorted(by: { $0.value < $1.value }) {
                let suffix = current.contains(uuid) ? "" : "  (not connected)"
                addRow(name + suffix, target: .display(uuid), shortcut: Shortcuts.shortcut(forDisplay: uuid))
            }
        }
        grid.column(at: 0).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        preferredContentSize = view.fittingSize
    }

    private func addRow(_ title: String, target: ShortcutTarget, shortcut: Shortcut?) {
        let recorder = ShortcutRecorder()
        recorder.shortcut = shortcut
        recorder.onChange = { [weak self] new in
            Shortcuts.assign(new, to: target)
            self?.reload()
        }
        recorders.append((target, recorder))
        let text = label(title)
        text.lineBreakMode = .byTruncatingTail
        grid.addRow(with: [text, recorder])
    }

    @objc private func restoreDefaults() {
        Shortcuts.restoreDefaults()
        reload()
    }
}

/// Click-to-record shortcut field.
final class ShortcutRecorder: NSView {
    static weak var active: ShortcutRecorder?

    var shortcut: Shortcut? { didSet { refresh() } }
    var onChange: ((Shortcut?) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private let clear = NSButton(title: "", target: nil, action: nil)
    private var monitor: Any?
    private var recording = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 196, height: 24))
        button.bezelStyle = .push
        button.controlSize = .regular
        button.frame = NSRect(x: 0, y: 0, width: 170, height: 24)
        button.target = self
        button.action = #selector(toggleRecording)
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clear.isBordered = false
        clear.contentTintColor = .tertiaryLabelColor
        clear.frame = NSRect(x: 176, y: 3, width: 18, height: 18)
        clear.target = self
        clear.action = #selector(clearShortcut)
        addSubview(button)
        addSubview(clear)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 196, height: 24) }
    override var firstBaselineOffsetFromTop: CGFloat { button.firstBaselineOffsetFromTop }

    private func refresh() {
        if recording {
            button.title = "Type shortcut…"
        } else if let shortcut {
            let taken = HotKeyCenter.shared.failed.contains(shortcut)
            button.title = (taken ? "⚠︎ " : "") + shortcut.display
            button.toolTip = taken ? "Another app already uses this shortcut, so it can't be registered." : nil
        } else {
            button.title = "Record Shortcut"
            button.toolTip = nil
        }
        clear.isHidden = shortcut == nil || recording
    }

    @objc private func toggleRecording() {
        recording ? stop() : start()
    }

    @objc private func clearShortcut() {
        shortcut = nil
        onChange?(nil)
    }

    private func start() {
        ShortcutRecorder.active?.stop()
        ShortcutRecorder.active = self
        recording = true
        refresh()
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if ShortcutRecorder.active === self { ShortcutRecorder.active = nil }
        HotKeyCenter.shared.resume()
        refresh()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        if event.type == .flagsChanged {
            button.title = flags.isEmpty ? "Type shortcut…" : Shortcut.symbols(flags)
            return nil
        }
        if flags.isEmpty, event.keyCode == UInt16(kVK_Escape) {
            stop()
            return nil
        }
        if flags.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            stop()
            clearShortcut()
            return nil
        }
        let candidate = Shortcut(keyCode: event.keyCode, flags: flags)
        guard candidate.isValidGlobal else {
            NSSound.beep()
            return nil
        }
        stop()
        shortcut = candidate
        onChange?(candidate)
        return nil
    }
}
