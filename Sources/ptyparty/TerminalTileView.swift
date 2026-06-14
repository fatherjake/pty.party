import AppKit
import SwiftTerm

/// A draggable, resizable terminal window living on the canvas.
final class TerminalTileView: CanvasTileView {
    static let defaultSize = NSSize(width: 640, height: 420)
    static let titleBarHeight: CGFloat = 30

    /// Identifies this tile to processes running inside it (via the
    /// PTYPARTY_TERMINAL_ID environment variable), so MCP calls made by a
    /// Claude session can be traced back to the terminal they came from.
    let terminalID: String

    /// Called just before the tile removes itself from the canvas.
    var onClosed: (() -> Void)?

    /// Claude session UUID pinned at launch, so a relaunch can resume this
    /// tile's own conversation rather than the directory's most recent one.
    var claudeSessionID: String?

    /// Name of the directly launched program ("claude"), nil for a shell.
    private(set) var launchedProgramName: String?
    /// Directory the process was started in.
    private(set) var startDirectory: String?
    /// Latest working directory reported by the shell (OSC 7).
    private(set) var currentDirectory: String?

    override var minSize: NSSize { NSSize(width: 280, height: 180) }

    /// What the program in this terminal appears to be doing, inferred from its
    /// output, and shown as the tile's border color.
    enum Activity {
        case working, asking, idle

        /// Maps a hook-written state word to an activity, ignoring anything we
        /// don't recognize.
        init?(hookState: String) {
            switch hookState {
            case "working": self = .working
            case "asking": self = .asking
            case "idle": self = .idle
            default: return nil
            }
        }
    }

    /// True while this tile's terminal has keyboard focus.
    var isFocused = false {
        didSet {
            updateBorder()
            updatePortVisibility()
        }
    }

    private var activity: Activity = .idle {
        didSet {
            if activity != oldValue {
                updateBorder()
                onActivityChanged?()
            }
        }
    }

    /// The tile's current inferred activity, read by the edge-glow overlay to
    /// decide whether (and in what color) an off-screen tile should glow.
    var currentActivity: Activity { activity }

    /// Called whenever the inferred activity changes, so the edge-glow overlay
    /// can redraw the off-screen indicators.
    var onActivityChanged: (() -> Void)?

    /// True once Claude Code hooks have reported this terminal's state. From
    /// then on the hook events are authoritative and the screen-scraping
    /// heuristic stands down (it remains the fallback for Codex tiles, plain
    /// shells, and Claude sessions without the hooks installed/trusted).
    private var usesHookActivity = false

    // Output-activity tracking, used to tell "working" from a settled prompt.
    private var lastOutputTime: TimeInterval = 0
    private var settledActivity: Activity = .idle
    private var needsRescan = true
    private var activityTimer: Timer?

    let terminal: ActivityTerminalView
    private let titleBar: TitleBarView
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let trafficLights: TrafficLightsView
    private let resizeGrip: ResizeGripView
    private let ports: [ConnectHandleView]
    private var dragTargetsVisible = false

    /// Green ring shown while this tile is selected (focused). Drawn at the
    /// tile's outer edge so it sits *outside* the activity/status border.
    private let selectionLayer = CAShapeLayer()

    /// Colored activity/status border (working = blue, asking = amber), drawn
    /// as an inset ring so the selection ring can sit outside it. Hidden when
    /// idle, where the tile's plain hairline edge shows instead.
    private let activityLayer = CAShapeLayer()

