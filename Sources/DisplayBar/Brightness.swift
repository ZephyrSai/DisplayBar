import AppKit
import CoreGraphics

/// Unified brightness: DisplayServices for Apple panels, DDC/CI for monitors that answer it,
/// gamma-table dimming for everything else.
enum Brightness {
    enum Kind { case native, ddc, software }

    static func kind(_ d: Display) -> Kind? {
        if d.isVirtual { return nil }
        // Built-in panels and Apple displays (Studio/Pro Display) go through DisplayServices.
        if Private.getBrightness != nil, Private.canChangeBrightness?(d.id) ?? d.isBuiltin { return .native }
        if d.ddc != nil, d.vcp[.brightness] != nil || !d.probed { return .ddc }
        return .software
    }

    /// 0…1, or nil while a DDC read is outstanding.
    static func get(_ d: Display) -> Float? {
        switch kind(d) {
        case .native:
            var value: Float = 0
            return Private.getBrightness?(d.id, &value) == 0 ? value : nil
        case .ddc:
            guard let v = d.vcp[.brightness] else { return nil }
            return Float(v.current) / Float(max(1, v.max))
        case .software:
            return Gamma.shared.level(d.id)
        case nil:
            return nil
        }
    }

    static func set(_ d: Display, _ value: Float) {
        let value = min(1, max(0, value))
        switch kind(d) {
        case .native: _ = Private.setBrightness?(d.id, value)
        case .ddc: DisplayManager.shared.setVCP(.brightness, fraction: value, on: d)
        case .software: Gamma.shared.set(d.id, value)
        case nil: break
        }
    }

    /// Steps in sixteenths like the system brightness keys and shows the HUD.
    static func step(_ d: Display, by delta: Float) {
        guard kind(d) != nil, let current = get(d) else {
            NSSound.beep()
            return
        }
        let next = min(1, max(0, ((current + delta) * 16).rounded() / 16))
        set(d, next)
        HUD.shared.show(symbol: next == 0 ? "sun.min" : "sun.max.fill", title: d.name, subtitle: nil, level: next, on: d.screen)
        NotificationCenter.default.post(name: .displayValuesChanged, object: nil)
    }
}

/// Software dimming by scaling the display's gamma table. macOS restores the
/// tables automatically when the process exits, so a crash can't leave a screen dim.
final class Gamma {
    static let shared = Gamma()
    private var levels: [CGDirectDisplayID: Float] = [:]
    private var base: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]
    static let floor: Float = 0.1

    func level(_ id: CGDirectDisplayID) -> Float { levels[id] ?? 1 }

    func set(_ id: CGDirectDisplayID, _ value: Float) {
        if base[id] == nil { capture(id) }
        levels[id] = max(Self.floor, min(1, value))
        apply(id)
    }

    func reapply(online: Set<CGDirectDisplayID>) {
        for id in levels.keys where !online.contains(id) {
            levels[id] = nil
            base[id] = nil
        }
        for id in levels.keys { apply(id) }
    }

    func restore() {
        guard !levels.isEmpty else { return }
        levels.removeAll()
        base.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    private func capture(_ id: CGDirectDisplayID) {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 0 else { return }
        base[id] = (Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count))))
    }

    private func apply(_ id: CGDirectDisplayID) {
        guard let table = base[id], let level = levels[id] else { return }
        let r = table.r.map { $0 * level }, g = table.g.map { $0 * level }, b = table.b.map { $0 * level }
        CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
    }
}
