import XCTest
@testable import HarborCore

final class LogBufferTests: XCTestCase {
    func testAppendAndSnapshotOrder() {
        let buffer = LogBuffer()
        buffer.appendLine("first")
        buffer.appendLine("second\r") // trailing CR stripped
        XCTAssertEqual(buffer.snapshot(), ["first", "second"])
    }

    func testRingBufferTrimsToCapacity() {
        let buffer = LogBuffer(capacity: 5)
        for index in 0..<12 {
            buffer.appendLine("line-\(index)")
        }
        let lines = buffer.snapshot()
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first, "line-7")
        XCTAssertEqual(lines.last, "line-11")
        XCTAssertEqual(buffer.droppedLineCount, 7)
    }

    func testClearResetsState() {
        let buffer = LogBuffer()
        buffer.appendLine("something")
        buffer.clear()
        XCTAssertTrue(buffer.snapshot().isEmpty)
        XCTAssertEqual(buffer.droppedLineCount, 0)
    }

    func testAppendFromMultipleThreadsKeepsAllLines() async {
        let buffer = LogBuffer(capacity: 5_000)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for index in 0..<1_000 {
                        buffer.appendLine("w\(worker)-\(index)")
                    }
                }
            }
        }
        XCTAssertEqual(buffer.snapshot().count, 4_000)
    }
}
