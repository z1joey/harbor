import XCTest
@testable import HarborCore

final class PortPoolTests: XCTestCase {
    func testDefaultPoolIs8100To8199() {
        XCTAssertEqual(PortPool.default.ranges, [PortRange(from: 8100, to: 8199)])
        XCTAssertEqual(PortPool.default.capacity, 100)
        XCTAssertTrue(PortPool.default.contains(8100))
        XCTAssertTrue(PortPool.default.contains(8199))
        XCTAssertFalse(PortPool.default.contains(8200))
        XCTAssertEqual(PortPool.default.summary, "8100–8199")
    }

    func testValidateRejectsEmptyInvertedOutOfRangeAndOverlapping() {
        XCTAssertThrowsError(try PortPool.validate(PortPool(ranges: [])))
        XCTAssertThrowsError(try PortPool.validate(PortPool(ranges: [PortRange(from: 8200, to: 8100)])))
        XCTAssertThrowsError(try PortPool.validate(PortPool(ranges: [PortRange(from: 0, to: 10)])))
        XCTAssertThrowsError(try PortPool.validate(PortPool(ranges: [PortRange(from: 1, to: 70000)])))
        XCTAssertThrowsError(try PortPool.validate(PortPool(ranges: [
            PortRange(from: 8100, to: 8150),
            PortRange(from: 8150, to: 8199),
        ])))
        XCTAssertNoThrow(try PortPool.validate(PortPool(ranges: [
            PortRange(from: 8100, to: 8149),
            PortRange(from: 8150, to: 8199),
        ])))
    }

    func testSummaryJoinsMultipleRanges() {
        let pool = PortPool(ranges: [PortRange(from: 8100, to: 8199), PortRange(from: 9000, to: 9009)])
        XCTAssertEqual(pool.summary, "8100–8199, 9000–9009")
        XCTAssertEqual(pool.capacity, 110)
    }
}

@MainActor
final class PortPoolStoreTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-pool-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("port-pool.json")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    func testMissingFileUsesDefaultWithoutWriting() {
        let store = PortPoolStore(storeURL: storeURL)
        XCTAssertEqual(store.pool, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testSaveRoundTripsAndRejectsInvalid() throws {
        let store = PortPoolStore(storeURL: storeURL)
        let pool = PortPool(ranges: [PortRange(from: 9000, to: 9009)])
        try store.save(pool)
        XCTAssertEqual(store.pool, pool)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let reloaded = PortPoolStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.pool, pool)

        XCTAssertThrowsError(try store.save(PortPool(ranges: [PortRange(from: 20, to: 10)])))
        XCTAssertEqual(store.pool, pool, "failed save must not clobber the last valid pool")
    }

    func testInvalidFileFallsBackToDefault() throws {
        try Data("{not json".utf8).write(to: storeURL)
        let store = PortPoolStore(storeURL: storeURL)
        XCTAssertEqual(store.pool, .default)
    }

    func testInvalidRangesOnDiskFallBackToDefault() throws {
        let data = try JSONEncoder().encode(PortPool(ranges: [PortRange(from: 50, to: 10)]))
        try data.write(to: storeURL)
        let store = PortPoolStore(storeURL: storeURL)
        XCTAssertEqual(store.pool, .default)
    }
}
