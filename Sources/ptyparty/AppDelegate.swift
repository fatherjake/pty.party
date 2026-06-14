import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let canvasSize = NSSize(width: 8000, height: 8000)

    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var sessionBadge: SessionBadgeView!
    private var canvas: CanvasView!
    private var cascadeCount = 0
    private weak var selectedImageTile: ImageTileView?
    private weak var selectedNoteTile: NoteTileView?
    private var responderObservation: NSKeyValueObservation?
    private var inbox: CanvasInbox?
    private var broker: RequestBroker?
    private var folderButton: NSButton!
    private var sessionSaveTimer: Timer?

    /// The session currently loaded on the canvas. Its folder is where the
    /// canvas snapshot and its images are persisted.
    private var currentSession: SessionStore.Info!
    /// Suppresses session saving while tearing the canvas down to swap sessions.
    private var isSwitchingSession = false

    /// The working folder stored in the loaded session, if any. nil falls back
    /// to the home directory.
    private var sessionWorkingDirectory: String?

    /// The folder new terminals open in. Belongs to the loaded session and is
    /// persisted in its session.json.
    private var workingDirectory: String {
        get {
            if let stored = sessionWorkingDirectory,
               FileManager.default.fileExists(atPath: stored) {
                return stored
            }
            return NSHomeDirectory()
        }
        set {
            sessionWorkingDirectory = newValue
            updateFolderButton()
            scheduleSessionSave()
        }
    }
    private var optionHeld = false
    private var isPanning = false
    private var lastPanLocation = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        publishSelection(nil)  // clear any stale selection from a previous run

        // Decide which session to load before building the canvas.
        currentSession = chooseStartupSession()
        SessionStore.lastOpenedID = currentSession.id

        canvas = CanvasView(frame: NSRect(origin: .zero, size: Self.canvasSize))
        canvas.onAddClaude = { [weak self] point in
            self?.addClaudeTerminal(at: point)
        }
        canvas.onAddCodex = { [weak self] point in
            self?.addCodexTerminal(at: point)
        }
        canvas.onAddShell = { [weak self] point in
            self?.addTerminal(at: point)
        }
        canvas.onAddCommandRunner = { [weak self] point in
            guard let self else { return }
            // New runners go straight into the editor.
            self.editCommandRunner(self.addCommandRunner(at: point))
        }
        canvas.onAddLog = { [weak self] point in
            self?.addLogTile(at: point)
        }
        canvas.onAddImage = { [weak self] image, point in
            self?.addImage(image, at: point)
        }
        canvas.onConnectionsChanged = { [weak self] in
            self?.publishConnections()
            self?.scheduleSessionSave()
        }
        canvas.onContentChanged = { [weak self] in
            self?.scheduleSessionSave()
        }
        publishConnections()  // clear stale connections from a previous run

        scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 3.0
        scrollView.backgroundColor = CanvasView.backgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // A container holds the scrolling canvas plus a fixed top-left badge
        // that doesn't scroll with the canvas.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840))
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        sessionBadge = SessionBadgeView()
        sessionBadge.onClick = { [weak self] badge in self?.showSessionMenu(from: badge) }
        sessionBadge.autoresizingMask = [.maxXMargin, .minYMargin]  // pin top-left
        container.addSubview(sessionBadge)
        window.contentView = container
        positionSessionBadge()

        // The badge is the session indicator now, so drop the redundant
        // centered window title text (the window keeps its name for the OS).
        window.titleVisibility = .hidden
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("PtyPartyMainWindow")
        window.center()
        addFolderSelector()
        updateWindowTitle()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start looking at the middle of the canvas.
        let visible = scrollView.contentView.bounds.size
        scrollView.contentView.scroll(to: NSPoint(
            x: (Self.canvasSize.width - visible.width) / 2,
            y: (Self.canvasSize.height - visible.height) / 2
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Intercepts clicks to raise tiles, and option-drag to pan the canvas.
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .flagsChanged, .mouseMoved, .cursorUpdate, .keyDown,
        ]
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleCanvasEvent(event) ?? event
        }

        // Highlight whichever terminal tile owns keyboard focus.
        responderObservation = window.observe(\.firstResponder, options: [.initial]) { [weak self] _, _ in
            self?.updateTerminalFocusBorders()
        }

        // Accept images dropped into the inbox by the MCP server.
        inbox = CanvasInbox(
            onImage: { [weak self] image, terminalID in
                self?.addImageFromInbox(image, terminalID: terminalID)
            },
            onNote: { [weak self] title, body, terminalID in
                self?.addNoteFromInbox(title: title, body: body, terminalID: terminalID)
            }
        )
        inbox?.start()

        // Answer live-state queries from the MCP server.
        broker = RequestBroker { [weak self] request in
            self?.handleBrokerRequest(request) ?? [:]
        }
        broker?.start()

        if !restoreSession() {
            addClaudeTerminal(at: visibleCenter())
        }

        // Greet first-time users with the onboarding card (reopenable from the
        // File menu thereafter).
        if !UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey) {
            UserDefaults.standard.set(true, forKey: Self.hasSeenWelcomeKey)
            addWelcomeTile()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionSaveTimer?.invalidate()
        saveSession()
    }

    private func terminalTile(withID id: String) -> TerminalTileView? {
        canvas.subviews.first { ($0 as? TerminalTileView)?.terminalID == id } as? TerminalTileView
    }

    private func handleBrokerRequest(_ request: [String: Any]) -> [String: Any] {
        switch request["type"] as? String {
        case "connected_terminal_output":
            guard let terminalID = request["terminalId"] as? String,
                  let tile = terminalTile(withID: terminalID)
            else { return ["terminals": []] }
            let entries: [[String: Any]] = canvas.connectedTerminals(to: tile).map {
                ["title": $0.tileTitle, "output": $0.recentOutput()]
            }
            return ["terminals": entries]

        case "log_append":
            guard let terminalID = request["terminalId"] as? String,
                  let tile = terminalTile(withID: terminalID)
            else { return ["ok": false, "error": "unknown terminal"] }
            let logs = canvas.connectedNotes(to: tile)
            guard !logs.isEmpty else { return ["ok": false, "error": "no log connected"] }
            let items = (request["items"] as? [String]) ?? []
            let section = request["section"] as? String
            for log in logs { log.appendItems(items, section: section) }
            scheduleSessionSave()
            return ["ok": true, "logs": logs.count, "items": items.count]

        case "log_check":
            guard let terminalID = request["terminalId"] as? String,
                  let tile = terminalTile(withID: terminalID)
            else { return ["ok": false, "error": "unknown terminal"] }
            let logs = canvas.connectedNotes(to: tile)
            guard !logs.isEmpty else { return ["ok": false, "error": "no log connected"] }
            let item = (request["item"] as? String) ?? ""
            var checked = 0
            for log in logs where log.setChecked(matching: item) { checked += 1 }
            if checked > 0 { scheduleSessionSave() }
            return ["ok": true, "checked": checked]

        default:
            return [:]
        }
    }

    // MARK: - Working folder selector

    /// A folder button in the title bar showing where new terminals open.
    private func addFolderSelector() {
        folderButton = NSButton(
            title: "",
            target: self,
            action: #selector(chooseWorkingDirectory(_:))
        )
        folderButton.bezelStyle = .texturedRounded
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Working folder")
        folderButton.imagePosition = .imageLeading
        updateFolderButton()

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = NSView()
        accessory.view.addSubview(folderButton)
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func updateFolderButton() {
        let path = workingDirectory
        let display = path == NSHomeDirectory()
            ? "~"
            : URL(fileURLWithPath: path).lastPathComponent
        folderButton.title = display
        folderButton.toolTip = "New terminals open in \((path as NSString).abbreviatingWithTildeInPath)"
        folderButton.sizeToFit()
        var size = folderButton.frame.size
        folderButton.frame.origin = .zero
        size.width += 10  // trailing margin before the window edge
        folderButton.superview?.setFrameSize(size)
    }

    @objc func chooseWorkingDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        panel.prompt = "Use Folder"
        panel.message = "New terminals will open in this folder."
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.workingDirectory = url.path
            }
        }
    }

    private func updateTerminalFocusBorders() {
        let responder = window.firstResponder as? NSView
        for case let tile as TerminalTileView in canvas.subviews {
            tile.isFocused = responder?.isDescendant(of: tile) ?? false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Event handling (tile raising + option-drag panning)

    /// Returns nil to swallow the event, or the event to let it through.
    private func handleCanvasEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }

        switch event.type {
        case .keyDown:
            // Backspace (51) or forward delete (117) removes the selected
            // image — unless a terminal has keyboard focus, where those
            // keys belong to the shell.
            guard event.keyCode == 51 || event.keyCode == 117,
                  selectedImageTile != nil || selectedNoteTile != nil
                    || canvas.selectedConnector != nil else { return event }
            let responderView = window.firstResponder as? NSView
            let terminalFocused = responderView.map { view in
                sequence(first: view, next: { $0.superview }).contains { $0 is TerminalTileView }
            } ?? false
            if terminalFocused { return event }
            canvas.deleteSelectedConnector()
            selectedImageTile?.close()
            selectedNoteTile?.close()
            return nil

        case .flagsChanged:
            setOptionHeld(event.modifierFlags.contains(.option))
            return event

        case .mouseMoved:
            if optionHeld { (isPanning ? NSCursor.closedHand : NSCursor.openHand).set() }
            return event

        case .cursorUpdate:
            // Keep views (e.g. the terminal's I-beam) from fighting the hand cursor.
            return optionHeld ? nil : event

        case .leftMouseDown:
            if optionHeld {
                isPanning = true
                lastPanLocation = event.locationInWindow
                NSCursor.closedHand.set()
                return nil
            }
            // Raise the clicked tile to the top of the stack.
            let point = canvas.convert(event.locationInWindow, from: nil)
            if let tile = canvas.subviews.last(where: {
                $0 is CanvasTileView && $0.frame.contains(point)
            }) as? CanvasTileView {
                tile.bringToFront()
                canvas.selectConnector(nil)
                if let imageTile = tile as? ImageTileView {
                    selectImageTile(imageTile)
                    window.makeFirstResponder(nil)  // take keyboard focus off any terminal
                } else if let noteTile = tile as? NoteTileView {
                    selectNoteTile(noteTile)
                    window.makeFirstResponder(nil)
                }
                // A terminal click keeps the current selection, so you can
                // select a tile and then type to Claude about it.
            } else if let connector = canvas.connector(at: point) {
                // Clicking a connection line (between tiles, over bare canvas)
                // selects it so backspace can remove it.
                canvas.selectConnector(connector)
                selectImageTile(nil)
                selectNoteTile(nil)
                window.makeFirstResponder(nil)
                return nil  // don't start panning off a connector click
            } else {
                selectImageTile(nil)
                selectNoteTile(nil)
                canvas.selectConnector(nil)
                window.makeFirstResponder(nil)  // clicking empty canvas defocuses terminals
                // Clicking bare canvas (inside the scroll area, not a tile)
                // grabs it for hand-panning, FigJam-style.
                let clipPoint = scrollView.contentView.convert(event.locationInWindow, from: nil)
                if scrollView.contentView.bounds.contains(clipPoint) {
                    isPanning = true
                    lastPanLocation = event.locationInWindow
                    NSCursor.closedHand.set()
                }
            }
            return event

        case .leftMouseDragged:
            guard isPanning else { return event }
            let location = event.locationInWindow
            let magnification = scrollView.magnification
            let dx = (location.x - lastPanLocation.x) / magnification
            let dy = (location.y - lastPanLocation.y) / magnification
            lastPanLocation = location
            // The canvas is flipped, so screen-up means decreasing document y
            // under the cursor — the viewport origin moves opposite the hand.
            var origin = scrollView.contentView.bounds.origin
            origin.x -= dx
            origin.y += dy
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return nil

        case .leftMouseUp:
            guard isPanning else { return event }
            isPanning = false
            if optionHeld {
                NSCursor.openHand.set()
                return nil  // the matching mouseDown was swallowed too
            }
            NSCursor.arrow.set()
            return event

        default:
            return event
        }
    }

    private func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        if held {
            window.disableCursorRects()
            NSCursor.openHand.set()
        } else {
            isPanning = false
            window.enableCursorRects()
            window.resetCursorRects()
            NSCursor.arrow.set()
        }
    }

    // MARK: - Terminals

    private func visibleCenter() -> NSPoint {
        let rect = canvas.visibleRect
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// The visible center, nudged a little further each call so that
    /// successively added tiles don't stack exactly on top of each other.
    private func cascadedVisibleCenter() -> NSPoint {
        var point = visibleCenter()
        let offset = CGFloat(cascadeCount % 8) * 32
        point.x += offset
        point.y += offset
        cascadeCount += 1
        return point
    }


    /// Resolves a CLI's absolute path once via the user's interactive shell
    /// (which has the full PATH), with fallbacks to the usual install
    /// locations.
    private static func resolveCLIPath(_ name: String, fallbacks: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }
        for candidate in fallbacks {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Absolute path of the claude CLI.
    private lazy var claudePath: String? = Self.resolveCLIPath(
        "claude",
        fallbacks: ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    )

    /// Absolute path of the codex CLI.
    private lazy var codexPath: String? = Self.resolveCLIPath(
        "codex",
        fallbacks: ["~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    )

    @objc func newClaudeTerminal(_ sender: Any?) {
        addClaudeTerminal(at: cascadedVisibleCenter())
    }

    @objc func newShellTerminal(_ sender: Any?) {
        addTerminal(at: cascadedVisibleCenter())
    }

    @objc func newCodexTerminal(_ sender: Any?) {
        addCodexTerminal(at: cascadedVisibleCenter())
    }

    @objc func newLog(_ sender: Any?) {
        addLogTile(at: cascadedVisibleCenter())
    }

    private func addClaudeTerminal(at point: NSPoint) {
        guard let claudePath else {
            presentCLIMissingAlert(name: "claude")
            return
        }
        // Pin a session ID so a relaunch can resume this exact conversation.
        let sessionID = UUID().uuidString.lowercased()
        let tile = addTerminal(at: point, program: claudePath, programArgs: ["--session-id", sessionID])
        tile.claudeSessionID = sessionID
    }

    private func addCodexTerminal(at point: NSPoint) {
        guard let codexPath else {
            presentCLIMissingAlert(name: "codex")
            return
        }
        // Codex assigns its own session id (it can't be pinned at start like
        // claude's), so we launch fresh; a relaunch restores the tile and its
        // connections but starts a new codex conversation.
        addTerminal(at: point, program: codexPath)
    }

    private func presentCLIMissingAlert(name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) not found"
        alert.informativeText = "Couldn't locate the \(name) CLI on your PATH or in the usual install locations."
        alert.beginSheetModal(for: window)
    }

    @discardableResult
    private func addTerminal(
        at center: NSPoint, program: String? = nil, programArgs: [String] = []
    ) -> TerminalTileView {
        let size = TerminalTileView.defaultSize
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let tile = TerminalTileView(frame: NSRect(origin: origin, size: size))
        installTerminalTile(tile)
        if let program {
            tile.startProgram(program, args: programArgs, in: workingDirectory)
        } else {
            tile.startShell(in: workingDirectory)
        }
        window.makeFirstResponder(tile.terminal)
        return tile
    }

    private func installTerminalTile(_ tile: TerminalTileView) {
        tile.onClosed = { [weak self] in
            DispatchQueue.main.async { self?.publishConnections() }
            self?.scheduleSessionSave()
        }
        canvas.addSubview(tile)
        scheduleSessionSave()
    }

    // MARK: - Welcome & project setup

    /// Tracks whether the onboarding card has been shown automatically.
    private static let hasSeenWelcomeKey = "hasSeenWelcome"

    @objc func showWelcome(_ sender: Any?) {
        addWelcomeTile()
    }

    /// Drops a transient onboarding card on the canvas. It isn't persisted to
    /// the session — it just lives until closed or the next relaunch.
    private func addWelcomeTile() {
        // Reuse an existing card rather than stacking duplicates.
        if let existing = canvas.subviews.compactMap({ $0 as? WelcomeTileView }).first {
            existing.bringToFront()
            return
        }
        let size = WelcomeTileView.defaultSize
        let center = cascadedVisibleCenter()
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let tile = WelcomeTileView(frame: NSRect(origin: origin, size: size))
        tile.onInstall = { [weak self, weak tile] in self?.runProjectSetup(card: tile) }
        canvas.addSubview(tile)  // not persisted: no scheduleSessionSave()

        // If the project is already set up, open straight into the done state.
        let target = workingDirectory
        if target != NSHomeDirectory() {
            let status = projectSetupStatus(in: target)
            if status.complete { tile.showComplete(status.lines) }
        }
    }

    /// Installs the ptyparty skill + PARTY.md into the user's project and points
    /// its AGENTS.md/CLAUDE.md at PARTY.md. Driven by the Welcome card's button.
    private func runProjectSetup(card: WelcomeTileView?) {
        // The target is the session's working folder; never write into ~, so
        // prompt for a real project folder when none is set.
        guard let target = resolveProjectFolder() else { return }
        let fileManager = FileManager.default
        var summary: [String] = []

        // 1. Skill — into a `skills` folder found in the project, or one the
        //    user chooses when none exists.
        if let skillsDir = findSkillsFolder(in: target) ?? promptForSkillsFolder(in: target) {
            let skillDir = skillsDir.appendingPathComponent("ptyparty", isDirectory: true)
            do {
                try fileManager.createDirectory(at: skillDir, withIntermediateDirectories: true)
                try OnboardingContent.skillMarkdown.write(
                    to: skillDir.appendingPathComponent("SKILL.md"),
                    atomically: true, encoding: .utf8
                )
                summary.append("• Skill → \(displayPath(skillDir.appendingPathComponent("SKILL.md")))")
            } catch {
                summary.append("• Skill failed: \(error.localizedDescription)")
            }
        } else {
            summary.append("• Skill skipped (no skills folder chosen)")
        }

        // 2. PARTY.md at the project root.
        let partyURL = URL(fileURLWithPath: target).appendingPathComponent("PARTY.md")
        do {
            try OnboardingContent.partyMarkdown.write(to: partyURL, atomically: true, encoding: .utf8)
            summary.append("• \(displayPath(partyURL))")
        } catch {
            summary.append("• PARTY.md failed: \(error.localizedDescription)")
        }

        // 3. Point AGENTS.md (preferred) or CLAUDE.md at PARTY.md.
        summary.append("• \(addPointerLine(in: target))")

        // Show the result inline on the card rather than a separate dialog.
        card?.showComplete(summary)
    }

    /// Whether the project at `target` already has PARTY.md, a pointer line, and
    /// the ptyparty skill installed, plus user-facing lines describing each.
    private func projectSetupStatus(in target: String) -> (complete: Bool, lines: [String]) {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: target)
        var lines: [String] = []

        let partyURL = rootURL.appendingPathComponent("PARTY.md")
        let partyExists = fileManager.fileExists(atPath: partyURL.path)
        lines.append(partyExists ? "• \(displayPath(partyURL))" : "• PARTY.md not installed")

        let pointerHost = ["AGENTS.md", "CLAUDE.md"]
            .map { rootURL.appendingPathComponent($0) }
            .first { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return content.contains(OnboardingContent.pointerLine)
            }
        lines.append(pointerHost.map { "• \($0.lastPathComponent) points at PARTY.md" }
            ?? "• AGENTS.md/CLAUDE.md not pointing at PARTY.md")

        let skillURL = installedSkillURL(in: target)
        lines.append(skillURL.map { "• Skill → \(displayPath($0))" }
            ?? "• ptyparty skill not installed")

        return (partyExists && pointerHost != nil && skillURL != nil, lines)
    }

    /// The installed `ptyparty/SKILL.md`, if a `skills` folder in the project
    /// already contains it.
    private func installedSkillURL(in target: String) -> URL? {
        guard let skillsDir = findSkillsFolder(in: target) else { return nil }
        let url = skillsDir.appendingPathComponent("ptyparty/SKILL.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The folder to install into: the working folder, or one the user picks
    /// when it's unset/home. Returns nil if the user cancels the picker.
    private func resolveProjectFolder() -> String? {
        let current = workingDirectory
        if current != NSHomeDirectory() { return current }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the project to set up for pty.party."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        workingDirectory = url.path  // adopt it as the session's working folder
        return url.path
    }

    /// Searches `root` for a directory named `skills`, skipping heavy folders and
    /// capping depth. Returns the first match (shallowest wins).
    private func findSkillsFolder(in root: String) -> URL? {
        let skip: Set<String> = ["node_modules", ".git", ".build", "dist", "build", "Pods", ".next"]
        let rootURL = URL(fileURLWithPath: root)
        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
        let maxDepth = 4
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                let name = entry.lastPathComponent
                if name == "skills" { return entry }
                if depth < maxDepth, !skip.contains(name) {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return nil
    }

    /// Asks the user to choose or create a skills folder when none was found.
    private func promptForSkillsFolder(in root: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Use Folder"
        panel.message = "No 'skills' folder found. Choose or create one for the ptyparty skill."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Prepends the PARTY.md pointer line to AGENTS.md (preferred) or CLAUDE.md,
    /// creating AGENTS.md if neither exists. Idempotent. Returns a status line.
    private func addPointerLine(in root: String) -> String {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let line = OnboardingContent.pointerLine
        let target = ["AGENTS.md", "CLAUDE.md"]
            .map { rootURL.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
            ?? rootURL.appendingPathComponent("AGENTS.md")

        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        if existing.contains(line) {
            return "\(target.lastPathComponent) already points at PARTY.md"
        }
        let updated = existing.isEmpty ? "\(line)\n" : "\(line)\n\n\(existing)"
        do {
            try updated.write(to: target, atomically: true, encoding: .utf8)
            return "\(target.lastPathComponent) now points at PARTY.md"
        } catch {
            return "\(target.lastPathComponent) update failed: \(error.localizedDescription)"
        }
    }

    /// A tilde-abbreviated path for user-facing messages.
    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Command runners

    @objc func newCommandRunner(_ sender: Any?) {
        editCommandRunner(addCommandRunner(at: cascadedVisibleCenter()))
    }

    @discardableResult
    private func addCommandRunner(at center: NSPoint, runnerID: String? = nil) -> CommandRunnerTileView {
        let size = CommandRunnerTileView.defaultSize
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let tile = CommandRunnerTileView(
            frame: NSRect(origin: origin, size: size),
            runnerID: runnerID ?? UUID().uuidString
        )
        tile.directory = workingDirectory
        installCommandRunnerTile(tile)
        return tile
    }

    private func installCommandRunnerTile(_ tile: CommandRunnerTileView) {
        tile.onClosed = { [weak self] in self?.scheduleSessionSave() }
        tile.onRequestEdit = { [weak self] runner in self?.editCommandRunner(runner) }
        canvas.addSubview(tile)
        scheduleSessionSave()
    }

    private func editCommandRunner(_ runner: CommandRunnerTileView) {
        let alert = NSAlert()
        alert.messageText = "Configure Command"
        alert.informativeText = "The command runs in your login shell. Loop of 0 runs it once per play."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 146))
        func addRow(label: String, value: String, placeholder: String, y: CGFloat) -> NSTextField {
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            caption.font = .systemFont(ofSize: 12)
            caption.frame = NSRect(x: 0, y: y + 3, width: 92, height: 17)
            form.addSubview(caption)
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.frame = NSRect(x: 100, y: y, width: 256, height: 24)
            form.addSubview(field)
            return field
        }
        let nameField = addRow(
            label: "Name", value: runner.name,
            placeholder: "Reset user", y: 114
        )
        let commandField = addRow(
            label: "Command", value: runner.command,
            placeholder: "npm run reset-user", y: 80
        )
        let directoryField = addRow(
            label: "Directory",
            value: (runner.directory as NSString).abbreviatingWithTildeInPath,
            placeholder: "~/Workspace/uv-api", y: 46
        )
        let intervalField = addRow(
            label: "Loop (sec)", value: String(Int(runner.loopInterval)),
            placeholder: "0", y: 12
        )
        alert.accessoryView = form
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { [weak self, weak runner] response in
            guard response == .alertFirstButtonReturn, let self, let runner else { return }
            runner.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            runner.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
            let directory = directoryField.stringValue.trimmingCharacters(in: .whitespaces)
            runner.directory = directory.isEmpty
                ? self.workingDirectory
                : (directory as NSString).expandingTildeInPath
            runner.loopInterval = max(0, TimeInterval(Int(intervalField.stringValue) ?? 0))
            runner.refreshUI()
            self.scheduleSessionSave()
        }
    }

    private func imageTileSize(for image: NSImage) -> NSSize {
        var size = image.size
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 320, height: 240)
        }
        let maxDimension: CGFloat = 480
        let scale = min(1, maxDimension / max(size.width, size.height))
        // The tile is the scaled image plus the port margins on every side.
        let margins = CanvasTileView.portCenterInset * 2
        return NSSize(
            width: size.width * scale + margins,
            height: size.height * scale + margins
        )
    }

    /// Places an MCP-delivered image just below the terminal whose Claude
    /// session sent it, falling back to the center of the current view.
    private func addImageFromInbox(_ image: NSImage, terminalID: String?) {
        if let terminalID,
           let tile = canvas.subviews.first(where: {
               ($0 as? TerminalTileView)?.terminalID == terminalID
           }) {
            let size = imageTileSize(for: image)
            let gap: CGFloat = 24
            addImage(image, at: NSPoint(
                x: tile.frame.minX + size.width / 2,
                y: tile.frame.maxY + gap + size.height / 2
            ))
        } else {
            addImage(image, at: cascadedVisibleCenter())
        }
    }

    private func addImage(_ image: NSImage, at point: NSPoint) {
        let tileSize = imageTileSize(for: image)
        let origin = NSPoint(x: point.x - tileSize.width / 2, y: point.y - tileSize.height / 2)
        let tile = ImageTileView(image: image, frame: NSRect(origin: origin, size: tileSize))
        installImageTile(tile)
        selectImageTile(tile)
    }

    private func installImageTile(_ tile: ImageTileView) {
        tile.onClosed = { [weak self, weak tile] in
            guard let self else { return }
            if self.selectedImageTile === tile {
                self.selectImageTile(nil)
            }
            // After the tile has actually left the canvas, so pruning sees it.
            DispatchQueue.main.async { self.publishConnections() }
            self.scheduleSessionSave()
        }
        canvas.addSubview(tile)
        scheduleSessionSave()
    }

    // MARK: - Notes

    /// Places an MCP-delivered sticky note just below the terminal whose Claude
    /// session wrote it, falling back to the center of the current view.
    private func addNoteFromInbox(title: String, body: String, terminalID: String?) {
        // A PRD checklist is revised repeatedly; a later write with the same
        // title updates that card in place rather than stacking a fresh copy
        // on the canvas each time. (Empty titles can't be matched, so they
        // always create a new card.)
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty,
           let existing = canvas.subviews.lazy.compactMap({ $0 as? NoteTileView })
               .first(where: {
                   $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                       .caseInsensitiveCompare(key) == .orderedSame
               }) {
            existing.update(title: title, body: body)
            scheduleSessionSave()
            return
        }

        // The card sizes its own height from the checklist; we just pick a
        // width and let it grow downward, then center it.
        let width = NoteTileView.defaultWidth
        let tile = NoteTileView(
            title: title, body: body,
            frame: NSRect(x: 0, y: 0, width: width, height: 200)
        )
        let size = tile.frame.size
        let center: NSPoint
        if let terminalID,
           let terminal = canvas.subviews.first(where: {
               ($0 as? TerminalTileView)?.terminalID == terminalID
           }) {
            let gap: CGFloat = 24
            center = NSPoint(
                x: terminal.frame.minX + size.width / 2,
                y: terminal.frame.maxY + gap + size.height / 2
            )
        } else {
            center = cascadedVisibleCenter()
        }
        tile.setFrameOrigin(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        installNoteTile(tile)
    }

    /// Creates an empty log card at `point`. The user connects one or more
    /// terminals to it (drag from the card's edge port to a terminal); their
    /// Claude sessions then write items into it via the `add_to_checklist`
    /// MCP tool, so several terminals can share one running checklist.
    @discardableResult
    private func addLogTile(at point: NSPoint) -> NoteTileView {
        let width = NoteTileView.defaultWidth
        let tile = NoteTileView(
            title: "Activity Log", body: "",
            frame: NSRect(x: 0, y: 0, width: width, height: 200)
        )
        let size = tile.frame.size
        tile.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        installNoteTile(tile)
        return tile
    }

    private func installNoteTile(_ tile: NoteTileView) {
        tile.onClosed = { [weak self, weak tile] in
            guard let self else { return }
            if self.selectedNoteTile === tile {
                self.selectNoteTile(nil)
            }
            // After the tile has actually left the canvas, so pruning sees it.
            DispatchQueue.main.async { self.publishConnections() }
            self.scheduleSessionSave()
        }
        canvas.addSubview(tile)
        scheduleSessionSave()
    }

    /// Serializes a note to a real Markdown document: the title as an H1
    /// heading, then the body.
    private static func markdown(title: String, body: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return body }
        return body.isEmpty ? "# \(trimmedTitle)\n" : "# \(trimmedTitle)\n\n\(body)"
    }

    /// Recovers a note's title and body from its Markdown file: a leading H1
    /// heading is the title, the remainder (less one blank separator) the body.
    private static func parseNote(_ markdown: String) -> (title: String, body: String) {
        guard markdown.hasPrefix("# ") else { return ("", markdown) }
        let firstBreak = markdown.firstIndex(of: "\n") ?? markdown.endIndex
        let title = String(markdown[markdown.index(markdown.startIndex, offsetBy: 2)..<firstBreak])
        var rest = firstBreak < markdown.endIndex
            ? String(markdown[markdown.index(after: firstBreak)...])
            : ""
        if rest.hasPrefix("\n") { rest.removeFirst() }
        return (title.trimmingCharacters(in: .whitespaces), rest)
    }

    // MARK: - Pasting

    /// ⌘V reaches us through the responder chain only when no terminal has
    /// keyboard focus, so a focused terminal always wins (text paste) and
    /// clipboard images land on the canvas otherwise.
    @objc func paste(_ sender: Any?) {
        let images = ImagePasteboard.images(from: NSPasteboard.general)
        guard !images.isEmpty else {
            NSSound.beep()
            return
        }
        for (index, image) in images.enumerated() {
            let offset = CGFloat(index) * 32
            var point = visibleCenter()
            point.x += offset
            point.y += offset
            addImage(image, at: point)
        }
    }

    // MARK: - Image selection

    /// Where the current selection is published for external tools (the MCP server).
    static let selectionFileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("selected-image.png")
    }()

    private func selectImageTile(_ tile: ImageTileView?) {
        if tile != nil { selectNoteTile(nil) }  // one selection at a time
        guard tile !== selectedImageTile else { return }
        selectedImageTile?.isSelected = false
        selectedImageTile = tile
        tile?.isSelected = true
        publishSelection(tile?.image)
    }

    private func selectNoteTile(_ tile: NoteTileView?) {
        if tile != nil { selectImageTile(nil) }  // one selection at a time
        guard tile !== selectedNoteTile else { return }
        selectedNoteTile?.isSelected = false
        selectedNoteTile = tile
        tile?.isSelected = true
    }

    private func publishSelection(_ image: NSImage?) {
        let url = Self.selectionFileURL
        guard let image, let png = pngData(from: image) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? png.write(to: url)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Session selection & switching

    /// Picks the session to load at launch: migrate any legacy canvas, then
    /// show the picker when sessions exist, or create a first one otherwise.
    private func chooseStartupSession() -> SessionStore.Info {
        SessionStore.migrateLegacyIfNeeded()
        let existing = SessionStore.list()
        if existing.isEmpty {
            return SessionStore.create(name: "My Canvas")
        }
        // Open the last-used session directly. The session badge's dropdown is
        // now the way to switch sessions, so a forced launch picker would be
        // redundant. (Open Session… in the menu still shows the full picker.)
        if let lastID = SessionStore.lastOpenedID,
           let last = existing.first(where: { $0.id == lastID }) {
            return last
        }
        return existing.first!
    }

    private func updateWindowTitle() {
        window.title = currentSession.map { "pty.party — \($0.name)" } ?? "pty.party"
        sessionBadge?.sessionName = currentSession?.name ?? ""
        positionSessionBadge()
    }

    /// Keeps the badge pinned to the top-left of the content area, re-measuring
    /// its width (the session name changes it) each time.
    private func positionSessionBadge() {
        guard let sessionBadge, let container = sessionBadge.superview else { return }
        sessionBadge.sizeToFit()
        let margin: CGFloat = 16
        sessionBadge.setFrameOrigin(NSPoint(
            x: margin,
            y: container.bounds.height - sessionBadge.frame.height - margin
        ))
    }

    /// Pops up the session switcher under the badge: every session, with the
    /// current one checked, plus new/rename actions.
    private func showSessionMenu(from badge: SessionBadgeView) {
        let menu = NSMenu()
        for info in SessionStore.list() {
            let item = NSMenuItem(
                title: info.name,
                action: #selector(switchToSessionMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = info.id
            item.state = (info.id == currentSession?.id) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Session…", action: #selector(newSession(_:)), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
        let renameItem = NSMenuItem(title: "Rename Session…", action: #selector(renameSession(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)
        // Anchor just below the badge's bottom-left corner.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: badge)
    }

    @objc private func switchToSessionMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let info = SessionStore.list().first(where: { $0.id == id })
        else { return }
        switchTo(info)
    }

    @objc func newSession(_ sender: Any?) {
        guard let name = promptForSessionName(title: "New Session", initial: "") else { return }
        switchTo(SessionStore.create(name: name))
    }

    @objc func openSession(_ sender: Any?) {
        guard let chosen = SessionPicker().run(allowCancel: true) else { return }
        switchTo(chosen)
    }

    @objc func renameSession(_ sender: Any?) {
        guard currentSession != nil,
              let name = promptForSessionName(title: "Rename Session", initial: currentSession.name)
        else { return }
        SessionStore.rename(currentSession, to: name)
        currentSession.name = name
        updateWindowTitle()
    }

    private func promptForSessionName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "My Canvas"
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Saves the current canvas, clears it, and loads another session in place.
    private func switchTo(_ session: SessionStore.Info) {
        guard session.id != currentSession?.id else { return }
        sessionSaveTimer?.invalidate()
        saveSession()

        isSwitchingSession = true
        teardownCanvas()
        currentSession = session
        isSwitchingSession = false

        SessionStore.lastOpenedID = session.id
        updateWindowTitle()
        publishConnections()  // the canvas is now empty until restore repopulates it
        if !restoreSession() {
            addClaudeTerminal(at: visibleCenter())
        }
    }

    /// Tears every tile off the canvas, killing terminal/runner processes, so
    /// a different session can be loaded cleanly.
    private func teardownCanvas() {
        selectImageTile(nil)
        selectNoteTile(nil)
        window.makeFirstResponder(nil)
        for view in canvas.subviews {
            switch view {
            case let terminal as TerminalTileView:
                terminal.onClosed = nil
                terminal.terminate()
                terminal.removeFromSuperview()
            case let runner as CommandRunnerTileView:
                runner.onClosed = nil
                runner.pauseRun()
                runner.removeFromSuperview()
            case let image as ImageTileView:
                image.onClosed = nil
                image.removeFromSuperview()
            case let note as NoteTileView:
                note.onClosed = nil
                note.removeFromSuperview()
            default:
                break
            }
        }
        canvas.clearConnections()
        cascadeCount = 0
    }

    // MARK: - Session persistence

    /// The canvas snapshot file for the loaded session.
    private var sessionFileURL: URL { currentSession.sessionFileURL }

    /// The saved-images folder for the loaded session.
    private var imagesDirURL: URL { currentSession.imagesDirURL }

    /// The saved-notes folder for the loaded session.
    private var notesDirURL: URL { currentSession.notesDirURL }

    /// Coalesces the frequent change notifications into one save per second.
    private func scheduleSessionSave() {
        guard !isSwitchingSession, currentSession != nil else { return }
        sessionSaveTimer?.invalidate()
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.saveSession()
        }
    }

    private func saveSession() {
        guard currentSession != nil else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: imagesDirURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: notesDirURL, withIntermediateDirectories: true)

        var tiles: [SessionState.Tile] = []
        var liveImageFiles = Set<String>()
        var liveNoteFiles = Set<String>()
        for view in canvas.subviews {
            if let terminal = view as? TerminalTileView {
                tiles.append(SessionState.Tile(
                    kind: .terminal,
                    id: terminal.terminalID,
                    x: terminal.frame.origin.x, y: terminal.frame.origin.y,
                    width: terminal.frame.width, height: terminal.frame.height,
                    program: terminal.launchedProgramName,
                    directory: terminal.currentDirectory ?? terminal.startDirectory,
                    imageFile: nil,
                    claudeSession: terminal.claudeSessionID,
                    command: nil, loopInterval: nil, name: nil
                ))
            } else if let runner = view as? CommandRunnerTileView {
                tiles.append(SessionState.Tile(
                    kind: .command,
                    id: runner.runnerID,
                    x: runner.frame.origin.x, y: runner.frame.origin.y,
                    width: runner.frame.width, height: runner.frame.height,
                    program: nil,
                    directory: runner.directory,
                    imageFile: nil,
                    claudeSession: nil,
                    command: runner.command, loopInterval: runner.loopInterval,
                    name: runner.name
                ))
            } else if let image = view as? ImageTileView {
                let fileName = "\(image.imageID).png"
                liveImageFiles.insert(fileName)
                let fileURL = imagesDirURL.appendingPathComponent(fileName)
                if !fileManager.fileExists(atPath: fileURL.path),
                   let png = pngData(from: image.image) {
                    try? png.write(to: fileURL)
                }
                tiles.append(SessionState.Tile(
                    kind: .image,
                    id: image.imageID,
                    x: image.frame.origin.x, y: image.frame.origin.y,
                    width: image.frame.width, height: image.frame.height,
                    program: nil, directory: nil,
                    imageFile: fileName,
                    claudeSession: nil,
                    command: nil, loopInterval: nil, name: nil
                ))
            } else if let note = view as? NoteTileView {
                let fileName = "\(note.noteID).md"
                liveNoteFiles.insert(fileName)
                try? Self.markdown(title: note.title, body: note.body)
                    .write(to: notesDirURL.appendingPathComponent(fileName),
                            atomically: true, encoding: .utf8)
                tiles.append(SessionState.Tile(
                    kind: .note,
                    id: note.noteID,
                    x: note.frame.origin.x, y: note.frame.origin.y,
                    width: note.frame.width, height: note.frame.height,
                    program: nil, directory: nil,
                    imageFile: nil,
                    noteFile: fileName,
                    claudeSession: nil,
                    command: nil, loopInterval: nil, name: nil
                ))
            }
        }

        // Drop image files whose tiles are gone.
        let stored = (try? fileManager.contentsOfDirectory(
            at: imagesDirURL, includingPropertiesForKeys: nil
        )) ?? []
        for url in stored where !liveImageFiles.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        // Drop note files whose tiles are gone.
        let storedNotes = (try? fileManager.contentsOfDirectory(
            at: notesDirURL, includingPropertiesForKeys: nil
        )) ?? []
        for url in storedNotes where !liveNoteFiles.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        canvas.pruneConnections()
        let state = SessionState(
            name: currentSession.name,
            workingDirectory: sessionWorkingDirectory,
            magnification: scrollView.magnification,
            scrollX: scrollView.contentView.bounds.origin.x,
            scrollY: scrollView.contentView.bounds.origin.y,
            tiles: tiles,
            imageConnections: canvas.connections.compactMap { connection in
                guard let image = connection.image, let terminal = connection.terminal else { return nil }
                return SessionState.Link(from: image.imageID, to: terminal.terminalID)
            },
            terminalConnections: canvas.terminalConnections.compactMap { link in
                guard let first = link.first, let second = link.second else { return nil }
                return SessionState.Link(from: first.terminalID, to: second.terminalID)
            },
            noteConnections: canvas.noteConnections.compactMap { connection in
                guard let note = connection.note, let terminal = connection.terminal else { return nil }
                return SessionState.Link(from: note.noteID, to: terminal.terminalID)
            }
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: sessionFileURL)
        }
    }

    /// Whether a claude session with this ID has saved history (a .jsonl in
    /// any project folder). Session IDs are globally unique, so a flat scan
    /// is enough.
    private static func claudeSessionExists(_ sessionID: String) -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        )) ?? []
        return dirs.contains {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("\(sessionID).jsonl").path
            )
        }
    }

    /// Rebuilds the previous canvas. Returns false when there is nothing
    /// to restore.
    private func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else {
            sessionWorkingDirectory = nil
            updateFolderButton()
            return false
        }

        // The working folder belongs to the session, so adopt it even when the
        // canvas itself is empty.
        sessionWorkingDirectory = state.workingDirectory
        updateFolderButton()

        guard !state.tiles.isEmpty else { return false }

        for tile in state.tiles {
            let frame = NSRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
            switch tile.kind {
            case .terminal:
                let view = TerminalTileView(frame: frame, terminalID: tile.id)
                installTerminalTile(view)
                let directory = tile.directory ?? workingDirectory
                switch tile.program {
                case "codex"?:
                    // Codex can't resume a specific session non-interactively,
                    // so relaunch it fresh; the tile and its connections are
                    // what we restore.
                    if let codexPath {
                        view.startProgram(codexPath, in: directory)
                    } else {
                        view.startShell(in: directory)
                    }
                case .some:
                    // Any other launched program is a claude terminal (the
                    // only kind before codex). Resume this tile's own pinned
                    // session if it has history; otherwise start fresh under
                    // the pinned ID so the next relaunch can resume it.
                    if let claudePath {
                        let sessionID = tile.claudeSession ?? UUID().uuidString.lowercased()
                        let args = Self.claudeSessionExists(sessionID)
                            ? ["--resume", sessionID]
                            : ["--session-id", sessionID]
                        view.startProgram(claudePath, args: args, in: directory)
                        view.claudeSessionID = sessionID
                    } else {
                        view.startShell(in: directory)
                    }
                case .none:
                    view.startShell(in: directory)
                }
            case .image:
                guard let fileName = tile.imageFile,
                      let image = NSImage(contentsOf: imagesDirURL.appendingPathComponent(fileName))
                else { continue }
                let view = ImageTileView(image: image, frame: frame, imageID: tile.id)
                installImageTile(view)
            case .command:
                let view = CommandRunnerTileView(frame: frame, runnerID: tile.id)
                view.command = tile.command ?? ""
                view.directory = tile.directory ?? workingDirectory
                view.name = tile.name ?? ""
                view.loopInterval = tile.loopInterval ?? 0
                // Restore expanded output if the saved tile was tall.
                if frame.height > CommandRunnerTileView.compactHeight + 20 {
                    view.setOutputVisible(true, resizeTile: false)
                }
                view.refreshUI()  // restored paused; press play to start
                installCommandRunnerTile(view)
            case .note:
                guard let fileName = tile.noteFile,
                      let markdown = try? String(
                          contentsOf: notesDirURL.appendingPathComponent(fileName),
                          encoding: .utf8
                      )
                else { continue }
                let (title, body) = Self.parseNote(markdown)
                let view = NoteTileView(title: title, body: body, frame: frame, noteID: tile.id)
                installNoteTile(view)
            }
        }

        var terminals: [String: TerminalTileView] = [:]
        var images: [String: ImageTileView] = [:]
        var notes: [String: NoteTileView] = [:]
        for view in canvas.subviews {
            if let terminal = view as? TerminalTileView { terminals[terminal.terminalID] = terminal }
            if let image = view as? ImageTileView { images[image.imageID] = image }
            if let note = view as? NoteTileView { notes[note.noteID] = note }
        }
        for link in state.imageConnections {
            if let image = images[link.from], let terminal = terminals[link.to] {
                canvas.toggleConnection(from: image, to: terminal)
            }
        }
        for link in state.terminalConnections {
            if let first = terminals[link.from], let second = terminals[link.to] {
                canvas.toggleTerminalConnection(first, second)
            }
        }
        for link in state.noteConnections ?? [] {
            if let note = notes[link.from], let terminal = terminals[link.to] {
                canvas.toggleNoteConnection(from: note, to: terminal)
            }
        }

        scrollView.magnification = state.magnification
        scrollView.contentView.scroll(to: NSPoint(x: state.scrollX, y: state.scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    // MARK: - Connection publishing

    /// Each terminal's connected images live in a folder named after its
    /// terminal ID, where the MCP server's get_connected_images reads them.
    static let connectionsDirURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty/connections", isDirectory: true)
    }()

    private func publishConnections() {
        canvas.pruneConnections()
        let fileManager = FileManager.default
        let dir = Self.connectionsDirURL
        try? fileManager.removeItem(at: dir)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var imagesByTerminal: [String: [NSImage]] = [:]
        for connection in canvas.connections {
            guard let image = connection.image, let terminal = connection.terminal else { continue }
            imagesByTerminal[terminal.terminalID, default: []].append(image.image)
        }
        for (terminalID, images) in imagesByTerminal {
            let terminalDir = dir.appendingPathComponent(terminalID, isDirectory: true)
            try? fileManager.createDirectory(at: terminalDir, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                guard let png = pngData(from: image) else { continue }
                try? png.write(to: terminalDir.appendingPathComponent("\(index).png"))
            }
        }

        var notesByTerminal: [String: [NoteTileView]] = [:]
        for connection in canvas.noteConnections {
            guard let note = connection.note, let terminal = connection.terminal else { continue }
            notesByTerminal[terminal.terminalID, default: []].append(note)
        }
        for (terminalID, notes) in notesByTerminal {
            let notesDir = dir.appendingPathComponent(terminalID, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true)
            try? fileManager.createDirectory(at: notesDir, withIntermediateDirectories: true)
            for (index, note) in notes.enumerated() {
                let markdown = Self.markdown(title: note.title, body: note.body)
                try? markdown.write(
                    to: notesDir.appendingPathComponent("\(index).md"),
                    atomically: true, encoding: .utf8
                )
            }
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        setMagnification(scrollView.magnification * 1.25)
    }

    @objc func zoomOut(_ sender: Any?) {
        setMagnification(scrollView.magnification / 1.25)
    }

    @objc func actualSize(_ sender: Any?) {
        setMagnification(1.0)
    }

    private func setMagnification(_ value: CGFloat) {
        let center = visibleCenter()
        scrollView.setMagnification(value, centeredAt: center)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About pty.party",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide pty.party", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit pty.party", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Claude", action: #selector(newClaudeTerminal(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Codex", action: #selector(newCodexTerminal(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "New Terminal", action: #selector(newShellTerminal(_:)), keyEquivalent: "N")
        let runnerItem = NSMenuItem(
            title: "New Command Runner",
            action: #selector(newCommandRunner(_:)),
            keyEquivalent: "n"
        )
        runnerItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(runnerItem)
        let logItem = NSMenuItem(title: "New Log", action: #selector(newLog(_:)), keyEquivalent: "l")
        logItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(logItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Set Working Folder…", action: #selector(chooseWorkingDirectory(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Set Up Project…", action: #selector(showWelcome(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        let newSessionItem = NSMenuItem(
            title: "New Session…",
            action: #selector(newSession(_:)),
            keyEquivalent: "n"
        )
        newSessionItem.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(newSessionItem)
        let openSessionItem = NSMenuItem(
            title: "Open Session…",
            action: #selector(openSession(_:)),
            keyEquivalent: "o"
        )
        openSessionItem.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(openSessionItem)
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Rename Session…", action: #selector(renameSession(_:)), keyEquivalent: "")
        sessionMenuItem.submenu = sessionMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
