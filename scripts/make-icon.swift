// Renders Resources/AppIcon.icns: run `swift scripts/make-icon.swift`.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1, rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.20, green: 0.36, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: 70)
    // Monitor body
    let screen = NSRect(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.33, width: rect.width * 0.66, height: rect.height * 0.44)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: screen, xRadius: size * 0.035, yRadius: size * 0.035).fill()
    let glass = screen.insetBy(dx: size * 0.028, dy: size * 0.028)
    NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.08, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.16, green: 0.22, blue: 0.48, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: glass, xRadius: size * 0.015, yRadius: size * 0.015), angle: 90)
    let stand = NSRect(x: rect.midX - rect.width * 0.05, y: rect.minY + rect.height * 0.22, width: rect.width * 0.1, height: rect.height * 0.11)
    NSBezierPath(rect: stand).fill()
    NSBezierPath(roundedRect: NSRect(x: rect.midX - rect.width * 0.17, y: rect.minY + rect.height * 0.2, width: rect.width * 0.34, height: rect.height * 0.045),
                 xRadius: size * 0.012, yRadius: size * 0.012).fill()
    // Power glyph on the screen
    let center = NSPoint(x: glass.midX, y: glass.midY), radius = glass.height * 0.27
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 125, endAngle: 55, clockwise: true)
    ring.lineWidth = size * 0.028
    ring.lineCapStyle = .round
    NSColor(srgbRed: 0.55, green: 0.80, blue: 1.0, alpha: 1).setStroke()
    ring.stroke()
    let bar = NSBezierPath()
    bar.move(to: NSPoint(x: center.x, y: center.y + radius * 0.05))
    bar.line(to: NSPoint(x: center.x, y: center.y + radius * 1.15))
    bar.lineWidth = size * 0.028
    bar.lineCapStyle = .round
    bar.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DisplayBar.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try! render(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
