import AppKit

/// The branding + session badge pinned to the top-left of the window: a green
/// app glyph, the "pty.party" wordmark, and the current session name with a
/// dropdown chevron. Clicking anywhere on it opens the session switcher.
final class SessionBadgeView: NSView {
    /// Called when the session name region is clicked, to pop up the session
    /// menu anchored under it.
    var onSelectSession: ((SessionBadgeView) -> Void)?

    /// Called when the host region is clicked, to pop up the host menu anchored
    /// under it. Use `hostSegmentMinX` to anchor it.
    var onSelectHost: ((SessionBadgeView) -> Void)?

    /// X (in this view's coords) where the host region begins — the boundary
    /// used for hit-testing and for anchoring the host menu.
    private(set) var hostSegmentMinX: CGFloat = 0

    /// X (in this view's coords) where the session name begins — used to anchor
    /// the session menu under the name rather than the badge's left edge.
    private(set) var nameSegmentMinX: CGFloat = 0

    /// The session name shown after the "pty.party /" wordmark.
    var sessionName: String = "" {
        didSet {
            guard sessionName != oldValue else { return }
            invalidateIntrinsicContentSize()
            sizeToFit()
            needsDisplay = true
        }
    }

    /// The SSH target this session runs on (`user@host` or an `~/.ssh/config`
    /// alias), or nil/empty for a local session. Shown as a trailing segment so
    /// you can see at a glance where the session's tiles run.
    var sessionHost: String? {
        didSet {
            guard sessionHost != oldValue else { return }
            invalidateIntrinsicContentSize()
            sizeToFit()
            needsDisplay = true
        }
    }

    /// The host label: the SSH target when remote, otherwise "Local".
    private var hostText: String {
        if let host = sessionHost, !host.isEmpty { return host }
        return "Local"
    }

    override var isFlipped: Bool { false }

    // MARK: Metrics
    private static let height: CGFloat = 46
    private static let hPad: CGFloat = 14
    private static let icon: CGFloat = 28
    private static let gap: CGFloat = 9          // between text elements
    private static let iconGap: CGFloat = 12     // icon → wordmark

    // MARK: Fonts
    private var wordFont: NSFont { Theme.mono(15, .bold) }
    private var slashFont: NSFont { Theme.mono(15, .medium) }
    private var nameFont: NSFont { Theme.mono(14, .medium) }
    private var hostFont: NSFont { Theme.mono(12, .medium) }
    private var chevronFont: NSFont { Theme.mono(10, .semibold) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Sizing

    private func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth(), height: Self.height)
    }

    private func contentWidth() -> CGFloat {
        let name = sessionName.isEmpty ? "session" : sessionName
        return Self.hPad + Self.icon + Self.iconGap
            + width("pty.party", wordFont) + Self.gap
            + width("/", slashFont) + Self.gap
            + width(name, nameFont) + Self.gap
            + width("▾", chevronFont) + Self.gap   // session dropdown chevron
            + width(hostText, hostFont) + Self.gap
            + width("▾", chevronFont) + Self.hPad
    }

    func sizeToFit() {
        setFrameSize(NSSize(width: contentWidth(), height: Self.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Pill background.
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        Theme.tile.setFill()
        pill.fill()
        Theme.border.setStroke()
        pill.lineWidth = 1
        pill.stroke()

        // App glyph: a green rounded square holding a dark "panel" mark.
        let iconRect = NSRect(
            x: Self.hPad, y: (bounds.height - Self.icon) / 2,
            width: Self.icon, height: Self.icon
        )
        let iconBG = NSBezierPath(roundedRect: iconRect, xRadius: 8, yRadius: 8)
        Theme.green.setFill()
        iconBG.fill()
        let inner = iconRect.insetBy(dx: 6, dy: 6)
        let panel = NSBezierPath(roundedRect: inner, xRadius: 3, yRadius: 3)
        Theme.canvas.setStroke()
        panel.lineWidth = 2
        panel.stroke()
        let bar = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.4, height: inner.height)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
        Theme.canvas.setFill()
        barPath.fill()

        // Wordmark + session, baseline-aligned to the icon's vertical center.
        var x = iconRect.maxX + Self.iconGap
        drawString("pty.party", wordFont, Theme.textPrimary, at: &x)
        x += Self.gap
        drawString("/", slashFont, Theme.green, at: &x)
        x += Self.gap
        nameSegmentMinX = x
        let name = sessionName.isEmpty ? "session" : sessionName
        drawString(name, nameFont, Theme.textDim, at: &x)
        x += Self.gap
        drawString("▾", chevronFont, Theme.textDim, at: &x)  // session dropdown
        x += Self.gap

        // Everything from here on is the host region (its own dropdown).
        hostSegmentMinX = x
        // Remote host stands out in green; a plain local session reads dim.
        let isRemote = sessionHost.map { !$0.isEmpty } ?? false
        drawString(hostText, hostFont, isRemote ? Theme.green : Theme.textDim, at: &x)
        x += Self.gap
        drawString("▾", chevronFont, Theme.textDim, at: &x)
    }

    /// Draws `s` left-aligned at `x`, vertically centered, then advances `x`.
    private func drawString(_ s: String, _ font: NSFont, _ color: NSColor, at x: inout CGFloat) {
        let size = (s as NSString).size(withAttributes: [.font: font])
        let y = (bounds.height - size.height) / 2
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs(font, color))
        x += size.width
    }

    // MARK: Interaction

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hostSegmentMinX > 0, point.x >= hostSegmentMinX {
            onSelectHost?(self)
        } else {
            onSelectSession?(self)
        }
    }
}
