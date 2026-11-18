// Renders docs/img/og.png, the 1200×630 link-preview card used by the website's
// og:image / twitter:image. Run from the repo root: `swift scripts/make-og.swift`.
// Uses Resources/AppIcon.icns and the real menu screenshot in docs/img/menu.png.
import AppKit

let width: CGFloat = 1200, height: CGFloat = 630

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: the site's dark navy with its two soft glows.
color(0x0A0F1E).setFill()
canvas.fill()
NSGradient(colors: [color(0x5B8DF8, 0.34), color(0x5B8DF8, 0)])!.draw(fromCenter: NSPoint(x: 120, y: 560), radius: 0,
                                                                     toCenter: NSPoint(x: 120, y: 560), radius: 620, options: [])
NSGradient(colors: [color(0x38C6E8, 0.20), color(0x38C6E8, 0)])!.draw(fromCenter: NSPoint(x: 1080, y: 120), radius: 0,
                                                                     toCenter: NSPoint(x: 1080, y: 120), radius: 560, options: [])

func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) -> NSSize {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    let s = NSAttributedString(string: string, attributes: attributes)
    s.draw(at: point)
    return s.size()
}

// Left: icon + name, headline, features, URL.
let left: CGFloat = 72
if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
    icon.draw(in: NSRect(x: left - 10, y: 462, width: 104, height: 104))
}
_ = text("DisplayBar", at: NSPoint(x: left + 104, y: 492), size: 46, weight: .bold, color: .white, kern: -0.8)

let headline = NSMutableAttributedString()
let headFont = NSFont.systemFont(ofSize: 54, weight: .heavy)
let para = NSMutableParagraphStyle()
para.lineHeightMultiple = 0.92
headline.append(NSAttributedString(string: "Every display, one\nswitch away in your\n", attributes: [.font: headFont, .foregroundColor: color(0xE8EDF8), .kern: -1.6, .paragraphStyle: para]))
headline.append(NSAttributedString(string: "menu bar.", attributes: [.font: headFont, .foregroundColor: color(0x7FA8FF), .kern: -1.6, .paragraphStyle: para]))
headline.draw(in: NSRect(x: left, y: 186, width: 640, height: 250))

// Feature pills, wrapping before they reach the screenshot.
var x = left
var y: CGFloat = 150
for label in ["Turn screens off", "DDC brightness & volume", "Arrange", "Virtual displays"] {
    let font = NSFont.systemFont(ofSize: 19, weight: .semibold)
    let size = (label as NSString).size(withAttributes: [.font: font])
    if x + size.width + 28 > 690 {
        x = left
        y -= 48
    }
    let pill = NSRect(x: x, y: y, width: size.width + 28, height: 38)
    color(0x16213D).setFill()
    let path = NSBezierPath(roundedRect: pill, xRadius: 19, yRadius: 19)
    path.fill()
    color(0x2F3D68).setStroke()
    path.lineWidth = 1.5
    path.stroke()
    (label as NSString).draw(at: NSPoint(x: x + 14, y: y + 8), withAttributes: [.font: font, .foregroundColor: color(0xC2CBE1)])
    x = pill.maxX + 10
}
_ = text("Free & open source  ·  native macOS app  ·  zephyrsai.github.io/DisplayBar", at: NSPoint(x: left, y: 48),
         size: 19, weight: .medium, color: color(0x97A2C4))

// Right: a slice of menu bar with the real menu hanging from it.
let menuScale: CGFloat = 1.3
guard let menu = NSImage(contentsOfFile: "docs/img/menu.png"), let menuRep = menu.representations.first else { fatalError("docs/img/menu.png missing") }
let menuSize = NSSize(width: CGFloat(menuRep.pixelsWide) * menuScale, height: CGFloat(menuRep.pixelsHigh) * menuScale)
let menuRect = NSRect(x: width - 64 - menuSize.width, y: (height - menuSize.height) / 2 - 22, width: menuSize.width, height: menuSize.height)

let bar = NSRect(x: menuRect.minX - 150, y: menuRect.maxY + 10, width: menuSize.width + 150 + 30, height: 34)
color(0x1E1E21, 0.92).setFill()
NSBezierPath(roundedRect: bar, xRadius: 9, yRadius: 9).fill()
_ = text("Finder   File   Edit   View", at: NSPoint(x: bar.minX + 16, y: bar.minY + 7), size: 15, weight: .medium, color: color(0xE6E8EF, 0.85))
let chip = NSRect(x: menuRect.maxX - 92, y: bar.minY + 6, width: 28, height: 22)
color(0xFFFFFF, 0.2).setFill()
NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: chip.midX - symbol.size.width / 2, y: chip.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
}
_ = text("21:48", at: NSPoint(x: menuRect.maxX - 52, y: bar.minY + 7), size: 15, weight: .medium, color: color(0xE6E8EF, 0.85))

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
menu.draw(in: menuRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "docs/img/og.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path) (\(Int(width))×\(Int(height)))")
