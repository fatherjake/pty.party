import AppKit
import SwiftTerm

/// A compact widget that runs a configured shell command on demand or on a
/// loop: a header with a bolt glyph, name and status; a `$ command` preview
/// box; a green run/stop button with a "last run" line; and an optional
/// expandable output log underneath.
final class CommandRunnerTileView: CanvasTileView {
    // Stacked metrics; compactHeight is derived from them so layout stays in sync.
    static let titleBarHeight: CGFloat = 34
    private static let pad: CGFloat = 14
    private static let boxTopGap: CGFloat = 8
    private static let boxHeight: CGFloat = 34
    private static let midGap: CGFloat = 12
    private static let buttonHeight: CGFloat = 30
    static let compactHeight: CGFloat =
        titleBarHeight + boxTopGap + boxHeight + midGap + buttonHeight + pad
    static let defaultSize = NSSize(width: 300, height: CommandRunnerTileView.compactHeight)

    override var minSize: NSSize { NSSize(width: 240, height: Self.compactHeight) }

    let runnerID: String
    var name = ""
    var command = ""
    var directory = NSHomeDirectory()
    var loopInterval: TimeInterval = 0  // 0 = run once per play
    private(set) var outputVisible = false

    var onClosed: (() -> Void)?
    var onRequestEdit: ((CommandRunnerTileView) -> Void)?

    private let terminal = LocalProcessTerminalView(frame: .zero)
    private let titleBar = TitleBarView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(frame: .zero)
    private let commandBox = CommandBoxView(frame: .zero)
    private let runButton = NSButton(frame: .zero)
    private let lastRunLabel = NSTextField(labelWithString: "")
    private let resizeGrip = ResizeGripView(frame: .zero)

    private var loopTimer: Timer?
    private(set) var isActive = false
    private var processRunning = false
    private var expandedHeight: CGFloat = 300
    private var lastRunDate: Date?
    private var lastExitCode: Int32?

    init(frame frameRect: NSRect, runnerID: String = UUID().uuidString) {
        self.runnerID = runnerID
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        layer?.backgroundColor = Theme.tile.cgColor

        titleBar.tile = self

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = Theme.green
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = Theme.mono(13, .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byClipping

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeTile)
        closeButton.isHidden = true  // swaps in for the status label on hover

        commandBox.onClick = { [weak self] in self?.editTapped() }

        runButton.bezelStyle = .regularSquare
        runButton.isBordered = false
        runButton.wantsLayer = true
        runButton.layer?.cornerRadius = 7
        runButton.target = self
        runButton.action = #selector(toggleRun)

        lastRunLabel.font = Theme.mono(11)
        lastRunLabel.textColor = Theme.textDim
        lastRunLabel.lineBreakMode = .byTruncatingTail

        terminal.processDelegate = self
        terminal.isHidden = true
        resizeGrip.tile = self

        addSubview(titleBar)
        titleBar.addSubview(iconView)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(statusLabel)
        titleBar.addSubview(closeButton)
        addSubview(commandBox)
        addSubview(runButton)
        addSubview(lastRunLabel)
        addSubview(terminal)
        addSubview(resizeGrip)
        refreshUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        loopTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        let barHeight = Self.titleBarHeight
        let pad = Self.pad
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        iconView.frame = NSRect(x: pad, y: (barHeight - 14) / 2, width: 14, height: 14)
        let titleX = iconView.frame.maxX + 8
        titleLabel.frame = NSRect(
            x: titleX, y: (barHeight - 18) / 2,
            width: max(0, bounds.width - titleX - 110), height: 18
        )
        statusLabel.frame = NSRect(x: bounds.width - 104, y: (barHeight - 14) / 2, width: 90, height: 14)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (barHeight - 16) / 2, width: 16, height: 16)

        commandBox.frame = NSRect(
            x: pad, y: barHeight + Self.boxTopGap,
            width: bounds.width - pad * 2, height: Self.boxHeight
        )

