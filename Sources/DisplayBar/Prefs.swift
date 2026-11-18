import Foundation

/// A display DisplayBar has turned off. macOS stops listing a disabled display entirely,
/// so this record is the only handle left to bring it back.
struct OffDisplay: Codable, Equatable {
    var id: UInt32
    var uuid: String
    var name: String
    var isBuiltin: Bool
    var isVirtual: Bool
}

enum Prefs {
    private(set) static var store = UserDefaults.standard

    /// Test/CLI runs use their own, wiped domain so they never touch the real app's state.
    static func useSuite(_ name: String) {
        store.removePersistentDomain(forName: name)
        store = UserDefaults(suiteName: name) ?? .standard
    }

    static func register() {
        store.register(defaults: [
            "reconnectOnQuit": true,
            "showAllModes": false,
            "brightnessAllDisplays": false,
            "restoreVirtual": true,
            "brightnessKeys": false,
            "volumeKeys": false,
        ])
    }

    static var reconnectOnQuit: Bool {
        get { store.bool(forKey: "reconnectOnQuit") }
        set { store.set(newValue, forKey: "reconnectOnQuit") }
    }

    static var showAllModes: Bool {
        get { store.bool(forKey: "showAllModes") }
        set { store.set(newValue, forKey: "showAllModes") }
    }

    /// Brightness shortcuts act on every display instead of the one under the pointer.
    static var brightnessAllDisplays: Bool {
        get { store.bool(forKey: "brightnessAllDisplays") }
        set { store.set(newValue, forKey: "brightnessAllDisplays") }
    }

    static var restoreVirtual: Bool {
        get { store.bool(forKey: "restoreVirtual") }
        set { store.set(newValue, forKey: "restoreVirtual") }
    }

    /// Keyboard brightness keys drive the external display under the pointer (needs Accessibility).
    static var brightnessKeys: Bool {
        get { store.bool(forKey: "brightnessKeys") }
        set { store.set(newValue, forKey: "brightnessKeys") }
    }

    /// Keyboard volume keys drive a monitor's speakers over DDC (needs Accessibility).
    static var volumeKeys: Bool {
        get { store.bool(forKey: "volumeKeys") }
        set { store.set(newValue, forKey: "volumeKeys") }
    }

    static var offDisplays: [OffDisplay] {
        get { load("offDisplays") ?? [] }
        set { save(newValue, "offDisplays") }
    }

    static var virtualSpecs: [VirtualSpec] {
        get { load("virtualSpecs") ?? [] }
        set { save(newValue, "virtualSpecs") }
    }

    /// Per-action overrides. A key mapped to `nil` means "cleared by the user".
    static var shortcuts: [String: Shortcut?] {
        get { load("shortcuts") ?? [:] }
        set { save(newValue, "shortcuts") }
    }

    /// Display UUID → "turn this display on/off" shortcut.
    static var displayShortcuts: [String: Shortcut] {
        get { load("displayShortcuts") ?? [:] }
        set { save(newValue, "displayShortcuts") }
    }

    static var customNames: [String: String] {
        get { load("customNames") ?? [:] }
        set { save(newValue, "customNames") }
    }

    /// Display UUID → last seen name, so shortcuts can be set for displays not plugged in.
    static var knownDisplays: [String: String] {
        get { load("knownDisplays") ?? [:] }
        set { save(newValue, "knownDisplays") }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        store.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
