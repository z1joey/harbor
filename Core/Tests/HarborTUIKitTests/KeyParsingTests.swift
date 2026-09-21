import XCTest
@testable import HarborTUIKit

final class KeyParsingTests: XCTestCase {
    private func keys(_ bytes: [UInt8]) -> [Key] {
        var parser = KeyParser()
        return parser.feed(bytes)
    }

    func testPlainCharacters() {
        XCTAssertEqual(keys([UInt8(ascii: "a")]), [.char("a")])
        XCTAssertEqual(keys(Array("hi".utf8)), [.char("h"), .char("i")])
    }

    func testControlKeys() {
        XCTAssertEqual(keys([0x0D]), [.enter])
        XCTAssertEqual(keys([0x0A]), [.enter])
        XCTAssertEqual(keys([0x09]), [.tab])
        XCTAssertEqual(keys([0x7F]), [.backspace])
        XCTAssertEqual(keys([0x08]), [.backspace])
        XCTAssertEqual(keys([0x03]), [.ctrl("c")])
        XCTAssertEqual(keys([0x01]), [.ctrl("a")])
        XCTAssertEqual(keys([0x1A]), [.ctrl("z")])
    }

    func testEscapeAloneAndSequences() {
        XCTAssertEqual(keys([0x1B]), [.escape])
        XCTAssertEqual(keys(Array("\u{1B}[A".utf8)), [.up])
        XCTAssertEqual(keys(Array("\u{1B}[B".utf8)), [.down])
        XCTAssertEqual(keys(Array("\u{1B}[C".utf8)), [.right])
        XCTAssertEqual(keys(Array("\u{1B}[D".utf8)), [.left])
        XCTAssertEqual(keys(Array("\u{1B}OA".utf8)), [.up])
        XCTAssertEqual(keys(Array("\u{1B}[5~".utf8)), [.pageUp])
        XCTAssertEqual(keys(Array("\u{1B}[6~".utf8)), [.pageDown])
        XCTAssertEqual(keys(Array("\u{1B}[H".utf8)), [.home])
        XCTAssertEqual(keys(Array("\u{1B}[F".utf8)), [.end])
    }

    func testUnknownEscapeFallsBackToEscapeThenKey() {
        // ESC x — unknown prefix: Esc delivered, then "x" re-parsed.
        XCTAssertEqual(keys([0x1B, UInt8(ascii: "x")]), [.escape, .char("x")])
    }

    func testUnsupportedCompleteSequencesResyncOnEscape() {
        // Complete but unrecognized sequences (Forward Delete ESC[3~,
        // Insert ESC[2~, Shift+Tab ESC[Z) must not stall the parser: the
        // ESC is delivered and the tail reparsed as plain characters.
        XCTAssertEqual(keys(Array("\u{1B}[3~".utf8)), [.escape, .char("["), .char("3"), .char("~")])
        XCTAssertEqual(keys(Array("\u{1B}[2~".utf8)), [.escape, .char("["), .char("2"), .char("~")])
        XCTAssertEqual(keys(Array("\u{1B}[Z".utf8)), [.escape, .char("["), .char("Z")])
    }

    func testKeysAfterUnsupportedSequenceStillParse() {
        // Regression: an unsupported sequence used to buffer every later
        // keypress behind it forever — q and Ctrl+C included.
        var parser = KeyParser()
        _ = parser.feed(Array("\u{1B}[3~".utf8))
        XCTAssertEqual(parser.feed(Array("q".utf8)), [.char("q")])
        XCTAssertEqual(parser.feed([0x03]), [.ctrl("c")])
        XCTAssertEqual(parser.feed(Array("\u{1B}[A".utf8)), [.up])
    }

    func testMalformedEscapeEventuallyFlushes() {
        var parser = KeyParser()
        // ESC [ followed by non-CSI bytes: waits briefly, then flushes.
        var bytes: [UInt8] = [0x1B, 0x5B, 0x00]
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "q"), count: 40))
        XCTAssertFalse(parser.feed(bytes).isEmpty)
        // And the parser stays usable afterwards.
        XCTAssertEqual(parser.feed(Array("\u{1B}[A".utf8)), [.up])
    }

    func testSequenceSplitAcrossFeeds() {
        // Lone ESC at the end of a drained read is the Esc key (see parser policy).
        var parser = KeyParser()
        XCTAssertEqual(parser.feed([0x1B]), [.escape])
        XCTAssertEqual(parser.feed([0x5B]), [.char("[")])
        XCTAssertEqual(parser.feed([UInt8(ascii: "A")]), [.char("A")])
        // A two-plus byte prefix without its final waits for more bytes.
        var parser2 = KeyParser()
        XCTAssertTrue(parser2.feed([0x1B, 0x5B]).isEmpty)
        XCTAssertEqual(parser2.feed([UInt8(ascii: "A")]), [.up])
    }

    func testUTF8MultibyteCharacter() {
        XCTAssertEqual(keys(Array("中".utf8)), [.char("中")])
        var parser = KeyParser()
        let bytes = Array("中".utf8)
        XCTAssertTrue(parser.feed([bytes[0], bytes[1]]).isEmpty) // partial
        XCTAssertEqual(parser.feed([bytes[2]]), [.char("中")])
    }

    func testStrayContinuationByteIsDropped() {
        XCTAssertEqual(keys([0x80]), [.char("\u{FFFD}")])
    }
}
