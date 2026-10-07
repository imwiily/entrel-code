import AppKit

// Renders the 1024x1024 Entrel Code app icon (the ">_" mark on a graphite squircle)
// to the path given as the first argument. Drawn in a 240-unit design space.
let size: CGFloat = 1024
let inset: CGFloat = 100
let scale = (size - inset * 2) / 240

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: inset, y: inset)
    context.scaleBy(x: scale, y: scale)

    // Container and its subtle inner plate.
    let container = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 240, height: 240), xRadius: 54, yRadius: 54)
    color(0x121213).setFill()
    container.fill()
    color(0x222224).setStroke()
    container.lineWidth = 1.5
    container.stroke()
    color(0x161618).withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 232, height: 232), xRadius: 50, yRadius: 50).fill()

    let light = color(0xE6E6E8), brand = color(0xD97745)
    func stroke(_ points: [NSPoint], _ color: NSColor) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 24
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
    // The 100-unit mark from the app, scaled to the icon and centered.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 120 + (x - 51) * 2.2, y: 120 + (y - 50) * 2.2) }
    stroke([p(26, 31), p(46, 50), p(26, 69)], light)
    stroke([p(56, 69), p(76, 69)], brand)
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
