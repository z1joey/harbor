import Foundation

/// A column definition: fixed display width and text alignment.
public struct TableColumn {
    public let title: String
    public let width: Int
    public let alignment: ColumnAlignment

    public init(title: String, width: Int, alignment: ColumnAlignment = .left) {
        self.title = title
        self.width = max(1, width)
        self.alignment = alignment
    }
}

/// One table row: pre-rendered cell strings plus an optional base style.
public struct TableRow {
    public var cells: [String]
    public var style: Style?

    public init(_ cells: [String], style: Style? = nil) {
        self.cells = cells
        self.style = style
    }
}

/// A scrollable table with a sticky header, width-aware cell padding and a
/// highlighted selection row. Pure value type — the panel owns the state and
/// maps domain data into rows before each repaint.
public struct TableView {
    public var columns: [TableColumn]
    public var rows: [TableRow]
    public var selectedRow: Int?
    public var topRow: Int = 0

    public init(columns: [TableColumn], rows: [TableRow] = []) {
        self.columns = columns
        self.rows = rows
        self.selectedRow = rows.isEmpty ? nil : 0
    }

    public mutating func select(_ index: Int?) {
        guard let index else {
            selectedRow = nil
            return
        }
        selectedRow = min(max(0, index), max(0, rows.count - 1))
    }

    /// Moves the selection by `delta`, clamped. Returns true when it moved.
    @discardableResult
    public mutating func moveSelection(_ delta: Int) -> Bool {
        guard !rows.isEmpty, let current = selectedRow else { return false }
        let next = min(max(0, current + delta), rows.count - 1)
        guard next != current else { return false }
        selectedRow = next
        return true
    }

    /// Adjusts `topRow` so the selection stays inside a `visibleRows` viewport.
    public mutating func ensureVisible(visibleRows: Int) {
        guard visibleRows > 0, let selected = selectedRow else { return }
        topRow = min(max(topRow, selected - visibleRows + 1), selected)
        topRow = min(max(0, topRow), max(0, rows.count - visibleRows))
    }

    public func render(into screen: inout Screen, rect: Rect) {
        guard rect.height >= 1, rect.width >= 1 else { return }
        let headerStyle = Style(bold: true, reverse: false)
        renderRow(columns.map(\.title), style: headerStyle, y: rect.y, screen: &screen, rect: rect)

        let visibleRows = rect.height - 1
        guard visibleRows > 0 else { return }
        let lastRow = min(topRow + visibleRows, rows.count)
        for index in topRow..<lastRow {
            let y = rect.y + 1 + (index - topRow)
            var style = rows[index].style ?? .plain
            if index == selectedRow {
                style = style + Style(reverse: true)
            }
            renderRow(rows[index].cells, style: style, y: y, screen: &screen, rect: rect)
        }
    }

    private func renderRow(_ cells: [String], style: Style, y: Int, screen: inout Screen, rect: Rect) {
        var x = rect.x
        for (index, column) in columns.enumerated() where x < rect.x + rect.width {
            let text = index < cells.count ? cells[index] : ""
            let clippedWidth = min(column.width, rect.x + rect.width - x)
            let padded = padToWidth(text, clippedWidth, alignment: column.alignment)
            screen.drawString(padded, x: x, y: y, style: style)
            x += column.width
        }
        if x < rect.x + rect.width {
            // Pad the remainder of the row so reverse-video selection spans the full width.
            let remaining = rect.x + rect.width - x
            screen.drawString(String(repeating: " ", count: remaining), x: x, y: y, style: style)
        }
    }
}
