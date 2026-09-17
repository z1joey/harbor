import Foundation

/// A port a project relies on without belonging to one specific `[[process]]`
/// — infrastructure like a database or message broker, or processes that
/// listen on several ports. Declared via `[[port_claim]]` in `harbor.toml`;
/// feeds static overlap detection and the ports overview.
public struct PortClaim: Identifiable, Hashable {
    public let port: Int
    /// Optional human label, e.g. "postgres".
    public let note: String?
    /// Optional `[[process]]` name this claim belongs to (display only).
    public let processName: String?

    public var id: Int { port }

    public init(port: Int, note: String? = nil, processName: String? = nil) {
        self.port = port
        self.note = note
        self.processName = processName
    }
}
