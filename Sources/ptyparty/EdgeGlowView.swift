import AppKit

/// A transparent, click-through layer pinned over the viewport (not the
/// scrolling canvas) that draws a soft directional glow at the screen edge
/// pointing toward any working/asking terminal that's being scrolled out of
/// sight — a Philips-Hue-style ambient cue. As the tile's center crosses the
/// edge — while it's still half visible — the glow blooms from zero into a tall
/// column spanning most of that edge, so it visibly hands off from the
/// terminal. As the tile recedes the column contracts toward a small, skinny
/// spot, so distance reads as a focused pinpoint and nearness as a wall of
/// light.
final class EdgeGlowView: NSView {
    /// The canvas whose terminal tiles we point toward. Tiles live in canvas
    /// coordinates; we convert each frame into our own (viewport) space, which
    /// folds in the scroll offset and magnification for free.
    weak var canvas: CanvasView?

    /// Distance (in viewport points) the tile's center travels past the edge
    /// over which the glow eases in from nothing — short, so it blooms quickly
    /// while the tile is still half on screen, anchoring the glow to it.
    private static let fadeInDistance: CGFloat = 110

    /// Distance over which the glow contracts from spanning most of the edge
    /// down toward a small spot as the tile recedes — further away, skinnier.
    private static let shrinkDistance: CGFloat = 750

    /// How far the glow bleeds inward from the edge at full strength — small,
    /// per the brief, but clearly present.
    private static let fullRadius: CGFloat = 170

    /// Fraction of the edge the glow spans the moment the tile leaves view:
    /// nearly the whole side, so a just-departed terminal reads as a tall
    /// column of light right off that edge.
    private static let nearSpanFraction: CGFloat = 0.45

    /// The glow's along-edge half-length once the tile is far away — a short,
    /// skinny spot, the far end of the morph from the near-screen column.
    private static let minAlongHalf: CGFloat = 95

    /// Peak opacity at the brightest core of a full-strength glow.
    private static let fullAlpha: CGFloat = 0.5

    // Never intercept events meant for the canvas or its tiles.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Recomputes and redraws the glows. Cheap when nothing is off-screen.
    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }
        let viewport = bounds
        guard !viewport.isEmpty else { return }

        for case let tile as TerminalTileView in canvas.subviews {
            let color: NSColor
            switch tile.currentActivity {
            case .working: color = Theme.blue
            case .asking: color = Theme.amber
            case .idle: continue  // only active tiles glow
            }

            // The tile's frame in our (viewport) coordinate space.
            let rect = convert(tile.frame, from: canvas)

            // Measure from the tile's *center*: the glow starts the instant the
            // center crosses an edge — while the tile is still half visible — so
            // you watch the glow emerge from the terminal before it's gone.
            // Distance is zero on an axis whose center is still inside.
            let gapX = max(viewport.minX - rect.midX, rect.midX - viewport.maxX, 0)
            let gapY = max(viewport.minY - rect.midY, rect.midY - viewport.maxY, 0)
            guard gapX > 0 || gapY > 0 else { continue }

            // Anchor the glow on the viewport boundary in the tile's direction:
            // snap to the crossed edge on each axis, else track the tile's
            // center so the glow slides along the edge toward it.
            let anchorX: CGFloat
            if rect.midX <= viewport.minX { anchorX = viewport.minX }
            else if rect.midX >= viewport.maxX { anchorX = viewport.maxX }
            else { anchorX = min(max(rect.midX, viewport.minX), viewport.maxX) }

            let anchorY: CGFloat
            if rect.midY <= viewport.minY { anchorY = viewport.minY }
            else if rect.midY >= viewport.maxY { anchorY = viewport.maxY }
            else { anchorY = min(max(rect.midY, viewport.minY), viewport.maxY) }

            // How far the tile's center has travelled past the viewport edge.
            let distance = hypot(gapX, gapY)
            // Eased fade-in so the glow blooms from nothing as the tile leaves,
            // rather than popping the moment the center clears the edge.
            let t = min(1, distance / Self.fadeInDistance)
            let intensity = t * t * (3 - 2 * t)  // smoothstep
            guard intensity > 0.01,
                  let ctx = NSGraphicsContext.current?.cgContext else { continue }

            // A diffuse, even falloff (rather than a hard bright core) reads as
            // ambient light spilling past the edge.
            let core = color.withAlphaComponent(Self.fullAlpha * intensity)
            let mid = color.withAlphaComponent(Self.fullAlpha * intensity * 0.4)
            guard let gradient = NSGradient(
                colors: [core, mid, color.withAlphaComponent(0)],
                atLocations: [0, 0.45, 1], colorSpace: .sRGB
            ) else { continue }

            // Shape: along a single edge the glow is a column (side) or band
            // (top/bottom) that spans most of the edge when the tile has just
            // left, then contracts toward a small spot as it recedes — skinnier
            // and shorter the further away. Corners (off both axes) stay round.
            var baseRadius = Self.fullRadius * intensity
            var scaleX: CGFloat = 1, scaleY: CGFloat = 1
            let onVerticalEdge = gapX > 0 && gapY == 0
            let onHorizontalEdge = gapY > 0 && gapX == 0
            if onVerticalEdge || onHorizontalEdge {
                let edgeSpan = onVerticalEdge ? viewport.height : viewport.width
                let recede = min(1, distance / Self.shrinkDistance)
                let nearHalf = edgeSpan * Self.nearSpanFraction
                let alongHalf = (nearHalf + (Self.minAlongHalf - nearHalf) * recede) * intensity
                // Keep the inward bleed no deeper than the glow is long, so it
                // stays edge-hugging and flattens to a small spot when far.
                baseRadius = min(baseRadius, alongHalf * 0.85)
                let stretch = baseRadius > 0 ? alongHalf / baseRadius : 1
                if onVerticalEdge { scaleY = stretch } else { scaleX = stretch }
            }
            guard baseRadius > 0.5 else { continue }

            // The off-screen half is clipped away by our bounds, leaving the
            // inward-facing half of the glow.
            ctx.saveGState()
            ctx.translateBy(x: anchorX, y: anchorY)
            ctx.scaleBy(x: scaleX, y: scaleY)
            gradient.draw(
                fromCenter: .zero, radius: 0,
                toCenter: .zero, radius: baseRadius,
                options: .drawsBeforeStartingLocation
            )
            ctx.restoreGState()
        }
    }
}
