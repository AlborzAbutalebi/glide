import AppKit

// Draws Glide's app icon (1024 x 1024 PNG). Usage: swift make-icon.swift out.png
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: a rounded square inset from the canvas edge.
    let inset = 100.0
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.74, blue: 0.84, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.36, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.30, green: 0.20, blue: 0.80, alpha: 1)])!
        .draw(in: shape, angle: -65)

    // Soft highlight across the top.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Motion lines: a glide to the left of the mouse.
    NSColor.white.withAlphaComponent(0.55).setStroke()
    for (i, y) in [600.0, 512, 424].enumerated() {
        let line = NSBezierPath()
        line.lineWidth = 30
        line.lineCapStyle = .round
        let length = [150.0, 210, 150][i]
        line.move(to: NSPoint(x: 330 - length, y: y))
        line.line(to: NSPoint(x: 330, y: y))
        line.stroke()
    }

    // The mouse.
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let mouse = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = mouse.size
        mouse.draw(in: NSRect(x: 600 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))
    }
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
