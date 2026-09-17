import Foundation

/// A registered project: a folder with a `harbor.toml` (or `.harbor.toml`).
/// If the config is invalid, `configError` is set and `processes` is empty.
public struct Project: Identifiable, Hashable {
    public let root: URL
    public let name: String
    public let processes: [ProcessDefinition]
    public let portClaims: [PortClaim]
    /// Process name from `open_process` — used by "Open in Browser" at project level.
    public let openProcessName: String?
    /// Static URL from `open_url` — used when set instead of `open_process`.
    public let openURL: URL?
    public let configFileName: String?
    public let configError: String?

    public var id: String { root.path }

    public init(root: URL, name: String, processes: [ProcessDefinition], portClaims: [PortClaim],
                openProcessName: String?, openURL: URL?, configFileName: String?, configError: String?) {
        self.root = root
        self.name = name
        self.processes = processes
        self.portClaims = portClaims
        self.openProcessName = openProcessName
        self.openURL = openURL
        self.configFileName = configFileName
        self.configError = configError
    }

    /// Every port the project declares: each `[[process]]` `port` plus all
    /// `[[port_claim]]` entries. This is what conflict detection plans against.
    public var claimedPorts: Set<Int> {
        var ports = Set(processes.compactMap(\.port))
        ports.formUnion(portClaims.map(\.port))
        return ports
    }

    public func configURL() -> URL? {
        guard let configFileName else { return nil }
        return root.appendingPathComponent(configFileName)
    }
}
