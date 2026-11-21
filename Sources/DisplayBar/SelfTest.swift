import AppKit
import Carbon.HIToolbox
import CDisplayPrivate

/// `DisplayBar --selftest`: exercises the safety rules, shortcuts and the real
/// disconnect/reconnect path on a temporary virtual display. Physical displays are only
/// read (plus a same-value DDC write), never turned off or reconfigured.
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ message: String) {
        print(ok ? "PASS" : "FAIL", message)
        if !ok { failures += 1 }
    }

    @discardableResult
    private static func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    static func run() {
        logic()
        arrangementMath()
        shortcuts()
        offRecords()
        // --no-displays: skip everything that adds/removes/reconfigures displays
        // (each reconfiguration makes macOS redraw the menu bar).
        if !CommandLine.arguments.contains("--no-displays") {
            live()
            rescue()
            manyDisplays()
        }
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func logic() {
        print("— safety rules")
        check(Safety.canTurnOff([1], visible: [1, 2], virtual: []), "built-in can go off while an external is visible")
        check(!Safety.canTurnOff([1], visible: [1], virtual: []), "the only screen can't go off")
        check(!Safety.canTurnOff([1], visible: [1, 9], virtual: [9]), "a virtual display doesn't count as a remaining screen")
        check(Safety.canTurnOff([9], visible: [1, 9], virtual: [9]), "a virtual display can go off")
        check(!Safety.canTurnOff([1, 2], visible: [1, 2], virtual: []), "can't turn every screen off at once")
        check(!Safety.canTurnOff([3], visible: [1, 2], virtual: []), "can't turn off a display that isn't visible")
        check(Safety.shouldRescue(visiblePhysical: 0, offCount: 1, lidClosed: false, sleeping: false), "rescue when no screen is left")
        check(!Safety.shouldRescue(visiblePhysical: 0, offCount: 1, lidClosed: true, sleeping: false), "no rescue with the lid closed")
        check(!Safety.shouldRescue(visiblePhysical: 0, offCount: 1, lidClosed: false, sleeping: true), "no rescue while sleeping")
        check(!Safety.shouldRescue(visiblePhysical: 1, offCount: 1, lidClosed: false, sleeping: false), "no rescue while a screen is visible")
        check(!Safety.shouldRescue(visiblePhysical: 0, offCount: 0, lidClosed: false, sleeping: false), "no rescue when nothing is off")
        check(Safety.usablePhysical(visible: [1], virtual: [], off: [1]) == 0, "a display we turned off doesn't count as usable even when macOS lists it")
        check(Safety.usablePhysical(visible: [1, 2, 9], virtual: [9], off: [1]) == 1, "usable screens skip virtual and turned-off displays")
        check(Safety.shouldForget(visible: true, othersUsable: 1, settling: false, young: false), "a record is dropped once its display is back on next to another screen")
        check(!Safety.shouldForget(visible: true, othersUsable: 0, settling: false, young: false), "a record stays while its display is the only thing listed (the rescue turns it on)")
        check(!Safety.shouldForget(visible: true, othersUsable: 1, settling: true, young: false), "a record stays during sleep and right after wake")
        check(!Safety.shouldForget(visible: true, othersUsable: 1, settling: false, young: true), "a young record stays while macOS is still turning displays off")
        check(!Safety.shouldForget(visible: false, othersUsable: 1, settling: false, young: false), "a record stays while its display is gone")
        check(Safety.shouldAdoptBuiltin(offline: true, recorded: false, lidClosed: false, settling: false, missingFor: 5), "an unrecorded, disabled built-in with the lid open is listed as off again")
        check(!Safety.shouldAdoptBuiltin(offline: true, recorded: false, lidClosed: true, settling: false, missingFor: 5), "not with the lid closed (clamshell)")
        check(!Safety.shouldAdoptBuiltin(offline: true, recorded: false, lidClosed: false, settling: true, missingFor: 5), "not while waking up")
        check(!Safety.shouldAdoptBuiltin(offline: true, recorded: false, lidClosed: false, settling: false, missingFor: 1), "not in the moment after the lid opens")
        check(!Safety.shouldAdoptBuiltin(offline: true, recorded: true, lidClosed: false, settling: false, missingFor: 5), "not when it's already listed as off")
        check(DisplayManager.eisaCode(19083) == "RTK", "EDID vendor 19083 decodes to RTK")
    }

    /// Off records against the real display list, without changing any display: records are
    /// injected for displays that are on, and the rescue is held back.
    private static func offRecords() {
        print("— off records (no display changes)")
        let manager = DisplayManager.shared
        manager.refresh(probe: false)
        manager.rescueOverride = { (1, false) }
        defer {
            manager.testReplaceOff([])
            manager.testSetWoke(secondsAgo: 1000)
            manager.rescueOverride = nil
            manager.refresh(probe: false)
        }
        func record(_ d: Display) -> OffDisplay {
            OffDisplay(id: d.id, uuid: d.uuid, name: d.name, isBuiltin: d.isBuiltin, isVirtual: false)
        }
        manager.testSetWoke(secondsAgo: 1000)
        let phantom = OffDisplay(id: 0x7EAD_0001, uuid: "selftest-phantom", name: "Phantom", isBuiltin: false, isVirtual: false)
        manager.testReplaceOff([phantom])
        manager.refresh(probe: false)
        check(manager.off == [phantom], "a display that's gone keeps its off record")

        let physical = manager.displays.filter { !$0.isVirtual && DisplayManager.visibleIDs().contains($0.id) }
        check(DisplayManager.offlineBuiltinID(online: DisplayManager.onlineIDs()) == nil || !physical.contains(where: \.isBuiltin), "the built-in isn't reported missing while it's on")
        guard let first = physical.first else { return check(false, "a visible physical display to test with") }

        manager.testReplaceOff(physical.map(record))
        manager.refresh(probe: false)
        check(manager.off.count == physical.count, "displays that are the only thing listed keep their records (the woke-without-a-screen case)")

        guard physical.count >= 2 else { return print("SKIP two-screen checks: only one physical display") }
        manager.testReplaceOff([record(first)])
        manager.testSetWoke(secondsAgo: 1)
        manager.refresh(probe: false)
        check(manager.off.count == 1, "right after wake, a listed display keeps its record")
        manager.testSetWoke(secondsAgo: 1000)
        manager.refresh(probe: false)
        check(manager.off.isEmpty, "once settled, a record is dropped when its display is on next to another screen")
    }

    private static func arrangementMath() {
        print("— arrangement math")
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var snapped = Arrangement.snap(laptop.offsetBy(dx: 1500, dy: 300), to: [main])
        check(snapped.minX == 1920 && snapped.minY == 300, "dropped overlapping the right half → snaps to the right edge (\(snapped.origin))")
        snapped = Arrangement.snap(laptop.offsetBy(dx: 600, dy: 1300), to: [main])
        check(snapped.minY == 1080 && snapped.minX == 600, "dropped below with a gap → snaps flush underneath (\(snapped.origin))")
        snapped = Arrangement.snap(laptop.offsetBy(dx: 1950, dy: 25), to: [main])
        check(snapped.minX == 1920 && snapped.minY == 0, "near-aligned tops snap flush (\(snapped.origin))")
        snapped = Arrangement.snap(laptop.offsetBy(dx: -1400, dy: 0), to: [main, CGRect(x: -1512, y: 0, width: 1512, height: 982)])
        check(!snapped.intersects(main.insetBy(dx: 1, dy: 1)) && !snapped.intersects(CGRect(x: -1511, y: 1, width: 1510, height: 980)), "never overlaps another display")
        let origins = Arrangement.normalized([1: main.offsetBy(dx: 100, dy: -50), 2: laptop.offsetBy(dx: 100 + 1920, dy: -50)], main: 1)
        check(origins[1] == .zero && origins[2] == CGPoint(x: 1920, y: 0), "normalisation keeps the main display at (0, 0)")
    }

    private static func shortcuts() {
        print("— shortcuts")
        check(HotkeyAction.turnOnAll.defaultShortcut?.display == "⌃⌥⌘R", "turn-all-on default is ⌃⌥⌘R")
        check(HotkeyAction.brightnessUp.defaultShortcut?.display == "⌃⌥⌘↑", "brightness-up default is ⌃⌥⌘↑")
        check(!Shortcut(kVK_ANSI_A, []).isValidGlobal, "a bare letter is rejected")
        check(Shortcut(kVK_F5, []).isValidGlobal, "a bare function key is accepted")
        check(Shortcut(kVK_UpArrow, [.control]).menuKeyEquivalent != nil, "arrow keys map to a menu key equivalent")
        let defaults = HotkeyAction.allCases.compactMap(\.defaultShortcut)
        check(Set(defaults).count == defaults.count, "default shortcuts don't collide")

        Shortcuts.assign(Shortcut(kVK_ANSI_D, [.control, .option, .command]), to: .action(.toggleBuiltIn))
        check(Shortcuts.shortcut(for: .toggleBuiltIn)?.display == "⌃⌥⌘D", "reassigning a shortcut binds it")
        check(Shortcuts.shortcut(for: .openMenu) == nil, "…and takes it away from the action that had it")
        Shortcuts.restoreDefaults()
        check(Shortcuts.shortcut(for: .openMenu)?.display == "⌃⌥⌘D", "restore defaults")

        let probe = Shortcut(kVK_F19, [.control, .option, .command, .shift])
        var fired = false
        check(HotKeyCenter.shared.register(probe) { fired = true }, "a global hotkey registers with Carbon")
        _ = fired
        HotKeyCenter.shared.removeAll()
    }

    /// The rescue path end to end: a display is off and "no physical screen is left".
    private static func rescue() {
        print("— rescue (simulated: every other screen unplugged)")
        let manager = DisplayManager.shared
        guard let id = VirtualDisplays.shared.create(VirtualSpec(serial: 9002, width: 1280, height: 800, hiDPI: false), persist: false),
              wait(5, until: { DisplayManager.onlineIDs().contains(id) }) else { return check(false, "create a virtual display") }
        manager.refresh(probe: false)
        check(manager.turnOff([id]) && wait(5) { !DisplayManager.onlineIDs().contains(id) }, "turn it off")

        manager.rescueOverride = { (0, true) }
        manager.refresh(probe: false)
        check(!wait(3) { DisplayManager.onlineIDs().contains(id) }, "lid closed: stays off (the Mac is going to sleep)")

        manager.rescueOverride = { (0, false) }
        manager.refresh(probe: false)
        check(wait(5) { DisplayManager.onlineIDs().contains(id) }, "lid open, no screen left: turned back on automatically")
        check(manager.off.isEmpty, "nothing left in the off list")
        manager.rescueOverride = nil
        VirtualDisplays.shared.remove(serial: 9002)
        wait(5) { !DisplayManager.onlineIDs().contains(id) }
    }

    private static func manyDisplays() {
        print("— many displays at once")
        let manager = DisplayManager.shared
        let specs = (0..<4).map { VirtualSpec(serial: 9010 + UInt32($0), width: [1920, 2560, 1280, 3440][$0], height: [1080, 1440, 720, 1440][$0], hiDPI: $0 == 1) }
        let ids = specs.compactMap { VirtualDisplays.shared.create($0, persist: false) }
        check(ids.count == 4 && wait(8) { ids.allSatisfy(DisplayManager.onlineIDs().contains) }, "4 virtual displays online alongside the real ones")
        manager.refresh(probe: false)
        let physical = manager.displays.filter { !$0.isVirtual }.map(\.id)
        check(manager.displays.count == physical.count + 4, "\(manager.displays.count) displays tracked")

        let menu = MenuController()
        menu.rebuild()
        let headers = menu.menu.items.compactMap { $0.view as? DisplayHeaderView }.count
        check(headers == manager.displays.count, "menu has a section per display (\(headers))")
        NSStatusBar.system.removeStatusItem(menu.statusItem)

        check(manager.canTurnOff(ids), "all virtual displays may go off together")
        check(!manager.canTurnOff(ids + physical), "but never together with every physical one")
        check(manager.turnOff(Array(ids.prefix(3))) && wait(6) { !ids.prefix(3).contains(where: DisplayManager.onlineIDs().contains) }, "turn 3 off in one transaction")
        wait(7) { false } // outlive the grace period: records must survive later refreshes too
        check(manager.off.count == 3, "3 remembered while off (\(manager.off.map { "\($0.id)" }))")
        manager.turnOn(Array(ids.prefix(3)))
        check(wait(6) { ids.allSatisfy(DisplayManager.onlineIDs().contains) }, "all back on")

        // Arrange: put the last virtual display flush right of the main display, via the editor's path.
        manager.refresh(probe: false)
        if let last = ids.last, let main = manager.displays.first(where: \.isMain) {
            var frames = manager.displays.filter { CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay }
                .reduce(into: [CGDirectDisplayID: CGRect]()) { $0[$1.id] = CGDisplayBounds($1.id) }
            let others = frames.filter { $0.key != last }.map(\.value)
            let right = others.map(\.maxX).max() ?? CGDisplayBounds(main.id).maxX
            let target = Arrangement.snap(CGRect(origin: CGPoint(x: right + 50, y: 10), size: CGDisplayBounds(last).size), to: others)
            frames[last] = target
            check(manager.arrange(frames), "apply an arrangement")
            check(wait(5) { CGDisplayBounds(last).origin == target.origin }, "display moved to \(target.origin) and touches its neighbour")
            check(CGDisplayBounds(main.id).origin == .zero, "main display still at (0, 0)")
        }
        for spec in specs { VirtualDisplays.shared.remove(serial: spec.serial) }
        check(wait(8) { !ids.contains(where: DisplayManager.onlineIDs().contains) }, "virtual displays removed")
    }

    private static func live() {
        print("— live (temporary virtual display)")
        let manager = DisplayManager.shared
        manager.start()
        check(Private.configureDisplayEnabled != nil, "CGSConfigureDisplayEnabled resolves")
        let physical = manager.displays.filter { !$0.isVirtual }
        print("     physical displays: " + physical.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))

        guard let id = VirtualDisplays.shared.create(VirtualSpec(serial: 9001, width: 1280, height: 720, hiDPI: false), persist: false) else {
            check(false, "create a virtual display")
            return
        }
        check(wait(5) { DisplayManager.onlineIDs().contains(id) }, "virtual display \(id) comes online")
        manager.refresh(probe: false)
        check(manager.display(id)?.isVirtual == true, "it is recognised as virtual")
        check(Brightness.kind(manager.display(id)!) == nil, "virtual displays get no brightness control")
        check(manager.canTurnOff([id]), "it may be turned off")

        check(manager.turnOff([id]), "turn it off")
        check(wait(5) { !DisplayManager.onlineIDs().contains(id) }, "it leaves the online list")
        check(manager.off.contains { $0.id == id }, "DisplayBar remembers it while it's off")
        manager.refresh(probe: false)
        check(manager.off.contains { $0.id == id }, "the record survives a refresh")

        manager.turnOn([id])
        check(wait(5) { DisplayManager.onlineIDs().contains(id) }, "turn it back on")
        check(!manager.off.contains { $0.id == id }, "the off record is cleared")

        manager.refresh(probe: false)
        let choices = manager.resolutionChoices(id, showAll: false)
        check(choices.count >= 3, "resolution list offers scaled modes (\(choices.count))")
        if let current = manager.currentMode(id), let other = choices.first(where: { $0.resolutionKey != current.resolutionKey }) {
            check(manager.setMode(id, other.mode), "switch to \(other.resolutionTitle)")
            check(wait(4) { manager.currentMode(id)?.resolutionKey == other.resolutionKey }, "mode change took effect")
        }

        if DBMonitorPanel.canRotate(id) {
            manager.setRotation(90, of: id)
            check(wait(4) { Int(CGDisplayRotation(id)) == 90 }, "rotate to 90°")
            manager.setRotation(0, of: id)
            check(wait(4) { Int(CGDisplayRotation(id)) == 0 }, "rotate back")
        } else {
            print("     (rotation not offered for the virtual display)")
        }

        VirtualDisplays.shared.remove(serial: 9001)
        check(wait(5) { !DisplayManager.onlineIDs().contains(id) }, "virtual display removed")

        print("— physical displays (read-only)")
        for d in physical {
            check(!manager.canTurnOff(physical.map(\.id)), "never all physical displays at once")
            if let ddc = d.ddc {
                if case let .value(v) = ddc.readSync(VCP.brightness.rawValue) {
                    check(true, "\(d.name): DDC brightness \(v.current)/\(v.max)")
                    check(ddc.writeSync(VCP.brightness.rawValue, UInt16(v.current)), "\(d.name): DDC write (same value)")
                    if case let .value(again) = ddc.readSync(VCP.brightness.rawValue) {
                        check(again.current == v.current, "\(d.name): value unchanged after the write")
                    }
                } else {
                    print("     \(d.name): no DDC brightness reply")
                }
            }
            if Brightness.kind(d) == .native { check(Brightness.get(d) != nil, "\(d.name): DisplayServices brightness readable") }
        }
    }
}
