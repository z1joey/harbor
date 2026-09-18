import XCTest
@testable import HarborCore

final class HarborStoreLocationTests: XCTestCase {
    private var legacy: URL!
    private var target: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-store-\(UUID().uuidString)", isDirectory: true)
        legacy = base.appendingPathComponent("legacy", isDirectory: true)
        target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent())
    }

    private func touch(_ path: String, in directory: URL, contents: String = "{}") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testMigrationMovesStoresAndCleansLegacyDirectory() throws {
        try touch("projects.json", in: legacy, contents: "[\"/tmp/a\"]")
        try touch("port-pool.json", in: legacy, contents: "{\"ranges\":[{\"from\":8200,\"to\":8299}]}")
        try touch("projects.json.lock", in: legacy, contents: "")
        try touch("port-pool.json.lock", in: legacy, contents: "")

        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("projects.json").path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("port-pool.json"), encoding: .utf8),
                       "{\"ranges\":[{\"from\":8200,\"to\":8299}]}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "empty legacy dir is removed")
    }

    func testExistingTargetFileWins() throws {
        try touch("projects.json", in: legacy, contents: "[\"/legacy\"]")
        try touch("projects.json", in: target, contents: "[\"/fresh\"]")

        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("projects.json"), encoding: .utf8),
                       "[\"/fresh\"]")
    }

    func testNoLegacyDirectoryIsANoOpButTargetIsCreated() throws {
        try? FileManager.default.removeItem(at: legacy)

        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("projects.json").path))
    }

    func testLegacyDirectoryWithUnknownFilesIsKept() throws {
        try touch("projects.json", in: legacy, contents: "[\"/a\"]")
        try touch("unrelated.txt", in: legacy)

        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("unrelated.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("projects.json").path))
    }

    func testDefaultURLsPointAtHarborHomeDirectory() {
        XCTAssertEqual(HarborStoreLocation.harborDirectory.path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".harbor").path)
        XCTAssertEqual(HarborStoreLocation.projectsURL.lastPathComponent, "projects.json")
        XCTAssertEqual(HarborStoreLocation.portPoolURL.lastPathComponent, "port-pool.json")
    }
}
