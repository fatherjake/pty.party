import AppKit
import UniformTypeIdentifiers

/// The big zoomable surface that tiles live on. Draws a dot grid so panning
/// and zooming have a visual anchor, and accepts image drops.
final class CanvasView: NSView {
    static let backgroundColor = Theme.canvas
    private static let dotColor = Theme.dot
    private static let dotSpacing: CGFloat = 40
    private static let dotSize: CGFloat = 2.5

    var onAddClaude: ((NSPoint) -> Void)?
    var onAddCodex: ((NSPoint) -> Void)?
    var onAddShell: ((NSPoint) -> Void)?
    var onAddCommandRunner: ((NSPoint) -> Void)?
    var onAddLog: ((NSPoint) -> Void)?
    var onAddImage: ((NSImage, NSPoint) -> Void)?
    var onConnectionsChanged: (() -> Void)?

    /// An image visually linked to a terminal, so the Claude session in that
    /// terminal can ask for "its" images.
    struct Connection {
        weak var image: ImageTileView?
        weak var terminal: TerminalTileView?
    }

    private(set) var connections: [Connection] = []

    /// Two terminals linked so one Claude session can read the other's
    /// output. Undirected.
    struct TerminalConnection {
        weak var first: TerminalTileView?
        weak var second: TerminalTileView?
    }

    private(set) var terminalConnections: [TerminalConnection] = []

    /// A sticky note visually linked to a terminal, so the Claude session in
    /// that terminal can read "its" notes.
    struct NoteConnection {
        weak var note: NoteTileView?
        weak var terminal: TerminalTileView?
    }

    private(set) var noteConnections: [NoteConnection] = []

    /// A stable identity for a drawn connector, so the same link can be
    /// hit-tested, highlighted and deleted regardless of array order.
    /// Terminal-to-terminal links are undirected, so their endpoints compare
    /// either way round.
    struct ConnectorID: Equatable {
        enum Kind { case image, note, terminal }
        let kind: Kind
        let a: ObjectIdentifier
        let b: ObjectIdentifier

        static func == (lhs: ConnectorID, rhs: ConnectorID) -> Bool {
            guard lhs.kind == rhs.kind else { return false }
            if lhs.a == rhs.a && lhs.b == rhs.b { return true }
            return lhs.kind == .terminal && lhs.a == rhs.b && lhs.b == rhs.a
        }
    }

    /// The connector the user has clicked: drawn dotted and removable with
    /// backspace. Transient UI state, never persisted.
    private(set) var selectedConnector: ConnectorID?

    /// The line being dragged out from a tile's connect handle. While set,
    /// the valid drop targets show their ports and the nearest one lights up.
    /// A Log (note) is a valid target only for a terminal's line, since you
    /// connect a Log to a terminal, never to another note.
    var pendingLine: (from: NSPoint, to: NSPoint, source: CanvasTileView?)? {
        didSet {
            let dragging = pendingLine != nil
            let notesAreTargets = pendingLine?.source is TerminalTileView
            if dragging != (oldValue != nil) {
                for case let terminal as TerminalTileView in subviews {
                    terminal.setConnectionTargets(visible: dragging)
                }
                for case let note as NoteTileView in subviews {
                    note.setConnectionTargets(visible: dragging && notesAreTargets)
                }
            }
            let dragPoint = pendingLine?.to
            for case let terminal as TerminalTileView in subviews {
                let pointIfHovered = dragPoint.flatMap { terminal.frame.contains($0) ? $0 : nil }
                terminal.highlightConnectionTarget(near: pointIfHovered)
            }
            for case let note as NoteTileView in subviews {
                let pointIfHovered = (notesAreTargets ? dragPoint : nil)
                    .flatMap { note.frame.contains($0) ? $0 : nil }
                note.highlightConnectionTarget(near: pointIfHovered)
            }
            refreshConnections()
        }
    }

    private var contextMenuPoint = NSPoint.zero

    override var isFlipped: Bool { true }

