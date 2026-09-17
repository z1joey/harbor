import Foundation
import Darwin

/// ANSI-16 palette; `nil` styles keep the terminal default.
public enum Color: Int, Equatable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack = 8, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
}

public struct Style: Equatable {
    public var fg: Color?
    public var bg: Color?
    public var bold: Bool
    public var reverse: Bool

    public init(fg: Color? = nil, bg: Color? = nil, bold: Bool = false, reverse: Bool = false) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.reverse = reverse
    }

    public static let plain = Style()

    /// Overlay: non-nil / set attributes of `overlay` win.
    public static func + (base: Style, overlay: Style) -> Style {
        Style(fg: overlay.fg ?? base.fg,
              bg: overlay.bg ?? base.bg,
              bold: overlay.bold || base.bold,
              reverse: overlay.reverse || base.reverse)
    }

    /// Full SGR sequence setting this style from a clean slate.
    public var sgr: String {
        var parts: [String] = []
        if bold { parts.append("1") }
        if reverse { parts.append("7") }
        if let fg { parts.append(String(30 + fg.rawValue)) }
        if let bg { parts.append(String(40 + bg.rawValue)) }
        if parts.isEmpty { return "\u{1B}[0m" }
        return "\u{1B}[0;" + parts.joined(separator: ";") + "m"
    }
}

/// One terminal cell. A double-width glyph occupies two cells: the leading
/// cell has `wide == true`, the trailing cell holds `wideTrailChar` and is
/// skipped by the diff encoder (the glyph's advance covers it).
public struct Cell: Equatable {
    public var ch: Character
    public var style: Style
    public var wide: Bool

    public static let wideTrailChar: Character = "\u{FFFE}"
    public static let blank = Cell(ch: " ", style: .plain, wide: false)

    public init(ch: Character, style: Style, wide: Bool = false) {
        self.ch = ch
        self.style = style
        self.wide = wide
    }
}

/// Column alignment shared by widgets that pad to a display width.
public enum ColumnAlignment: Equatable {
    case left
    case right
}

/// A rectangular cell grid with width-aware string drawing.
public struct Screen {
    public private(set) var width: Int
    public private(set) var height: Int
    private var cells: [Cell]

    public init(width: Int = 80, height: Int = 24) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: Cell.blank, count: self.width * self.height)
    }

    public mutating func resize(width newWidth: Int, height newHeight: Int) {
        guard newWidth != width || newHeight != height else { return }
        self = Screen(width: newWidth, height: newHeight)
    }

    public mutating func clear() {
        cells = Array(repeating: Cell.blank, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Cell {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "cell out of bounds")
            return cells[y * width + x]
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "cell out of bounds")
            cells[y * width + x] = newValue
        }
    }

    /// Draws text left-to-right starting at (`x`, `y`), clipped at the right
    /// edge. Unprintable characters render as "?".
    public mutating func drawString(_ text: String, x: Int, y: Int, style: Style = .plain) {
        guard y >= 0, y < height else { return }
        var cursor = x
        for ch in text {
            let w = stringWidth(String(ch))
            guard w >= 1 else { continue } // zero-width: skip
            guard cursor + w <= width else { break }
            guard cursor >= 0 else { cursor += w; continue }
            let printable = isPrintable(ch) ? ch : "?"
            self[cursor, y] = Cell(ch: printable, style: style, wide: w == 2)
            cursor += 1
            if w == 2, cursor < width {
                self[cursor, y] = Cell(ch: Cell.wideTrailChar, style: style, wide: false)
                cursor += 1
            }
        }
    }

    /// Overwrites a whole row with `style` (then optional text on top).
    public mutating func fillRow(_ y: Int, style: Style, text: String = "", x: Int = 0) {
        guard y >= 0, y < height else { return }
        for x in 0..<width {
            self[x, y] = Cell(ch: " ", style: style, wide: false)
        }
        guard !text.isEmpty else { return }
        drawString(text, x: x, y: y, style: style)
    }

    /// Minimal byte stream that turns `previous` into `self`. nil previous or
    /// a size mismatch emits a full-screen clear plus every cell.
    public func encodeChanges(previous: Screen?) -> [UInt8] {
        var out: [UInt8] = []
        let fullRepaint = previous == nil || previous!.width != width || previous!.height != height
        if fullRepaint {
            out.append(contentsOf: Array("\u{1B}[2J".utf8))
        }
        var cursorX = -1
        var cursorY = -1
        var currentStyle: Style?
        for y in 0..<height {
            var x = 0
            while x < width {
                let cell = self[x, y]
                if cell.ch == Cell.wideTrailChar { x += 1; continue }
                if !fullRepaint, let prev = previous, prev[x, y] == cell {
                    x += 1
                    continue
                }
                if cursorX != x || cursorY != y {
                    out.append(contentsOf: Array("\u{1B}[\(y + 1);\(x + 1)H".utf8))
                }
                if currentStyle != cell.style {
                    out.append(contentsOf: Array(cell.style.sgr.utf8))
                    currentStyle = cell.style
                }
                out.append(contentsOf: Array(String(cell.ch).utf8))
                cursorX = x + (cell.wide ? 2 : 1)
                cursorY = y
                x += cell.wide ? 2 : 1
            }
        }
        if currentStyle != nil {
            out.append(contentsOf: Array("\u{1B}[0m".utf8))
        }
        return out
    }
}
