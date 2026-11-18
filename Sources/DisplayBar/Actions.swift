import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable {
    case openMenu
    case toggleBuiltIn
    case toggleExternal
    case turnOffUnderPointer
    case turnOnAll
    case brightnessUp
    case brightnessDown
    case makeMainUnderPointer
    case volumeUp
    case volumeDown
    case muteToggle
    case arrange

    var title: String {
        switch self {
        case .openMenu: "Open the DisplayBar menu"
        case .toggleBuiltIn: "Turn built-in display off / on"
        case .toggleExternal: "Turn external displays off / on"
        case .turnOffUnderPointer: "Turn off the display under the pointer"
        case .turnOnAll: "Turn all displays back on"
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .makeMainUnderPointer: "Make the display under the pointer main"
        case .volumeUp: "Monitor volume up"
        case .volumeDown: "Monitor volume down"
        case .muteToggle: "Mute / unmute monitor"
        case .arrange: "Arrange displays"
        }
    }

    var defaultShortcut: Shortcut? {
        let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
        switch self {
        case .openMenu: return Shortcut(kVK_ANSI_D, hyper)
        case .toggleBuiltIn: return Shortcut(kVK_ANSI_B, hyper)
        case .toggleExternal: return Shortcut(kVK_ANSI_E, hyper)
        case .turnOnAll: return Shortcut(kVK_ANSI_R, hyper)
        case .brightnessUp: return Shortcut(kVK_UpArrow, hyper)
        case .brightnessDown: return Shortcut(kVK_DownArrow, hyper)
        case .turnOffUnderPointer, .makeMainUnderPointer, .volumeUp, .volumeDown, .muteToggle, .arrange: return nil
        }
    }
}

/// Where a shortcut is bound: a global action, or "toggle this display".
enum ShortcutTarget: Hashable {
    case action(HotkeyAction)
    case display(String)
}

enum Shortcuts {
    static func shortcut(for action: HotkeyAction) -> Shortcut? {
        if let override = Prefs.shortcuts[action.rawValue] { return override }
        return action.defaultShortcut
    }

    static func shortcut(forDisplay uuid: String) -> Shortcut? { Prefs.displayShortcuts[uuid] }

    static var all: [(ShortcutTarget, Shortcut)] {
        var result: [(ShortcutTarget, Shortcut)] = []
        for action in HotkeyAction.allCases {
            if let s = shortcut(for: action) { result.append((.action(action), s)) }
        }
        for (uuid, s) in Prefs.displayShortcuts { result.append((.display(uuid), s)) }
        return result
    }

    /// Binds `shortcut` to `target`, taking it away from anything else that had it.
    static func assign(_ shortcut: Shortcut?, to target: ShortcutTarget) {
        var actions = Prefs.shortcuts
        var displays = Prefs.displayShortcuts
        if let shortcut {
            for (other, existing) in all where existing == shortcut && other != target {
                switch other {
                case let .action(a): actions.updateValue(nil, forKey: a.rawValue)
                case let .display(uuid): displays[uuid] = nil
                }
            }
        }
        switch target {
        case let .action(a): actions.updateValue(shortcut, forKey: a.rawValue)
        case let .display(uuid): displays[uuid] = shortcut
        }
        Prefs.shortcuts = actions
        Prefs.displayShortcuts = displays
        reregister()
    }

    static func restoreDefaults() {
        Prefs.shortcuts = [:]
        Prefs.displayShortcuts = [:]
        reregister()
    }

    static func reregister() {
        let center = HotKeyCenter.shared
        guard !center.suspended else { return }
        center.removeAll()
        for action in HotkeyAction.allCases {
            if let s = shortcut(for: action) { center.register(s) { Actions.perform(action) } }
        }
        for (uuid, s) in Prefs.displayShortcuts {
            center.register(s) { Actions.toggleDisplay(uuid: uuid) }
        }
    }
}

enum Actions {
    private static var lastFired: [String: TimeInterval] = [:]

    /// A shortcut shown in an open menu can arrive both as the hotkey and as the menu
    /// command; this keeps toggles from running twice.
    private static func debounce(_ key: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFired[key], now - last < 0.3 { return false }
        lastFired[key] = now
        return true
    }

    static func perform(_ action: HotkeyAction) {
        let isBrightness = [.brightnessUp, .brightnessDown, .volumeUp, .volumeDown].contains(action)
        guard isBrightness || debounce(action.rawValue) else { return }
        let manager = DisplayManager.shared
        switch action {
        case .openMenu:
            (NSApp.delegate as? AppDelegate)?.menu?.open()
        case .toggleBuiltIn:
            manager.toggle(label: "built-in display", on: { $0.isBuiltin }, offMatch: { $0.isBuiltin })
        case .toggleExternal:
            manager.toggle(label: "external display", on: { !$0.isBuiltin }, offMatch: { !$0.isBuiltin && !$0.isVirtual })
        case .turnOffUnderPointer:
            if let d = manager.displayUnderPointer() { manager.turnOff([d.id], feedback: true) }
        case .turnOnAll:
            manager.turnOnAll(feedback: true)
        case .brightnessUp:
            stepBrightness(1 / 16)
        case .brightnessDown:
            stepBrightness(-1 / 16)
        case .makeMainUnderPointer:
            if let d = manager.displayUnderPointer() { manager.makeMain(d.id) }
        case .volumeUp, .volumeDown, .muteToggle:
            guard let d = MonitorAudio.shortcutTarget() else { return NSSound.beep() }
            if action == .muteToggle { manager.toggleMute(d) } else { manager.stepVolume(d, by: action == .volumeUp ? 1 / 16 : -1 / 16) }
        case .arrange:
            ArrangeWindowController.show()
        }
    }

    static func toggleDisplay(uuid: String) {
        guard debounce("display-" + uuid) else { return }
        DisplayManager.shared.toggle(uuid: uuid)
    }

    private static func stepBrightness(_ delta: Float) {
        let manager = DisplayManager.shared
        let targets = Prefs.brightnessAllDisplays
            ? manager.displays.filter { Brightness.kind($0) != nil }
            : [manager.displayUnderPointer()].compactMap { $0 }
        if targets.isEmpty { NSSound.beep() }
        for d in targets { Brightness.step(d, by: delta) }
    }
}
