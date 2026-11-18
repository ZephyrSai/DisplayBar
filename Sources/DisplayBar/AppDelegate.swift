import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menu: MenuController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = anotherInstance() {
            NSLog("DisplayBar: already running as pid \(other.processIdentifier); exiting")
            exit(0) // not terminate(): that would run the quit-time display restore
        }
        // A windowless app looks idle to macOS; it must never be reaped while it holds
        // displays off, and quitting must always run the restore path.
        ProcessInfo.processInfo.disableAutomaticTermination("DisplayBar manages displays")
        ProcessInfo.processInfo.disableSuddenTermination()
        installSignalHandlers()
        DisplayManager.shared.start()
        if Prefs.restoreVirtual { VirtualDisplays.shared.restore() }
        menu = MenuController()
        Shortcuts.reregister()
        MediaKeys.shared.update()
        Debug.afterLaunch(self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayManager.shared.prepareForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return false
    }

    private func anotherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != getpid() && !$0.isTerminated }
    }

    /// `kill`/logout send SIGTERM, which skips applicationWillTerminate by default.
    /// Route it through terminate() so turned-off displays come back.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
