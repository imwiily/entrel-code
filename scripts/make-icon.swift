import AppKit

// Renders a 1024x1024 app icon PNG to the path given as the first argument.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.89, green: 0.53, blue: 0.40, alpha: 1),
           ending: NSColor(red: 0.76, green: 0.39, blue: 0.27, alpha: 1))!.draw(in: path, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
