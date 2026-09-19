import Foundation
import Darwin

/// Loads the projects registered in the central store — one config TOML per
/// project under `~/.harbor/projects/`, the directory listing being the
/// registry — and keeps parsed `Project` values up to date.
///
/// The store is owned by the harbor-pilot skill (which writes config files,
/// possibly while no Harbor frontend is running) and by hand edits. Harbor
/// frontends only read it: both the GUI and the TUI watch the central
/// directory plus each config file, so either picks up registrations,
/// updates, and unregistrations (file deletion) live — including the skill's
/// atomic tmp+rename writes.
@MainActor
public final class ProjectRegistry: ObservableObject {
    @Published public private(set) var projects: [Project] = []

    /// Directory holding one config TOML per project.
    public let centralDirectory: URL
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: [String: DispatchWorkItem] = [:]
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var directoryReloadDebounce: DispatchWorkItem?

    public init(centralDirectory: URL? = nil) {
        if let centralDirectory {
            self.centralDirectory = centralDirectory
        } else {
            self.centralDirectory = HarborStoreLocation.projectsDirectory
            try? FileManager.default.createDirectory(
                at: HarborStoreLocation.projectsDirectory, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Loading

    /// Config TOMLs in the central directory, sorted by filename. Dotfiles
    /// and editor/skill temp files are ignored.
    private func centralConfigURLs() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: centralDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "toml" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func load() {
        projects = Self.flagDuplicateRoots(centralConfigURLs().map(buildProject))
        restartWatchers()
        restartDirectoryWatcher()
    }

    /// Re-reads the store after the skill (or a hand edit) changed it. A
    /// no-op when nothing really changed — e.g. directory events caused by
    /// sibling files in `~/.harbor`.
    private func loadFromDirectory() {
        let reloaded = Self.flagDuplicateRoots(centralConfigURLs().map(buildProject))
        guard reloaded != projects else { return }
        projects = reloaded
        restartWatchers()
    }

    /// Spec failure mode: two configs declaring the same root both stay
    /// listed, but every entry after the first (by filename) is flagged so
    /// the conflict is discoverable.
    private static func flagDuplicateRoots(_ loaded: [Project]) -> [Project] {
        var firstByRoot: [String: String] = [:]
        return loaded.map { project in
            guard let root = project.root?.path else { return project }
            guard let first = firstByRoot[root] else {
                firstByRoot[root] = project.configFileName
                return project
            }
            return Project(configURL: project.configURL, root: project.root, name: project.name,
                           processes: [], portClaims: [],
                           openProcessName: nil, openURL: nil,
                           configError: "Root \(root) is already registered by \"\(first)\" — remove this duplicate config file.")
        }
    }

    public func buildProject(configAt: URL) -> Project {
        switch HarborConfigParser.parse(configAt: configAt) {
        case .success(let parsed):
            return Project(configURL: configAt, root: parsed.root, name: parsed.name,
                           processes: parsed.processes, portClaims: parsed.portClaims,
                           openProcessName: parsed.openProcessName, openURL: parsed.openURL,
                           configError: nil)
        case .failure(let error):
            return Project(configURL: configAt, root: nil,
                           name: configAt.deletingPathExtension().lastPathComponent,
                           processes: [], portClaims: [],
                           openProcessName: nil, openURL: nil,
                           configError: error.localizedDescription)
        }
    }

    /// Cheap refresh of every project's parsed config (used on window focus).
    public func reloadAll() {
        guard !projects.isEmpty else { return }
        projects = Self.flagDuplicateRoots(centralConfigURLs().map(buildProject))
        restartWatchers()
    }

    /// Re-parses one project's config (config file changed on disk).
    public func reload(projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let configURL = projects[index].configURL
        projects[index] = buildProject(configAt: configURL)
        watch(project: projects[index])
    }

    // MARK: - Config watching

    private func restartWatchers() {
        for project in projects {
            watch(project: project)
        }
    }

    private func watch(project: Project) {
        fileWatchers[project.id]?.cancel()
        fileWatchers[project.id] = nil
        reloadDebounce[project.id]?.cancel()
        reloadDebounce[project.id] = nil
        let fd = open(project.configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        let capturedID = project.id
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleReload(projectID: capturedID)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatchers[project.id] = source
    }

    private func scheduleReload(projectID: String) {
        reloadDebounce[projectID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload(projectID: projectID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        reloadDebounce[projectID] = work
    }

    // MARK: - Directory watching

    /// Watches the central directory itself: new config files (skill
    /// registrations) and deletions (unregistrations) surface as directory
    /// events; atomic renames never keep a stale per-file watcher armed. The
    /// load diff-guard makes events from sibling files in `~/.harbor` no-ops.
    private func restartDirectoryWatcher() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        let fd = open(centralDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDirectoryReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcher = source
    }

    private func scheduleDirectoryReload() {
        directoryReloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadFromDirectory()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        directoryReloadDebounce = work
    }
}
