import XCTest
@testable import HarborCore

/// The registry is read-only: `~/.harbor/projects.json` is owned by the
/// harbor-toml skill (or hand edits); Harbor only reads and watches it.
@MainActor
final class ProjectRegistryTests: XCTestCase {
    private var storeDirectory: URL!
    private var storeURL: URL!
    private var projectRoot: URL!

    override func setUp() async throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-registry-\(UUID().uuidString)", isDirectory: true)
        storeURL = storeDirectory.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-registry-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try """
        name = "registry-fixture"

        [[process]]
        name = "api"
        command = "sleep 1"
        port = 8001
        """.write(to: projectRoot.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: projectRoot)
    }

    /// Writes the store the way the skill does: tmp file + rename.
    private func writeStore(_ paths: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(paths).write(to: storeURL, options: .atomic)
    }

    func testLoadReadsRegisteredRoots() throws {
        try writeStore([projectRoot.path])

        let registry = ProjectRegistry(storeURL: storeURL)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(project.id, projectRoot.path)
        XCTAssertEqual(project.name, "registry-fixture")
        XCTAssertEqual(project.processes.first?.name, "api")
    }

    func testRelaunchRestoresProjects() throws {
        try writeStore([projectRoot.path])
        _ = ProjectRegistry(storeURL: storeURL)

        // A fresh instance (simulated relaunch) reads the same store.
        let second = ProjectRegistry(storeURL: storeURL)
        XCTAssertEqual(second.projects.count, 1)
        XCTAssertEqual(second.projects.first?.root.path, projectRoot.path)
        XCTAssertEqual(second.projects.first?.processes.first?.name, "api")
    }

    func testLoadDoesNotRewriteStore() throws {
        try writeStore([projectRoot.path])
        let before = try Data(contentsOf: storeURL)

        _ = ProjectRegistry(storeURL: storeURL)

        let after = try Data(contentsOf: storeURL)
        XCTAssertEqual(before, after, "the registry must never rewrite the skill-owned store")
    }

    func testLoadNormalizesLegacyTrailingSlashPathsInMemory() throws {
        try writeStore([projectRoot.path + "/"])

        let registry = ProjectRegistry(storeURL: storeURL)
        XCTAssertEqual(registry.projects.first?.id, projectRoot.path)
    }

    func testMissingStoreMeansNoProjects() throws {
        let registry = ProjectRegistry(storeURL: storeURL)
        XCTAssertTrue(registry.projects.isEmpty)
    }

    func testInvalidConfigListsProjectWithVisibleError() throws {
        let brokenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: brokenRoot) }
        try "name = [broken".write(to: brokenRoot.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)
        try writeStore([brokenRoot.path])

        let registry = ProjectRegistry(storeURL: storeURL)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertNotNil(project.configError)
        XCTAssertTrue(project.processes.isEmpty)
    }

    func testRootWithoutConfigListsProjectWithError() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try writeStore([emptyRoot.path])

        let registry = ProjectRegistry(storeURL: storeURL)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertNotNil(project.configError)
        XCTAssertTrue(project.processes.isEmpty)
    }

    /// The skill may register projects while Harbor runs: the store is
    /// replaced atomically and the directory watcher must reload it live.
    func testWatcherPicksUpSkillStoreRewrite() throws {
        try writeStore([projectRoot.path])
        let registry = ProjectRegistry(storeURL: storeURL)
        XCTAssertEqual(registry.projects.count, 1)

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try """
        name = "late-arrival"

        [[process]]
        name = "web"
        command = "sleep 1"
        port = 8002
        """.write(to: otherRoot.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)

        // Rewrite the store the way the skill does — atomic replace.
        try writeStore([projectRoot.path, otherRoot.path])

        // The watcher debounces 0.4s; pump the run loop until it lands.
        let deadline = Date().addingTimeInterval(5)
        while registry.projects.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(registry.projects.count, 2)
        XCTAssertEqual(registry.projects.last?.name, "late-arrival")
    }
}
