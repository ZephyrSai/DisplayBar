import AppKit
import Carbon.HIToolbox

/// A key + modifiers combination, stored as a virtual key code so it survives layout changes.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifiers = flags.intersection(Self.relevant).rawValue
    }

    init(_ key: Int, _ flags: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt16(key), flags: flags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    var display: String { Self.symbols(flags) + Self.keyName(keyCode) }

    var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }

    /// Global shortcuts need ⌘, ⌃ or ⌥ (or a function key) so they don't swallow typing.
    var isValidGlobal: Bool { !flags.intersection([.command, .option, .control]).isEmpty || isFunctionKey }

    /// Character NSMenuItem needs to draw the shortcut next to a menu command.
    var menuKeyEquivalent: String? {
        if let scalar = Self.menuFunctionKeys[Int(keyCode)] { return String(Character(UnicodeScalar(scalar)!)) }
        if let fn = Self.functionKeys[Int(keyCode)] { return String(Character(UnicodeScalar(NSF1FunctionKey + fn - 1)!)) }
        guard let char = Self.translate(keyCode), char.count == 1 else { return nil }
        return char.lowercased()
    }

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    private static let menuFunctionKeys: [Int: Int] = [
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20,
        kVK_Delete: 0x08, kVK_Escape: 0x1B,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "Help",
    ]

    static func keyName(_ keyCode: UInt16) -> String {
        if let name = specialNames[Int(keyCode)] { return name }
        if let fn = functionKeys[Int(keyCode)] { return "F\(fn)" }
        return translate(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// The character the current (ASCII-capable) keyboard layout prints for a key.
    static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
    }
}

/// System-wide hotkeys through Carbon's RegisterEventHotKey: works in every app and
/// needs no Accessibility or Input Monitoring permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private(set) var failed: Set<Shortcut> = []
    private(set) var suspended = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
        failed.removeAll()
    }

    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        guard !suspended else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4442_4152), id: nextID) // 'DBAR'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failed.insert(shortcut)
            NSLog("DisplayBar: shortcut \(shortcut.display) is taken by another app (\(status))")
            return false
        }
        refs.append(ref)
        handlers[nextID] = handler
        nextID += 1
        return true
    }

    /// While a shortcut field is recording, every hotkey is released so the keys reach it.
    func suspend() {
        suspended = true
        removeAll()
    }

    func resume() {
        suspended = false
        Shortcuts.reregister()
    }
}
