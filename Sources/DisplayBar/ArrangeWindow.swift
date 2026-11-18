import AppKit
import ImageIO

/// "Arrange Displays" — the System Settings arrangement canvas: drag displays to
/// place them (they snap edge to edge), drag the white menu bar to pick the main display.
/// The window and its wallpaper thumbnails are released when it closes.
final class ArrangeWindowController: NSWindowController, NSWindowDelegate {
    private static var current: ArrangeWindowController?

    static func show() {
        let controller = current ?? ArrangeWindowController()
        current = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static var isOpen: Bool { current != nil }
    static var window: NSWindow? { current?.window }

    private let canvas = ArrangementView()
    private let note = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Arrange Displays"
        window.minSize = NSSize(width: 460, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        [canvas, note, done].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            done.centerYAnchor.constraint(equalTo: note.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        window.contentView = root
        window.center()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .displaysChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reload() {
        canvas.reload()
        var text = "Drag displays to arrange them. Drag the white menu bar to another display to make it the main display."
        let off = DisplayManager.shared.off.map(\.name)
        if !off.isEmpty { text += " Turned-off displays aren't shown (\(off.joined(separator: ", ")))." }
        note.stringValue = text
    }

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async {
            ArrangeWindowController.current = nil
            Memory.trimSoon()
        }
    }
}

/// Snapping and normalisation, kept pure so the self-test can check it.
enum Arrangement {
    /// Moves `moving` (proposed frame, global points) so it touches one of `others` without
    /// overlapping any, as close as possible to where it was dropped. Edges within
    /// `alignSlop` points snap flush with the neighbour's edge.
    static func snap(_ moving: CGRect, to others: [CGRect], alignSlop: CGFloat = 40) -> CGRect {
        guard !others.isEmpty else { return moving }
        let w = moving.width, h = moving.height, p = moving.origin
        var candidates: [CGPoint] = []

        func align(_ value: CGFloat, start: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
            for target in [start, end - size, (start + end - size) / 2] where abs(value - target) <= alignSlop { return target }
            return value
        }
        for o in others {
            let y = align(min(max(p.y, o.minY - h + 1), o.maxY - 1), start: o.minY, end: o.maxY, size: h)
            let x = align(min(max(p.x, o.minX - w + 1), o.maxX - 1), start: o.minX, end: o.maxX, size: w)
            candidates += [CGPoint(x: o.maxX, y: y), CGPoint(x: o.minX - w, y: y),
                           CGPoint(x: x, y: o.maxY), CGPoint(x: x, y: o.minY - h)]
        }
        let valid = candidates
            .map { CGRect(origin: CGPoint(x: $0.x.rounded(), y: $0.y.rounded()), size: moving.size) }
            .filter { candidate in !others.contains { $0.intersection(candidate).width > 0.5 && $0.intersection(candidate).height > 0.5 } }
        return valid.min { hypot($0.minX - p.x, $0.minY - p.y) < hypot($1.minX - p.x, $1.minY - p.y) } ?? moving
    }

    /// Origins with the main display back at (0, 0), as CoreGraphics expects.
    static func normalized(_ frames: [CGDirectDisplayID: CGRect], main: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint] {
        let shift = frames[main]?.origin ?? .zero
        return frames.mapValues { CGPoint(x: $0.minX - shift.x, y: $0.minY - shift.y) }
    }
}

final class ArrangementView: NSView {
    private struct Tile {
        let id: CGDirectDisplayID
        let name: String
        var frame: CGRect // global points (top-left origin, like CoreGraphics)
        let isMain: Bool
        let mirrors: Int
        let image: CGImage?
    }

    private var tiles: [Tile] = []
    private var scale: CGFloat = 0.1
    private var offset = CGPoint.zero
    private var dragging: (index: Int, grab: CGPoint)?
    private var draggingMenuBar: CGPoint?
    private var thumbnails: [CGDirectDisplayID: CGImage] = [:]
    static var showWallpaper = true

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        guard dragging == nil else { return }
        let manager = DisplayManager.shared
        let shown = manager.displays.filter { CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay }
        tiles = shown.map { d in
            let mirrors = manager.displays.filter { CGDisplayMirrorsDisplay($0.id) == d.id }.count
            return Tile(id: d.id, name: d.name, frame: CGDisplayBounds(d.id), isMain: d.isMain, mirrors: mirrors, image: thumbnail(for: d))
        }
        needsLayout = true
        needsDisplay = true
    }

    private func thumbnail(for d: Display) -> CGImage? {
        guard Self.showWallpaper else { return nil }
        if let cached = thumbnails[d.id] { return cached }
        guard let screen = d.screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 360,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        thumbnails[d.id] = image
        return image
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        computeTransform()
    }

    private func computeTransform() {
        guard !tiles.isEmpty else { return }
        let union = tiles.dropFirst().reduce(tiles[0].frame) { $0.union($1.frame) }
        let pad: CGFloat = 36
        scale = min((bounds.width - 2 * pad) / max(union.width, 1), (bounds.height - 2 * pad) / max(union.height, 1), 0.2)
        offset = CGPoint(x: bounds.midX - union.midX * scale, y: bounds.midY - union.midY * scale)
    }

    private func viewRect(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX * scale + offset.x, y: frame.minY * scale + offset.y, width: frame.width * scale, height: frame.height * scale)
    }