    private let connectionOverlay = ConnectionOverlayView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        connectionOverlay.canvas = self
        connectionOverlay.frame = bounds
        connectionOverlay.autoresizingMask = [.width, .height]
        addSubview(connectionOverlay)
    }

    /// Keeps the connection overlay above every tile, including tiles
    /// re-added by bringToFront().
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== connectionOverlay, connectionOverlay.superview === self {
            super.addSubview(connectionOverlay)
        }
    }

    /// Fired whenever tiles move, resize, appear or disappear — anything
    /// worth persisting.
    var onContentChanged: (() -> Void)?

    func refreshConnections() {
        connectionOverlay.needsDisplay = true
        onContentChanged?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Self.backgroundColor.setFill()
        dirtyRect.fill()

        Self.dotColor.setFill()
        let spacing = Self.dotSpacing
        let dot = Self.dotSize
        let startX = (dirtyRect.minX / spacing).rounded(.down) * spacing
        let startY = (dirtyRect.minY / spacing).rounded(.down) * spacing
        var x = startX
        while x <= dirtyRect.maxX {
            var y = startY
            while y <= dirtyRect.maxY {
                NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot).fill()
                y += spacing
            }
            x += spacing
        }
    }

    // MARK: - Connections

    /// Drops every connection, used when clearing the canvas to load another
    /// session.
    func clearConnections() {
        connections.removeAll()
        terminalConnections.removeAll()
        noteConnections.removeAll()
        selectedConnector = nil
        pendingLine = nil
        refreshConnections()
    }

    /// A drawn connector: its identity, its endpoints on screen, and whether
    /// it renders dashed at rest. The overlay draws from this and hit-testing
    /// reads from it, so the line you see is exactly the line you can click.
    struct ConnectorSegment {
        let id: ConnectorID
        let from: NSPoint
        let to: NSPoint
        let dashed: Bool
    }

    /// Every connector currently on the canvas, computed the same way the
    /// overlay draws them. Skips links whose endpoints have gone away.
    func connectorSegments() -> [ConnectorSegment] {
        var segments: [ConnectorSegment] = []
        for connection in connections {
            guard let image = connection.image, let terminal = connection.terminal,
                  image.superview === self, terminal.superview === self else { continue }
            let terminalCenter = NSPoint(x: terminal.frame.midX, y: terminal.frame.midY)
            let from = image.connectionAnchor(toward: terminalCenter)
            let to = terminal.connectionAnchor(toward: from)
            segments.append(ConnectorSegment(
                id: ConnectorID(kind: .image, a: ObjectIdentifier(image), b: ObjectIdentifier(terminal)),
                from: from, to: to, dashed: false))
        }
        for connection in noteConnections {
            guard let note = connection.note, let terminal = connection.terminal,
                  note.superview === self, terminal.superview === self else { continue }
            let terminalCenter = NSPoint(x: terminal.frame.midX, y: terminal.frame.midY)
            let from = note.connectionAnchor(toward: terminalCenter)
            let to = terminal.connectionAnchor(toward: from)
            segments.append(ConnectorSegment(
                id: ConnectorID(kind: .note, a: ObjectIdentifier(note), b: ObjectIdentifier(terminal)),
                from: from, to: to, dashed: false))
        }
        for link in terminalConnections {
            guard let first = link.first, let second = link.second,
                  first.superview === self, second.superview === self else { continue }
            let secondCenter = NSPoint(x: second.frame.midX, y: second.frame.midY)
            let from = first.connectionAnchor(toward: secondCenter)
            let to = second.connectionAnchor(toward: from)
            segments.append(ConnectorSegment(
                id: ConnectorID(kind: .terminal, a: ObjectIdentifier(first), b: ObjectIdentifier(second)),
                from: from, to: to, dashed: true))
        }
        return segments
    }

    /// The connector nearest `point`, if one runs within grabbing distance.
    /// Lets a click land a connection even though the lines are hairline-thin.
    func connector(at point: NSPoint) -> ConnectorID? {
        let threshold: CGFloat = 8
        var best: (id: ConnectorID, distance: CGFloat)?
        for segment in connectorSegments() {
            let distance = Self.distance(from: point, toSegment: segment.from, segment.to)
            guard distance <= threshold else { continue }
            if best == nil || distance < best!.distance {
                best = (segment.id, distance)
            }
        }
        return best?.id
    }

    /// Selects a connector (or clears the selection), redrawing the overlay.
    /// Selection isn't persisted, so this deliberately skips onContentChanged.
    func selectConnector(_ id: ConnectorID?) {
        guard selectedConnector != id else { return }
        selectedConnector = id
        connectionOverlay.needsDisplay = true
    }

    /// Removes the selected connector, whatever its kind, and clears the
    /// selection. Mirrors the toggle* methods so connected state stays in sync.
    func deleteSelectedConnector() {
        guard let id = selectedConnector else { return }
        switch id.kind {
        case .image:
            connections.removeAll {
                guard let image = $0.image, let terminal = $0.terminal else { return false }
                return ConnectorID(kind: .image, a: ObjectIdentifier(image), b: ObjectIdentifier(terminal)) == id
            }
        case .note:
            noteConnections.removeAll {
                guard let note = $0.note, let terminal = $0.terminal else { return false }
                return ConnectorID(kind: .note, a: ObjectIdentifier(note), b: ObjectIdentifier(terminal)) == id
            }
        case .terminal:
            terminalConnections.removeAll {
                guard let first = $0.first, let second = $0.second else { return false }
                return ConnectorID(kind: .terminal, a: ObjectIdentifier(first), b: ObjectIdentifier(second)) == id
            }
        }
        selectedConnector = nil
        refreshConnections()
        onConnectionsChanged?()
    }

    /// Shortest distance from `p` to the line segment `a`–`b`.
    private static func distance(from p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    func pruneConnections() {
        connections.removeAll {
            $0.image?.superview !== self || $0.terminal?.superview !== self
        }
        terminalConnections.removeAll {
            $0.first?.superview !== self || $0.second?.superview !== self
        }
        noteConnections.removeAll {
            $0.note?.superview !== self || $0.terminal?.superview !== self
        }
    }

    /// Connects the image to the terminal, or disconnects if already linked.
    func toggleConnection(from image: ImageTileView, to terminal: TerminalTileView) {
        pruneConnections()
        if let index = connections.firstIndex(where: {
            $0.image === image && $0.terminal === terminal
        }) {
            connections.remove(at: index)
        } else {
            connections.append(Connection(image: image, terminal: terminal))
        }
        refreshConnections()
        onConnectionsChanged?()
    }

    /// Links two terminals, or unlinks them if already connected.
    func toggleTerminalConnection(_ first: TerminalTileView, _ second: TerminalTileView) {
        pruneConnections()
        if let index = terminalConnections.firstIndex(where: {
            ($0.first === first && $0.second === second) ||
            ($0.first === second && $0.second === first)
        }) {
            terminalConnections.remove(at: index)
        } else {
            terminalConnections.append(TerminalConnection(first: first, second: second))
        }
        refreshConnections()
        onConnectionsChanged?()
    }

    /// Connects the note to the terminal, or disconnects if already linked.
    func toggleNoteConnection(from note: NoteTileView, to terminal: TerminalTileView) {
        pruneConnections()
        if let index = noteConnections.firstIndex(where: {
            $0.note === note && $0.terminal === terminal
        }) {
            noteConnections.remove(at: index)
        } else {
            noteConnections.append(NoteConnection(note: note, terminal: terminal))
        }
        refreshConnections()
        onConnectionsChanged?()
    }

    /// The notes linked to `terminal`.
    func connectedNotes(to terminal: TerminalTileView) -> [NoteTileView] {
        pruneConnections()
        return noteConnections.compactMap {
            $0.terminal === terminal ? $0.note : nil
        }
    }

    /// The terminals linked to `terminal`.
    func connectedTerminals(to terminal: TerminalTileView) -> [TerminalTileView] {
        pruneConnections()
        return terminalConnections.compactMap {
            if $0.first === terminal { return $0.second }
            if $0.second === terminal { return $0.first }
            return nil
        }
    }

    /// The topmost terminal tile under `point`, if any.
    func terminalTile(at point: NSPoint) -> TerminalTileView? {
        subviews.reversed().first {
            $0 is TerminalTileView && $0.frame.contains(point)
        } as? TerminalTileView
    }

    /// The topmost note (Log) tile under `point`, if any.
    func noteTile(at point: NSPoint) -> NoteTileView? {
        subviews.reversed().first {
            $0 is NoteTileView && $0.frame.contains(point)
        } as? NoteTileView
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onAddClaude?(convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuPoint = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "New Claude", action: #selector(contextAddClaude), keyEquivalent: "")
        claudeItem.target = self
        menu.addItem(claudeItem)
        let codexItem = NSMenuItem(title: "New Codex", action: #selector(contextAddCodex), keyEquivalent: "")
        codexItem.target = self
        menu.addItem(codexItem)
        let shellItem = NSMenuItem(title: "New Terminal", action: #selector(contextAddShell), keyEquivalent: "")
        shellItem.target = self
        menu.addItem(shellItem)
        let runnerItem = NSMenuItem(title: "New Command Runner", action: #selector(contextAddCommandRunner), keyEquivalent: "")
        runnerItem.target = self
        menu.addItem(runnerItem)
        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "New Log", action: #selector(contextAddLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        return menu
    }

    @objc private func contextAddLog() {
        onAddLog?(contextMenuPoint)
    }

    @objc private func contextAddCommandRunner() {
        onAddCommandRunner?(contextMenuPoint)
    }

    @objc private func contextAddClaude() {
        onAddClaude?(contextMenuPoint)
    }

    @objc private func contextAddCodex() {
        onAddCodex?(contextMenuPoint)
    }

    @objc private func contextAddShell() {
        onAddShell?(contextMenuPoint)
    }

    // MARK: - Image drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadImage(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let images = images(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return false }
        for (index, image) in images.enumerated() {
            let offset = CGFloat(index) * 32
            onAddImage?(image, NSPoint(x: dropPoint.x + offset, y: dropPoint.y + offset))
        }
        return true
    }

    private func canReadImage(from pasteboard: NSPasteboard) -> Bool {
        !ImagePasteboard.imageFileURLs(from: pasteboard).isEmpty || NSImage.canInit(with: pasteboard)
    }

    private func images(from pasteboard: NSPasteboard) -> [NSImage] {
        ImagePasteboard.images(from: pasteboard)
    }
}

/// A transparent, click-through layer above all tiles that draws connection
/// lines, so links stay visible when tiles overlap them.
final class ConnectionOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }

    // Never intercept events meant for tiles or the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }
        let selected = canvas.selectedConnector
        // Terminal-to-terminal links draw dashed to tell them apart; the
        // selected connector overrides everything with a dotted highlight.
        for segment in canvas.connectorSegments() {
            let style: ConnectionStyle = segment.id == selected
                ? .selected
                : (segment.dashed ? .dashed : .solid)
            drawConnection(from: segment.from, to: segment.to, style: style)
        }
        if let pendingLine = canvas.pendingLine {
            var to = pendingLine.to
            // Snap the loose end onto the hovered target's nearest port: any
            // terminal, or a Log when dragging out from a terminal.
            if let terminal = canvas.terminalTile(at: to) {
                to = terminal.connectionAnchor(toward: to)
            } else if pendingLine.source is TerminalTileView,
                      let note = canvas.noteTile(at: to) {
                to = note.connectionAnchor(toward: to)
            }
            drawConnection(from: pendingLine.from, to: to)
        }
    }

    private enum ConnectionStyle { case solid, dashed, selected }

    private func drawConnection(from: NSPoint, to: NSPoint, style: ConnectionStyle = .solid) {
        let selected = style == .selected
        let color = Theme.green
        color.withAlphaComponent(selected ? 1 : 0.85).setStroke()
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 2.5
        switch style {
        case .solid:
            break
        case .dashed:
            path.setLineDash([6, 4], count: 2, phase: 0)
        case .selected:
            // Round caps turn a tight dash into a clear row of dots.
            path.lineCapStyle = .round
            path.setLineDash([0.5, 5], count: 2, phase: 0)
        }
        path.stroke()
        color.setFill()
        for point in [from, to] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }
}

/// Shared pasteboard-to-image extraction, used for both drag-drop and ⌘V.
enum ImagePasteboard {
    static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    static func images(from pasteboard: NSPasteboard) -> [NSImage] {
        // Prefer file contents: a copied Finder file also puts its *icon* on
        // the pasteboard, and NSImage(pasteboard:) would return that instead.
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0) }
        }
        // Raw image data, e.g. a screenshot or an image copied from a browser.
        if let image = NSImage(pasteboard: pasteboard) {
            return [image]
        }
        return []
    }
}
