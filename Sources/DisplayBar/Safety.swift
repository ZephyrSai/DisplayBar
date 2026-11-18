import CoreGraphics

/// The rules that keep DisplayBar from leaving the Mac without a usable screen.
/// Pure functions so the self-test can exercise every branch without touching hardware.
enum Safety {
    /// Turning `ids` off is allowed only if at least one *physical* screen stays visible.
    /// A virtual display alone doesn't count: nothing can be seen on it.
    static func canTurnOff(_ ids: Set<CGDirectDisplayID>, visible: [CGDirectDisplayID], virtual: Set<CGDirectDisplayID>) -> Bool {
        guard !ids.isEmpty, ids.allSatisfy(visible.contains) else { return false }
        return visible.contains { !ids.contains($0) && !virtual.contains($0) }
    }

    /// Turn everything back on when no physical screen is left (for example, the external
    /// monitor was unplugged while the built-in display was off). Skipped with the lid closed,
    /// where an empty screen list means "going to sleep", and while the system sleeps.
    static func shouldRescue(visiblePhysical: Int, offCount: Int, lidClosed: Bool, sleeping: Bool) -> Bool {
        offCount > 0 && visiblePhysical == 0 && !lidClosed && !sleeping
    }
}
