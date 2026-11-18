import CDisplayPrivate
import CoreGraphics
import Foundation

/// A virtual ("dummy") display definition. Sizes are in points; HiDPI renders at 2×.
struct VirtualSpec: Codable, Hashable {
    var serial: UInt32
    var width: Int
    var height: Int
    var hiDPI: Bool

    var pixelWidth: Int { hiDPI ? width * 2 : width }
    var pixelHeight: Int { hiDPI ? height * 2 : height }
    var title: String { "\(width) × \(height)" + (hiDPI ? " HiDPI" : "") }
    var name: String { "Virtual \(title)" }

    static let presets: [VirtualSpec] = [
        VirtualSpec(serial: 0, width: 1920, height: 1080, hiDPI: false),
        VirtualSpec(serial: 0, width: 2560, height: 1440, hiDPI: false),
        VirtualSpec(serial: 0, width: 3840, height: 2160, hiDPI: false),
        VirtualSpec(serial: 0, width: 3440, height: 1440, hiDPI: false),
        VirtualSpec(serial: 0, width: 1920, height: 1080, hiDPI: true),
        VirtualSpec(serial: 0, width: 2560, height: 1440, hiDPI: true),
        VirtualSpec(serial: 0, width: 1728, height: 1117, hiDPI: true),
    ]
}

/// Creates CGVirtualDisplays. They exist only while DisplayBar runs; saved specs are
/// recreated at launch when "Recreate virtual displays" is on.
final class VirtualDisplays {
    static let shared = VirtualDisplays()

    private(set) var specs: [VirtualSpec] = []
    private var live: [UInt32: CGVirtualDisplay] = [:]
    private static let vendorID: UInt32 = 0x0DBA
    private static let productID: UInt32 = 0xD15B

    func owns(_ id: CGDirectDisplayID) -> Bool { live.values.contains { $0.displayID == id } }

    func displayID(of spec: VirtualSpec) -> CGDirectDisplayID? { live[spec.serial]?.displayID }

    func spec(for id: CGDirectDisplayID) -> VirtualSpec? {
        guard let serial = live.first(where: { $0.value.displayID == id })?.key else { return nil }
        return specs.first { $0.serial == serial }
    }

    func restore() {
        for spec in Prefs.virtualSpecs { _ = create(spec, persist: false) }
        specs = Prefs.virtualSpecs.filter { live[$0.serial] != nil }
    }

    /// Creates a virtual display. A `serial` of 0 picks a new one.
    @discardableResult
    func create(_ template: VirtualSpec, persist: Bool = true) -> CGDirectDisplayID? {
        var spec = template
        if spec.serial == 0 {
            spec.serial = max(1000, (Prefs.virtualSpecs.map(\.serial) + Array(live.keys)).max() ?? 1000) + 1
        }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = spec.name
        descriptor.maxPixelsWide = UInt32(spec.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(spec.pixelHeight)
        let ppi = spec.hiDPI ? 218.0 : 109.0
        descriptor.sizeInMillimeters = CGSize(width: Double(spec.pixelWidth) / ppi * 25.4, height: Double(spec.pixelHeight) / ppi * 25.4)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = spec.serial
        let serial = spec.serial
        descriptor.terminationHandler = { _, _ in
            DispatchQueue.main.async {
                VirtualDisplays.shared.live[serial] = nil
                DisplayManager.shared.scheduleRefresh()
            }
        }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.hiDPI ? 1 : 0
        settings.modes = Self.modes(for: spec).map { CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: 60) }
        guard display.apply(settings) else { return nil }

        live[serial] = display
        if persist {
            specs.append(spec)
            Prefs.virtualSpecs = specs
        }
        DisplayManager.shared.scheduleRefresh()
        return display.displayID
    }

    func remove(serial: UInt32) {
        live[serial] = nil
        specs.removeAll { $0.serial == serial }
        Prefs.virtualSpecs = specs
        DisplayManager.shared.scheduleRefresh()
    }

    /// Pixel sizes offered to macOS: the full size first (it becomes the default), then
    /// smaller sizes of the same aspect ratio so the display can be scaled like a real one.
    static func modes(for spec: VirtualSpec) -> [(Int, Int)] {
        let factor = spec.hiDPI ? 2 : 1
        var sizes: [(Int, Int)] = [(spec.pixelWidth, spec.pixelHeight)]
        let widths = [3840, 3440, 3200, 3008, 2880, 2560, 2304, 2240, 2048, 1920, 1728, 1680, 1600, 1440, 1366, 1280, 1152, 1024, 800]
        for width in widths where width < spec.width {
            var height = Int((Double(width) * Double(spec.height) / Double(spec.width)).rounded())
            height -= height % 2
            sizes.append((width * factor, height * factor))
        }
        return sizes
    }
}
