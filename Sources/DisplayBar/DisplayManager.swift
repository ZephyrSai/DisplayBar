import AppKit
import CDisplayPrivate
import ColorSync
import CoreGraphics
import IOKit
import os

/// Decisions about off records, sleep/wake and the rescue, so a lost screen can be traced:
/// `log show --predicate 'subsystem == "DisplayBar"' --last 1h`
let displayLog = Logger(subsystem: "DisplayBar", category: "displays")

extension Notification.Name {
    /// The set of displays or their configuration changed.
    static let displaysChanged = Notification.Name("DisplayBar.displaysChanged")
    /// Cached DDC/brightness values changed (sliders refresh in place).
    static let displayValuesChanged = Notification.Name("DisplayBar.displayValuesChanged")
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// One enabled (online) display. Objects are reused across refreshes so DDC caches survive.
final class Display {
    let id: CGDirectDisplayID
    let uuid: String
    let isBuiltin: Bool
    let isVirtual: Bool
    var systemName: String
    var ddc: DDC?
    var vcp: [VCP: VCPValue] = [:]
    var vcpUnsupported: Set<VCP> = []
    var probing = false
    var probed = false
    var lastRead: TimeInterval = 0
    /// Volume before an emulated mute; nil when not muted.
    var mutedVolume: Int?

    init(id: CGDirectDisplayID, uuid: String, isBuiltin: Bool, isVirtual: Bool, systemName: String) {
        self.id = id
        self.uuid = uuid
        self.isBuiltin = isBuiltin
        self.isVirtual = isVirtual
        self.systemName = systemName
    }

    var name: String { Prefs.customNames[uuid] ?? systemName }
    var isMain: Bool { CGDisplayIsMain(id) != 0 }
    var bounds: CGRect { CGDisplayBounds(id) }
    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == id } }
    var symbol: String { Display.symbol(builtin: isBuiltin, virtual: isVirtual) }

    static func symbol(builtin: Bool, virtual: Bool) -> String {
        builtin ? "laptopcomputer" : virtual ? "rectangle.dashed" : "display"
    }
}

/// A display mode with the bits the menus need.
struct ModeInfo {
    let mode: CGDisplayMode

    var width: Int { mode.width }
    var height: Int { mode.height }
    var pixelWidth: Int { mode.pixelWidth }
    var pixelHeight: Int { mode.pixelHeight }
    var refresh: Double { mode.refreshRate }
    var hiDPI: Bool { pixelWidth > width }
    var isNative: Bool { mode.ioFlags & 0x0200_0000 != 0 }
    var isDefault: Bool { mode.ioFlags & 0x0000_0004 != 0 }
    var resolutionKey: String { "\(width)x\(height)/\(pixelWidth)x\(pixelHeight)" }
    var refreshKey: Int { Int(refresh.rounded()) }

    var resolutionTitle: String { "\(width) × \(height)" }
    var refreshTitle: String { refresh > 0 ? String(format: refresh.rounded() == refresh ? "%.0f Hz" : "%.2f Hz", refresh) : "Default" }

