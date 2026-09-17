import Foundation

/// A decoded keypress from stdin.
public enum Key: Equatable {
    case char(Character)
    case ctrl(Character)
    case enter
    case tab
    case backspace
    case escape
    case up, down, left, right
    case home, end
    case pageUp, pageDown
}

/// Incremental decoder: feed raw stdin bytes, get keys out. Partial escape
/// sequences are kept across feeds because reads can split them mid-way.
///
/// Policy for the ambiguous lone `ESC` byte (Esc key vs. a split sequence):
/// if a drained read ends exactly at `ESC`, it is emitted as `.escape`
/// immediately. Terminals send arrow/function sequences in a single write, so
/// a genuine split across two reads is rare; no timeout machinery needed.
public struct KeyParser {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [Key] {
        feed([UInt8](data))
    }

    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        buffer.append(contentsOf: bytes)
        var keys: [Key] = []
        while let (key, consumed) = parseOne() {
            buffer.removeFirst(consumed)
            keys.append(key)
        }
        return keys
    }

    /// Next key plus the bytes it consumed; nil when the buffer holds nothing
    /// complete yet. A lone `ESC` with nothing behind it decodes as .escape.
    private func parseOne() -> (Key, Int)? {
        guard let b = buffer.first else { return nil }
        switch b {
        case 0x1B:
            return parseEscape()
        case 0x0D, 0x0A:
            return (.enter, 1)
        case 0x09:
            return (.tab, 1)
        case 0x7F, 0x08:
            return (.backspace, 1)
        case 0x00:
            return (.ctrl("@"), 1)
        case 1...26:
            return (.ctrl(Character(UnicodeScalar(b + 0x60))), 1)
        case 0x1C...0x1F:
            return (.ctrl(Character(UnicodeScalar(b + 0x40))), 1)
        default:
            return parseUTF8()
        }
    }

    private func parseEscape() -> (Key, Int)? {
        if buffer.count == 1 { return (.escape, 1) }
        guard buffer[1] == UInt8(ascii: "[") || buffer[1] == UInt8(ascii: "O") else {
            // Not a known sequence prefix (e.g. alt+key): emit Esc, reparse the rest.
            return (.escape, 1)
        }
        if buffer.count >= 3, let key = Self.finalTable[String(decoding: buffer[0..<3], as: UTF8.self)] {
            return (key, 3)
        }
        if let tilde = buffer.firstIndex(of: UInt8(ascii: "~")), tilde >= 2, tilde <= 4 {
            let sequence = String(decoding: buffer[0...tilde], as: UTF8.self)
            if let key = Self.tildeTable[sequence] { return (key, tilde + 1) }
        }
        // Incomplete (or unsupported) sequence: wait for more bytes.
        return nil
    }

    private func parseUTF8() -> (Key, Int)? {
        let b = buffer[0]
        let length: Int
        if b < 0x80 { length = 1 }
        else if b >= 0xC0, b < 0xE0 { length = 2 }
        else if b >= 0xE0, b < 0xF0 { length = 3 }
        else if b >= 0xF0, b < 0xF8 { length = 4 }
        else { return (.char("\u{FFFD}"), 1) } // stray continuation byte: drop
        guard buffer.count >= length else { return nil }
        let text = String(decoding: buffer[0..<length], as: UTF8.self)
        guard let ch = text.first else { return (.char("\u{FFFD}"), length) }
        return (.char(ch), length)
    }

    private static let finalTable: [String: Key] = [
        "\u{1B}[A": .up, "\u{1B}[B": .down, "\u{1B}[C": .right, "\u{1B}[D": .left,
        "\u{1B}OA": .up, "\u{1B}OB": .down, "\u{1B}OC": .right, "\u{1B}OD": .left,
        "\u{1B}[H": .home, "\u{1B}[F": .end,
    ]

    private static let tildeTable: [String: Key] = [
        "\u{1B}[1~": .home, "\u{1B}[4~": .end, "\u{1B}[5~": .pageUp, "\u{1B}[6~": .pageDown,
    ]
}

/// macOS `wcwidth(3)` is locale-driven: in the "C" locale every non-ASCII
/// scalar reports unprintable. The TUI always emits UTF-8 bytes, so bootstrap
/// a UTF-8 LC_CTYPE once before measuring.
private let widthLocaleBootstrap: Void = {
    if setlocale(LC_CTYPE, "en_US.UTF-8") == nil {
        setlocale(LC_CTYPE, "")
    }
}()

/// Display width of a scalar in terminal cells (wcwidth(3)). Unprintable
/// scalars report width 1; `Screen.drawString` substitutes them with "?".
public func cellWidth(of scalar: Unicode.Scalar) -> Int {
    _ = widthLocaleBootstrap
    let result = Int(wcwidth(wchar_t(scalar.value)))
    return result < 0 ? 1 : result
}

public func stringWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { $0 + cellWidth(of: $1) }
}

func isPrintable(_ ch: Character) -> Bool {
    ch.unicodeScalars.allSatisfy { wcwidth(wchar_t($0.value)) >= 0 }
}

/// Pads or truncates to an exact display width (width-aware, never splits a
/// double-width glyph).
public func padToWidth(_ text: String, _ width: Int, alignment: ColumnAlignment = .left) -> String {
    let w = stringWidth(text)
    if w > width { return truncatedToWidth(text, width) }
    let padding = String(repeating: " ", count: width - w)
    switch alignment {
    case .left: return text + padding
    case .right: return padding + text
    }
}

public func truncatedToWidth(_ text: String, _ maxWidth: Int) -> String {
    var result = ""
    var used = 0
    for ch in text {
        let w = stringWidth(String(ch))
        if used + w > maxWidth { break }
        result.append(ch)
        used += w
    }
    return result
}
