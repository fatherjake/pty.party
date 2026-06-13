import AppKit

/// A modal picker for choosing which saved session to open, or creating a new
/// one. Shown at launch and reachable later from the Session menu.
final class SessionPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var openButton: NSButton!
    private var renameButton: NSButton!
    private var deleteButton: NSButton!

    private var sessions: [SessionStore.Info] = []
    private var chosen: SessionStore.Info?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Runs modally and returns the session to open, or nil if the user
    /// cancelled. When `allowCancel` is false the picker can only be dismissed
    /// by opening or creating a session.
    func run(allowCancel: Bool) -> SessionStore.Info? {
        sessions = SessionStore.list()
        buildWindow(allowCancel: allowCancel)
        selectPreferredRow()
        updateButtons()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return chosen
    }

    // MARK: - Window

    private func buildWindow(allowCancel: Bool) {
        let width: CGFloat = 520
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 380))

        let heading = NSTextField(labelWithString: "Open a Session")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 340, width: 480, height: 24)
        content.addSubview(heading)

        let subheading = NSTextField(labelWithString: "Pick up where you left off, or start a new canvas.")
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        subheading.frame = NSRect(x: 20, y: 320, width: 480, height: 18)
        content.addSubview(subheading)

        // Table of sessions.
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 92, width: 480, height: 216))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        tableView = NSTableView(frame: scroll.bounds)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Session"
        nameColumn.width = 320
        tableView.addTableColumn(nameColumn)

        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Last Modified"
        dateColumn.width = 150
        tableView.addTableColumn(dateColumn)

        scroll.documentView = tableView
        content.addSubview(scroll)

        // Bottom button row: management on the left, open/cancel on the right.
        let newButton = makeButton("New Session…", action: #selector(createNew))
        newButton.frame = NSRect(x: 20, y: 20, width: 130, height: 32)
        content.addSubview(newButton)

        renameButton = makeButton("Rename…", action: #selector(renameSelected))
        renameButton.frame = NSRect(x: 158, y: 20, width: 90, height: 32)
        content.addSubview(renameButton)

        deleteButton = makeButton("Delete", action: #selector(deleteSelected))
        deleteButton.frame = NSRect(x: 256, y: 20, width: 80, height: 32)
        content.addSubview(deleteButton)

        openButton = makeButton("Open", action: #selector(openSelected))
        openButton.frame = NSRect(x: 430, y: 20, width: 70, height: 32)
        openButton.keyEquivalent = "\r"  // Return opens the selected session
        content.addSubview(openButton)

        if allowCancel {
            let cancelButton = makeButton("Cancel", action: #selector(cancel))
            cancelButton.frame = NSRect(x: 352, y: 20, width: 70, height: 32)
            cancelButton.keyEquivalent = "\u{1b}"  // Esc
            content.addSubview(cancelButton)
        }

        let styleMask: NSWindow.StyleMask = allowCancel ? [.titled, .closable] : [.titled]
        window = NSWindow(
            contentRect: content.frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "pty.party"
        window.contentView = content
        window.center()
        window.initialFirstResponder = tableView
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func selectPreferredRow() {
        let preferred = SessionStore.lastOpenedID
        let index = sessions.firstIndex { $0.id == preferred } ?? (sessions.isEmpty ? nil : 0)
        if let index {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0
        openButton.isEnabled = hasSelection
        renameButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    private var selectedSession: SessionStore.Info? {
        let row = tableView.selectedRow
        return sessions.indices.contains(row) ? sessions[row] : nil
    }

    // MARK: - Actions

    @objc private func openSelected() {
        guard let session = selectedSession else { return }
        chosen = session
        NSApp.stopModal()
    }

    @objc private func cancel() {
        chosen = nil
        NSApp.stopModal()
    }

    @objc private func createNew() {
        guard let name = promptForName(title: "New Session", placeholder: "My Canvas", initial: "")
        else { return }
        chosen = SessionStore.create(name: name)
        NSApp.stopModal()
    }

    @objc private func renameSelected() {
        guard let session = selectedSession,
              let name = promptForName(title: "Rename Session", placeholder: "", initial: session.name)
        else { return }
        SessionStore.rename(session, to: name)
        reload(preserving: session.id)
    }

    @objc private func deleteSelected() {
        guard let session = selectedSession else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(session.name)”?"
        alert.informativeText = "This permanently removes the session and its saved images. Running terminals are not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SessionStore.delete(session)
        reload(preserving: nil)
    }

    private func reload(preserving id: String?) {
        sessions = SessionStore.list()
        tableView.reloadData()
        if let id, let index = sessions.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateButtons()
    }

    /// A small modal text prompt; returns the trimmed name, or nil if cancelled
    /// or left blank.
    private func promptForName(title: String, placeholder: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(
        _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
    ) -> Any? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        if tableColumn?.identifier.rawValue == "date" {
            return Self.dateFormatter.string(from: session.modifiedAt)
        }
        return session.name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
