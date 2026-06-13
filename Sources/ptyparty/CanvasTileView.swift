import AppKit

/// Base class for everything that lives on the canvas: a tile that can be
/// raised above its siblings and resized via a corner grip.
class CanvasTileView: NSView {
    /// Distance from a tile edge to the center of a connection port on it.
    static let portCenterInset: CGFloat = 9

    var minSize: NSSize { NSSize(width: 80, height: 80) }

    /// The center of the connection port nearest `point`, in canvas
    /// coordinates — lines attach to whichever side faces the other end.
    func connectionAnchor(toward point: NSPoint) -> NSPoint {
        let inset = Self.portCenterInset
        let candidates = [
            NSPoint(x: frame.midX, y: frame.minY + inset),
            NSPoint(x: frame.midX, y: frame.maxY - inset),
            NSPoint(x: frame.minX + inset, y: frame.midY),
            NSPoint(x: frame.maxX - inset, y: frame.midY),
        ]
        return candidates.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }!
    }

    override var isFlipped: Bool { true }

    func bringToFront() {
        guard let canvas = superview, canvas.subviews.last !== self else { return }
        let focused = (window?.firstResponder as? NSView)
            .flatMap { $0.isDescendant(of: self) ? $0 : nil }
        canvas.addSubview(self)  // re-adding moves the view to the top of the z-order
        if let focused {
            window?.makeFirstResponder(focused)
        }
    }

    /// Clamp or adjust a size proposed by the resize grip.
    func clampedSize(_ proposed: NSSize) -> NSSize {
        NSSize(width: max(minSize.width, proposed.width),
               height: max(minSize.height, proposed.height))
    }

    // Make connection lines vanish with their tile, whatever removed it.
    override func removeFromSuperview() {
        let canvas = superview as? CanvasView
        super.removeFromSuperview()
        canvas?.refreshConnections()
    }

    // Keep the connection lines tracking tile movement.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        (superview as? CanvasView)?.refreshConnections()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        (superview as? CanvasView)?.refreshConnections()
    }
}

/// Shared look for connection ports on tiles.
enum PortStyle {
    static func draw(in bounds: NSRect, active: Bool) {
        let circle = bounds.insetBy(dx: 1.5, dy: 1.5)
        if active {
            Theme.green.setFill()
        } else {
            Theme.inset.withAlphaComponent(0.95).setFill()
        }
        NSBezierPath(ovalIn: circle).fill()
        (active ? Theme.green : Theme.textDim).withAlphaComponent(active ? 1.0 : 0.8).setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// Bottom-right corner handle for resizing a tile.
final class ResizeGripView: NSView {
    weak var tile: CanvasTileView?
    private var startPoint = NSPoint.zero
    private var startSize = NSSize.zero

    override func draw(_ dirtyRect: NSRect) {
        Theme.textFaint.withAlphaComponent(0.9).setStroke()
        for inset in stride(from: CGFloat(4), through: 12, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + inset))
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tile, let canvas = tile.superview else { return }
        tile.bringToFront()
        startPoint = canvas.convert(event.locationInWindow, from: nil)
        startSize = tile.frame.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile, let canvas = tile.superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        // The canvas is flipped, so dragging down/right grows the tile.
        let proposed = NSSize(
            width: startSize.width + (point.x - startPoint.x),
            height: startSize.height + (point.y - startPoint.y)
        )
        tile.setFrameSize(tile.clampedSize(proposed))
        tile.needsLayout = true
    }
}
