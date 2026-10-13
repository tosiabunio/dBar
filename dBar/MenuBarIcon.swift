import AppKit

/// The menu bar glyph: two LED-style level bars (L over R) echoing the meter in the popover.
/// It's a template image, so the menu bar tints it for light/dark mode; unlit segments are
/// drawn translucent rather than in a different colour.
enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static let segmentCount = 6
    private static let segmentWidth: CGFloat = 2
    private static let segmentGap: CGFloat = 1
    private static let barHeight: CGFloat = 5
    private static let barGap: CGFloat = 2
    /// Lit segments in the top (L) and bottom (R) bars.
    private static let litSegments = [4, 3]
    private static let unlitAlpha: CGFloat = 0.3

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let barsWidth = CGFloat(segmentCount) * segmentWidth + CGFloat(segmentCount - 1) * segmentGap
            let left = (size.width - barsWidth) / 2
            let top = (size.height - 2 * barHeight - barGap) / 2

            for (row, lit) in litSegments.enumerated() {
                let y = top + CGFloat(row) * (barHeight + barGap)
                for segment in 0..<segmentCount {
                    let x = left + CGFloat(segment) * (segmentWidth + segmentGap)
                    let rect = CGRect(x: x, y: y, width: segmentWidth, height: barHeight)
                    NSColor.black.withAlphaComponent(segment < lit ? 1 : unlitAlpha).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "dBar output level"
        return image
    }
}
