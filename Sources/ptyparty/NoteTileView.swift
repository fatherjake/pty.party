import AppKit

/// A PRD-style checklist card on the canvas, written by a Claude/Codex session
/// via the MCP server. The content is a plain Markdown task list
/// (`- [ ]` / `- [x]`, indented for sub-tasks) with an optional title; it is
/// persisted as a little `.md` file in the session's notes/ folder and
/// rendered here as a card with checkboxes, the active item highlighted, and a
/// progress footer.
final class NoteTileView: CanvasTileView {
    static let defaultWidth: CGFloat = 320
    override var minSize: NSSize { NSSize(width: 220, height: 120) }

    /// Stable identity, also the basename of the backing `<id>.md` file.
    let noteID: String

    private(set) var title: String
    private(set) var body: String

    var onClosed: (() -> Void)?

    var isSelected = false {
        didSet {
            updatePortVisibility()
            layer?.borderWidth = isSelected ? 2 : 1
            layer?.borderColor = (isSelected
                ? Theme.green
                : Self.cardBorder).cgColor
        }
    }

    /// True while a terminal's connection line is being dragged, so the Log
    /// reveals its ports as drop targets even when it isn't selected.
    private var dragTargetsVisible = false

    private let closeButton = NSButton(frame: .zero)
    private let resizeGrip = ResizeGripView(frame: .zero)
    private let ports: [ConnectHandleView]
    private var dragOffset = NSPoint.zero

    /// One row of the checklist.
    private struct Task {
        var level: Int
        var checked: Bool
        var text: String
    }
    /// A rendered line: either a `## section` heading or a task row.
    private enum Row {
        case section(String)
        case task(Task)
    }
    private var rows: [Row] = []
    /// Just the task rows, for progress counting and the active-item logic.
    private var tasks: [Task] {
        rows.compactMap { if case .task(let t) = $0 { return t } else { return nil } }
    }

    // MARK: Layout metrics
    private static let pad: CGFloat = 18
    private static let headerHeight: CGFloat = 22
    private static let headerGap: CGFloat = 16   // header → first row (incl. divider)
    private static let rowHeight: CGFloat = 34
    private static let sectionHeight: CGFloat = 28  // a `## section` heading row
    private static let footerGap: CGFloat = 12    // last row → footer (incl. divider)
    private static let footerHeight: CGFloat = 30
    private static let checkbox: CGFloat = 20
    private static let indent: CGFloat = 22

    // MARK: Palette
    private static let cardBG = Theme.tile
    private static let cardBorder = Theme.border
    private static let prdGray = Theme.textDim
    private static let divider = Theme.divider
    private static let green = Theme.green
    private static let activeRowBG = Theme.greenWash
    private static let boxBorder = Theme.textFaint
    private static let textDark = Theme.textPrimary
    private static let textDone = Theme.greenDim
    private static let track = Theme.inset

    init(title: String, body: String, frame: NSRect, noteID: String = UUID().uuidString) {
        self.noteID = noteID
        self.title = title
        self.body = body
        ports = (0..<4).map { _ in ConnectHandleView(frame: .zero) }
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = Self.cardBG.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Self.cardBorder.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        layer?.shadowRadius = 10
        layer?.masksToBounds = false

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeTile)
        closeButton.isHidden = true  // shown on hover

        resizeGrip.tile = self

        addSubview(closeButton)
        addSubview(resizeGrip)
        for port in ports {
            port.tile = self
            port.toolTip = "Drag to a terminal to connect this checklist"
            port.isHidden = true
            addSubview(port)
        }
        parseBody()
        sizeToContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the checklist's content (e.g. a later write to the same note).
    func update(title: String, body: String) {
        self.title = title
        self.body = body
        parseBody()
        sizeToContent()
        needsDisplay = true
    }