    var attributedTitle: NSAttributedString {
        let title = NSMutableAttributedString(string: resolutionTitle, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        var tags: [String] = []
        if hiDPI { tags.append("HiDPI") }
        if isNative { tags.append("Native") }
        if isDefault { tags.append("Default") }
        if !tags.isEmpty {
            title.append(NSAttributedString(string: "   " + tags.joined(separator: " · "), attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return title
    }
}

final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [Display] = []
    private(set) var off: [OffDisplay] = []
    private(set) var ddcAsleep: Set<CGDirectDisplayID> = []
    private var started = false
    private var refreshScheduled = false
    private var sleeping = false
    /// Uptime of the last wake. Displays come and go for a few seconds after waking (and
    /// macOS may list a disabled panel while nothing else is connected), so off records are
    /// neither dropped nor adopted until `wakeSettle` has passed.
    private var wokeAt: TimeInterval = -.infinity
    private static let wakeSettle: TimeInterval = 8
    private var rescuePending = false
    /// Rescues since a usable screen was last seen; caps the retries if macOS ignores them.
    private var rescueAttempts = 0
    private static let maxRescueAttempts = 5
    /// When the built-in panel was first seen missing with the lid open and no off record.
    private var builtinMissingSince: TimeInterval?
    /// When each display was turned off. macOS disables the displays of one transaction one
    /// after another, so a refresh in between still sees some of them online; records younger
    /// than `offGrace` are never treated as "turned back on elsewhere".
    private var offAt: [CGDirectDisplayID: TimeInterval] = [:]
    private static let offGrace: TimeInterval = 6
    private var lastLoggedState = ""

    private var settling: Bool {
        sleeping || ProcessInfo.processInfo.systemUptime - wokeAt < Self.wakeSettle
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // Virtual displays die with the process, so their "off" records are meaningless now.
        off = Prefs.offDisplays.filter { !$0.isVirtual }
        Prefs.offDisplays = off

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh() }
        }, nil)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            displayLog.notice("will sleep; off: \(DisplayManager.shared.off.map(\.id), privacy: .public)")
            DisplayManager.shared.sleeping = true
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DisplayManager.shared.didWake()
        }
        // Belt and braces: if the system wake notification is missed, the screens waking still ends "sleeping".
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            if DisplayManager.shared.sleeping { DisplayManager.shared.didWake() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            DisplayManager.shared.scheduleRefresh()
        }
        refresh()
        // Covers a launch while the built-in panel is already disabled and unrecorded.
        DispatchQueue.main.asyncAfter(deadline: .now() + Safety.adoptDelay + 0.5) { self.scheduleRefresh() }
    }

    private func didWake() {
        sleeping = false
        wokeAt = ProcessInfo.processInfo.systemUptime
        displayLog.notice("did wake; online: \(Self.onlineIDs(), privacy: .public) visible: \(Self.visibleIDs(), privacy: .public) off: \(self.off.map(\.id), privacy: .public) lid closed: \(Self.lidClosed(), privacy: .public)")
        scheduleRefresh(after: 2)
        // Once the wake has settled, look again: records may be dropped/adopted and the lid may read open by now.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettle + 0.5) { self.scheduleRefresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettle + Safety.adoptDelay + 1) { self.scheduleRefresh() }
    }

    /// Restores everything DisplayBar changed (used on quit when the preference is on).
    func prepareForQuit() {
        if Prefs.reconnectOnQuit {
            let physical = off.filter { !$0.isVirtual }
            if !physical.isEmpty { _ = Self.configure(physical.map(\.id), enabled: true) }
            off.removeAll()
            Prefs.offDisplays = []
            for d in displays where ddcAsleep.contains(d.id) { d.ddc?.writeSync(VCP.power.rawValue, 1) }
        } else {
            Prefs.offDisplays = off.filter { !$0.isVirtual }
        }
        Gamma.shared.restore()
    }

    func scheduleRefresh(after delay: TimeInterval = 0.35) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh(probe: Bool = true) {
        let ids = Self.onlineIDs()
        var next: [Display] = []
        for id in ids {
            let display = displays.first { $0.id == id } ?? makeDisplay(id)
            display.systemName = Self.systemName(id)
            // IOAVService objects are replaced on hot-plug and wake; re-resolve every time.
            if !display.isBuiltin && !display.isVirtual { display.ddc = DDC.make(for: id) }
            next.append(display)
        }
        displays = next
        ddcAsleep = ddcAsleep.filter(ids.contains)

        let now = ProcessInfo.processInfo.systemUptime
        let visible = Self.visibleIDs()
        let settling = self.settling
        let offIDs = Set(off.map(\.id))
        var stillOff: [OffDisplay] = []
        var recheck = false
        for record in off {
            let isVisible = visible.contains(record.id)
            let young = now - (offAt[record.id] ?? 0) < Self.offGrace
            let others = Safety.usablePhysical(visible: visible.filter { $0 != record.id }, virtual: virtualIDs, off: offIDs)
            if Safety.shouldForget(visible: isVisible, othersUsable: others, settling: settling, young: young) {
                displayLog.notice("\(record.id, privacy: .public) is back on next to another screen; dropping its off record")
            } else {
                stillOff.append(record)
                if isVisible && (young || settling) { recheck = true }
            }
        }
        if recheck { scheduleRefresh(after: Self.offGrace) }
        offAt = offAt.filter { id, _ in stillOff.contains { $0.id == id } }
        if stillOff != off {
            off = stillOff
            Prefs.offDisplays = off
        }
        adoptLostBuiltin(online: ids, now: now, settling: settling)
        if Safety.usablePhysical(visible: visible, virtual: virtualIDs, off: Set(off.map(\.id))) > 0 { rescueAttempts = 0 }
        logState(online: ids, visible: visible)

        var known = Prefs.knownDisplays
        for d in displays where !d.isVirtual && known[d.uuid] != d.name { known[d.uuid] = d.name }
        if known != Prefs.knownDisplays { Prefs.knownDisplays = known }

        DBMonitorPanel.reload() // dropped now, re-created lazily the next time a menu needs it
        Gamma.shared.reapply(online: Set(ids))
        if probe { for d in displays where !d.probed { self.probe(d) } }
        checkRescue()
        NotificationCenter.default.post(name: .displaysChanged, object: nil)
    }

    /// Lists the built-in panel as off again when it is missing with the lid open and nothing
    /// records it (the record was lost, or another app disabled it), so it can't stay stranded.
    private func adoptLostBuiltin(online: [CGDirectDisplayID], now: TimeInterval, settling: Bool) {
        let missing = Self.offlineBuiltinID(online: online)
        let recorded = off.contains { $0.isBuiltin || $0.id == missing }
        guard let id = missing, !recorded, !settling, !Self.lidClosed() else {
            builtinMissingSince = nil
            return
        }
        let since = builtinMissingSince ?? now
        builtinMissingSince = since
        guard Safety.shouldAdoptBuiltin(offline: true, recorded: false, lidClosed: false, settling: false, missingFor: now - since) else {
            // Look again once it has been missing long enough; a lid that just opened needs a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + Safety.adoptDelay - (now - since) + 0.2) { self.scheduleRefresh() }
            return
        }
        builtinMissingSince = nil
        let uuid = Self.uuid(id)
        let name = Prefs.customNames[uuid] ?? Prefs.knownDisplays[uuid] ?? "Built-in Display"
        displayLog.notice("built-in \(id, privacy: .public) is disabled with the lid open and wasn't recorded; listing it as off")
        off.append(OffDisplay(id: id, uuid: uuid, name: name, isBuiltin: true, isVirtual: false))
        Prefs.offDisplays = off.filter { !$0.isVirtual }
    }

    /// The built-in panel's ID when it exists but isn't online. macOS keeps answering for a
    /// disabled display's ID (built-in flag, UUID), it just leaves it out of the online list.
    static func offlineBuiltinID(online: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if online.contains(where: { CGDisplayIsBuiltin($0) != 0 }) { return nil }
        for id in CGDirectDisplayID(1)...16 where CGDisplayIsBuiltin(id) != 0 && CGDisplayCreateUUIDFromDisplayID(id) != nil {
            return id
        }
        return nil
    }

    private func logState(online: [CGDirectDisplayID], visible: [CGDirectDisplayID]) {
        let state = "online \(online) visible \(visible) off \(off.map(\.id)) sleeping \(sleeping) settling \(settling)"
        guard state != lastLoggedState else { return }
        lastLoggedState = state
        displayLog.notice("\(state, privacy: .public)")
    }

    private func makeDisplay(_ id: CGDirectDisplayID) -> Display {
        let info = Private.info(id)
        let isVirtual = (info?["kCGDisplayIsVirtualDevice"] as? Bool ?? false) || VirtualDisplays.shared.owns(id)
        return Display(id: id, uuid: Self.uuid(id), isBuiltin: CGDisplayIsBuiltin(id) != 0, isVirtual: isVirtual, systemName: Self.systemName(id))
    }

    // MARK: Queries

    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Displays that currently show something: active, or a member of a mirror set.
    static func visibleIDs() -> [CGDirectDisplayID] {
        onlineIDs().filter { CGDisplayIsActive($0) != 0 || CGDisplayIsInMirrorSet($0) != 0 }
    }

    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return "display-\(id)" }
        return string as String
    }

    static func systemName(_ id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }), !screen.localizedName.isEmpty {
            return screen.localizedName
        }
        if let names = Private.info(id)?["DisplayProductName"] as? [String: String] {
            let preferred = Locale.preferredLanguages.lazy.map { $0.replacingOccurrences(of: "-", with: "_") }.compactMap { names[$0] }.first
            if let name = preferred ?? names["en_US"] ?? names.values.first(where: { !$0.isEmpty }), !name.isEmpty { return name }
        }
        if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
        if let code = eisaCode(CGDisplayVendorNumber(id)) { return "\(code) Display" }
        return "Display \(id)"
    }

    /// EDID manufacturer ID → three-letter PNP code (19083 → "RTK").
    static func eisaCode(_ vendor: UInt32) -> String? {
        guard vendor > 0, vendor < 0x8000 else { return nil }
        let letters = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F]
        guard letters.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return String(letters.map { Character(UnicodeScalar(UInt8(64 + $0))) })
    }

    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    func display(_ id: CGDirectDisplayID) -> Display? { displays.first { $0.id == id } }

    func displayUnderPointer() -> Display? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 8, &ids, &count)
        return ids.prefix(Int(count)).lazy.compactMap { self.display($0) }.first
    }

    var virtualIDs: Set<CGDirectDisplayID> { Set(displays.filter(\.isVirtual).map(\.id)) }

    func canTurnOff(_ ids: [CGDirectDisplayID]) -> Bool {
        Safety.canTurnOff(Set(ids), visible: Self.visibleIDs(), virtual: virtualIDs)
    }

    func name(of id: CGDirectDisplayID) -> String {
        display(id)?.name ?? off.first { $0.id == id }?.name ?? "Display \(id)"
    }

    func subtitle(_ d: Display) -> String {
        var parts: [String] = []
        if let mode = CGDisplayCopyDisplayMode(d.id) {
            let info = ModeInfo(mode: mode)
            parts.append(info.resolutionTitle + (info.hiDPI ? " HiDPI" : ""))
            if mode.refreshRate > 0 { parts.append("\(info.refreshKey) Hz") }
        }
        let master = CGDisplayMirrorsDisplay(d.id)
        if master != kCGNullDirectDisplay { parts.append("Mirroring \(name(of: master))") }
        if ddcAsleep.contains(d.id) { parts.append("Asleep") }
        if d.isMain { parts.append("Main") }
        return parts.joined(separator: " · ")
    }

    // MARK: Turning displays off and on

    static func configure(_ ids: [CGDirectDisplayID], enabled: Bool) -> Bool {
        guard let setEnabled = Private.configureDisplayEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in ids where setEnabled(config, id, enabled) != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Disconnects displays (BetterDisplay-style "turn off"). Refuses if no physical
    /// screen would be left. Returns whether the displays were turned off.
    @discardableResult
    func turnOff(_ ids: [CGDirectDisplayID], feedback: Bool = false) -> Bool {
        let targets = ids.filter { display($0) != nil }
        guard !targets.isEmpty else { return false }
        guard canTurnOff(targets) else {
            NSSound.beep()
            if feedback { HUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Can't turn off the last screen", subtitle: nil) }
            return false
        }
        let records = targets.compactMap { id -> OffDisplay? in
            guard let d = display(id) else { return nil }
            return OffDisplay(id: id, uuid: d.uuid, name: d.name, isBuiltin: d.isBuiltin, isVirtual: d.isVirtual)
        }
        // Record first: once disabled, macOS no longer lists the display anywhere.
        off.removeAll { targets.contains($0.id) }
        off.append(contentsOf: records)
        let now = ProcessInfo.processInfo.systemUptime
        for id in targets { offAt[id] = now }
        Prefs.offDisplays = off.filter { !$0.isVirtual }
        guard Self.configure(targets, enabled: false) else {
            off.removeAll { targets.contains($0.id) }
            Prefs.offDisplays = off.filter { !$0.isVirtual }
            NSSound.beep()
            if feedback { HUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "macOS refused to turn the display off", subtitle: nil) }
            return false
        }
        if feedback {
            let title = records.count == 1 ? "\(records[0].name) is off" : "\(records.count) displays are off"
            let hint = Shortcuts.shortcut(for: .turnOnAll).map { "\($0.display) turns everything back on" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                HUD.shared.show(symbol: "power", title: title, subtitle: hint)
            }
        }
        scheduleRefresh()
        return true
    }

    /// `keepOnFailure`: if macOS refuses, keep every record so the next attempt can retry
    /// (the rescue). Otherwise only the built-in's record survives a refusal; an external's
    /// is dropped since it may simply have been unplugged meanwhile.
    func turnOn(_ ids: [CGDirectDisplayID], feedback: Bool = false, keepOnFailure: Bool = false) {
        guard !ids.isEmpty else { return }
        let names = ids.map { name(of: $0) }
        let ok = Self.configure(ids, enabled: true)
        displayLog.notice("turn on \(ids, privacy: .public): \(ok ? "ok" : "refused", privacy: .public)")
        // Once macOS accepts, it considers the display enabled (even if it was unplugged
        // meanwhile), so the record has done its job.
        let done = ids.filter { id in ok || !(keepOnFailure || off.contains { $0.id == id && $0.isBuiltin }) }
        off.removeAll { done.contains($0.id) }
        for id in done { offAt[id] = nil }
        Prefs.offDisplays = off.filter { !$0.isVirtual }
        if feedback {
            HUD.shared.show(symbol: ok ? "power" : "exclamationmark.triangle.fill",
                            title: ok ? (names.count == 1 ? "Turning on \(names[0])" : "Turning on \(names.count) displays") : "Couldn't turn the display on",
                            subtitle: nil)
        }
        scheduleRefresh()
    }

    func turnOnAll(feedback: Bool = false) {
        for d in displays where ddcAsleep.contains(d.id) { ddcWake(d) }
        if off.isEmpty {
            if feedback { HUD.shared.show(symbol: "checkmark.circle", title: "All displays are on", subtitle: nil) }
            return
        }
        turnOn(off.map(\.id), feedback: feedback)
    }

    /// Toggles a group: turns off its visible members, or turns its off members back on.
    func toggle(label: String, on: (Display) -> Bool, offMatch: (OffDisplay) -> Bool) {
        let visible = displays.filter { !$0.isVirtual && on($0) }
        if !visible.isEmpty {
            turnOff(visible.map(\.id), feedback: true)
            return
        }
        let offTargets = off.filter(offMatch)
        if offTargets.isEmpty {
            NSSound.beep()
            HUD.shared.show(symbol: "display.trianglebadge.exclamationmark", title: "No \(label) connected", subtitle: nil)
        } else {
            turnOn(offTargets.map(\.id), feedback: true)
        }
    }

    func toggle(uuid: String) {
        if let d = displays.first(where: { $0.uuid == uuid }) {
            turnOff([d.id], feedback: true)
        } else if let o = off.first(where: { $0.uuid == uuid }) {
            turnOn([o.id], feedback: true)
        } else {
            NSSound.beep()
            HUD.shared.show(symbol: "display.trianglebadge.exclamationmark", title: "\(Prefs.knownDisplays[uuid] ?? "Display") isn't connected", subtitle: nil)
        }
    }

    /// Test hook: replaces the live readings (usable physical screens, lid state).
    var rescueOverride: (() -> (physical: Int, lidClosed: Bool))?

    /// Test hooks: inject off records (in memory and in the self-test's own defaults) and
    /// pretend the last wake was `secondsAgo` seconds ago.
    func testReplaceOff(_ records: [OffDisplay]) {
        off = records
        offAt = [:]
        Prefs.offDisplays = off
    }

    func testSetWoke(secondsAgo: TimeInterval) {
        sleeping = false
        wokeAt = ProcessInfo.processInfo.systemUptime - secondsAgo
    }

    private func rescueState() -> (physical: Int, lidClosed: Bool) {
        if let rescueOverride { return rescueOverride() }
        let physical = Safety.usablePhysical(visible: Self.visibleIDs(), virtual: virtualIDs, off: Set(off.map(\.id)))
        return (physical, Self.lidClosed())
    }

    func checkRescue() {
        guard !off.isEmpty, !rescuePending else { return }
        let state = rescueState()
        guard Safety.shouldRescue(visiblePhysical: state.physical, offCount: off.count, lidClosed: state.lidClosed, sleeping: sleeping) else { return }
        guard rescueAttempts < Self.maxRescueAttempts else { return }
        // Re-check after a moment so a transient state during reconfiguration doesn't trigger it.
        rescuePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.rescuePending = false
            let state = self.rescueState()
            if Safety.shouldRescue(visiblePhysical: state.physical, offCount: self.off.count, lidClosed: state.lidClosed, sleeping: self.sleeping) {
                self.rescueAttempts += 1
                displayLog.notice("no usable screen left (attempt \(self.rescueAttempts, privacy: .public)); turning \(self.off.map(\.id), privacy: .public) back on")
                self.turnOn(self.off.map(\.id), keepOnFailure: true)
                // Check it worked: a refused attempt kept its records, a panel that stayed dark is adopted again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.scheduleRefresh() }
            }
        }
    }

    // MARK: DDC

    func probe(_ d: Display) {
        guard let ddc = d.ddc, !d.probing else {
            if d.ddc == nil { d.probed = true }
            return
        }
        d.probing = true
        ddc.read([.brightness, .contrast, .volume, .input]) { results in
            d.probing = false
            d.probed = true
            d.lastRead = ProcessInfo.processInfo.systemUptime
            self.apply(results, to: d)
        }
    }

    /// Re-reads values that the monitor's own buttons may have changed.
    func refreshLiveValues() {
        let now = ProcessInfo.processInfo.systemUptime
        for d in displays where d.probed && !d.probing && now - d.lastRead > 5 {
            guard let ddc = d.ddc else { continue }
            let codes = [VCP.brightness, .contrast, .volume].filter { d.vcp[$0] != nil }
            guard !codes.isEmpty else { continue }
            d.probing = true
            ddc.read(codes) { results in
                d.probing = false
                d.lastRead = ProcessInfo.processInfo.systemUptime
                self.apply(results, to: d)
            }
        }
    }

    private func apply(_ results: [VCP: DDCReadResult], to d: Display) {
        for (code, result) in results {
            switch result {
            case let .value(value):
                d.vcp[code] = value
                d.vcpUnsupported.remove(code)
            case .unsupported:
                d.vcpUnsupported.insert(code)
                d.vcp[code] = nil
            case .failed:
                break
            }
        }
        NotificationCenter.default.post(name: .displayValuesChanged, object: nil)
    }

    func setVCP(_ code: VCP, fraction: Float, on d: Display) {
        guard let ddc = d.ddc, var value = d.vcp[code] else { return }
        value.current = Int((Float(value.max) * min(1, max(0, fraction))).rounded())
        d.vcp[code] = value
        ddc.set(code, value.current)
    }

    /// Volume over DDC. Mute is emulated (volume 0, remembering the old level) because
    /// many monitors don't implement VCP 0x8D.
    func stepVolume(_ d: Display, by delta: Float) {
        guard let value = d.vcp[.volume] else { return NSSound.beep() }
        if let previous = d.mutedVolume, delta > 0 {
            d.mutedVolume = nil
            d.vcp[.volume]?.current = previous
        }
        let current = Float(d.vcp[.volume]?.current ?? value.current) / Float(max(1, value.max))
        let next = min(1, max(0, ((current + delta) * 64).rounded() / 64))
        setVCP(.volume, fraction: next, on: d)
        showVolumeHUD(d)
    }

    func toggleMute(_ d: Display) {
        guard let value = d.vcp[.volume], let ddc = d.ddc else { return NSSound.beep() }
        if let previous = d.mutedVolume {
            d.mutedVolume = nil
            d.vcp[.volume]?.current = previous
            ddc.set(.volume, previous)
        } else {
            d.mutedVolume = value.current
            d.vcp[.volume]?.current = 0
            ddc.set(.volume, 0)
        }
        showVolumeHUD(d)
    }

    func setVolume(_ d: Display, fraction: Float) {
        d.mutedVolume = nil
        setVCP(.volume, fraction: fraction, on: d)
    }

    private func showVolumeHUD(_ d: Display) {
        guard let v = d.vcp[.volume] else { return }
        let level = Float(v.current) / Float(max(1, v.max))
        let symbol = d.mutedVolume != nil || level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        HUD.shared.show(symbol: symbol, title: d.name, subtitle: nil, level: level, on: d.screen)
        NotificationCenter.default.post(name: .displayValuesChanged, object: nil)
    }

    func setInput(_ source: InputSource, on d: Display) {
        d.ddc?.set(.input, source.rawValue)
        d.vcp[.input] = VCPValue(current: source.rawValue, max: d.vcp[.input]?.max ?? 0)
    }

    /// Puts the monitor into DDC standby while macOS keeps it connected.
    func ddcSleep(_ d: Display) {
        guard canTurnOff([d.id]) else {
            NSSound.beep()
            HUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Can't put the last screen to sleep", subtitle: nil)
            return
        }
        d.ddc?.set(.power, 4)
        ddcAsleep.insert(d.id)
        NotificationCenter.default.post(name: .displaysChanged, object: nil)
    }

    func ddcWake(_ d: Display) {
        d.ddc?.set(.power, 1)
        ddcAsleep.remove(d.id)
        NotificationCenter.default.post(name: .displaysChanged, object: nil)
    }

    // MARK: Modes

    func modes(_ id: CGDirectDisplayID) -> [ModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        var result: [ModeInfo] = []
        for mode in all where mode.isUsableForDesktopGUI() {
            let info = ModeInfo(mode: mode)
            if seen.insert("\(info.resolutionKey)@\(info.refreshKey)").inserted { result.append(info) }
        }
        return result
    }

    func currentMode(_ id: CGDirectDisplayID) -> ModeInfo? {
        CGDisplayCopyDisplayMode(id).map(ModeInfo.init)
    }

    /// Like System Settings: dense (Retina-class) panels list their HiDPI "looks like" sizes,
    /// everything else lists plain resolutions. Unknown physical size → judge by pixel count.
    func prefersHiDPI(_ id: CGDirectDisplayID, nativeWidth: Int) -> Bool {
        if VirtualDisplays.shared.spec(for: id)?.hiDPI == true { return true }
        let size = CGDisplayScreenSize(id)
        if size.width > 10 { return Double(nativeWidth) / (size.width / 25.4) >= 150 }
        return nativeWidth >= 3000
    }

    /// One entry per resolution, at the current refresh rate when available.
    /// Default view: HiDPI sizes plus native on dense panels, plain resolutions otherwise.
    func resolutionChoices(_ id: CGDirectDisplayID, showAll: Bool) -> [ModeInfo] {
        let all = modes(id)
        let current = currentMode(id)
        let nativePixels = all.first(where: \.isNative).map { ($0.pixelWidth, $0.pixelHeight) }
            ?? all.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }).map { ($0.pixelWidth, $0.pixelHeight) }
        let hiDPIList = prefersHiDPI(id, nativeWidth: nativePixels?.0 ?? 0) && all.contains(where: \.hiDPI)

        var byResolution: [String: ModeInfo] = [:]
        for mode in all {
            let isCurrent = mode.resolutionKey == current?.resolutionKey
            if !showAll && !isCurrent {
                if hiDPIList {
                    let native = nativePixels.map { mode.pixelWidth == $0.0 && mode.pixelHeight == $0.1 } ?? false
                    guard mode.hiDPI || native else { continue }
                } else if mode.hiDPI {
                    continue
                }
            }
            let key = mode.resolutionKey
            if let existing = byResolution[key] {
                let wantsRefresh = current?.refreshKey ?? 0
                if existing.refreshKey == wantsRefresh { continue }
                if mode.refreshKey == wantsRefresh || mode.refresh > existing.refresh { byResolution[key] = mode }
            } else {
                byResolution[key] = mode
            }
        }
        return byResolution.values.sorted {
            if $0.hiDPI != $1.hiDPI { return $0.hiDPI }
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
    }

    func refreshChoices(_ id: CGDirectDisplayID) -> [ModeInfo] {
        guard let current = currentMode(id) else { return [] }
        var seen = Set<Int>()
        return modes(id)
            .filter { $0.resolutionKey == current.resolutionKey && seen.insert($0.refreshKey).inserted }
            .sorted { $0.refresh > $1.refresh }
    }

    @discardableResult
    func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        scheduleRefresh()
        return ok
    }

    // MARK: Arrangement

    /// Moves the menu bar to `id` by making its origin (0, 0) and shifting the rest.
    func makeMain(_ id: CGDirectDisplayID) {
        guard display(id) != nil, CGDisplayIsMain(id) == 0 else { return }
        let origin = CGDisplayBounds(id).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for d in displays where CGDisplayMirrorsDisplay(d.id) == kCGNullDirectDisplay {
            let bounds = CGDisplayBounds(d.id)
            CGConfigureDisplayOrigin(config, d.id, Int32(bounds.origin.x - origin.x), Int32(bounds.origin.y - origin.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
        scheduleRefresh()
    }

    /// Applies a whole arrangement (global-point frames of the non-mirrored displays).
    @discardableResult
    func arrange(_ frames: [CGDirectDisplayID: CGRect]) -> Bool {
        guard let main = frames.keys.first(where: { CGDisplayIsMain($0) != 0 }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (id, origin) in Arrangement.normalized(frames, main: main) {
            CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        }
        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        scheduleRefresh()
        return ok
    }

    /// Makes `id` show the contents of `master`, or stops mirroring when `master` is nil.
    func mirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, id, master ?? kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .permanently)
        scheduleRefresh()
    }

    func setRotation(_ degrees: Int, of id: CGDirectDisplayID) {
        DBMonitorPanel.setRotation(Int32(degrees), of: id)
        scheduleRefresh()
    }
}
