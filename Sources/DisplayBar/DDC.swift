import CoreGraphics
import Foundation
import IOKit

/// MCCS VCP codes DisplayBar uses.
enum VCP: UInt8, CaseIterable {
    case brightness = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62
    case power = 0xD6
}

struct VCPValue: Equatable {
    var current: Int
    var max: Int
}

enum DDCReadResult {
    case value(VCPValue)
    case unsupported
    case failed
}

/// DDC/CI over IOAVService (Apple silicon). Reads are synchronous on a private serial
/// queue; writes are coalesced so a dragged slider sends only the latest value.
final class DDC {
    let service: CFTypeRef
    let framebuffer: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [UInt8: UInt16] = [:]
    private var draining = false

    private init(service: CFTypeRef, framebuffer: String) {
        self.service = service
        self.framebuffer = framebuffer
        queue = DispatchQueue(label: "DisplayBar.ddc.\(framebuffer)", qos: .userInitiated)
    }

    /// Finds the DDC channel for an external display: CoreDisplay names the framebuffer
    /// (`…/dispext0@A0000000/IOMobileFramebufferShim`) and the matching
    /// `DCPAVServiceProxy` lives under `…/dispext0:dcpav-service-epic:0/`.
    static func make(for id: CGDirectDisplayID) -> DDC? {
        guard CGDisplayIsBuiltin(id) == 0,
              let create = Private.avCreate,
              let location = Private.info(id)?["IODisplayLocation"] as? String,
              let node = location.split(separator: "/").last(where: { $0.hasPrefix("disp") })
        else { return nil }
        let framebuffer = String(node.split(separator: "@").first ?? node)

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var buffer = [CChar](repeating: 0, count: 1024)
            guard IORegistryEntryGetPath(service, kIOServicePlane, &buffer) == KERN_SUCCESS else { continue }
            guard String(cString: buffer).contains("/\(framebuffer):") else { continue }
            if let kind = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               kind != "External" { continue }
            guard let av = create(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }
            return DDC(service: av, framebuffer: framebuffer)
        }
        return nil
    }

    // MARK: Wire protocol

    private static func checksum(_ seed: UInt8, _ bytes: [UInt8], through end: Int) -> UInt8 {
        var value = seed
        for i in 0...end { value ^= bytes[i] }
        return value
    }

    /// Get VCP Feature. Blocking (~70 ms); call off the main thread.
    func readSync(_ code: UInt8) -> DDCReadResult {
        guard let write = Private.avWrite, let read = Private.avRead else { return .failed }
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = Self.checksum(0x6E, packet, through: 2)
        for _ in 0..<4 {
            var sent = false
            for _ in 0..<2 {
                usleep(10_000)
                if write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { sent = true }
            }
            if sent {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                if read(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   Self.checksum(0x50, reply, through: 9) == reply[10],
                   reply[2] == 0x02, reply[4] == code {
                    if reply[3] != 0 { return .unsupported }
                    let max = Int(reply[6]) << 8 | Int(reply[7])
                    let current = Int(reply[8]) << 8 | Int(reply[9])
                    return .value(VCPValue(current: current, max: max > 0 ? max : 100))
                }
            }
            usleep(20_000)
        }
        return .failed
    }

    /// Set VCP Feature. Blocking; call off the main thread.
    @discardableResult
    func writeSync(_ code: UInt8, _ value: UInt16) -> Bool {
        guard let write = Private.avWrite else { return false }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = Self.checksum(0x6E ^ 0x51, packet, through: 4)
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            if write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
        }
        return ok
    }

    // MARK: Async API (main-thread callers)

    /// Queues a write; rapid calls for the same code collapse to the newest value.
    func set(_ code: VCP, _ value: Int) {
        lock.lock()
        pending[code.rawValue] = UInt16(clamping: value)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (code, value) = pending.first else {
                draining = false
                lock.unlock()
                return
            }
            pending.removeValue(forKey: code)
            lock.unlock()
            writeSync(code, value)
        }
    }

    func read(_ codes: [VCP], completion: @escaping ([VCP: DDCReadResult]) -> Void) {
        queue.async {
            var results: [VCP: DDCReadResult] = [:]
            for code in codes { results[code] = self.readSync(code.rawValue) }
            DispatchQueue.main.async { completion(results) }
        }
    }
}

/// Common MCCS input source values (VCP 0x60).
enum InputSource: Int, CaseIterable {
    case vga1 = 0x01, dvi1 = 0x03, dvi2 = 0x04
    case displayPort1 = 0x0F, displayPort2 = 0x10
    case hdmi1 = 0x11, hdmi2 = 0x12
    case usbC = 0x1B

    var title: String {
        switch self {
        case .vga1: "VGA"
        case .dvi1: "DVI 1"
        case .dvi2: "DVI 2"
        case .displayPort1: "DisplayPort 1"
        case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        }
    }
}