    /// Parses the Markdown into rows: `## ` lines become section headings,
    /// `- [ ]` / `- [x]` lines become task rows, everything else is ignored.
    private func parseBody() {
        rows = body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("## ") {
                let title = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : Row.section(title)
            }
            // Indentation: every two leading spaces (or a tab) is one level.
            let indentChars = line.count - trimmed.count
            guard let marker = Self.taskMarker(trimmed) else { return nil }
            return Row.task(Task(
                level: min(indentChars / 2, 4),
                checked: marker.checked,
                text: marker.text
            ))
        }
    }

    /// Appends new todo items, optionally under a `## section` heading. A fresh
    /// heading is only inserted when the list doesn't already end in that
    /// section, so repeated appends to the same group stay together. Safe for
    /// several terminals to call — each appends without disturbing the rest.
    func appendItems(_ items: [String], section: String?) {
        var lines = body.isEmpty ? [] : body.components(separatedBy: "\n")
        if let section = section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty,
           lastSectionTitle(in: lines)?.caseInsensitiveCompare(section) != .orderedSame {
            if !lines.isEmpty { lines.append("") }
            lines.append("## \(section)")
        }
        for item in items {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("- [ ] \(text)")
        }
        update(title: title, body: lines.joined(separator: "\n"))
    }

    /// Ticks (or un-ticks) the first matching task by its text. Returns true if
    /// a row actually changed.
    @discardableResult
    func setChecked(matching text: String, checked: Bool = true) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = body.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = Substring(line).drop { $0 == " " || $0 == "\t" }
            guard let marker = Self.taskMarker(trimmed), marker.checked != checked,
                  marker.text.trimmingCharacters(in: .whitespaces)
                      .caseInsensitiveCompare(needle) == .orderedSame
            else { continue }
            for box in (checked ? ["[ ]"] : ["[x]", "[X]"]) {
                if let r = line.range(of: box) {
                    lines[i] = line.replacingCharacters(in: r, with: checked ? "[x]" : "[ ]")
                    break
                }
            }
            update(title: title, body: lines.joined(separator: "\n"))
            return true
        }
        return false
    }

    /// The title of the last `## section` in `lines`, if any.
    private func lastSectionTitle(in lines: [String]) -> String? {
        for line in lines.reversed() {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("## ") {
                return trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Matches `- [ ] text` / `- [x] text` (also `*`/`+` bullets) and returns
    /// the checked flag and trailing text, or nil if the line isn't a task.
    private static func taskMarker(_ s: Substring) -> (checked: Bool, text: String)? {
        guard let first = s.first, first == "-" || first == "*" || first == "+" else { return nil }
        let afterBullet = s.dropFirst().drop { $0 == " " }
        guard afterBullet.first == "[", afterBullet.count >= 3 else { return nil }
        let box = afterBullet.dropFirst().first!
        let afterBox = afterBullet.dropFirst(2)
        guard afterBox.first == "]" else { return nil }
        let text = afterBox.dropFirst().drop { $0 == " " }
        let checked = (box == "x" || box == "X")
        return (checked, String(text))
    }

    /// The index into `rows` of the active row: the first unchecked task, which
    /// the card highlights as the item in progress.
    private var activeRowIndex: Int? {
        rows.firstIndex { if case .task(let t) = $0 { return !t.checked } else { return false } }
    }

    /// Height needed to show the whole checklist at the current width.
    private func preferredHeight() -> CGFloat {
        let rowsHeight = rows.isEmpty
            ? Self.rowHeight  // the empty-state hint occupies one row
            : rows.reduce(CGFloat(0)) { acc, row in
                if case .section = row { return acc + Self.sectionHeight }
                return acc + Self.rowHeight
            }
        return Self.pad + Self.headerHeight + Self.headerGap
            + rowsHeight + Self.footerGap + Self.footerHeight + Self.pad
    }

    private func sizeToContent() {
        setFrameSize(NSSize(width: bounds.width, height: preferredHeight()))
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.maxX - 24, y: 8, width: 16, height: 16)
        resizeGrip.frame = NSRect(x: bounds.maxX - 18, y: bounds.maxY - 18, width: 18, height: 18)
        let inset = Self.portCenterInset
        let portSize: CGFloat = 14
        let centers = [
            NSPoint(x: bounds.midX, y: inset),
            NSPoint(x: bounds.midX, y: bounds.maxY - inset),
            NSPoint(x: inset, y: bounds.midY),
            NSPoint(x: bounds.maxX - inset, y: bounds.midY),
        ]
        for (port, center) in zip(ports, centers) {
            port.frame = NSRect(
                x: center.x - portSize / 2, y: center.y - portSize / 2,
                width: portSize, height: portSize
            )
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let pad = Self.pad
        let width = bounds.width

        // Header: green chevron, title, "PRD" tag.
        let headerMidY = pad + Self.headerHeight / 2
        let chevron = "›" as NSString
        let chevronAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(16, .semibold),
            .foregroundColor: Self.green,
        ]
        let chevronSize = chevron.size(withAttributes: chevronAttrs)
        chevron.draw(
            at: NSPoint(x: pad, y: headerMidY - chevronSize.height / 2),
            withAttributes: chevronAttrs
        )

        let prd = "LOG"
        let prdAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(11, .semibold),
            .foregroundColor: Self.prdGray,
            .kern: 1.5,
        ]
        let prdSize = (prd as NSString).size(withAttributes: prdAttrs)
        (prd as NSString).draw(
            at: NSPoint(x: width - pad - prdSize.width, y: headerMidY - prdSize.height / 2),
            withAttributes: prdAttrs
        )

        let titleX = pad + chevronSize.width + 10
        drawText(
            title.isEmpty ? "Checklist" : title,
            font: Theme.mono(14, .semibold),
            color: Self.textDark, strike: false,
            in: NSRect(x: titleX, y: pad, width: width - pad - prdSize.width - 12 - titleX,
                       height: Self.headerHeight)
        )

        // Divider under the header.
        let headerBottom = pad + Self.headerHeight + 8
        drawDivider(atY: headerBottom, pad: pad, width: width)

        // Rows: sections and tasks, stacked top-to-bottom.
        var rowY = pad + Self.headerHeight + Self.headerGap
        let active = activeRowIndex
        if rows.isEmpty {
            drawEmptyHint(atY: rowY, width: width)
        } else {
            for (i, row) in rows.enumerated() {
                switch row {
                case .section(let heading):
                    drawSection(heading, atY: rowY, width: width)
                    rowY += Self.sectionHeight
                case .task(let task):
                    drawRow(task, isActive: i == active, atY: rowY, width: width)
                    rowY += Self.rowHeight
                }
            }
        }

        // Footer: divider, "x/y done", progress bar.
        let footerTop = bounds.height - pad - Self.footerHeight
        drawDivider(atY: footerTop, pad: pad, width: width)
        drawFooter(atY: footerTop + 8, pad: pad, width: width)
    }

    private func drawRow(_ task: Task, isActive: Bool, atY rowY: CGFloat, width: CGFloat) {
        let pad = Self.pad
        if isActive {
            let highlight = NSRect(
                x: pad - 8, y: rowY + 1, width: width - (pad - 8) * 2, height: Self.rowHeight - 2
            )
            let highlightPath = NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8)
            Self.activeRowBG.setFill()
            highlightPath.fill()
            Self.green.withAlphaComponent(0.55).setStroke()
            highlightPath.lineWidth = 1
            highlightPath.stroke()
        }

        let box = Self.checkbox
        let boxX = pad + CGFloat(task.level) * Self.indent
        let boxRect = NSRect(x: boxX, y: rowY + (Self.rowHeight - box) / 2, width: box, height: box)
        let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6)

        if task.checked {
            Self.green.setFill()
            boxPath.fill()
            drawCheckmark(in: boxRect)
        } else if isActive {
            // Active item: a green-outlined box with a filled green core, like a
            // selected radio — the item in progress.
            Theme.inset.setFill()
            boxPath.fill()
            Self.green.setStroke()
            boxPath.lineWidth = 2
            boxPath.stroke()
            let core = boxRect.insetBy(dx: 5, dy: 5)
            Self.green.setFill()
            NSBezierPath(roundedRect: core, xRadius: 2.5, yRadius: 2.5).fill()
        } else {
            Theme.inset.setFill()
            boxPath.fill()
            Self.boxBorder.setStroke()
            boxPath.lineWidth = 1.5
            boxPath.stroke()
        }

        let textX = boxRect.maxX + 12
        drawText(
            task.text,
            font: Theme.mono(13, isActive ? .medium : .regular),
            color: task.checked ? Self.textDone : Self.textDark,
            strike: task.checked,
            in: NSRect(x: textX, y: rowY, width: width - pad - textX, height: Self.rowHeight)
        )
    }

    /// A section heading inside the list: a small, dim, all-caps label that
    /// separates one group of tasks from the next.
    private func drawSection(_ heading: String, atY y: CGFloat, width: CGFloat) {
        drawText(
            heading.uppercased(),
            font: Theme.mono(11, .semibold), color: Self.prdGray, strike: false,
            in: NSRect(x: Self.pad, y: y + 4, width: width - Self.pad * 2, height: Self.sectionHeight - 4)
        )
    }

    /// Shown when the log has no items yet, to point the user at how to fill it.
    private func drawEmptyHint(atY y: CGFloat, width: CGFloat) {
        drawText(
            "Connect a terminal to start logging",
            font: Theme.mono(12, .regular), color: Self.prdGray, strike: false,
            in: NSRect(x: Self.pad, y: y, width: width - Self.pad * 2, height: Self.rowHeight)
        )
    }

    private func drawCheckmark(in box: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX + box.width * 0.27, y: box.minY + box.height * 0.52))
        path.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.68))
        path.line(to: NSPoint(x: box.minX + box.width * 0.73, y: box.minY + box.height * 0.34))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // A cut-out check in the card color reads crisply on the green fill.
        Self.cardBG.setStroke()
        path.stroke()
    }

    private func drawFooter(atY y: CGFloat, pad: CGFloat, width: CGFloat) {
        let total = tasks.count
        let done = tasks.filter { $0.checked }.count
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(12, .semibold),
            .foregroundColor: Self.green,
        ]
        let count = "[\(done)/\(total)]" as NSString
        let countSize = count.size(withAttributes: countAttrs)
        let rowMidY = y + 9
        count.draw(at: NSPoint(x: pad, y: rowMidY - countSize.height / 2), withAttributes: countAttrs)

        // Progress bar fills the remaining width.
        let barX = pad + countSize.width + 14
        let barRect = NSRect(x: barX, y: rowMidY - 3, width: max(0, width - pad - barX), height: 6)
        Self.track.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
        if total > 0, done > 0 {
            let fraction = CGFloat(done) / CGFloat(total)
            let fillRect = NSRect(
                x: barRect.minX, y: barRect.minY,
                width: max(6, barRect.width * fraction), height: barRect.height
            )
            Self.green.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawDivider(atY y: CGFloat, pad: CGFloat, width: CGFloat) {
        Self.divider.setFill()
        NSRect(x: pad, y: y, width: width - pad * 2, height: 1).fill()
    }

    /// Draws a single, vertically-centered, tail-truncated line of text.
    private func drawText(
        _ string: String, font: NSFont, color: NSColor, strike: Bool, in rect: NSRect
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = color
        }
        let lineHeight = font.ascender - font.descender
        let textRect = NSRect(
            x: rect.minX, y: rect.midY - lineHeight / 2,
            width: rect.width, height: lineHeight
        )
        (string as NSString).draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    /// Ports show while the Log is selected (drag sources) or while a terminal's
    /// connection line is being dragged (drop targets).
    private func updatePortVisibility() {
        let visible = isSelected || dragTargetsVisible
        for port in ports {
            port.isHidden = !visible
            if !visible { port.isHighlighted = false }
        }
    }

    /// Shows or hides the edge ports while a connection is dragged, letting the
    /// Log act as a drop target for a terminal's port.
    func setConnectionTargets(visible: Bool) {
        dragTargetsVisible = visible
        updatePortVisibility()
    }

    /// Highlights the port nearest the drag point (canvas coordinates), or
    /// clears all highlights when passed nil.
    func highlightConnectionTarget(near canvasPoint: NSPoint?) {
        guard let canvasPoint, let canvas = superview else {
            ports.forEach { $0.isHighlighted = false }
            return
        }
        let local = convert(canvasPoint, from: canvas)
        let nearest = ports.min {
            hypot($0.frame.midX - local.x, $0.frame.midY - local.y) <
            hypot($1.frame.midX - local.x, $1.frame.midY - local.y)
        }
        for port in ports {
            port.isHighlighted = port === nearest
        }
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

    func close() {
        onClosed?()
        removeFromSuperview()
    }

    @objc private func closeTile() {
        close()
    }
}
