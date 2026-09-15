import XCTest

final class ConfigParserTests: XCTestCase {
    private let sampleToml = """
    name = "example"

    [[process]]
    name = "api"
    command = "uv run uvicorn app.main:app --reload"
    cwd = "backend"
    port = 8000
    ready_url = "http://127.0.0.1:8000/health"
    auto_restart = false
    env = { "FOO" = "bar", "RETRIES" = 3, "VERBOSE" = true }

    [[process]]
    name = "web"
    command = "npm run dev"
    port = 5173
    """

    func testParsesProcessesAndFields() throws {
        let parsed = try HarborConfigParser.parse(text: sampleToml)
        XCTAssertEqual(parsed.name, "example")
        XCTAssertEqual(parsed.processes.count, 2)

        let api = parsed.processes[0]
        XCTAssertEqual(api.name, "api")
        XCTAssertEqual(api.command, "uv run uvicorn app.main:app --reload")
        XCTAssertEqual(api.cwd, "backend")
        XCTAssertEqual(api.port, 8000)
        XCTAssertEqual(api.readyURL?.absoluteString, "http://127.0.0.1:8000/health")
        XCTAssertEqual(api.autoRestart, false)
        XCTAssertEqual(api.env["FOO"], "bar")
        XCTAssertEqual(api.env["RETRIES"], "3")   // ints coerced to strings
        XCTAssertEqual(api.env["VERBOSE"], "true") // bools coerced to strings

        let web = parsed.processes[1]
        XCTAssertEqual(web.name, "web")
        XCTAssertEqual(web.port, 5173)
        XCTAssertNil(web.cwd)
    }

    func testRepoSampleFixtureParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("fixtures/sample-harbor.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try HarborConfigParser.parse(text: text)
        XCTAssertEqual(parsed.processes.count, 2)
        XCTAssertEqual(parsed.processes[0].port, 8000)
    }

    func testDotHarborTomlIsLocated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try sampleToml.write(to: root.appendingPathComponent(".harbor.toml"), atomically: true, encoding: .utf8)

        let result = HarborConfigParser.parse(root: root)
        guard case .success(let parsed) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(parsed.configName, ".harbor.toml")
        XCTAssertEqual(parsed.processes.count, 2)
    }

    func testInvalidTomlYieldsReadableParseError() {
        do {
            _ = try HarborConfigParser.parse(text: "name = [broken")
            XCTFail("expected error")
        } catch let error as HarborConfigError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("TOML parse error"), "unexpected message: \(message)")
            XCTAssertTrue(message.contains("line"), "expected position info: \(message)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testMissingCommandIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        """)) { error in
            XCTAssertTrue("\(error)".contains("command") || error.localizedDescription.contains("command"))
        }
    }

    func testDuplicateProcessNamesAreRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "a"

        [[process]]
        name = "api"
        command = "b"
        """))
    }

    func testOutOfRangePortIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "a"
        port = 99999
        """))
    }

    func testTemplateConfigRoundTrips() throws {
        let template = HarborConfigParser.templateText(projectName: "fresh project \"quoted\"")
        let parsed = try HarborConfigParser.parse(text: template)
        XCTAssertEqual(parsed.processes.count, 1)
        XCTAssertEqual(parsed.processes[0].name, "dev")
    }

    func testProjectWithoutProcessesIsEmptyNotError() throws {
        let parsed = try HarborConfigParser.parse(text: "name = \"empty\"")
        XCTAssertEqual(parsed.name, "empty")
        XCTAssertTrue(parsed.processes.isEmpty)
    }
}
