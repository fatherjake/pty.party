import AppKit

/// A transient onboarding card placed on the canvas on first launch (and
/// reopenable from the menu). It lists what the user needs installed and offers
/// a one-click button that installs the `ptyparty` skill and `PARTY.md` into
/// their project. Unlike notes/logs it is **not** persisted to the session — it
/// just lives until closed or the next relaunch.
final class WelcomeTileView: CanvasTileView {
    static let defaultSize = NSSize(width: 380, height: 360)
    override var minSize: NSSize { NSSize(width: 320, height: 320) }

    /// Invoked when the user clicks "Set up this project…".
    var onInstall: (() -> Void)?
    var onClosed: (() -> Void)?

    /// One probed prerequisite, rendered as a live ✓/⚠/✗ row in the card.
    struct Dependency {
        let label: String
        let found: Bool
        /// Required deps show ✗ in red when missing; recommended ones show ⚠.
        let required: Bool
        /// Shown after the label when missing (e.g. an install command).
        let hint: String?
    }

    private let closeButton = NSButton(frame: .zero)
    private let stack = NSStackView()
    private let depsStack = NSStackView()
    private let installButton = NSButton(frame: .zero)
    private var dragOffset = NSPoint.zero

    private static let cardBG = Theme.tile
    private static let cardBorder = Theme.border

    override init(frame: NSRect) {
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
        addSubview(closeButton)

        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pad: CGFloat = 18
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
        ])

        stack.addArrangedSubview(label(
            "Welcome to pty.party", font: Theme.mono(15, .semibold), color: Theme.textPrimary
        ))
        stack.addArrangedSubview(label(
            "Wire AI agents and terminals together on an infinite canvas.",
            font: Theme.mono(12, .regular), color: Theme.textDim, wraps: true
        ))

        stack.addArrangedSubview(label(
            "YOU'LL NEED", font: Theme.mono(11, .semibold), color: Theme.textDim
        ))
        depsStack.orientation = .vertical
        depsStack.alignment = .leading
        depsStack.spacing = 6
        stack.addArrangedSubview(depsStack)
        depsStack.addArrangedSubview(label(
            "Checking dependencies…", font: Theme.mono(12, .regular), color: Theme.textDim
        ))

        stack.addArrangedSubview(label(
            "Set up the current project so agents read PARTY.md and the ptyparty skill, and so live tile status works via Claude Code hooks (Claude will ask once to trust them):",
            font: Theme.mono(12, .regular), color: Theme.textDim, wraps: true
        ))

        installButton.title = "Set up this project…"
        installButton.bezelStyle = .rounded
        installButton.controlSize = .large
        installButton.target = self
        installButton.action = #selector(installClicked)
        installButton.keyEquivalent = "\r"
        stack.addArrangedSubview(installButton)
    }

    /// Renders the probed prerequisites as ✓/⚠/✗ rows. Called after a background
    /// PATH probe, so it can replace the "Checking dependencies…" placeholder.
    func setDependencies(_ deps: [Dependency]) {
        depsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for dep in deps {
            let glyph: String
            let color: NSColor
            if dep.found {
                glyph = "✓"; color = Theme.green
            } else if dep.required {
                glyph = "✗"; color = Theme.red
            } else {
                glyph = "⚠"; color = Theme.amber
            }
            var text = "\(glyph) \(dep.label)"
            if !dep.found, let hint = dep.hint { text += " — \(hint)" }
            depsStack.addArrangedSubview(label(
                text, font: Theme.mono(12, .regular),
                color: dep.found ? Theme.textPrimary : color, wraps: true
            ))
        }
    }

    /// Swaps the card to its "setup complete" state, listing what's installed.
    /// Used both after a successful run and when an already-set-up project is
    /// detected on open.
    func showComplete(_ lines: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label(
            "✓ Setup complete", font: Theme.mono(15, .semibold), color: Theme.green
        ))
        stack.addArrangedSubview(label(
            "Agents launched in this project will read PARTY.md and the ptyparty skill.",
            font: Theme.mono(12, .regular), color: Theme.textDim, wraps: true
        ))
        for line in lines {
            stack.addArrangedSubview(label(
                line, font: Theme.mono(12, .regular), color: Theme.textPrimary, wraps: true
            ))
        }
        installButton.title = "Set up again…"
        installButton.keyEquivalent = ""
        stack.addArrangedSubview(installButton)
    }

    private func label(
        _ text: String, font: NSFont, color: NSColor, wraps: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = wraps ? 0 : 1
        if wraps {
            field.preferredMaxLayoutWidth = Self.defaultSize.width - 36
        }
        return field
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.maxX - 24, y: 8, width: 16, height: 16)
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

    @objc private func installClicked() { onInstall?() }

    func close() {
        onClosed?()
        removeFromSuperview()
    }

    @objc private func closeTile() { close() }
}
