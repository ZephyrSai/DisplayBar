import CoreGraphics
import Foundation
import IOKit

/// Private C entry points, resolved at runtime so a missing symbol degrades a feature
/// instead of preventing launch.
enum Private {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ library: String, _ name: String, as _: T.Type) -> T? {
        let handle = dlopen(library, RTLD_LAZY)
        guard let pointer = dlsym(handle ?? rtldDefault, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let coreDisplay = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"

    // SkyLight: enable/disable a display inside a CGDisplayConfiguration transaction.
    // This is the "disconnect" BetterDisplay offers: the display leaves the desktop
    // and stops being driven until it is enabled again (or the login session ends).
    typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    static let configureDisplayEnabled = symbol(skyLight, "CGSConfigureDisplayEnabled", as: ConfigureEnabledFn.self)

    // CoreDisplay: per-display info (IODisplayLocation, virtual flag, vendor data).
    typealias InfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let infoFn = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: InfoFn.self)

    static func info(_ id: CGDirectDisplayID) -> [String: Any]? {
        infoFn?(id)?.takeRetainedValue() as? [String: Any]
    }

    // DisplayServices: built-in (and Apple) display brightness.
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Bool
    static let getBrightness = symbol(displayServices, "DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    static let setBrightness = symbol(displayServices, "DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    static let canChangeBrightness = symbol(displayServices, "DisplayServicesCanChangeBrightness", as: CanChangeBrightnessFn.self)

    // IOKit (Apple silicon): I2C to the monitor through the DCP AV service = DDC/CI.
    typealias AVCreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    static let avCreate = symbol(ioKit, "IOAVServiceCreateWithService", as: AVCreateFn.self)
    static let avRead = symbol(ioKit, "IOAVServiceReadI2C", as: AVI2CFn.self)
    static let avWrite = symbol(ioKit, "IOAVServiceWriteI2C", as: AVI2CFn.self)
}
