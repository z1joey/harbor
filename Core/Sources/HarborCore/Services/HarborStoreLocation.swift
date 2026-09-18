import Foundation

/// Canonical location of Harbor's on-disk state: the hidden `~/.harbor`
/// folder. It holds the Port Allocation Convention (`projects.json` +
/// `port-pool.json`) and is shared with the harbor-pilot skill, which
/// registers projects by appending to `projects.json` — possibly while no
/// Harbor frontend is running.
public enum HarborStoreLocation {
    /// `~/.harbor` — created on demand by frontends and the skill alike.
    public static var harborDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".harbor", isDirectory: true)
    }

    /// Registered project roots (JSON array of absolute paths).
    public static var projectsURL: URL {
        harborDirectory.appendingPathComponent("projects.json")
    }

    /// Pool ranges the convention may hand out.
    public static var portPoolURL: URL {
        harborDirectory.appendingPathComponent("port-pool.json")
    }

    /// Pre-`~/.harbor` store location; read once at startup for migration.
    public static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harbor", isDirectory: true)
    }

    /// One-time move of the legacy Application Support stores into
    /// `~/.harbor`. Files already in `~/.harbor` always win (the skill may
    /// have created them); when two frontends race, the loser's move is a
    /// silent no-op.
    public static func migrateLegacyStoresIfNeeded(legacy: URL = legacyDirectory,
                                                   target: URL = harborDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        for name in ["projects.json", "port-pool.json"] {
            let from = legacy.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
        // Lock sidecars belong to the writers, and writers now live in ~/.harbor.
        for name in ["projects.json.lock", "port-pool.json.lock"] {
            try? fm.removeItem(at: legacy.appendingPathComponent(name))
        }
        let leftovers = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
        if leftovers.isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }
}
