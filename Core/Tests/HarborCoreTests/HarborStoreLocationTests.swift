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

    // MARK: - migration marker (TCC: never re-probe the App Support domain)

    func testFirstPassWritesMarkerAndLaterPassesSkipLegacyProbing() throws {
        try touch("projects.json", in: legacy, contents: "[\"/a\"]")
        let marker = target.appendingPathComponent(HarborStoreLocation.legacyMigrationMarkerName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the first pass must record that migration has run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("projects.json").path))

        // A brand-new legacy store appearing afterwards is NOT picked up:
        // the marker short-circuits before any probe of that domain.
        try touch("projects.json", in: legacy, contents: "[\"/late\"]")
        HarborStoreLocation.migrateLegacyStoresIfNeeded(legacy: legacy, target: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("projects.json"), encoding: .utf8),
                       "[\"/a\"]", "no second migration after the marker exists")
    }

    func testConfigMigrationSkipsLegacyFallbackOnceMarkerExists() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        // Marker present + no modern registry anywhere: the legacy App Support
        // registry must not even be probed, so nothing is imported.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try writeRegistry([rootA], at: legacy.appendingPathComponent("projects.json"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: target.appendingPathComponent(HarborStoreLocation.legacyMigrationMarkerName).path,
            contents: nil)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(
            modernRegistry: target.appendingPathComponent("projects.json"), // absent
            legacyAppSupport: legacy, central: central)

        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: central.path)
            .filter { $0.hasSuffix(".toml") }, [])
    }

    func testDefaultURLsPointAtHarborHomeDirectory() {
        XCTAssertEqual(HarborStoreLocation.harborDirectory.path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".harbor").path)
        XCTAssertEqual(HarborStoreLocation.projectsURL.lastPathComponent, "projects.json")
        XCTAssertEqual(HarborStoreLocation.portPoolURL.lastPathComponent, "port-pool.json")
        XCTAssertEqual(HarborStoreLocation.projectsDirectory.lastPathComponent, "projects")
    }

    // MARK: - 1.3 central config migration

    private var central: URL!
    private var rootA: URL!
    private var rootB: URL!
    private var registryURL: URL!

    private func makeLegacyRoot(_ name: String, configName: String? = "harbor.toml",
                                configText: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-migrate-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let configName {
            let text = configText ?? """
            name = "\(name)"

            [[process]]
            name = "api"
            command = "sleep 1"
            port = 8100
            """
            try text.write(to: root.appendingPathComponent(configName), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func writeRegistry(_ roots: [URL], at url: URL) throws {
        let data = try JSONEncoder().encode(roots.map(\.path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func testCentralConfigMigrationImportsRootConfigs() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        rootB = try makeLegacyRoot("dictionary")
        registryURL = target.appendingPathComponent("projects.json")
        try writeRegistry([rootA, rootB], at: registryURL)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)

        XCTAssertEqual(try String(contentsOf: central.appendingPathComponent("steward.toml"), encoding: .utf8),
                       "root = \"\(rootA.path)\"\n\n" +
                       "name = \"steward\"\n\n[[process]]\nname = \"api\"\ncommand = \"sleep 1\"\nport = 8100")
        XCTAssertTrue(FileManager.default.fileExists(atPath: central.appendingPathComponent("dictionary.toml").path))
        // Root-side files and the legacy registry are left untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("harbor.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryURL.path))
    }

    func testCentralConfigMigrationSkipsRootsWithoutConfig() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("empty", configName: nil)
        registryURL = target.appendingPathComponent("projects.json")
        try writeRegistry([rootA], at: registryURL)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)

        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: central.path))?.filter { $0.hasSuffix(".toml") },
                       [])
    }

    func testCentralConfigMigrationIsIdempotent() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        registryURL = target.appendingPathComponent("projects.json")
        try writeRegistry([rootA], at: registryURL)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)
        let afterFirst = try FileManager.default.contentsOfDirectory(atPath: central.path).sorted()
        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: central.path).sorted(), afterFirst)
    }

    func testCentralConfigMigrationHonorsExistingCentralFiles() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        registryURL = target.appendingPathComponent("projects.json")
        try writeRegistry([rootA], at: registryURL)
        // A central config already declares this root — it must win.
        try FileManager.default.createDirectory(at: central, withIntermediateDirectories: true)
        try "root = \"\(rootA.path)\"\nname = \"already-here\"\n"
            .write(to: central.appendingPathComponent("already-here.toml"), atomically: true, encoding: .utf8)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: central.path)
            .filter { $0.hasSuffix(".toml") }, ["already-here.toml"])
    }

    func testCentralConfigMigrationHandlesLegacyAppSupportRegistry() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        registryURL = legacy.appendingPathComponent("projects.json") // no ~/.harbor registry
        try writeRegistry([rootA], at: registryURL)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(
            modernRegistry: target.appendingPathComponent("projects.json"), // absent → fallback
            legacyAppSupport: legacy, central: central)

        XCTAssertTrue(FileManager.default.fileExists(atPath: central.appendingPathComponent("steward.toml").path))
    }

    func testCentralConfigMigrationSanitizesCollisionNames() throws {
        central = target.appendingPathComponent("projects", isDirectory: true)
        rootA = try makeLegacyRoot("steward")
        rootB = try makeLegacyRoot("weird name/with:chars")
        registryURL = target.appendingPathComponent("projects.json")
        try writeRegistry([rootA, rootB], at: registryURL)

        HarborStoreLocation.migrateLegacyConfigsIfNeeded(legacyRegistry: registryURL,
                                                         legacyAppSupport: legacy, central: central)

        let files = try FileManager.default.contentsOfDirectory(atPath: central.path).sorted()
        XCTAssertEqual(files, ["steward.toml", "weird-name-with-chars.toml"])
    }
}
