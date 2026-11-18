import AppKit

let arguments = CommandLine.arguments
let app = NSApplication.shared

if arguments.contains("--list") {
    Prefs.useSuite("com.displaybar.cli")
    Prefs.register()
    CLI.list()
    exit(0)
}

if arguments.contains("--selftest") {
    Prefs.useSuite("com.displaybar.selftest")
    Prefs.register()
    app.setActivationPolicy(.accessory)
    // A timer (not a main-queue block) so the test can pump the run loop and still
    // receive main-queue callbacks from CoreGraphics.
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in SelfTest.run() }
    app.run()
}

Prefs.register()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
