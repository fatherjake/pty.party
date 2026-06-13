import AppKit

/// An image dropped onto the canvas. Drag anywhere on it to move it; the
/// corner grip resizes it while preserving its aspect ratio.
final class ImageTileView: CanvasTileView {
    let image: NSImage
    /// Called just before the tile removes itself from the canvas.
    var onClosed: (() -> Void)?

    var isSelected = false {
        didSet {
            needsDisplay = true
            // Ports only show on the selected image, Figma-style.
            for port in ports {
                port.isHidden = !isSelected
            }
        }
    }

    /// The image is inset from the tile bounds so the border-straddling
    /// ports stay inside the tile's hit-testable frame.
    private var imageRect: NSRect {
        bounds.insetBy(dx: Self.portCenterInset, dy: Self.portCenterInset)
    }

    private let aspectRatio: CGFloat  // height / width
    private let closeButton: NSButton
    private let resizeGrip: ResizeGripView
    private let ports: [ConnectHandleView]
    private var dragOffset = NSPoint.zero

    /// Stable identity used to persist connections across relaunches.
    let imageID: String

    init(image: NSImage, frame: NSRect, imageID: String = UUID().uuidString) {
        self.image = image
        self.imageID = imageID
        let margins = CanvasTileView.portCenterInset * 2
        let contentSize = NSSize(width: frame.width - margins, height: frame.height - margins)
        aspectRatio = contentSize.width > 0 ? contentSize.height / contentSize.width : 1
        closeButton = NSButton(frame: .zero)
        resizeGrip = ResizeGripView(frame: .zero)
        ports = (0..<4).map { _ in ConnectHandleView(frame: .zero) }
        super.init(frame: frame)

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.7)
        closeButton.target = self
        closeButton.action = #selector(closeTile)

        resizeGrip.tile = self

        addSubview(closeButton)
        addSubview(resizeGrip)
        for port in ports {
            port.tile = self
            port.toolTip = "Drag to a terminal to connect this image"
            port.isHidden = true  // shown when the image is selected
            addSubview(port)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var minSize: NSSize {
        let margins = Self.portCenterInset * 2
        let minWidth: CGFloat = aspectRatio >= 1 ? 60 : 60 / aspectRatio
        return NSSize(width: minWidth + margins, height: minWidth * aspectRatio + margins)
    }

    override func clampedSize(_ proposed: NSSize) -> NSSize {
        // Follow whichever axis the user has pulled further, keeping the
        // image content's aspect (the tile adds fixed margins around it).
        let margins = Self.portCenterInset * 2
        var contentWidth = max(proposed.width - margins, (proposed.height - margins) / aspectRatio)
        let minWidth: CGFloat = aspectRatio >= 1 ? 60 : 60 / aspectRatio
        contentWidth = max(contentWidth, minWidth)
        return NSSize(
            width: contentWidth + margins,
            height: contentWidth * aspectRatio + margins
        )
    }

    override func layout() {
        super.layout()
        let content = imageRect
        closeButton.frame = NSRect(x: content.minX + 5, y: content.minY + 5, width: 18, height: 18)
        resizeGrip.frame = NSRect(x: content.maxX - 18, y: content.maxY - 18, width: 18, height: 18)
        // One port straddling the midpoint of each image edge.
        let portSize: CGFloat = 14
        let centers = [
            NSPoint(x: content.midX, y: content.minY),  // top
            NSPoint(x: content.midX, y: content.maxY),  // bottom
            NSPoint(x: content.minX, y: content.midY),  // left
            NSPoint(x: content.maxX, y: content.midY),  // right
        ]
        for (port, center) in zip(ports, centers) {
            port.frame = NSRect(
                x: center.x - portSize / 2, y: center.y - portSize / 2,
                width: portSize, height: portSize
            )
        }
    }


    override func draw(_ dirtyRect: NSRect) {
        let content = imageRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: content, xRadius: 8, yRadius: 8).addClip()
        image.draw(
            in: content,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: content, xRadius: 8, yRadius: 8)
        if isSelected {
            Theme.green.setStroke()
            border.lineWidth = 3
        } else {
            Theme.border.setStroke()
            border.lineWidth = 1
        }
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas = superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas = superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        setFrameOrigin(NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
    }

    /// Removes the image from the canvas (✕ button or Backspace).
    func close() {
        onClosed?()
        removeFromSuperview()
    }

    @objc private func closeTile() {
        close()
    }
}

/// An edge port you drag out to a terminal to connect a tile to it. Lives on
/// images (visible when selected) and terminals (visible when focused, also
/// acting as drop targets during a drag).
final class ConnectHandleView: NSView {
    weak var tile: CanvasTileView?

    /// Lit up as the snap target while another port's line is dragged near.
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        PortStyle.draw(in: bounds, active: isHovered || isHighlighted)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private var canvas: CanvasView? { tile?.superview as? CanvasView }

    /// This port's center in canvas coordinates.
    private var anchorPoint: NSPoint? {
        guard let tile, let canvas else { return nil }
        return tile.convert(NSPoint(x: frame.midX, y: frame.midY), to: canvas)
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas, let anchorPoint else { return }
        canvas.pendingLine = (
            from: anchorPoint,
            to: canvas.convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas, let anchorPoint else { return }
        canvas.pendingLine = (
            from: anchorPoint,
            to: canvas.convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let tile, let canvas else { return }
        canvas.pendingLine = nil
        let point = canvas.convert(event.locationInWindow, from: nil)
        guard let terminal = canvas.terminalTile(at: point) else { return }
        if let image = tile as? ImageTileView {
            canvas.toggleConnection(from: image, to: terminal)
        } else if let note = tile as? NoteTileView {
            canvas.toggleNoteConnection(from: note, to: terminal)
        } else if let source = tile as? TerminalTileView, source !== terminal {
            canvas.toggleTerminalConnection(source, terminal)
        }
    }
}
