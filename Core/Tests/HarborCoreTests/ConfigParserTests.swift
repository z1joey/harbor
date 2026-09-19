import XCTest
@testable import HarborCore

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
        XCTAssertEqual(api.readyURL(port: 8000)?.absoluteString, "http://127.0.0.1:8000/health")
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
        // Walk up from the test file: SPM and the Xcode test target nest at different depths.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var url: URL?
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("fixtures/sample-config.toml")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            dir.deleteLastPathComponent()
        }
        guard let url else {
            XCTFail("fixtures/sample-config.toml not found in any parent directory")
            return
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try HarborConfigParser.parse(text: text)
        XCTAssertEqual(parsed.processes.count, 2)
        XCTAssertEqual(parsed.processes[0].port, 8000)
    }

    func testLocateConfigFindsBothFlavors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try sampleToml.write(to: root.appendingPathComponent(".harbor.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HarborConfigParser.locateConfig(in: root)?.lastPathComponent, ".harbor.toml")
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".harbor.toml"))
        try sampleToml.write(to: root.appendingPathComponent("harbor.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HarborConfigParser.locateConfig(in: root)?.lastPathComponent, "harbor.toml")
    }

    // MARK: - central configs (parse(configAt:))

    private func writeCentralConfig(_ text: String, name: String = "central") throws -> URL {
        let central = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-central-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: central, withIntermediateDirectories: true)
        let url = central.appendingPathComponent("\(name).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCentralConfigParsesRootKey() throws {
        let url = try writeCentralConfig("""
        root = "/Users/joey/Projects/example"

        [[process]]
        name = "api"
        command = "run api"
        port = 8000
        """)
        guard case .success(let parsed) = HarborConfigParser.parse(configAt: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.configName, "central.toml")
        XCTAssertEqual(parsed.root?.path, "/Users/joey/Projects/example")
        XCTAssertEqual(parsed.name, "example", "name falls back to the root folder name")
        XCTAssertEqual(parsed.processes.first?.port, 8000)
    }

    func testCentralConfigExpandsTildeRoot() throws {
        let url = try writeCentralConfig("""
        root = "~/Projects/example"
        name = "tilde"
        """)
        guard case .success(let parsed) = HarborConfigParser.parse(configAt: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.root?.path, FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/example").standardizedFileURL.path)
        XCTAssertEqual(parsed.name, "tilde", "an explicit name wins over the folder fallback")
    }

    func testCentralConfigWithoutRootKeyFails() throws {
        let url = try writeCentralConfig(sampleToml)
        guard case .failure(let error) = HarborConfigParser.parse(configAt: url) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.localizedDescription.contains("root"),
                      "unexpected message: \(error.localizedDescription)")
    }

    func testCentralConfigWithRelativeRootFails() throws {
        let url = try writeCentralConfig("root = \"Projects/example\"\n")
        guard case .failure(let error) = HarborConfigParser.parse(configAt: url) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.localizedDescription.contains("absolute"),
                      "unexpected message: \(error.localizedDescription)")
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

    func testProjectWithoutProcessesIsEmptyNotError() throws {
        let parsed = try HarborConfigParser.parse(text: "name = \"empty\"")
        XCTAssertEqual(parsed.name, "empty")
        XCTAssertTrue(parsed.processes.isEmpty)
    }

    // MARK: - [[port_claim]]

    func testParsesPortClaims() throws {
        let parsed = try HarborConfigParser.parse(text: """
        name = "claims"
        [[process]]
        name = "deps"
        command = "docker compose up -d postgres redis"

        [[port_claim]]
        port = 5432
        note = "postgres"
        process = "deps"

        [[port_claim]]
        port = 6379
        """)
        XCTAssertEqual(parsed.portClaims.count, 2)
        XCTAssertEqual(parsed.portClaims[0].port, 5432)
        XCTAssertEqual(parsed.portClaims[0].note, "postgres")
        XCTAssertEqual(parsed.portClaims[0].processName, "deps")
        XCTAssertEqual(parsed.portClaims[1].port, 6379)
        XCTAssertNil(parsed.portClaims[1].processName)
    }

    func testPortClaimsWithoutProcessesAreAllowed() throws {
        let parsed = try HarborConfigParser.parse(text: """
        name = "external"
        [[port_claim]]
        port = 5432
        note = "system postgres"
        """)
        XCTAssertEqual(parsed.portClaims.map(\.port), [5432])
        XCTAssertTrue(parsed.processes.isEmpty)
    }

    func testPortClaimOutOfRangeIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[port_claim]]
        port = 70000
        """))
    }

    func testPortClaimMissingPortIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[port_claim]]
        note = "no port here"
        """))
    }

    func testDuplicatePortClaimIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[port_claim]]
        port = 5432

        [[port_claim]]
        port = 5432
        """))
    }

    func testPortClaimClashingWithProcessPortIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "web"
        command = "npm run dev"
        port = 5173

        [[port_claim]]
        port = 5173
        note = "duplicate of the process port"
        """))
    }

    func testPortClaimForUnknownProcessIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run api"

        [[port_claim]]
        port = 5432
        process = "database"
        """))
    }

    // MARK: - declared port, port_env, ${port}

    func testParsesDeclaredPortWithPortPlaceholder() throws {
        let parsed = try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "uvicorn app:app --port $PORT"
        port = 8100
        ready_url = "http://127.0.0.1:${port}/health"
        """)
        let api = try XCTUnwrap(parsed.processes.first)
        XCTAssertEqual(api.port, 8100)
        XCTAssertEqual(api.portEnv, "PORT")
        XCTAssertEqual(api.readyURLTemplate, "http://127.0.0.1:${port}/health")
        XCTAssertEqual(api.readyURL(port: 8100)?.absoluteString, "http://127.0.0.1:8100/health")
    }

    func testParsesCustomPortEnvOnDeclaredPort() throws {
        let parsed = try HarborConfigParser.parse(text: """
        [[process]]
        name = "web"
        command = "npm run dev -- --port $APP_PORT"
        port = 8101
        port_env = "APP_PORT"
        """)
        let web = try XCTUnwrap(parsed.processes.first)
        XCTAssertEqual(web.port, 8101)
        XCTAssertEqual(web.portEnv, "APP_PORT")
    }

    func testAutoPortStringIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run"
        port = "auto"
        """)) { error in
            let message = (error as? HarborConfigError)?.localizedDescription ?? "\(error)"
            XCTAssertTrue(message.contains("auto"), "unexpected message: \(message)")
        }
    }

    func testInvalidPortStringIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run"
        port = "dynamic"
        """))
    }

    func testPortEnvWithoutPortIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run"
        port_env = "PORT"
        """)) { error in
            let message = (error as? HarborConfigError)?.localizedDescription ?? "\(error)"
            XCTAssertTrue(message.contains("port_env"), "unexpected message: \(message)")
        }
    }

    func testReadyURLPortPlaceholderWithoutPortIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run"
        ready_url = "http://127.0.0.1:${port}/"
        """)) { error in
            let message = (error as? HarborConfigError)?.localizedDescription ?? "\(error)"
            XCTAssertTrue(message.contains("${port}"), "unexpected message: \(message)")
        }
    }

    func testInvalidPortEnvNameIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        [[process]]
        name = "api"
        command = "run"
        port = 8100
        port_env = "bad-name"
        """))
    }

    // MARK: - open_process / open_url

    func testParsesOpenProcess() throws {
        let parsed = try HarborConfigParser.parse(text: """
        open_process = "web"
        [[process]]
        name = "api"
        command = "run api"
        port = 8000
        [[process]]
        name = "web"
        command = "npm run dev"
        port = 8080
        ready_url = "http://127.0.0.1:8080/"
        """)
        XCTAssertEqual(parsed.openProcessName, "web")
        XCTAssertNil(parsed.openURL)
    }

    func testParsesOpenURL() throws {
        let parsed = try HarborConfigParser.parse(text: """
        open_url = "http://127.0.0.1:3000/"
        [[process]]
        name = "web"
        command = "npm run dev"
        """)
        XCTAssertNil(parsed.openProcessName)
        XCTAssertEqual(parsed.openURL?.absoluteString, "http://127.0.0.1:3000/")
    }

    func testOpenProcessForUnknownProcessIsRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        open_process = "missing"
        [[process]]
        name = "api"
        command = "run"
        """))
    }

    func testOpenProcessAndOpenURLTogetherAreRejected() {
        XCTAssertThrowsError(try HarborConfigParser.parse(text: """
        open_process = "web"
        open_url = "http://127.0.0.1:8080/"
        [[process]]
        name = "web"
        command = "npm run dev"
        """))
    }
}