    init(frame frameRect: NSRect, terminalID: String = UUID().uuidString) {
        self.terminalID = terminalID
        terminal = ActivityTerminalView(frame: .zero)
        titleBar = TitleBarView(frame: .zero)
        titleLabel = NSTextField(labelWithString: "zsh")
        statusLabel = NSTextField(labelWithString: "")
        trafficLights = TrafficLightsView(frame: .zero)
        resizeGrip = ResizeGripView(frame: .zero)
        ports = (0..<4).map { _ in ConnectHandleView(frame: .zero) }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        // Match the terminal background so the cell-snapping gap blends in.
        layer?.backgroundColor = NSColor.black.cgColor

        // The border rings sit above the title-bar and terminal subview layers
        // (added below) via zPosition, so an opaque subview can't paint over the
        // ring along the top edge — selection above activity.
        activityLayer.fillColor = NSColor.clear.cgColor
        activityLayer.lineWidth = 4
        activityLayer.isHidden = true
        activityLayer.zPosition = 1
        layer?.addSublayer(activityLayer)

        selectionLayer.fillColor = NSColor.clear.cgColor
        selectionLayer.strokeColor = Theme.green.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        selectionLayer.zPosition = 2
        layer?.addSublayer(selectionLayer)

        titleBar.tile = self
        titleLabel.font = Theme.mono(12, .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center

        statusLabel.font = Theme.mono(11, .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byClipping

        trafficLights.onClose = { [weak self] in self?.closeTile() }

        terminal.processDelegate = self
        // Output and bell drive the status border. These fire off the main
        // thread, so the timer (on the main run loop) reads the results.
        terminal.onData = { [weak self] in
            guard let self else { return }
            self.lastOutputTime = ProcessInfo.processInfo.systemUptime
            self.needsRescan = true
        }
        terminal.onBell = { [weak self] in self?.needsRescan = true }

        resizeGrip.tile = self

        addSubview(titleBar)
        titleBar.addSubview(trafficLights)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(statusLabel)
        addSubview(terminal)
        addSubview(resizeGrip)
        for port in ports {
            port.tile = self
            port.toolTip = "Drag to another terminal to connect them"
            port.isHidden = true
            addSubview(port)
            // Keep ports above the border rings (zPosition 1–2) so the activity
            // ring doesn't cut across them when the tile is focused.
            port.wantsLayer = true
            port.layer?.zPosition = 3
        }

        updateBorder()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.evaluateActivity()
        }
        RunLoop.main.add(timer, forMode: .common)  // keep ticking during scroll/drag
        activityTimer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { activityTimer?.invalidate() }

    /// The inset activity ring reflects the inferred activity — working (blue)
    /// or asking a question (amber) — so the status is never hidden; idle shows
    /// only the tile's plain hairline edge. Selection (focus) is shown by a
    /// separate green ring at the outer edge, *outside* the activity ring, and
    /// the title-bar status pill is kept in sync.
    private func updateBorder() {
        updateStatus()
        selectionLayer.isHidden = !isFocused
        // Drop the neutral hairline while focused so the green ring is the
        // outermost edge.
        layer?.borderWidth = isFocused ? 0 : 1
        layer?.borderColor = Theme.border.cgColor
        switch activity {
        case .working:
            activityLayer.isHidden = false
            activityLayer.strokeColor = Theme.blue.withAlphaComponent(0.7).cgColor
        case .asking:
            activityLayer.isHidden = false
            activityLayer.strokeColor = Theme.amber.cgColor
        case .idle:
            activityLayer.isHidden = true
        }
    }

    /// Renders the right-side status as a colored dot + label: working (blue),
    /// "needs you" (amber) when a question is pending, else idle (dim).
    private func updateStatus() {
        let (text, color): (String, NSColor)
        switch activity {
        case .working: (text, color) = ("working", Theme.blue)
        case .asking: (text, color) = ("needs you", Theme.amber)
        case .idle: (text, color) = ("idle", Theme.textDim)
        }
        let string = NSMutableAttributedString(
            string: "● ",
            attributes: [.font: Theme.mono(9), .foregroundColor: color]
        )
        string.append(NSAttributedString(
            string: text,
            attributes: [.font: Theme.mono(11, .medium), .foregroundColor: Theme.textDim]
        ))
        statusLabel.attributedStringValue = string
    }

    /// Re-derives the activity state. Output seen very recently means working;
    /// once output settles, the visible buffer is scanned once to tell a
    /// pending question from a finished, idle prompt.
    /// Authoritative state from a Claude Code hook (see ActivityWatcher). Takes
    /// over from the heuristic the first time it's called.
    func setHookActivity(_ activity: Activity) {
        usesHookActivity = true
        self.activity = activity
    }

    private func evaluateActivity() {
        // Hooks win once they've spoken; don't let the heuristic fight them.
        guard !usesHookActivity else { return }
        let idleFor = ProcessInfo.processInfo.systemUptime - lastOutputTime
        if idleFor < 0.7 {
            activity = .working
            return
        }
        if needsRescan {
            needsRescan = false
            settledActivity = Self.classify(promptRegion())
        }
        activity = settledActivity
    }

    /// The live-prompt region: the bottom-most non-empty rows of the visible
    /// screen (newest last), where an interactive CLI anchors its input box,
    /// menu and footer. Only this slice is classified, so marker words that
    /// merely appear higher up in the scrollback transcript — e.g. while we're
    /// discussing them — don't get mistaken for an actual prompt.
    private func promptRegion(maxLines: Int = 8) -> [String] {
        let term = terminal.getTerminal()
        var lines: [String] = []
        for row in 0..<term.rows {
            if let line = term.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return Array(lines.suffix(maxLines))
    }

    /// Classifies a settled terminal from its bottom prompt region. Heuristic
    /// and shared across Claude, Codex and plain shells, so tweak here if a
    /// CLI's prompt isn't recognized. We match only the *interactive* prompt
    /// markers (a numbered/highlighted choice or a y/n prompt), which disappear
    /// once answered — not lingering printed text like "Do you want…".
    private static func classify(_ region: [String]) -> Activity {
        let lower = region.map { $0.lowercased() }
        let blob = lower.joined(separator: "\n")
        // Both Claude and Codex show an interrupt hint while thinking, even
        // when they briefly pause emitting output — still working.
        if blob.contains("esc to interrupt") || blob.contains("ctrl+t to") {
            return .working
        }
        // A picker's navigation/selection footer is the bottom-most line(s) of
        // the prompt, so only check the last couple — that keeps prose that
        // merely mentions these words (like this very conversation) from
        // flipping the tile to "needs you".
        let footer = lower.suffix(2).joined(separator: " ")
        if footer.contains("to navigate") || footer.contains("enter to select") {
            return .asking
        }
        // A y/n confirmation prompt, within the bottom region.
        if ["(y/n)", "[y/n]", "(yes/no)"].contains(where: { blob.contains($0) }) {
            return .asking
        }
        // A highlighted choice: a pointer glyph at the start of a line followed
        // by a numbered or yes/no option — any selected row, not just "1.".
        let pointers: Set<Character> = ["❯", "›", "‣", "→", "▶"]
        for rawLine in region {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            guard let first = line.first, pointers.contains(first) else { continue }
            let rest = line.dropFirst().drop { $0 == " " || $0 == "\t" }
            if rest.first?.isNumber == true { return .asking }
            let restLower = rest.lowercased()
            if restLower.hasPrefix("yes") || restLower.hasPrefix("no") { return .asking }
        }
        return .idle
    }

    override func layout() {
        super.layout()
        // The green selection ring hugs the outer edge; the colored activity
        // ring sits inset inside it. Both stay within the clipped bounds, so
        // selection reads as the outer highlight. Don't animate the paths as
        // the tile is live-resized.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = bounds
        let selectionRect = bounds.insetBy(dx: 2, dy: 2)
        selectionLayer.path = CGPath(
            roundedRect: selectionRect, cornerWidth: 8, cornerHeight: 8, transform: nil
        )
        activityLayer.frame = bounds
        let activityRect = bounds.insetBy(dx: 7, dy: 7)
        activityLayer.path = CGPath(
            roundedRect: activityRect, cornerWidth: 5, cornerHeight: 5, transform: nil
        )
        CATransaction.commit()
        let barHeight = Self.titleBarHeight
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let lightsWidth: CGFloat = 50
        trafficLights.frame = NSRect(x: 12, y: 0, width: lightsWidth, height: barHeight)
        // Reserve symmetric side gutters so the centered title isn't pushed off
        // by the wider of the lights / status; status sits in the right gutter.
        let gutter: CGFloat = 124
        statusLabel.frame = NSRect(
            x: bounds.width - gutter, y: (barHeight - 14) / 2, width: gutter - 14, height: 14
        )
        titleLabel.frame = NSRect(
            x: gutter, y: (barHeight - 16) / 2, width: max(0, bounds.width - gutter * 2), height: 16
        )
        // Snap the terminal height to a whole number of character cells:
        // SwiftTerm puts any partial-row remainder at the top, which the
        // title bar would otherwise clip into.
        let inset: CGFloat = 4
        var terminalHeight = bounds.height - barHeight - inset * 2
        let rows = terminal.getTerminal().rows
        if rows > 0 {
            let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(rows)
            if cellHeight > 0 {
                terminalHeight = max(cellHeight, floor(terminalHeight / cellHeight) * cellHeight)
            }
        }
        terminal.frame = NSRect(
            x: inset,
            y: barHeight + inset,
            width: bounds.width - inset * 2,
            height: terminalHeight
        )
        resizeGrip.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18)
        let portSize: CGFloat = 14
        let portInset = Self.portCenterInset
        let portCenters = [
            NSPoint(x: bounds.midX, y: portInset),
            NSPoint(x: bounds.midX, y: bounds.height - portInset),
            NSPoint(x: portInset, y: bounds.midY),
            NSPoint(x: bounds.width - portInset, y: bounds.midY),
        ]
        for (port, center) in zip(ports, portCenters) {
            port.frame = NSRect(
                x: center.x - portSize / 2, y: center.y - portSize / 2,
                width: portSize, height: portSize
            )
        }
    }

    // MARK: - Connection ports

    /// Ports show while the terminal is focused (drag sources) or while any
    /// connection line is being dragged (drop targets).
    private func updatePortVisibility() {
        let visible = isFocused || dragTargetsVisible
        for port in ports {
            port.isHidden = !visible
            if !visible {
                port.isHighlighted = false
            }
        }
    }

    /// Shows or hides the edge ports while a connection is dragged.
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

    // MARK: - Output capture

    var tileTitle: String {
        titleLabel.stringValue
    }

    /// The most recent lines of this terminal's buffer, scrollback included.
    func recentOutput(maxLines: Int = 200) -> String {
        let data = terminal.getTerminal().getBufferAsData()
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the user's login shell in `directory`.
    func startShell(in directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        startDirectory = directory
        start(executable: shell, execName: execName, in: directory)
    }

    /// Runs a program directly as the tile's process (no shell underneath);
    /// the tile closes when it exits.
    func startProgram(_ executable: String, args: [String] = [], in directory: String) {
        let name = (executable as NSString).lastPathComponent
        setTitle(name)
        launchedProgramName = name
        startDirectory = directory
        start(executable: executable, args: args, execName: nil, in: directory)
    }

    private func start(executable: String, args: [String] = [], execName: String?, in directory: String) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PTYPARTY_TERMINAL_ID"] = terminalID
        // Don't leak session state when pty.party itself was launched from a
        // Claude Code session — a nested claude should start fresh.
        for key in env.keys where key.hasPrefix("CLAUDE") {
            env.removeValue(forKey: key)
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }
        // Make sure the terminal has its real dimensions before the process
        // queries them, so full-screen TUIs don't boot into a 0×0 terminal.
        layoutSubtreeIfNeeded()
        terminal.startProcess(
            executable: executable,
            args: args,
            environment: envArray,
            execName: execName,
            currentDirectory: directory
        )
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    @objc private func closeTile() {
        onClosed?()
        removeFromSuperview()
    }

    /// Kills the child process. Used when clearing the canvas to switch
    /// sessions, where the delegate callbacks are intentionally bypassed.
    func terminate() {
        activityTimer?.invalidate()
        terminal.terminate()
    }
}

/// A local-process terminal that reports raw output and bell events, so the
/// tile can infer whether the program inside is working, asking, or idle.
/// `LocalProcessTerminalView` owns its `terminalDelegate`, so we subclass and
/// override the open hooks rather than replacing the delegate.
final class ActivityTerminalView: LocalProcessTerminalView {
    var onData: (() -> Void)?
    var onBell: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onData?()
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }
}

// MARK: - Shell process events

extension TerminalTileView: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        setTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory, let url = URL(string: directory) {
            currentDirectory = url.path
            setTitle((url.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        activityTimer?.invalidate()
        onClosed?()
        removeFromSuperview()
    }
}

/// The drag handle along the top of a tile.
final class TitleBarView: NSView {
    weak var tile: CanvasTileView?
    private var dragOffset = NSPoint.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.tile.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        guard let tile, let canvas = tile.superview else { return }
        tile.bringToFront()
        let point = canvas.convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: point.x - tile.frame.origin.x, y: point.y - tile.frame.origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile, let canvas = tile.superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        tile.setFrameOrigin(NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
    }
}

/// The three macOS-style dots at the left of a terminal tile's title bar. They
/// read as dim by default; hovering brightens them and reveals the leftmost as
/// a red close button (the others are inert).
final class TrafficLightsView: NSView {
    var onClose: (() -> Void)?

    private static let dot: CGFloat = 11
    private static let gap: CGFloat = 8
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private func dotRect(_ index: Int) -> NSRect {
        let x = CGFloat(index) * (Self.dot + Self.gap)
        return NSRect(x: x, y: (bounds.height - Self.dot) / 2, width: Self.dot, height: Self.dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit: [NSColor] = [
            NSColor(srgbRed: 0.96, green: 0.42, blue: 0.42, alpha: 1),
            Theme.amber,
            Theme.green,
        ]
        for index in 0..<3 {
            let color = isHovered ? lit[index] : Theme.textFaint.withAlphaComponent(0.7)
            color.setFill()
            NSBezierPath(ovalIn: dotRect(index)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(dotRect(0), cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Only the red (leftmost) dot does anything: it closes the tile.
        let point = convert(event.locationInWindow, from: nil)
        if dotRect(0).insetBy(dx: -2, dy: -2).contains(point) {
            onClose?()
        }
    }
}
