import Foundation
import TOMLKit

public struct ParsedProjectConfig {
    public var name: String
    public var configName: String
    /// Project folder the config defines, resolved from the `root` key.
    /// Non-nil for configs parsed through `parse(configAt:)`.
    public var root: URL?
    public var processes: [ProcessDefinition]
    public var portClaims: [PortClaim]
    public var openProcessName: String?
    public var openURL: URL?
}

public enum HarborConfigError: LocalizedError {
    case readFailed(String)
    case parse(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let message): return message
        case .parse(let message): return "TOML parse error: \(message)"
        case .invalid(let message): return message
        }
    }
}

/// Parses Harbor project config TOML (via TOMLKit) into project definitions.
///
/// Since 1.3 configs live in `~/.harbor/projects/*.toml` and must declare a
/// top-level `root = "/absolute/path"` key naming the project folder.
/// `locateConfig(in:)` and the legacy `parse(root:)` reading of per-root
/// `harbor.toml` files survive only for the one-time 1.3 migration.
public enum HarborConfigParser {
    public static let configNames = ["harbor.toml", ".harbor.toml"]

    /// Legacy: locates a `harbor.toml` / `.harbor.toml` in a project root.
    /// Migration only — frontends never read project roots for config.
    public static func locateConfig(in root: URL) -> URL? {
        let fm = FileManager.default
        for name in configNames {
            let candidate = root.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Parses a central config file from `~/.harbor/projects/`. The file must
    /// declare `root = "/absolute/path"` (`~` allowed); the display name
    /// defaults to the root folder's name.
    public static func parse(configAt: URL) -> Result<ParsedProjectConfig, Error> {
        guard let text = try? String(contentsOf: configAt, encoding: .utf8) else {
            return .failure(HarborConfigError.readFailed("Could not read \(configAt.lastPathComponent)."))
        }
        do {
            let parsed = try parse(text: text)
            guard let rootString = parsed.rootPath, !rootString.isEmpty else {
                throw HarborConfigError.invalid(
                    "Missing the required top-level \"root\" key — add root = \"/absolute/path/to/project\".")
            }
            let expanded = (rootString as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw HarborConfigError.invalid("root \"\(rootString)\" must be an absolute path (\"~\" allowed).")
            }
            let root = URL(fileURLWithPath: expanded).standardizedFileURL
            let name = parsed.name?.isEmpty == false ? parsed.name! : root.lastPathComponent
            return .success(ParsedProjectConfig(name: name, configName: configAt.lastPathComponent,
                                                root: root,
                                                processes: parsed.processes, portClaims: parsed.portClaims,
                                                openProcessName: parsed.openProcessName,
                                                openURL: parsed.openURL))
        } catch {
            return .failure(error)
        }
    }

    /// Throws `HarborConfigError` with a user-readable message on any problem.
    public static func parse(text: String) throws -> (name: String?, rootPath: String?,
                                                      processes: [ProcessDefinition], portClaims: [PortClaim],
                                                      openProcessName: String?, openURL: URL?) {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            throw HarborConfigError.parse(String(describing: error))
        }

        let name = table["name"]?.string

        var rootPath: String?
        if let rootString = table["root"]?.string {
            guard !rootString.isEmpty else {
                throw HarborConfigError.invalid("\"root\" must be a non-empty absolute path.")
            }
            rootPath = rootString
        } else if table["root"] != nil {
            throw HarborConfigError.invalid("\"root\" must be a string holding an absolute project path.")
        }

        guard let processArray = table["process"]?.array else {
            if table["process"] != nil {
                throw HarborConfigError.invalid("\"process\" must be a list of tables ([[process]]).")
            }
            let open = try parseOpenBrowser(table: table, processNames: [])
            return (name, rootPath, [], try parsePortClaims(table: table, processes: []),
                    open.openProcessName, open.openURL)
        }

        var processes: [ProcessDefinition] = []
        var seenNames = Set<String>()
        var seenPorts: [Int: String] = [:]
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
                if let firstOwner = seenPorts[parsedPort] {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port \(parsedPort) is already declared by process \"\(firstOwner)\".")
                }
                seenPorts[parsedPort] = processName
            } else if let portString = entry["port"]?.string {
                if portString == "auto" {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port = \"auto\" is no longer supported; declare an integer port from the Harbor pool (default 8100–8199).")
                }
                throw HarborConfigError.invalid("Process \"\(processName)\": port must be an integer 1–65535, not \"\(portString)\".")
            } else if entry["port"] != nil {
                throw HarborConfigError.invalid("Process \"\(processName)\": port must be an integer 1–65535.")
            }

            var portEnv = "PORT"
            if let envName = entry["port_env"]?.string {
                guard port != nil else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port_env is only allowed when port is declared.")
                }
                guard !envName.isEmpty else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port_env must be a non-empty string.")
                }
                guard envName.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": port_env \"\(envName)\" is not a valid environment variable name.")
                }
                portEnv = envName
            } else if entry["port_env"] != nil {
                throw HarborConfigError.invalid("Process \"\(processName)\": port_env must be a string.")
            }

            var readyURLTemplate: String?
            if let urlString = entry["ready_url"]?.string {
                if urlString.contains("${port}") && port == nil {
                    throw HarborConfigError.invalid("Process \"\(processName)\": ready_url \"\(urlString)\" uses ${port} but no port is declared.")
                }
                let validateString = urlString.replacingOccurrences(of: "${port}", with: "1")
                guard let url = URL(string: validateString), url.scheme != nil else {
                    throw HarborConfigError.invalid("Process \"\(processName)\": ready_url \"\(urlString)\" is not a valid URL.")
                }
                readyURLTemplate = urlString
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
                portEnv: portEnv,
                readyURLTemplate: readyURLTemplate,
                autoRestart: entry["auto_restart"]?.bool ?? false,
                env: env
            ))
        }
        let open = try parseOpenBrowser(table: table, processNames: Set(processes.map(\.name)))
        return (name, rootPath, processes, try parsePortClaims(table: table, processes: processes),
                open.openProcessName, open.openURL)
    }

    private static func parseOpenBrowser(table: TOMLTable,
                                         processNames: Set<String>) throws -> (openProcessName: String?, openURL: URL?) {
        let hasOpenProcess = table["open_process"] != nil
        let hasOpenURL = table["open_url"] != nil
        if hasOpenProcess && hasOpenURL {
            throw HarborConfigError.invalid("Use either open_process or open_url, not both.")
        }
        if let openProcess = table["open_process"]?.string {
            guard !openProcess.isEmpty else {
                throw HarborConfigError.invalid("open_process must be a non-empty string.")
            }
            guard processNames.contains(openProcess) else {
                throw HarborConfigError.invalid("open_process \"\(openProcess)\" is not defined in this config.")
            }
            return (openProcess, nil)
        }
        if table["open_process"] != nil {
            throw HarborConfigError.invalid("open_process must be a string.")
        }
        if let openURLString = table["open_url"]?.string {
            guard !openURLString.isEmpty else {
                throw HarborConfigError.invalid("open_url must be a non-empty string.")
            }
            guard let url = URL(string: openURLString), url.scheme != nil else {
                throw HarborConfigError.invalid("open_url \"\(openURLString)\" is not a valid URL.")
            }
            return (nil, url)
        }
        if table["open_url"] != nil {
            throw HarborConfigError.invalid("open_url must be a string.")
        }
        return (nil, nil)
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
}
