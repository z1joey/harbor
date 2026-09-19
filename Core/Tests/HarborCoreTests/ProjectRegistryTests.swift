import XCTest
@testable import HarborCore

/// The registry is read-only: `~/.harbor/projects/` is owned by the
/// harbor-pilot skill (or hand edits); Harbor only reads and watches it.
/// One config TOML per project; the directory listing is the registry.
@MainActor
final class ProjectRegistryTests: XCTestCase {
    private var centralDirectory: URL!
    private var projectRoot: URL!

    override func setUp() async throws {
        centralDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-central-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: centralDirectory, withIntermediateDirectories: true)
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-registry-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("backend"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: centralDirectory)
        try? FileManager.default.removeItem(at: projectRoot)
    }

    /// Writes a central config the way the skill does: tmp file + rename.
    @discardableResult
    private func registerConfig(name: String, root: URL? = nil,
                                displayName: String? = nil, port: Int = 8001) throws -> URL {
        let text = """
        \(displayName.map { "name = \"\($0)\"\n" } ?? "")root = "\((root ?? projectRoot).standardizedFileURL.path)"

        [[process]]
        name = "api"
        command = "sleep 1"
        cwd = "backend"
        port = \(port)
        """
        let url = centralDirectory.appendingPathComponent("\(name).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadReadsCentralConfigs() throws {
        try registerConfig(name: "steward", displayName: "registry-fixture")

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertTrue(project.id.hasSuffix("/steward.toml"),
                      "unexpected id: \(project.id)")
        XCTAssertEqual(project.name, "registry-fixture")
        XCTAssertEqual(project.root?.path, projectRoot.path)
        XCTAssertEqual(project.processes.first?.name, "api")
        XCTAssertNil(project.configError)
    }

    func testRelaunchRestoresProjects() throws {
        try registerConfig(name: "steward")
        _ = ProjectRegistry(centralDirectory: centralDirectory)

        // A fresh instance (simulated relaunch) reads the same store.
        let second = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(second.projects.count, 1)
        XCTAssertEqual(second.projects.first?.root?.path, projectRoot.path)
        XCTAssertEqual(second.projects.first?.processes.first?.name, "api")
    }

    func testLoadDoesNotRewriteCentralFiles() throws {
        try registerConfig(name: "steward")
        let before = try Data(contentsOf: centralDirectory.appendingPathComponent("steward.toml"))

        _ = ProjectRegistry(centralDirectory: centralDirectory)

        let after = try Data(contentsOf: centralDirectory.appendingPathComponent("steward.toml"))
        XCTAssertEqual(before, after, "the registry must never rewrite the skill-owned store")
    }

    func testMissingDirectoryMeansNoProjects() throws {
        let registry = ProjectRegistry(centralDirectory: centralDirectory.appendingPathComponent("absent"))
        XCTAssertTrue(registry.projects.isEmpty)
    }

    func testIgnoreFilesThatAreNotConfigs() throws {
        try registerConfig(name: "steward")
        try "roots".write(to: centralDirectory.appendingPathComponent("projects.json"),
                          atomically: true, encoding: .utf8)
        try "partial".write(to: centralDirectory.appendingPathComponent(".steward.toml.tmp"),
                            atomically: true, encoding: .utf8)
        try "notes".write(to: centralDirectory.appendingPathComponent("README.md"),
                          atomically: true, encoding: .utf8)

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(registry.projects.map(\.configFileName), ["steward.toml"])
    }

    func testInvalidConfigListsProjectWithVisibleError() throws {
        try "name = [broken".write(to: centralDirectory.appendingPathComponent("steward.toml"),
                                   atomically: true, encoding: .utf8)

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertNotNil(project.configError)
        XCTAssertTrue(project.processes.isEmpty)
        XCTAssertNil(project.root)
    }

    func testMissingRootKeyListsProjectWithError() throws {
        try """
        [[process]]
        name = "api"
        command = "sleep 1"
        """.write(to: centralDirectory.appendingPathComponent("steward.toml"),
                  atomically: true, encoding: .utf8)

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertTrue(project.configError?.contains("root") == true,
                      "unexpected error: \(project.configError ?? "nil")")
        XCTAssertTrue(project.processes.isEmpty)
    }

    /// Two central configs claiming the same root both stay listed; the
    /// second (by filename) is flagged so the conflict is discoverable.
    func testDuplicateRootsBothListed() throws {
        try registerConfig(name: "aaa")
        try registerConfig(name: "bbb")

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(registry.projects.count, 2)
        XCTAssertTrue(registry.projects[0].configError == nil)
        XCTAssertNotNil(registry.projects[1].configError,
                        "the second config for the same root should be flagged")
    }

    /// Harbor never reads the project root for config: a central config keeps
    /// working even when the legacy root-side harbor.toml is gone or changed.
    func testProjectRootIsNeverReadForConfig() throws {
        try """
        name = "legacy"

        [[process]]
        name = "legacy-api"
        command = "sleep 1"
        port = 9999
        """.write(to: projectRoot.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)
        try registerConfig(name: "steward", displayName: "central-truth", port: 8100)

        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        let project = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(project.name, "central-truth")
        XCTAssertEqual(project.processes.first?.name, "api")
        XCTAssertEqual(project.processes.first?.port, 8100)

        // Changing the root-side file must not influence parsing.
        try "name = [broken".write(to: projectRoot.appendingPathComponent("harbor.toml"),
                                   atomically: true, encoding: .utf8)
        registry.reloadAll()
        XCTAssertEqual(registry.projects.first?.processes.first?.port, 8100)
        XCTAssertNil(registry.projects.first?.configError)
    }

    /// The skill may register projects while Harbor runs: a new config file
    /// appears atomically and the directory watcher must pick it up live.
    func testWatcherPicksUpSkillRegistration() throws {
        try registerConfig(name: "steward")
        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(registry.projects.count, 1)

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let text = """
        root = "\(otherRoot.path)"

        [[process]]
        name = "web"
        command = "sleep 1"
        port = 8002
        """
        let tmp = centralDirectory.appendingPathComponent(".late-arrival.toml.tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp,
                                         to: centralDirectory.appendingPathComponent("late-arrival.toml"))

        // The watcher debounces 0.4s; pump the run loop until it lands.
        let deadline = Date().addingTimeInterval(5)
        while registry.projects.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(registry.projects.count, 2)
        let late = registry.projects.first { $0.configFileName == "late-arrival.toml" }
        XCTAssertEqual(late?.root?.path, otherRoot.standardizedFileURL.path)
        XCTAssertEqual(late?.processes.first?.port, 8002)
    }

    /// Deleting the config file is unregistering: the project disappears live.
    func testWatcherPicksUpUnregistration() throws {
        let url = try registerConfig(name: "steward")
        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(registry.projects.count, 1)

        try FileManager.default.removeItem(at: url)

        let deadline = Date().addingTimeInterval(5)
        while !registry.projects.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(registry.projects.isEmpty)
    }

    /// An in-place edit of a config file reloads that project only.
    func testWatcherPicksUpInPlaceEdit() throws {
        let url = try registerConfig(name: "steward", displayName: "before", port: 8001)
        let registry = ProjectRegistry(centralDirectory: centralDirectory)
        XCTAssertEqual(registry.projects.first?.name, "before")

        try """
        name = "after"
        root = "\(projectRoot.path)"

        [[process]]
        name = "api"
        command = "sleep 1"
        port = 8123
        """.write(to: url, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(5)
        while registry.projects.first?.name != "after" && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(registry.projects.first?.name, "after")
        XCTAssertEqual(registry.projects.first?.processes.first?.port, 8123)
    }
}
