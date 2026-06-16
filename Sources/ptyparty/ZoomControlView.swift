import AppKit

/// A small zoom control pinned to the bottom-left of the window, styled to
/// match the session badge: a pill holding a "−" button, the current zoom
/// percentage, and a "+" button. Clicking the percentage resets to 100%.
final class ZoomControlView: NSView {
    /// Called when the "−" segment is clicked.
    var onZoomOut: (() -> Void)?
    /// Called when the "+" segment is clicked.
    var onZoomIn: (() -> Void)?
    /// Called when the percentage segment is clicked (reset to actual size).
    var onReset: (() -> Void)?

    /// The current magnification (1.0 == 100%), shown as a percentage.
    var magnification: CGFloat = 1 {
        didSet {
            guard magnification != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    // MARK: Metrics
    private static let height: CGFloat = 36
    private static let hPad: CGFloat = 12
    private static let gap: CGFloat = 12        // between the three segments
    private static let buttonWidth: CGFloat = 16

    // MARK: Fonts
    private var symbolFont: NSFont { Theme.mono(17, .medium) }
    private var percentFont: NSFont { Theme.mono(12, .medium) }

    /// X boundaries (in this view's coords) splitting the −, %, and + regions,
    /// computed in draw and reused for hit-testing.
    private var minusMaxX: CGFloat = 0
    private var percentMaxX: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        wantsLayer = true
        sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Sizing

    private var percentText: String { "\(Int((magnification * 100).rounded()))%" }

    private func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth(), height: Self.height)
    }

    private func contentWidth() -> CGFloat {
        // Use a fixed-width slot for the percentage so the pill doesn't jitter
        // as the digit count changes while zooming.
        Self.hPad + Self.buttonWidth + Self.gap
            + width("1000%", percentFont) + Self.gap
            + Self.buttonWidth + Self.hPad
    }

    func sizeToFit() {
        setFrameSize(NSSize(width: contentWidth(), height: Self.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Pill background, matching the session badge.
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.tile.setFill()
        pill.fill()
        Theme.border.setStroke()
        pill.lineWidth = 1
        pill.stroke()

        var x = Self.hPad
        drawSymbol("−", in: NSRect(x: x, y: 0, width: Self.buttonWidth, height: bounds.height))
        x += Self.buttonWidth
        minusMaxX = x + Self.gap / 2
        x += Self.gap

        let slot = width("1000%", percentFont)
        drawCentered(percentText, percentFont, Theme.textDim,
                     in: NSRect(x: x, y: 0, width: slot, height: bounds.height))
        x += slot
        percentMaxX = x + Self.gap / 2
        x += Self.gap

        drawSymbol("+", in: NSRect(x: x, y: 0, width: Self.buttonWidth, height: bounds.height))
    }

    private func drawSymbol(_ s: String, in rect: NSRect) {
        drawCentered(s, symbolFont, Theme.textPrimary, in: rect)
    }

    private func drawCentered(_ s: String, _ font: NSFont, _ color: NSColor, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: rect.minX + (rect.width - size.width) / 2,
            y: rect.minY + (rect.height - size.height) / 2
        )
        (s as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: Interaction

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= minusMaxX {
            onZoomOut?()
        } else if point.x <= percentMaxX {
            onReset?()
        } else {
            onZoomIn?()
        }
    }
}
