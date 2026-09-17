import Foundation
import TOMLKit

struct ParsedProjectConfig {
    var name: String
    var configName: String
    var processes: [ProcessDefinition]
    var portClaims: [PortClaim]
}

enum HarborConfigError: LocalizedError {
    case readFailed(String)
    case parse(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): return message
        case .parse(let message): return "TOML parse error: \(message)"
        case .invalid(let message): return message
        }
    }
}

/// Parses `harbor.toml` / `.harbor.toml` (TOML via TOMLKit) into project definitions.
enum HarborConfigParser {
    static let configNames = ["harbor.toml", ".harbor.toml"]

    static func locateConfig(in root: URL) -> URL? {
        let fm = FileManager.default
        for name in configNames {
            let candidate = root.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func parse(root: URL) -> Result<ParsedProjectConfig, Error> {
        guard let configURL = locateConfig(in: root) else {
            return .failure(HarborConfigError.readFailed("No harbor.toml (or .harbor.toml) found in this folder."))
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failure(HarborConfigError.readFailed("Could not read \(configURL.lastPathComponent)."))
        }
        do {
            let parsed = try parse(text: text)
            let name = parsed.name?.isEmpty == false ? parsed.name! : root.lastPathComponent
            return .success(ParsedProjectConfig(name: name, configName: configURL.lastPathComponent,
                                                processes: parsed.processes, portClaims: parsed.portClaims))
        } catch {
            return .failure(error)
        }
    }

    /// Throws `HarborConfigError` with a user-readable message on any problem.
    static func parse(text: String) throws -> (name: String?, processes: [ProcessDefinition], portClaims: [PortClaim]) {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            throw HarborConfigError.parse(String(describing: error))
        }

        let name = table["name"]?.string

        guard let processArray = table["process"]?.array else {
            if table["process"] != nil {
                throw HarborConfigError.invalid("\"process\" must be a list of tables ([[process]]).")
            }
            return (name, [], try parsePortClaims(table: table, processes: []))
        }

        var processes: [ProcessDefinition] = []
        var seenNames = Set<String>()
        for index in 0..<processArray.count {
            guard let entry = processArray[index]?.table else {
                throw HarborConfigError.invalid("process[\(index)] is not a table.")
            }
            guard let processName = entry["name"]?.string, !processName.isEmpty else {
                throw HarborConfigError.invalid("process[\(index)] is missing a non-empty \"name\".")
            }
            guard !seenNames.contains(processName) else {
                throw HarborConfigError.invalid("Duplicate process name \"\(processName)\".")
            }
            seenNames.insert(processName)
            guard let command = entry["command"]?.string, !command.isEmpty else {
                throw HarborConfigError.invalid("Process \"\(processName)\" is missing a non-empty \"command\".")
            }

            var port: Int?
            if let parsedPort = entry["port"]?.int {
                guard parsedPort >= 1, parsedPort <= 65535 else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port \(parsedPort) is out of range (1–65535).")
                }
                port = parsedPort
            }

            var readyURL: URL?
            if let urlString = entry["ready_url"]?.string {
                guard let url = URL(string: urlString), url.scheme != nil else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": ready_url \"\(urlString)\" is not a valid URL.")
                }
                readyURL = url
            }

            var env: [String: String] = [:]
            if let envTable = entry["env"]?.table {
                for (key, value) in envTable {
                    if let stringValue = value.string {
                        env[key] = stringValue
                    } else if let intValue = value.int {
                        env[key] = String(intValue)
                    } else if let boolValue = value.bool {
                        env[key] = boolValue ? "true" : "false"
                    } else {
                        throw HarborConfigError.invalid("Process \"\(processName)\": env \"\(key)\" must be a string, number, or boolean.")
                    }
                }
            }

            processes.append(ProcessDefinition(
                name: processName,
                command: command,
                cwd: entry["cwd"]?.string,
                port: port,
                readyURL: readyURL,
                autoRestart: entry["auto_restart"]?.bool ?? false,
                env: env
            ))
        }
        return (name, processes, try parsePortClaims(table: table, processes: processes))
    }

    /// Parses `[[port_claim]]` entries: ports the project relies on without a
    /// single owning `[[process]]` (databases, brokers, multi-port processes).
    private static func parsePortClaims(table: TOMLTable, processes: [ProcessDefinition]) throws -> [PortClaim] {
        guard let claimArray = table["port_claim"]?.array else {
            if table["port_claim"] != nil {
                throw HarborConfigError.invalid("\"port_claim\" must be a list of tables ([[port_claim]]).")
            }
            return []
        }

        let processNames = Set(processes.map(\.name))
        var seenPorts = Set(processes.compactMap(\.port))
        var claims: [PortClaim] = []
        for index in 0..<claimArray.count {
            guard let entry = claimArray[index]?.table else {
                throw HarborConfigError.invalid("port_claim[\(index)] is not a table.")
            }
            guard let port = entry["port"]?.int, port >= 1, port <= 65535 else {
                throw HarborConfigError.invalid("port_claim[\(index)] is missing an integer \"port\" between 1 and 65535.")
            }
            guard seenPorts.insert(port).inserted else {
                throw HarborConfigError.invalid("port_claim[\(index)]: port \(port) is already declared in this config.")
            }
            let note = entry["note"]?.string
            let processName = entry["process"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            if let processName, !processNames.contains(processName) {
                throw HarborConfigError.invalid("port_claim[\(index)]: process \"\(processName)\" is not defined in this config.")
            }
            claims.append(PortClaim(port: port, note: note, processName: processName))
        }
        return claims
    }

    static func templateText(projectName: String, suggestedPort: Int? = nil) -> String {
        let portComment = suggestedPort.map {
            "# port = \($0)                  # suggested: no registered project claims \($0)"
        } ?? "# port = 8000                  # optional, enables conflict detection"

        return """
        name = "\(Self.escape(projectName))"

        # Rename and fill in your processes below, then start them from Harbor.
        [[process]]
        name = "dev"
        command = "echo \\"replace me with your dev command\\" && sleep 3600"
        # cwd = "backend"              # optional, relative to this folder
        \(portComment)
        # ready_url = "http://127.0.0.1:8000/health"  # optional, M3 health gate
        # auto_restart = false         # optional, restart on crash
        # env = { "FOO" = "bar" }      # optional environment overrides

        # Ports the project relies on without one owning [[process]] — a
        # database, broker, … — so Harbor can warn before two projects collide.
        # [[port_claim]]
        # port = 5432
        # note = "postgres"
        # process = "dev"              # optional, must match a [[process]] name above
        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
