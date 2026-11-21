import CoreGraphics
import Foundation

/// The rules that keep DisplayBar from leaving the Mac without a usable screen.
/// Pure functions so the self-test can exercise every branch without touching hardware.
enum Safety {
    /// Turning `ids` off is allowed only if at least one *physical* screen stays visible.
    /// A virtual display alone doesn't count: nothing can be seen on it.
    static func canTurnOff(_ ids: Set<CGDirectDisplayID>, visible: [CGDirectDisplayID], virtual: Set<CGDirectDisplayID>) -> Bool {
        guard !ids.isEmpty, ids.allSatisfy(visible.contains) else { return false }
        return visible.contains { !ids.contains($0) && !virtual.contains($0) }
    }

    /// Physical screens that can really be used: visible, not virtual, and not one DisplayBar
    /// turned off. A display DisplayBar disabled can still be *listed* by macOS (it lists the
    /// built-in panel again when nothing else is left, for example after the only external
    /// monitor was unplugged during sleep), so a recorded-off display never counts.
    static func usablePhysical(visible: [CGDirectDisplayID], virtual: Set<CGDirectDisplayID>, off: Set<CGDirectDisplayID>) -> Int {
        visible.filter { !virtual.contains($0) && !off.contains($0) }.count
    }

    /// Turn everything back on when no usable physical screen is left (for example, the
    /// external monitor was unplugged while the built-in display was off). Skipped with the lid
    /// closed, where an empty screen list means "going to sleep", and while the system sleeps.
    static func shouldRescue(visiblePhysical: Int, offCount: Int, lidClosed: Bool, sleeping: Bool) -> Bool {
        offCount > 0 && visiblePhysical == 0 && !lidClosed && !sleeping
    }

    /// Whether an "off" record can be dropped because the display came back on some other way.
    /// Only when it is visible *next to another usable screen*, outside sleep and the settling
    /// time after wake, and the record isn't young (macOS disables one display at a time).
    /// If it is the only thing listed, the record stays and the rescue turns it on properly.
    static func shouldForget(visible: Bool, othersUsable: Int, settling: Bool, young: Bool) -> Bool {
        visible && othersUsable > 0 && !settling && !young
    }

    /// The built-in panel is missing with the lid open and DisplayBar has no record of it, so
    /// it was disabled and the record was lost (or another app disabled it). After `adoptDelay`
    /// it is listed as off again, so the menu can turn it on and the rescue covers it.
    static let adoptDelay: TimeInterval = 4

    static func shouldAdoptBuiltin(offline: Bool, recorded: Bool, lidClosed: Bool, settling: Bool, missingFor: TimeInterval) -> Bool {
        offline && !recorded && !lidClosed && !settling && missingFor >= adoptDelay
    }
}
