import XCTest
@testable import HarborTUIKit

final class WidgetTests: XCTestCase {
    // MARK: - TableView

    private func makeTable(rows: Int) -> TableView {
        var table = TableView(columns: [
            TableColumn(title: "NAME", width: 6),
            TableColumn(title: "PORT", width: 5, alignment: .right),
        ])
        table.rows = (0..<rows).map { TableRow(["p\($0)", String($0)]) }
        return table
    }

    func testTableSelectionClampsAndMoves() {
        var table = makeTable(rows: 3)
        table.select(10)
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertTrue(table.moveSelection(-1))
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(table.moveSelection(5))
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertFalse(table.moveSelection(1)) // already at end
    }

    func testTableEnsureVisibleScrollsWindow() {
        var table = makeTable(rows: 10)
        table.select(7)
        table.ensureVisible(visibleRows: 5)
        // Viewport shows 7...11 clamped to rows 5...9: topRow must be >= 3.
        XCTAssertGreaterThanOrEqual(table.topRow, 3)
        table.select(0)
        table.ensureVisible(visibleRows: 5)
        XCTAssertEqual(table.topRow, 0)
    }

    func testTableRendersHeaderSelectionAndScroll() {
        var table = makeTable(rows: 6)
        table.select(2)
        var screen = Screen(width: 20, height: 4) // header + 3 rows
        table.render(into: &screen, rect: Rect(x: 0, y: 0, width: 20, height: 4))
        func rowText(_ y: Int) -> String { String((0..<20).map { screen[$0, y].ch }) }
        XCTAssertTrue(rowText(0).contains("NAME"))
        XCTAssertTrue(rowText(0).contains("PORT"))
        // Rows 0,1,2 visible; row 2 selected (reverse video).
        XCTAssertTrue(screen[0, 3].style.reverse || rowText(3).contains("p2"))
        // Row 3 ("p3") must not be on screen.
        XCTAssertFalse(rowText(2).contains("p3"))
    }

    func testTableRightAlignsNumericColumn() {
        var table = makeTable(rows: 1)
        var screen = Screen(width: 12, height: 2)
        table.render(into: &screen, rect: Rect(x: 0, y: 0, width: 12, height: 2))
        // PORT column is 5 wide, right aligned: row cell "0" sits at column 10.
        XCTAssertEqual(screen[10, 1].ch, "0")
    }

    // MARK: - LogView

    func testLogFollowShowsTail() {
        var log = LogView()
        log.setLines((0..<100).map { "line \($0)" })
        let range = log.visibleRange(viewport: 10)
        XCTAssertEqual(range.lowerBound, 90)
        XCTAssertEqual(range.upperBound, 100)
    }

    func testLogScrollUpPausesAndBackResumes() {
        var log = LogView()
        log.setLines((0..<100).map { "line \($0)" })
        log.scrollUp(5)
        XCTAssertFalse(log.follow)
        XCTAssertEqual(log.visibleRange(viewport: 10).upperBound, 95)
        log.scrollDown(10) // over-scroll clamps
        XCTAssertTrue(log.follow)
        XCTAssertEqual(log.visibleRange(viewport: 10).upperBound, 100)
    }

    func testLogRendersClippedLines() {
        var log = LogView()
        log.setLines(["short", String(repeating: "x", count: 50)])
        var screen = Screen(width: 10, height: 2)
        log.render(into: &screen, rect: Rect(x: 0, y: 0, width: 10, height: 2))
        XCTAssertEqual(String((0..<10).map { screen[$0, 0].ch }), "short     ")
        XCTAssertEqual(String((0..<10).map { screen[$0, 1].ch }), String(repeating: "x", count: 10))
    }

    // MARK: - CommandBar

    func testCommandBarEditing() {
        var bar = CommandBar()
        bar.insert("a")
        bar.insert("b")
        bar.insert("中")
        XCTAssertEqual(bar.input, "ab中")
        XCTAssertEqual(bar.cursorIndex, 3)
        bar.moveLeft()
        bar.backspace() // deletes 'b'
        XCTAssertEqual(bar.input, "a中")
        XCTAssertEqual(bar.cursorIndex, 1)
        bar.moveLeft()
        bar.moveLeft() // clamps at 0
        XCTAssertEqual(bar.cursorIndex, 0)
        bar.reset()
        XCTAssertTrue(bar.input.isEmpty)
    }

    // MARK: - Bars

    func testStatusBarJoinsSegments() {
        let bar = StatusBar(left: "running 2", right: "q quit")
        var screen = Screen(width: 20, height: 1)
        bar.render(into: &screen, y: 0)
        let text = String((0..<20).map { screen[$0, 0].ch })
        XCTAssertTrue(text.hasPrefix("running 2"))
        XCTAssertTrue(text.hasPrefix("running 2  q quit")) // row tail is blank padding
        XCTAssertTrue(screen[0, 0].style.reverse)
    }

    func testConfirmBarRendersOptions() {
        let bar = ConfirmBar(message: "Kill 8080?", options: [.init(key: "y", label: "kill"), .init(key: "n", label: "cancel")])
        XCTAssertEqual(bar.renderedText, "Kill 8080?  [y] kill  [n] cancel")
    }
}