    private func globalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    private func menuBarRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + 2, y: rect.minY + 2, width: rect.width - 4, height: max(5, min(9, rect.height * 0.06)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        // Draw the dragged tile last so it floats above the others.
        let order = tiles.indices.filter { $0 != dragging?.index } + (dragging.map { [$0.index] } ?? [])
        for index in order { drawTile(tiles[index], highlighted: index == dragging?.index) }
        if let point = draggingMenuBar, let main = tiles.first(where: \.isMain) {
            let width = viewRect(main.frame).width - 4
            let bar = CGRect(x: point.x - width / 2, y: point.y - 4, width: width, height: 8)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawTile(_ tile: Tile, highlighted: Bool) {
        let rect = viewRect(tile.frame).insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let image = tile.image, let context = NSGraphicsContext.current?.cgContext {
            // Aspect-fill; the view is flipped, so flip the image back.
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            var fill = rect
            if rect.width / rect.height > aspect { fill.size.height = rect.width / aspect } else { fill.size.width = rect.height * aspect }
            fill.origin = CGPoint(x: rect.midX - fill.width / 2, y: rect.midY - fill.height / 2)
            context.saveGState()
            context.translateBy(x: 0, y: fill.maxY + fill.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: fill)
            context.restoreGState()
        } else {
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.27, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.36, green: 0.52, blue: 0.93, alpha: 1)])?
                .draw(in: rect, angle: -60)
        }
        NSColor.black.withAlphaComponent(0.18).setFill()
        rect.fill(using: .sourceOver)
        if tile.isMain && draggingMenuBar == nil {
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: menuBarRect(in: rect), xRadius: 2, yRadius: 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        (highlighted ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.55)).setStroke()
        shape.lineWidth = highlighted ? 3 : 1
        shape.stroke()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        var name = tile.name
        if tile.mirrors > 0 { name += " + \(tile.mirrors) mirrored" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(13, rect.height / 7)), weight: .semibold),
            .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: style,
        ]
        let size = (name as NSString).size(withAttributes: attributes)
        (name as NSString).draw(in: CGRect(x: rect.minX + 6, y: rect.midY - size.height / 2, width: rect.width - 12, height: size.height),
                                withAttributes: attributes)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let main = tiles.first(where: \.isMain), menuBarRect(in: viewRect(main.frame)).insetBy(dx: 0, dy: -4).contains(point), tiles.count > 1 {
            draggingMenuBar = point
            NSCursor.closedHand.push()
            needsDisplay = true
            return
        }
        if let index = tiles.lastIndex(where: { viewRect($0.frame).contains(point) }) {
            let rect = viewRect(tiles[index].frame)
            dragging = (index, CGPoint(x: point.x - rect.minX, y: point.y - rect.minY))
            NSCursor.closedHand.push()
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingMenuBar != nil {
            draggingMenuBar = point
        } else if let drag = dragging {
            let origin = globalPoint(CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y))
            tiles[drag.index].frame.origin = origin
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { NSCursor.pop(); needsDisplay = true }
        let point = convert(event.locationInWindow, from: nil)
        if draggingMenuBar != nil {
            draggingMenuBar = nil
            if let target = tiles.first(where: { viewRect($0.frame).contains(point) }), !target.isMain {
                DisplayManager.shared.makeMain(target.id)
            }
            return
        }
        guard let drag = dragging else { return }
        dragging = nil
        let others = tiles.enumerated().filter { $0.offset != drag.index }.map(\.element.frame)
        let snapped = Arrangement.snap(tiles[drag.index].frame, to: others)
        tiles[drag.index].frame = snapped
        let original = CGDisplayBounds(tiles[drag.index].id)
        guard snapped.origin != original.origin else { return }
        DisplayManager.shared.arrange(tiles.reduce(into: [:]) { $0[$1.id] = $1.frame })
    }
}
