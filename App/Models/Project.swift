import Foundation

/// A registered project: a folder with a `harbor.toml` (or `.harbor.toml`).
/// If the config is invalid, `configError` is set and `processes` is empty.
struct Project: Identifiable, Hashable {
    let root: URL
    let name: String
    let processes: [ProcessDefinition]
    let portClaims: [PortClaim]
    let configFileName: String?
    let configError: String?

    var id: String { root.path }

    /// Every port the project declares: each `[[process]]` `port` plus all
    /// `[[port_claim]]` entries. This is what conflict detection plans against.
    var claimedPorts: Set<Int> {
        var ports = Set(processes.compactMap(\.port))
        ports.formUnion(portClaims.map(\.port))
        return ports
    }

    func configURL() -> URL? {
        guard let configFileName else { return nil }
        return root.appendingPathComponent(configFileName)
    }
}