        let buttonY = commandBox.frame.maxY + Self.midGap
        let buttonWidth: CGFloat = 84
        runButton.frame = NSRect(x: pad, y: buttonY, width: buttonWidth, height: Self.buttonHeight)
        let labelX = runButton.frame.maxX + 12
        lastRunLabel.frame = NSRect(
            x: labelX, y: buttonY, width: max(0, bounds.width - pad - labelX), height: Self.buttonHeight
        )

        if outputVisible {
            let top = buttonY + Self.buttonHeight + 10
            var terminalHeight = bounds.height - top - pad
            let rows = terminal.getTerminal().rows
            if rows > 0 {
                let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(rows)
                if cellHeight > 0 {
                    terminalHeight = max(cellHeight, floor(terminalHeight / cellHeight) * cellHeight)
                }
            }
            terminal.frame = NSRect(
                x: pad, y: top,
                width: bounds.width - pad * 2, height: terminalHeight
            )
        }
        resizeGrip.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18)
    }

    override func clampedSize(_ proposed: NSSize) -> NSSize {
        let width = max(minSize.width, proposed.width)
        if outputVisible {
            return NSSize(width: width, height: max(Self.compactHeight + 120, proposed.height))
        }
        // Compact mode has a fixed height; only the width resizes.
        return NSSize(width: width, height: Self.compactHeight)
    }

    // MARK: - Hover (status ⇄ close)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        statusLabel.isHidden = true
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        statusLabel.isHidden = false
    }

    // MARK: - Output panel

    func setOutputVisible(_ visible: Bool, resizeTile: Bool) {
        outputVisible = visible
        terminal.isHidden = !visible
        if resizeTile {
            if visible {
                setFrameSize(NSSize(width: frame.width, height: max(expandedHeight, Self.compactHeight + 120)))
            } else {
                expandedHeight = frame.height
                setFrameSize(NSSize(width: frame.width, height: Self.compactHeight))
            }
        }
        needsLayout = true
    }

    // MARK: - Running

    @objc private func toggleRun() {
        if isActive {
            pauseRun()
        } else {
            play()
        }
    }

    @objc func play() {
        guard !command.isEmpty else {
            onRequestEdit?(self)
            return
        }
        isActive = true
        runOnce()
        loopTimer?.invalidate()
        if loopInterval > 0 {
            loopTimer = Timer.scheduledTimer(withTimeInterval: loopInterval, repeats: true) { [weak self] _ in
                self?.runOnce()
            }
        }
        refreshUI()
    }

    @objc func pauseRun() {
        isActive = false
        loopTimer?.invalidate()
        loopTimer = nil
        if processRunning {
            terminal.terminate()
        }
        refreshUI()
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit…", action: #selector(editTapped), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let output = NSMenuItem(
            title: outputVisible ? "Hide Output" : "Show Output",
            action: #selector(toggleOutput), keyEquivalent: ""
        )
        output.target = self
        menu.addItem(output)
        let clear = NSMenuItem(title: "Clear Output", action: #selector(clearOutput), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeTile), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func editTapped() {
        onRequestEdit?(self)
    }

    @objc private func toggleOutput() {
        setOutputVisible(!outputVisible, resizeTile: true)
    }

    @objc private func clearOutput() {
        // Clear screen, scrollback and home the cursor.
        terminal.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }

    private func runOnce() {
        guard !processRunning else { return }  // previous run still going; skip this tick
        processRunning = true
        lastRunDate = Date()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for key in env.keys where key.hasPrefix("CLAUDE") {
            env.removeValue(forKey: key)
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: Date())
        terminal.feed(text: "\r\n\u{1b}[1;36m▶ \(command)\u{1b}[0m  \u{1b}[2m\(stamp)\u{1b}[0m\r\n")
        terminal.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: envArray,
            execName: nil,
            currentDirectory: (directory as NSString).expandingTildeInPath
        )
        refreshUI()
    }

    func refreshUI() {
        if !name.isEmpty {
            titleLabel.stringValue = name
        } else if !command.isEmpty {
            titleLabel.stringValue = command
        } else {
            titleLabel.stringValue = "command-runner"
        }
        titleLabel.toolTip = command.isEmpty
            ? "Press ⋯ (right-click) to configure"
            : "\(command)  —  in \((directory as NSString).abbreviatingWithTildeInPath)"

        commandBox.command = command

        // Status: a colored dot + word. Running/waiting are green/amber while
        // active; otherwise idle.
        let (statusText, dotColor): (String, NSColor)
        if isActive {
            statusText = processRunning ? "running" : "waiting"
            dotColor = processRunning ? Theme.green : Theme.amber
        } else {
            statusText = "idle"
            dotColor = Theme.textDim
        }
        statusLabel.attributedStringValue = Self.statusString(statusText, dot: dotColor)

        // Run / stop button.
        let title = isActive ? "■ stop" : "▶ run"
        let titleColor = isActive ? Theme.textDim : Theme.canvas
        runButton.layer?.backgroundColor = (isActive ? Theme.inset : Theme.green).cgColor
        runButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.mono(12, .semibold),
                .foregroundColor: titleColor,
            ]
        )

        // Last-run line.
        lastRunLabel.attributedStringValue = lastRunString()
    }

    private static func statusString(_ text: String, dot: NSColor) -> NSAttributedString {
        let string = NSMutableAttributedString(
            string: "● ",
            attributes: [.font: Theme.mono(9), .foregroundColor: dot]
        )
        string.append(NSAttributedString(
            string: text,
            attributes: [.font: Theme.mono(11, .medium), .foregroundColor: Theme.textDim]
        ))
        return string
    }

    private func lastRunString() -> NSAttributedString {
        guard let lastRunDate else {
            return NSAttributedString(
                string: loopInterval > 0 ? "every \(Int(loopInterval))s" : "never run",
                attributes: [.font: Theme.mono(11), .foregroundColor: Theme.textFaint]
            )
        }
        var prefix = "last run \(Self.relativeTime(lastRunDate))"
        if loopInterval > 0 { prefix = "every \(Int(loopInterval))s · " + prefix }
        let string = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: Theme.mono(11), .foregroundColor: Theme.textDim]
        )
        if let code = lastExitCode {
            string.append(NSAttributedString(
                string: " · ",
                attributes: [.font: Theme.mono(11), .foregroundColor: Theme.textDim]
            ))
            string.append(NSAttributedString(
                string: "exit \(code)",
                attributes: [.font: Theme.mono(11, .medium),
                             .foregroundColor: code == 0 ? Theme.greenDim : Theme.red]
            ))
        }
        return string
    }

    /// A short "2m ago" style age for the last run.
    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    @objc private func closeTile() {
        pauseRun()
        onClosed?()
        removeFromSuperview()
    }
}

