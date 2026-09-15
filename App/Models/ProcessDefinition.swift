import Foundation

/// One `[[process]]` entry parsed from a project's `harbor.toml`.
struct ProcessDefinition: Identifiable, Hashable {
    let name: String
    let command: String
    let cwd: String?
    let port: Int?
    let readyURL: URL?
    let autoRestart: Bool
    let env: [String: String]

    var id: String { name }
}
