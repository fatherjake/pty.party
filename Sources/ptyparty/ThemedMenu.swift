import AppKit

/// A lightweight popup menu drawn in the app's terminal-native palette, used in
/// place of `NSMenu` so the session/host switchers and the canvas right-click
/// menu match the rest of the UI instead of the system's light/vibrant chrome.
///
/// It mirrors the slice of `NSMenu` we actually use: a flat list of titled
/// rows, optional checkmarks, disabled rows, and separators. It dismisses on an
/// outside click, Escape, or selection, and supports arrow-key navigation.
final class ThemedMenu {
    struct Item {
        let title: String
        let isSeparator: Bool
        let isChecked: Bool
        let isEnabled: Bool
        let action: (() -> Void)?

        /// A selectable row. `checked` draws a leading ✓; a disabled row reads
        /// dim and can't be chosen.
        static func item(
            _ title: String,
            checked: Bool = false,
            enabled: Bool = true,
            action: @escaping () -> Void
        ) -> Item {
            Item(title: title, isSeparator: false, isChecked: checked,
                 isEnabled: enabled, action: action)
        }

        /// A hairline divider between groups.
        static let separator = Item(
            title: "", isSeparator: true, isChecked: false, isEnabled: false, action: nil
        )
    }

    private let items: [Item]
    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    /// The menu currently on screen, retained so it outlives the call that
    /// showed it. Only one themed menu is ever open at a time.
    private static var active: ThemedMenu?

    init(items: [Item]) {
        self.items = items
    }

    /// Pops the menu up with its top-left anchored at `point` (in `view`'s
    /// coordinates), the same anchoring contract as `NSMenu.popUp(at:in:)`.
    func show(at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        Self.active?.dismiss()

        let content = ThemedMenuView(items: items)
        content.onPick = { [weak self] action in
            self?.dismiss()
            action()
        }
        content.onCancel = { [weak self] in self?.dismiss() }

        let size = content.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.contentView = content

        // Anchor the panel's top-left at the requested point, dropping downward.
        let windowPoint = view.convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        var origin = NSPoint(x: screenPoint.x, y: screenPoint.y - size.height)
        if let frame = window.screen?.visibleFrame {
            // Flip above the anchor rather than spill off the bottom edge.
            if origin.y < frame.minY { origin.y = screenPoint.y }
            origin.x = min(origin.x, frame.maxX - size.width)
            origin.x = max(origin.x, frame.minX)
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        panel.invalidateShadow()

        self.panel = panel
        Self.active = self

        // Outside clicks dismiss; clicks inside fall through to the content view.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss(); return nil }
            return event
        }
        // While open, the menu owns the keyboard for navigation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            (self?.panel?.contentView as? ThemedMenuView)?.handleKeyDown(event)
            return nil
        }
    }

    private func dismiss() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        if Self.active === self { Self.active = nil }
    }
}

/// The drawn surface of a `ThemedMenu`: the rounded card plus its rows.
private final class ThemedMenuView: NSView {
    private let items: [ThemedMenu.Item]
    private var highlighted: Int?

    var onPick: ((() -> Void) -> Void)?  // called with the chosen action
    var onCancel: (() -> Void)?

    // MARK: Metrics
    private static let rowHeight: CGFloat = 28
    private static let separatorHeight: CGFloat = 11
    private static let hInset: CGFloat = 6      // card edge → row edge
    private static let leftPad: CGFloat = 10    // row edge → checkmark column
    private static let checkWidth: CGFloat = 16
    private static let rightPad: CGFloat = 18
    private static let vPad: CGFloat = 6        // card top/bottom padding
    private static let corner: CGFloat = 10
    private var font: NSFont { Theme.mono(13, .regular) }

    init(items: [ThemedMenu.Item]) {
        self.items = items
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setFrameSize(intrinsicContentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Layout

    override var intrinsicContentSize: NSSize {
        var height = Self.vPad * 2
        var widest: CGFloat = 0
        for item in items {
            height += item.isSeparator ? Self.separatorHeight : Self.rowHeight
            if !item.isSeparator {
                let w = (item.title as NSString).size(withAttributes: [.font: font]).width
                widest = max(widest, w)
            }
        }
        let width = Self.hInset * 2 + Self.leftPad + Self.checkWidth + widest + Self.rightPad
        return NSSize(width: max(width, 180), height: height)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    /// The vertical span of row `index` within the card.
    private func rowRect(_ index: Int) -> NSRect {
        var y = Self.vPad
        for i in 0..<index {
            y += items[i].isSeparator ? Self.separatorHeight : Self.rowHeight
        }
        let h = items[index].isSeparator ? Self.separatorHeight : Self.rowHeight
        return NSRect(x: Self.hInset, y: y, width: bounds.width - Self.hInset * 2, height: h)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        for i in items.indices where rowRect(i).contains(point) {
            return items[i].isSeparator ? nil : i
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The card itself, matching the badge/zoom pills.
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.corner, yRadius: Self.corner
        )
        Theme.tile.setFill()
        card.fill()
        Theme.border.setStroke()
        card.lineWidth = 1
        card.stroke()

        for (i, item) in items.enumerated() {
            let rect = rowRect(i)
            if item.isSeparator {
                Theme.divider.setStroke()
                let y = rect.midY.rounded() + 0.5
                let line = NSBezierPath()
                line.move(to: NSPoint(x: rect.minX + 6, y: y))
                line.line(to: NSPoint(x: rect.maxX - 6, y: y))
                line.lineWidth = 1
                line.stroke()
                continue
            }

            if highlighted == i, item.isEnabled {
                Theme.greenWash.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
            }

            let textColor: NSColor = item.isEnabled ? Theme.textPrimary : Theme.textFaint
            if item.isChecked {
                draw("✓", at: rect.minX + Self.leftPad, in: rect,
                     color: item.isEnabled ? Theme.green : Theme.textFaint)
            }
            draw(item.title, at: rect.minX + Self.leftPad + Self.checkWidth, in: rect, color: textColor)
        }
    }

    private func draw(_ s: String, at x: CGFloat, in row: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let y = row.minY + (row.height - size.height) / 2
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: Tracking & interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        setHighlight(rowIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHighlight(nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = rowIndex(at: convert(event.locationInWindow, from: nil)),
              items[i].isEnabled, let action = items[i].action else { return }
        onPick?(action)
    }

    private func setHighlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        needsDisplay = true
    }

    /// The first selectable row at or after `from`, walking `step` (±1) and
    /// wrapping, so arrow keys skip separators and disabled rows.
    private func selectableRow(from start: Int, step: Int) -> Int? {
        let count = items.count
        guard count > 0 else { return nil }
        var i = start
        for _ in 0..<count {
            i = (i + step + count) % count
            if !items[i].isSeparator && items[i].isEnabled { return i }
        }
        return nil
    }

    func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            onCancel?()
        case 125:  // Down
            setHighlight(selectableRow(from: highlighted ?? -1, step: 1))
        case 126:  // Up
            setHighlight(selectableRow(from: highlighted ?? items.count, step: -1))
        case 36, 76:  // Return / Enter
            if let i = highlighted, items[i].isEnabled, let action = items[i].action {
                onPick?(action)
            }
        default:
            break
        }
    }
}
