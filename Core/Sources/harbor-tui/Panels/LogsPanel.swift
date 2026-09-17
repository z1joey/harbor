import Foundation
import HarborCore
import HarborTUIKit

/// Logs panel: tail view of the focused process's ring buffer.
struct LogsPanel {
    var focused: ProcessKey?
    var view = LogView()

    /// Called by TuiApp on each repaint with the focused buffer's snapshot
    /// (the struct itself stays free of MainActor-isolated calls).
    mutating func refresh(lines: [String]) {
        view.setLines(lines)
    }

    func render(into screen: inout Screen, rect: Rect, label: String) {
        guard rect.height >= 2 else { return }
        let followBadge = view.follow ? "follow: on" : "follow: off"
        let header = truncatedToWidth("logs — \(label)   [f] \(followBadge)  [c] clear  [↑↓/PgUp/PgDn] scroll",
                                      rect.width)
        screen.drawString(header, x: rect.x, y: rect.y, style: Style(fg: .brightBlack))
        view.render(into: &screen, rect: Rect(x: rect.x, y: rect.y + 1, width: rect.width, height: rect.height - 1))
    }
}
