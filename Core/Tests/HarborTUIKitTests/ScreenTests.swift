import XCTest
@testable import HarborTUIKit

final class ScreenTests: XCTestCase {
    // MARK: - Width helpers

    func testCellWidths() {
        XCTAssertEqual(stringWidth("a"), 1)
        XCTAssertEqual(stringWidth("中"), 2)
        XCTAssertEqual(stringWidth("a中b"), 4)
        XCTAssertEqual(stringWidth(""), 0)
    }

    func testPadAndTruncate() {
        XCTAssertEqual(padToWidth("ab", 4), "ab  ")
        XCTAssertEqual(padToWidth("ab", 4, alignment: .right), "  ab")
        XCTAssertEqual(padToWidth("中", 3), "中 ")
        XCTAssertEqual(truncatedToWidth("abcde", 3), "abc")
        XCTAssertEqual(truncatedToWidth("中中", 3), "中")
    }

    // MARK: - Drawing

    func testDrawStringPlacesCellsAndTruncates() {
        var screen = Screen(width: 4, height: 2)
        screen.drawString("abcdef", x: 0, y: 0)
        XCTAssertEqual(String([screen[0, 0].ch, screen[1, 0].ch, screen[2, 0].ch, screen[3, 0].ch]), "abcd")
    }

    func testDrawWideCharacterMarksTrailingCell() {
        var screen = Screen(width: 4, height: 1)
        screen.drawString("中x", x: 0, y: 0)
        XCTAssertEqual(screen[0, 0].ch, "中")
        XCTAssertTrue(screen[0, 0].wide)
        XCTAssertEqual(screen[1, 0].ch, Cell.wideTrailChar)
        XCTAssertEqual(screen[2, 0].ch, "x")
    }

    func testUnprintableBecomesQuestionMark() {
        var screen = Screen(width: 4, height: 1)
        screen.drawString("\u{01}", x: 0, y: 0)
        XCTAssertEqual(screen[0, 0].ch, "?")
    }

    func testDrawClipsWideCharacterAtEdge() {
        var screen = Screen(width: 3, height: 1)
        screen.drawString("a中", x: 0, y: 0) // 中 needs columns 1-2, fits exactly
        XCTAssertEqual(screen[1, 0].ch, "中")
        screen = Screen(width: 2, height: 1)
        screen.drawString("a中", x: 0, y: 0) // 中 would overflow: clipped
        XCTAssertEqual(screen[1, 0].ch, " ")
    }

    // MARK: - Diff encoding

    private func text(_ screen: Screen) -> String {
        String(decoding: screen.encodeChanges(previous: nil), as: UTF8.self)
    }

    func testFirstFrameEmitsClearAndContent() {
        var screen = Screen(width: 4, height: 1)
        screen.drawString("hi", x: 0, y: 0)
        let output = text(screen)
        XCTAssertTrue(output.contains("\u{1B}[2J"))
        XCTAssertTrue(output.contains("\u{1B}[1;1H"))
        XCTAssertTrue(output.contains("hi"))
    }

    func testSecondFrameWithNoChangeIsEmpty() {
        var screen = Screen(width: 4, height: 1)
        screen.drawString("hi", x: 0, y: 0)
        let first = screen.encodeChanges(previous: nil)
        let second = screen.encodeChanges(previous: screen)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    func testChangeProducesMinimalUpdate() {
        var screen = Screen(width: 10, height: 1)
        screen.drawString("hello", x: 0, y: 0)
        _ = screen.encodeChanges(previous: nil)
        let before = screen // value-type snapshot of the last presented frame
        screen.drawString("j", x: 1, y: 0)
        let output = String(decoding: screen.encodeChanges(previous: before), as: UTF8.self)
        XCTAssertTrue(output.contains("\u{1B}[1;2H"))
        XCTAssertTrue(output.contains("j"))
        XCTAssertFalse(output.contains("hello"))
    }

    func testStyleChangeEmitsSGR() {
        var screen = Screen(width: 10, height: 1)
        screen.drawString("a", x: 0, y: 0, style: Style(fg: .red, bold: true))
        let output = text(screen)
        XCTAssertTrue(output.contains("\u{1B}[0;31m".replacingOccurrences(of: "[0;", with: "[0;")) || output.contains("\u{1B}[0;1;31m"))
        XCTAssertTrue(output.contains("\u{1B}[0m"))
    }
}
