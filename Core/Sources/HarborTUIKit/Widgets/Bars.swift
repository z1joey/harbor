import Foundation

/// Full-width status line: left and right segments joined with spaces.
public struct StatusBar {
    public var left: String
    public var right: String
    public var style: Style

    public init(left: String = "", right: String = "", style: Style = Style(reverse: true)) {
        self.left = left
        self.right = right
        self.style = style
    }

    public func render(into screen: inout Screen, y: Int) {
        guard screen.height > y else { return }
        let rightPadded = right.isEmpty ? "" : "  " + right
        let available = screen.width - stringWidth(rightPadded)
        let line = truncatedToWidth(left, max(0, available)) + rightPadded
        screen.fillRow(y, style: style, text: line)
    }
}

/// Inline confirmation prompt rendered above the status bar:
/// message followed by bracketed key options ("[y] yes  [n] no").
public struct ConfirmBar {
    public struct Option {
        public var key: Character
        public var label: String

        public init(key: Character, label: String) {
            self.key = key
            self.label = label
        }
    }

    public var message: String
    public var options: [Option]
    public var style: Style

    public init(message: String, options: [Option], style: Style = Style(fg: .yellow)) {
        self.message = message
        self.options = options
        self.style = style
    }

    public var renderedText: String {
        let options = options.map { "[\($0.key)] \($0.label)" }.joined(separator: "  ")
        let joined = message.isEmpty ? options : message + "  " + options
        return truncatedToWidth(joined, 500)
    }

    public func render(into screen: inout Screen, y: Int) {
        guard screen.height > y else { return }
        screen.fillRow(y, style: style, text: truncatedToWidth(renderedText, screen.width))
    }
}

/// One-line `:command` input with a block cursor.
public struct CommandBar {
    public var prompt: String = ":"
    public var input: String = ""
    public var cursorIndex: Int = 0 // character offset into input

    public init(prompt: String = ":") {
        self.prompt = prompt
    }

    public mutating func insert(_ ch: Character) {
        let index = input.index(input.startIndex, offsetBy: min(cursorIndex, input.count))
        input.insert(ch, at: index)
        cursorIndex += 1
    }

    public mutating func backspace() {
        guard cursorIndex > 0 else { return }
        let index = input.index(input.startIndex, offsetBy: cursorIndex - 1)
        input.remove(at: index)
        cursorIndex -= 1
    }

    public mutating func moveLeft() { cursorIndex = max(0, cursorIndex - 1) }
    public mutating func moveRight() { cursorIndex = min(input.count, cursorIndex + 1) }

    public mutating func reset() {
        input = ""
        cursorIndex = 0
    }

    public func render(into screen: inout Screen, y: Int) {
        guard screen.height > y else { return }
        screen.fillRow(y, style: .plain, text: prompt + input)
        // Block cursor: reversed glyph under the caret, or a reversed space at the end.
        let cursorX = stringWidth(prompt) + stringWidth(String(input.prefix(cursorIndex)))
        let underCursor: Character
        if cursorIndex < input.count {
            underCursor = input[input.index(input.startIndex, offsetBy: cursorIndex)]
        } else {
            underCursor = " "
        }
        screen.drawString(String(underCursor), x: cursorX, y: y, style: Style(reverse: true))
    }
}
