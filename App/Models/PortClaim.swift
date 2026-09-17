import Foundation

/// A port a project relies on without belonging to one specific `[[process]]`
/// — infrastructure like a database or message broker, or processes that
/// listen on several ports. Declared via `[[port_claim]]` in `harbor.toml`;
/// feeds static overlap detection and the ports overview.
struct PortClaim: Identifiable, Hashable {
    let port: Int
    /// Optional human label, e.g. "postgres".
    let note: String?
    /// Optional `[[process]]` name this claim belongs to (display only).
    let processName: String?

    var id: Int { port }
}
