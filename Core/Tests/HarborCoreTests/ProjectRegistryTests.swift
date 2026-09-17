import XCTest
@testable import HarborCore

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private var storeURL: URL!
    private var projectRoot: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-registry-\(UUID().uuidString).json")
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
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: projectRoot)
    }

    func testAddPersistsRootPath() throws {
        let registry = ProjectRegistry(storeURL: storeURL)
        let result = registry.add(root: projectRoot, createTemplateIfMissing: false)
        guard case .success(let project) = result else {
            return XCTFail("add failed: \(result)")
        }
        XCTAssertEqual(project.name, "registry-fixture")
        XCTAssertEqual(project.processes.count, 1)

        let stored = try JSONDecoder().decode([String].self, from: Data(contentsOf: storeURL))
        XCTAssertEqual(stored, [projectRoot.path])
    }

    func testRelaunchRestoresProjects() throws {
        let first = ProjectRegistry(storeURL: storeURL)
        _ = first.add(root: projectRoot, createTemplateIfMissing: false)

        // A fresh instance (simulated relaunch) reads the same store.
        let second = ProjectRegistry(storeURL: storeURL)
        XCTAssertEqual(second.projects.count, 1)
        XCTAssertEqual(second.projects.first?.root.path, projectRoot.path)
        XCTAssertEqual(second.projects.first?.processes.first?.name, "api")
    }

    func testRemoveRewritesStoreFromInMemoryProjects() throws {
        let legacyPath = projectRoot.path + "/"
        try JSONEncoder().encode([legacyPath]).write(to: storeURL)

        let registry = ProjectRegistry(storeURL: storeURL)
        XCTAssertEqual(registry.projects.count, 1)
        let project = try XCTUnwrap(registry.projects.first)

        registry.remove(projectID: project.id)
        XCTAssertTrue(registry.projects.isEmpty)

        let stored = try JSONDecoder().decode([String].self, from: Data(contentsOf: storeURL))
        XCTAssertTrue(stored.isEmpty)
    }

    func testRemoveUnregistersButKeepsFiles() throws {
        let registry = ProjectRegistry(storeURL: storeURL)
        _ = registry.add(root: projectRoot, createTemplateIfMissing: false)

        registry.remove(projectID: projectRoot.path)
        XCTAssertTrue(registry.projects.isEmpty)
        let stored = try JSONDecoder().decode([String].self, from: Data(contentsOf: storeURL))
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("harbor.toml").path))
    }

    func testAddWithoutConfigRequiresTemplateOptIn() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        let registry = ProjectRegistry(storeURL: storeURL)
        guard case .failure(let error) = registry.add(root: emptyRoot, createTemplateIfMissing: false) else {
            return XCTFail("expected failure without config")
        }
        XCTAssertTrue(error.localizedDescription.contains("harbor.toml"), "unexpected: \(error.localizedDescription)")

        guard case .success = registry.add(root: emptyRoot, createTemplateIfMissing: true) else {
            return XCTFail("expected template creation to allow add")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent("harbor.toml").path))
    }

    func testInvalidConfigRegistersWithVisibleError() throws {
        let brokenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: brokenRoot) }
        try "name = [broken".write(to: brokenRoot.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)

        let registry = ProjectRegistry(storeURL: storeURL)
        guard case .success(let project) = registry.add(root: brokenRoot, createTemplateIfMissing: false) else {
            return XCTFail("project with broken config should still register with error state")
        }
        XCTAssertNotNil(project.configError)
        XCTAssertTrue(project.processes.isEmpty)
    }
}
