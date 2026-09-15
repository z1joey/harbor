import Foundation
import TOMLKit

struct ParsedProjectConfig {
    var name: String
    var configName: String
    var processes: [ProcessDefinition]
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
            return .success(ParsedProjectConfig(name: name, configName: configURL.lastPathComponent, processes: parsed.processes))
        } catch {
            return .failure(error)
        }
    }

    /// Throws `HarborConfigError` with a user-readable message on any problem.
    static func parse(text: String) throws -> (name: String?, processes: [ProcessDefinition]) {
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
            return (name, [])
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
        return (name, processes)
    }

    static func templateText(projectName: String) -> String {
        """
        name = "\(Self.escape(projectName))"

        # Rename and fill in your processes below, then start them from Harbor.
        [[process]]
        name = "dev"
        command = "echo \\"replace me with your dev command\\" && sleep 3600"
        # cwd = "backend"              # optional, relative to this folder
        # port = 8000                  # optional, enables conflict detection
        # ready_url = "http://127.0.0.1:8000/health"  # optional, M3 health gate
        # auto_restart = false         # optional, restart on crash
        # env = { "FOO" = "bar" }      # optional environment overrides
        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
