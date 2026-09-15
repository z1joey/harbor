import Foundation

/// A registered project: a folder with a `harbor.toml` (or `.harbor.toml`).
/// If the config is invalid, `configError` is set and `processes` is empty.
struct Project: Identifiable, Hashable {
    let root: URL
    let name: String
    let processes: [ProcessDefinition]
    let configFileName: String?
    let configError: String?

    var id: String { root.path }

    func configURL() -> URL? {
        guard let configFileName else { return nil }
        return root.appendingPathComponent(configFileName)
    }
}