/// The recessed `$ command` preview box. Click anywhere on it to edit the
/// runner's command.
final class CommandBoxView: NSView {
    var onClick: (() -> Void)?

    var command: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = Theme.inset.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.divider.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 12
        let prompt = "$ " as NSString
        let promptAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(12, .semibold), .foregroundColor: Theme.green,
        ]
        let promptSize = prompt.size(withAttributes: promptAttrs)
        let midY = bounds.midY - promptSize.height / 2
        prompt.draw(at: NSPoint(x: pad, y: midY), withAttributes: promptAttrs)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = (command.isEmpty ? "click to configure…" : command) as NSString
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(12),
            .foregroundColor: command.isEmpty ? Theme.textFaint : Theme.textPrimary,
            .paragraphStyle: paragraph,
        ]
        let textX = pad + promptSize.width
        text.draw(
            in: NSRect(x: textX, y: midY, width: bounds.width - textX - pad, height: promptSize.height),
            withAttributes: textAttrs
        )
    }
}

// MARK: - Process events

extension CommandRunnerTileView: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processRunning = false
        let code = exitCode ?? -1
        lastExitCode = code
        let color = code == 0 ? "32" : "31"
        terminal.feed(text: "\u{1b}[\(color)m■ exited \(code)\u{1b}[0m\r\n")
        if loopInterval <= 0 {
            isActive = false
            loopTimer?.invalidate()
            loopTimer = nil
        }
        refreshUI()
    }
}
