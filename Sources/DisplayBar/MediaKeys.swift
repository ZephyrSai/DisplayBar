import AppKit
import ApplicationServices
import CoreAudio

/// Where macOS is sending sound, and whether that's a monitor only DDC can turn up or down.
/// CoreAudio is touched only when a volume key or shortcut asks, never at launch.
enum MonitorAudio {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyTransportType)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func name(_ device: AudioDeviceID) -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// True when macOS itself can change the device's volume (then DDC isn't needed).
    static func hasSoftwareVolume(_ device: AudioDeviceID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &addr), AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    /// The monitor whose speakers are playing, if its volume can only be set over DDC.
    static func ddcTarget() -> Display? {
        guard let device = defaultOutput() else { return nil }
        let kind = transport(device)
        guard kind == kAudioDeviceTransportTypeDisplayPort || kind == kAudioDeviceTransportTypeHDMI, !hasSoftwareVolume(device) else { return nil }
        let candidates = DisplayManager.shared.displays.filter { $0.vcp[.volume] != nil }
        let deviceName = name(device).lowercased()
        let named = candidates.first { d in
            let display = d.systemName.lowercased()
            return !deviceName.isEmpty && (deviceName.contains(display) || display.contains(deviceName))
        }
        return named ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    /// Target for volume shortcuts: the monitor playing sound, else the one under the pointer.
    static func shortcutTarget() -> Display? {
        if let target = ddcTarget() { return target }
        if let d = DisplayManager.shared.displayUnderPointer(), d.vcp[.volume] != nil { return d }
        return DisplayManager.shared.displays.first { $0.vcp[.volume] != nil }
    }
}

/// Optional: the keyboard's brightness and volume keys drive external monitors.
/// Needs Accessibility (an event tap that can swallow the key). Keys that macOS can
/// handle itself — the built-in screen, speakers with software volume — pass through.
final class MediaKeys {
    static let shared = MediaKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }
    static var wanted: Bool { Prefs.brightnessKeys || Prefs.volumeKeys }

    func update(prompt: Bool = false) {
        guard Self.wanted else { return stop() }
        let trusted = prompt
            ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            : AXIsProcessTrusted()
        trusted ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media and brightness keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
                                              MediaKeys.shared.handle(type, event)
                                          }, userInfo: nil) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        // ⌥⇧ + key = quarter steps, like macOS.
        let fine = ns.modifierFlags.contains([.option, .shift])
        let step: Float = fine ? 1 / 64 : 1 / 16

        switch key {
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
            guard Prefs.brightnessKeys, let d = DisplayManager.shared.displayUnderPointer(),
                  let kind = Brightness.kind(d), kind != .native else { return pass }
            if isDown { Brightness.step(d, by: key == 2 ? step : -step) }
            return nil
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP / _DOWN / MUTE
            guard Prefs.volumeKeys, let d = MonitorAudio.ddcTarget() else { return pass }
            if isDown {
                if key == 7 { DisplayManager.shared.toggleMute(d) } else { DisplayManager.shared.stepVolume(d, by: key == 0 ? step : -step) }
            }
            return nil
        default:
            return pass
        }
    }
}
