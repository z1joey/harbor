import Foundation

/// One `[[process]]` entry parsed from a project's `harbor.toml`.
public struct ProcessDefinition: Identifiable, Hashable {
    public let name: String
    public let command: String
    public let cwd: String?
    /// Declared port from config (`port = 8000`). Nil when the process has no port.
    public let port: Int?
    /// Environment variable name Harbor injects with `port` at start (default `PORT`).
    public let portEnv: String
    /// Raw `ready_url` template; may contain `${port}` when `port` is declared.
    public let readyURLTemplate: String?
    public let autoRestart: Bool
    public let env: [String: String]

    public var id: String { name }

    public init(name: String,
                command: String,
                cwd: String?,
                port: Int?,
                portEnv: String = "PORT",
                readyURLTemplate: String? = nil,
                autoRestart: Bool = false,
                env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.cwd = cwd
        self.port = port
        self.portEnv = portEnv
        self.readyURLTemplate = readyURLTemplate
        self.autoRestart = autoRestart
        self.env = env
    }

    /// Resolves `readyURLTemplate` for health probes and browser links.
    /// `${port}` is substituted when present (requires a concrete port number).
    public func readyURL(port: Int?) -> URL? {
        guard let template = readyURLTemplate else { return nil }
        let resolved: String
        if template.contains("${port}") {
            guard let port else { return nil }
            resolved = template.replacingOccurrences(of: "${port}", with: String(port))
        } else {
            resolved = template
        }
        guard let url = URL(string: resolved), url.scheme != nil else { return nil }
        return url
    }
}
