// Renders the pty.party app icon as a 1024×1024 PNG.
//
// It reproduces the in-app brand glyph from SessionBadgeView — a green rounded
// square holding a dark "window" panel with a left sidebar bar — laid out on
// Apple's macOS icon grid (824pt content centered in a 1024 canvas).
//
// Usage:  swift make-icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

// Theme colors (mirrors Sources/ptyparty/Theme.swift).
let green = NSColor(srgbRed: 0.49, green: 0.89, blue: 0.55, alpha: 1)
let dark  = NSColor(srgbRed: 0.045, green: 0.050, blue: 0.045, alpha: 1)

let canvas: CGFloat = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not allocate bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Green app tile on the macOS icon grid: 824 content centered, ~185 corner.
let side: CGFloat = 824
let margin = (canvas - side) / 2
let tileRect = NSRect(x: margin, y: margin, width: side, height: side)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185.4, yRadius: 185.4)
green.setFill()
tile.fill()

// Interior "window" mark, at SessionBadgeView's proportions relative to the
// tile: inset 6/28, panel stroke 2/28, panel corner 3/16, left bar 40% wide.
let inset = (6.0 / 28.0) * side
let inner = tileRect.insetBy(dx: inset, dy: inset)

// Panel outline.
let panelRadius = (3.0 / 16.0) * inner.width
let panel = NSBezierPath(roundedRect: inner, xRadius: panelRadius, yRadius: panelRadius)
dark.setStroke()
panel.lineWidth = (2.0 / 28.0) * side
panel.stroke()

// Left sidebar bar.
let bar = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.4, height: inner.height)
let barRadius = (2.0 / 16.0) * inner.width
let barPath = NSBezierPath(roundedRect: bar, xRadius: barRadius, yRadius: barRadius)
dark.setFill()
barPath.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
