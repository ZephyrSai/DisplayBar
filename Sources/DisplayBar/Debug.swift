import AppKit
import CDisplayPrivate

/// Developer hooks, all driven by environment variables:
///   DISPLAYBAR_OPEN_MENU=1          open the status menu after launch
///   DISPLAYBAR_SETTINGS=0|1         open Settings on a tab after launch
///   DISPLAYBAR_SNAPSHOT=<dir>       render Settings panes + menu rows + HUD to PNGs, then quit
enum Debug {
    static let env = ProcessInfo.processInfo.environment

    static func afterLaunch(_ delegate: AppDelegate) {
        if let tab = env["DISPLAYBAR_SETTINGS"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SettingsWindowController.show(tab: tab) }
        }
        if env["DISPLAYBAR_OPEN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { delegate.menu?.open() }
        }
        if env["DISPLAYBAR_TOUR"] == "1" { tour(delegate) }
        if let dir = env["DISPLAYBAR_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { snapshot(to: URL(fileURLWithPath: dir)) }
        }
    }

    /// Opens and closes each piece of UI on a fixed timeline so footprint can be sampled
    /// from outside: menu 2–5 s, Settings 8–11 s, Arrange 14–17 s, HUD at 20 s, quit at 30 s.
    private static func tour(_ delegate: AppDelegate) {
        func at(_ t: Double, _ label: String, _ work: @escaping () -> Void) {
            let timer = Timer(timeInterval: t, repeats: false) { _ in print("[tour] \(t)s \(label)"); fflush(stdout); work() }
            RunLoop.main.add(timer, forMode: .common) // fires during menu tracking too
        }
        at(2, "menu open") { delegate.menu?.open() }
        at(5, "menu close") { delegate.menu?.menu.cancelTracking() }
        at(8, "settings open") { SettingsWindowController.show(tab: 1) }
        at(11, "settings close") { SettingsWindowController.current?.close() }
        at(14, "arrange open") { ArrangeWindowController.show() }
        at(17, "arrange close") { ArrangeWindowController.window?.close() }
        at(20, "hud") { HUD.shared.show(symbol: "sun.max.fill", title: "Tour", subtitle: nil, level: 0.5) }
        at(26, "state") { print("[tour] windows alive: \(NSApp.windows.map { "\(type(of: $0))" })"); fflush(stdout) }
        at(30, "quit") { NSApp.terminate(nil) }
    }

    private static func write(_ view: NSView, _ url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    private static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, name) in ["general", "shortcuts"].enumerated() {
            SettingsWindowController.show(tab: index)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let frameView = SettingsWindowController.current?.window?.contentView?.superview { write(frameView, dir.appendingPathComponent("settings-\(name).png")) }
        }
        SettingsWindowController.current?.close()

        ArrangementView.showWallpaper = false // never put the user's wallpaper in a screenshot
        ArrangeWindowController.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let frameView = ArrangeWindowController.window?.contentView?.superview { write(frameView, dir.appendingPathComponent("arrange.png")) }
        ArrangeWindowController.window?.close()

        // Menu rows as they appear in the menu, stacked on a menu-like background.
        let manager = DisplayManager.shared
        var rows: [NSView] = []
        for d in manager.displays {
            rows.append(DisplayHeaderView(width: MenuController.width, symbol: d.symbol, title: d.name, subtitle: manager.subtitle(d),
                                          isOn: true, canToggle: manager.canTurnOff([d.id])))
            if Brightness.kind(d) != nil {
                let slider = SliderRowView(width: MenuController.width, symbol: "sun.max.fill", accessibility: "Brightness")
                slider.setValue(Brightness.get(d))
                rows.append(slider)
            }
        }
        rows.append(DisplayHeaderView(width: MenuController.width, symbol: "laptopcomputer", title: "Sample Turned-Off Display",
                                      subtitle: "Off", isOn: false, canToggle: true))
        let height = rows.reduce(0) { $0 + $1.frame.height } + 12
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: MenuController.width, height: height))
        container.material = .menu
        container.state = .active
        var y = height - 6
        for row in rows {
            y -= row.frame.height
            row.frame.origin = NSPoint(x: 0, y: y)
            container.addSubview(row)
        }
        let host = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = container
        host.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        write(container, dir.appendingPathComponent("menu-rows.png"))
        host.orderOut(nil)

        HUD.shared.show(symbol: "sun.max.fill", title: manager.displays.first?.name ?? "Display", subtitle: nil, level: 0.62)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let hud = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible })?.contentView { write(hud, dir.appendingPathComponent("hud.png")) }
        NSApp.terminate(nil)
    }
}

/// `DisplayBar --list`: read-only report of what DisplayBar sees.
enum CLI {
    static func list() {
        let manager = DisplayManager.shared
        manager.refresh(probe: false)
        print("SkyLight disconnect API: \(Private.configureDisplayEnabled != nil ? "available" : "MISSING")   MonitorPanel: \(DBMonitorPanel.isAvailable())   lid closed: \(DisplayManager.lidClosed())")
        for d in manager.displays {
            print("\n[\(d.id)] \(d.name)   builtin=\(d.isBuiltin) virtual=\(d.isVirtual) main=\(d.isMain)")
            print("   uuid \(d.uuid)")
            print("   \(manager.subtitle(d))   can turn off: \(manager.canTurnOff([d.id]))")
            print("   brightness: \(Brightness.kind(d).map { "\($0)" } ?? "none") = \(Brightness.get(d).map { String(format: "%.3f", $0) } ?? "n/a")")
            if let ddc = d.ddc {
                let values = VCP.allCases.filter { $0 != .power }.map { code -> String in
                    switch ddc.readSync(code.rawValue) {
                    case let .value(v): "\(code)=\(v.current)/\(v.max)"
                    case .unsupported: "\(code)=unsupported"
                    case .failed: "\(code)=failed"
                    }
                }
                print("   ddc (\(ddc.framebuffer)): " + values.joined(separator: "  "))
            } else {
                print("   ddc: none")
            }
            print("   rotation: \(DBMonitorPanel.canRotate(d.id) ? "\(Int(CGDisplayRotation(d.id)))°" : "n/a")   hdr: \(DBMonitorPanel.hasHDR(d.id) ? (DBMonitorPanel.isHDREnabled(d.id) ? "on" : "off") : "n/a")   presets: \(DBMonitorPanel.presetNames(d.id).count)")
            let choices = manager.resolutionChoices(d.id, showAll: false)
            print("   resolutions (\(choices.count)): " + choices.map { $0.resolutionTitle + ($0.hiDPI ? "h" : "") }.joined(separator: ", "))
            print("   refresh: " + manager.refreshChoices(d.id).map(\.refreshTitle).joined(separator: ", "))
        }
        print("\nturned off: \(manager.off.map(\.name))")
    }
}
