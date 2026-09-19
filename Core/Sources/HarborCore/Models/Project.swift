import Foundation

/// A registered project, defined by one config TOML under
/// `~/.harbor/projects/` — the config file is the project's identity
/// (`id`). `root` is the folder Harbor runs commands in, declared by the
/// config's `root` key. If the config is invalid, `configError` is set,
/// `processes` is empty, and `root` may be nil (missing/invalid `root` key).
public struct Project: Identifiable, Hashable {
    public let configURL: URL
    public let root: URL?
    public let name: String
    public let processes: [ProcessDefinition]
    public let portClaims: [PortClaim]
    /// Process name from `open_process` — used by "Open in Browser" at project level.
    public let openProcessName: String?
    /// Static URL from `open_url` — used when set instead of `open_process`.
    public let openURL: URL?
    public let configError: String?

    public var id: String { configURL.path }
    public var configFileName: String { configURL.lastPathComponent }

    public init(configURL: URL, root: URL?, name: String, processes: [ProcessDefinition], portClaims: [PortClaim],
                openProcessName: String?, openURL: URL?, configError: String?) {
        self.configURL = configURL
        self.root = root
        self.name = name
        self.processes = processes
        self.portClaims = portClaims
        self.openProcessName = openProcessName
        self.openURL = openURL
        self.configError = configError
    }

    /// Every port the project declares: each `[[process]]` `port` plus all
    /// `[[port_claim]]` entries. This is what conflict detection plans against.
    public var claimedPorts: Set<Int> {
        var ports = Set(processes.compactMap(\.port))
        ports.formUnion(portClaims.map(\.port))
        return ports
    }
}
