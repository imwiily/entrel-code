import AppKit

// Renders the 1024x1024 Entrel Code app icon (the "elo" mark on a graphite squircle)
// to the path given as the first argument. Geometry follows the 240-unit design SVG.
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

    context.translateBy(x: 56, y: 46)
    let light = color(0xE6E6E8), brand = color(0xD97745)

    light.setFill()
    NSBezierPath(roundedRect: NSRect(x: 14, y: 14, width: 16, height: 120), xRadius: 8, yRadius: 8).fill()

    func stroke(_ build: (NSBezierPath) -> Void, _ color: NSColor) {
        let path = NSBezierPath()
        build(path)
        path.lineWidth = 16
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
    stroke({ p in  // top rail
        p.move(to: NSPoint(x: 22, y: 22)); p.line(to: NSPoint(x: 86, y: 22))
        p.curve(to: NSPoint(x: 102, y: 38), controlPoint1: NSPoint(x: 94.84, y: 22), controlPoint2: NSPoint(x: 102, y: 29.16))
        p.curve(to: NSPoint(x: 86, y: 54), controlPoint1: NSPoint(x: 102, y: 46.84), controlPoint2: NSPoint(x: 94.84, y: 54))
        p.line(to: NSPoint(x: 30, y: 54))
    }, light)
    stroke({ p in  // terracotta link
        p.move(to: NSPoint(x: 22, y: 74)); p.line(to: NSPoint(x: 78, y: 74))
        p.curve(to: NSPoint(x: 94, y: 90), controlPoint1: NSPoint(x: 86.84, y: 74), controlPoint2: NSPoint(x: 94, y: 81.16))
        p.curve(to: NSPoint(x: 78, y: 106), controlPoint1: NSPoint(x: 94, y: 98.84), controlPoint2: NSPoint(x: 86.84, y: 106))
        p.line(to: NSPoint(x: 30, y: 106))
    }, brand)
    stroke({ p in  // bottom rail
        p.move(to: NSPoint(x: 22, y: 126)); p.line(to: NSPoint(x: 86, y: 126))
        p.curve(to: NSPoint(x: 102, y: 110), controlPoint1: NSPoint(x: 94.84, y: 126), controlPoint2: NSPoint(x: 102, y: 118.84))
    }, light)
    stroke({ p in
        p.move(to: NSPoint(x: 22, y: 126)); p.line(to: NSPoint(x: 92, y: 126))
    }, light)
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
