import Foundation

/// A scrolling log tail. Follow mode pins the view to the newest lines;
/// scrolling up pauses it, scrolling back to the bottom resumes.
public struct LogView {
    public var lines: [String] = []
    public var follow = true
    /// Lines hidden above the viewport while `follow == false`.
    public var scrollFromBottom = 0

    public init() {}

    public mutating func setLines(_ lines: [String]) {
        self.lines = lines
        clampScroll()
    }

    public mutating func toBottom() {
        follow = true
        scrollFromBottom = 0
    }

    /// Returns true when follow mode changed (used to refresh the follow badge).
    @discardableResult
    public mutating func scrollUp(_ amount: Int = 1) -> Bool {
        follow = false
        scrollFromBottom = min(scrollFromBottom + amount, max(0, lines.count - 1))
        return true
    }

    @discardableResult
    public mutating func scrollDown(_ amount: Int = 1) -> Bool {
        guard !follow else { return false }
        scrollFromBottom = max(0, scrollFromBottom - amount)
        if scrollFromBottom == 0 { follow = true }
        return true
    }

    /// Index range of `lines` visible in a `viewport`-tall window.
    public func visibleRange(viewport: Int) -> Range<Int> {
        guard viewport > 0 else { return 0..<0 }
        let hidden = follow ? 0 : scrollFromBottom
        let end = max(0, lines.count - hidden)
        let start = max(0, end - viewport)
        return start..<end
    }

    public func render(into screen: inout Screen, rect: Rect) {
        guard rect.height >= 1 else { return }
        for y in rect.y..<rect.bottom {
            screen.fillRow(y, style: .plain)
        }
        let range = visibleRange(viewport: rect.height)
        for (offset, index) in range.enumerated() {
            let line = truncatedToWidth(lines[index], rect.width)
            screen.drawString(line, x: rect.x, y: rect.y + offset)
        }
    }

    private mutating func clampScroll() {
        scrollFromBottom = min(scrollFromBottom, max(0, lines.count - 1))
    }
}
