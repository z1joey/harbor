import Foundation

/// Canonical location of Harbor's on-disk state: the hidden `~/.harbor`
/// folder. Since 1.3 it is the single source of truth: one config TOML per
/// project under `projects/`, the pool in `port-pool.json`, and — during the
/// transition — the derived `projects.json` mirror kept by the harbor-pilot
/// skill, which writes all of it, possibly while no Harbor frontend is
/// running.
public enum HarborStoreLocation {
    /// `~/.harbor` — created on demand by frontends and the skill alike.
    public static var harborDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".harbor", isDirectory: true)
    }

    /// One config TOML per project lives here; the directory listing is the
    /// project registry. Frontends never read project roots for config.
    public static var projectsDirectory: URL {
        harborDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    /// Derived mirror of the registered roots (array of absolute paths),
    /// written by the skill for pre-1.3 consumers. Not read by 1.3 frontends.
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

    /// Written into the harbor root after the first legacy-migration pass.
    /// Once present, later launches never probe `~/Library/Application
    /// Support` again: probing another app identity's data triggers macOS
    /// 26's TCC app-data prompt on every launch of an ad-hoc-signed build,
    /// and the grant cannot persist for such builds.
    public static let legacyMigrationMarkerName = ".legacy-migration-done"

    /// Written into the harbor root after the first central-config import
    /// pass. Without it, a root whose config imports into an unparseable
    /// central file (bad legacy TOML, relative root, write failure) would be
    /// re-imported on every launch, piling up `<slug>-2.toml`, `-3.toml`, …
    public static let configMigrationMarkerName = ".config-migration-done"

    /// One-time move of the legacy Application Support stores into
    /// `~/.harbor`. Files already in `~/.harbor` always win (the skill may
    /// have created them); when two frontends race, the loser's move is a
    /// silent no-op. After the first pass a marker in the harbor root short-
    /// circuits every later launch, so the legacy domain is never touched
    /// again.
    public static func migrateLegacyStoresIfNeeded(legacy: URL = legacyDirectory,
                                                   target: URL = harborDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent(legacyMigrationMarkerName)
        guard !fm.fileExists(atPath: marker.path) else { return }
        defer { fm.createFile(atPath: marker.path, contents: nil) }
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

    // MARK: - Central config migration (1.3)

    /// One-time import of per-root `harbor.toml` / `.harbor.toml` files into
    /// the central `~/.harbor/projects/` store. For every root listed in the
    /// v1.2 registry (falling back to the App Support copy while only that
    /// exists) with no central config already declaring it, the root's config
    /// — if any — is copied in with a `root = "/abs/path"` key injected.
    ///
    /// Existing central files always win; the legacy registry and the root
    /// configs are never modified or deleted. Strictly one-shot: after the
    /// first pass a marker in the harbor root short-circuits every later
    /// launch, so a root whose import produced an unparseable central file
    /// is never re-imported (it shows up once, flagged, in the registry UI).
    public static func migrateLegacyConfigsIfNeeded(legacyRegistry: URL? = nil,
                                                    modernRegistry: URL? = nil,
                                                    legacyAppSupport: URL = legacyDirectory,
                                                    central: URL = projectsDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: central, withIntermediateDirectories: true)

        let marker = central.deletingLastPathComponent()
            .appendingPathComponent(configMigrationMarkerName)
        guard !fm.fileExists(atPath: marker.path) else { return }
        defer { fm.createFile(atPath: marker.path, contents: nil) }

        let registry: URL
        if let legacyRegistry {
            registry = legacyRegistry
        } else {
            let modern = modernRegistry ?? projectsURL
            if fm.fileExists(atPath: modern.path) {
                registry = modern
            } else {
                // The legacy fallback probes the App Support domain — skip it
                // entirely once a first migration pass has run (marker in the
                // harbor root), so later launches never touch it again.
                let marker = central.deletingLastPathComponent()
                    .appendingPathComponent(legacyMigrationMarkerName)
                guard !fm.fileExists(atPath: marker.path) else { return }
                registry = legacyAppSupport.appendingPathComponent("projects.json")
            }
        }
        guard let data = fm.contents(atPath: registry.path),
              let roots = try? JSONDecoder().decode([String].self, from: data) else { return }

        let covered = centralConfigRoots(central: central)
        for root in roots {
            let normalized = URL(fileURLWithPath: (root as NSString).standardizingPath)
            guard !covered.contains(normalized.standardizedFileURL.path) else { continue }
            guard let configURL = HarborConfigParser.locateConfig(in: normalized),
                  let text = try? String(contentsOf: configURL, encoding: .utf8) else { continue }
            let parsed = try? HarborConfigParser.parse(text: text)
            writeCentralConfig(text: text, root: normalized,
                               suggestedName: parsed?.name ?? normalized.lastPathComponent,
                               central: central)
        }
    }

    /// Roots declared by the central configs that parse cleanly.
    private static func centralConfigRoots(central: URL) -> Set<String> {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: central, includingPropertiesForKeys: nil)) ?? []
        var roots: Set<String> = []
        for url in urls where url.pathExtension == "toml" && !url.lastPathComponent.hasPrefix(".") {
            if case .success(let parsed) = HarborConfigParser.parse(configAt: url),
               let root = parsed.root {
                roots.insert(root.path)
            }
        }
        return roots
    }

    /// Copies TOML text into the central store as `<slug>.toml`, injecting a
    /// top-level `root` key when the text does not declare one. Collision
    /// names get `-2`, `-3`, … suffixes. Write errors are swallowed: the
    /// migration pass runs once (marker), so a failed import is simply lost —
    /// best-effort, matching the legacy-stores migration.
    private static func writeCentralConfig(text: String, root: URL, suggestedName: String,
                                           central: URL) {
        let fm = FileManager.default
        let declaresRoot = text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("root")
                && trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        let content = declaresRoot ? text : "root = \"\(root.standardizedFileURL.path)\"\n\n" + text

        let slug = sanitizeFilename(suggestedName)
        var candidate = central.appendingPathComponent("\(slug).toml")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = central.appendingPathComponent("\(slug)-\(suffix).toml")
            suffix += 1
        }
        try? content.write(to: candidate, atomically: true, encoding: .utf8)
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[^A-Za-z0-9._+-]"#, with: "-",
                                                options: .regularExpression)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "project" : trimmed
    }
}
