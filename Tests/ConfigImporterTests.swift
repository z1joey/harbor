import XCTest

final class ConfigImporterTests: XCTestCase {
    func testProcfileDraftParsesBack() throws {
        let draft = try XCTUnwrap(ConfigImporter.fromProcfile(
            """
            web: npm run dev
            api: uv run uvicorn app.main:app --reload
            # comment lines are ignored
            worker: node worker.js
            """,
            projectName: "myapp"
        ))
        XCTAssertTrue(draft.toml.contains("name = \"myapp\""))
        XCTAssertTrue(draft.toml.contains("name = \"web\""))
        XCTAssertTrue(draft.toml.contains("npm run dev"))

        let parsed = try HarborConfigParser.parse(text: draft.toml)
        XCTAssertEqual(parsed.name, "myapp")
        XCTAssertEqual(parsed.processes.map(\.name), ["web", "api", "worker"])
        XCTAssertEqual(parsed.processes[1].command, "uv run uvicorn app.main:app --reload")
    }

    func testPackageJSONDraftSkipsHooksAndRoundTrips() throws {
        let json = """
        {
          "name": "webapp",
          "scripts": {
            "predev": "echo hook",
            "dev": "vite",
            "build": "vite build",
            "postbuild": "echo hook",
            "test": "jest"
          }
        }
        """
        let draft = try XCTUnwrap(ConfigImporter.fromPackageJSON(Data(json.utf8), projectName: "webapp"))
        XCTAssertFalse(draft.toml.contains("predev"))
        XCTAssertFalse(draft.toml.contains("postbuild"))
        XCTAssertTrue(draft.toml.contains("npm run dev"))

        let parsed = try HarborConfigParser.parse(text: draft.toml)
        XCTAssertEqual(parsed.processes.map(\.name), ["build", "dev", "test"])
        XCTAssertEqual(parsed.processes.first { $0.name == "dev" }?.command, "npm run dev")
    }

    func testGarbageInputsYieldNil() {
        XCTAssertNil(ConfigImporter.fromProcfile("no colons here\n", projectName: "x"))
        XCTAssertNil(ConfigImporter.fromPackageJSON(Data("not json".utf8), projectName: "x"))
        XCTAssertNil(ConfigImporter.fromPackageJSON(Data(#"{"scripts": {}}"#.utf8), projectName: "x"))
    }

    func testDraftsInFolderFindsExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "web: sleep 5\n".write(to: root.appendingPathComponent("Procfile"), atomically: true, encoding: .utf8)
        let drafts = ConfigImporter.drafts(in: root)
        XCTAssertEqual(drafts.map(\.sourceName), ["Procfile"])
    }
}
