import AppKit

/// The shared, terminal-native palette and type for the canvas and every tile:
/// a near-black surface, a single spring-green accent, an amber "needs you"
/// signal, and monospaced text throughout.
enum Theme {
    // MARK: Surfaces
    /// The canvas backdrop: a 95%-black surface with a faint green tint.
    static let canvas = NSColor(srgbRed: 0.045, green: 0.050, blue: 0.045, alpha: 1)
    /// The dot grid on the canvas.
    static let dot = NSColor(srgbRed: 0.52, green: 0.60, blue: 0.53, alpha: 0.38)
    /// A tile's card background.
    static let tile = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.055, alpha: 1)
    /// Recessed boxes inside a tile (command preview, etc.).
    static let inset = NSColor(srgbRed: 0.094, green: 0.102, blue: 0.094, alpha: 1)
    /// A tile's resting border.
    static let border = NSColor(srgbRed: 0.55, green: 0.63, blue: 0.56, alpha: 0.20)
    /// Hairline dividers inside a tile.
    static let divider = NSColor(srgbRed: 0.55, green: 0.63, blue: 0.56, alpha: 0.12)

    // MARK: Accents
    /// The primary spring-green accent: focus, progress, "run", active items.
    static let green = NSColor(srgbRed: 0.49, green: 0.89, blue: 0.55, alpha: 1)
    /// A muted green for completed, struck-through items.
    static let greenDim = NSColor(srgbRed: 0.44, green: 0.60, blue: 0.47, alpha: 1)
    /// A subtle green wash behind the active row.
    static let greenWash = NSColor(srgbRed: 0.49, green: 0.89, blue: 0.55, alpha: 0.10)
    /// The amber "needs you / waiting" signal.
    static let amber = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.33, alpha: 1)
    /// A soft red for failures.
    static let red = NSColor(srgbRed: 0.95, green: 0.45, blue: 0.45, alpha: 1)

    // MARK: Text
    static let textPrimary = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.87, alpha: 1)
    static let textDim = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.55, alpha: 1)
    static let textFaint = NSColor(srgbRed: 0.40, green: 0.43, blue: 0.40, alpha: 1)

    // MARK: Type
    /// A monospaced system font at the given size/weight, matching the
    /// terminal-native look of the whole canvas.
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
