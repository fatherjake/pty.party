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

    /// The line being dragged out from an image's connect handle. While set,
    /// terminals show their target ports and the nearest one lights up.
    var pendingLine: (from: NSPoint, to: NSPoint)? {
        didSet {
            let dragging = pendingLine != nil
            if dragging != (oldValue != nil) {
                for case let terminal as TerminalTileView in subviews {
                    terminal.setConnectionTargets(visible: dragging)
                }
            }
            let dragPoint = pendingLine?.to
            for case let terminal as TerminalTileView in subviews {
                let pointIfHovered = dragPoint.flatMap { terminal.frame.contains($0) ? $0 : nil }
                terminal.highlightConnectionTarget(near: pointIfHovered)
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
        pendingLine = nil
        refreshConnections()
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
        for connection in canvas.connections {
            guard let image = connection.image, let terminal = connection.terminal,
                  image.superview === canvas, terminal.superview === canvas else { continue }
            let terminalCenter = NSPoint(x: terminal.frame.midX, y: terminal.frame.midY)
            let from = image.connectionAnchor(toward: terminalCenter)
            let to = terminal.connectionAnchor(toward: from)
            drawConnection(from: from, to: to)
        }
        for connection in canvas.noteConnections {
            guard let note = connection.note, let terminal = connection.terminal,
                  note.superview === canvas, terminal.superview === canvas else { continue }
            let terminalCenter = NSPoint(x: terminal.frame.midX, y: terminal.frame.midY)
            let from = note.connectionAnchor(toward: terminalCenter)
            let to = terminal.connectionAnchor(toward: from)
            drawConnection(from: from, to: to)
        }
        // Terminal-to-terminal links draw dashed to tell them apart.
        for link in canvas.terminalConnections {
            guard let first = link.first, let second = link.second,
                  first.superview === canvas, second.superview === canvas else { continue }
            let secondCenter = NSPoint(x: second.frame.midX, y: second.frame.midY)
            let from = first.connectionAnchor(toward: secondCenter)
            let to = second.connectionAnchor(toward: from)
            drawConnection(from: from, to: to, dashed: true)
        }
        if let pendingLine = canvas.pendingLine {
            var to = pendingLine.to
            // Snap the loose end onto the hovered terminal's nearest port.
            if let terminal = canvas.terminalTile(at: to) {
                to = terminal.connectionAnchor(toward: to)
            }
            drawConnection(from: pendingLine.from, to: to)
        }
    }

    private func drawConnection(from: NSPoint, to: NSPoint, dashed: Bool = false) {
        let color = Theme.green
        color.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 2.5
        if dashed {
            path.setLineDash([6, 4], count: 2, phase: 0)
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
