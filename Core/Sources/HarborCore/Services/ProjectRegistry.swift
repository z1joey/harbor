import Foundation
import Darwin

/// Loads the list of registered project roots (`~/.harbor/projects.json`) and
/// keeps parsed `Project` values up to date by watching each config file for
/// changes.
///
/// The registry file is owned by the harbor-pilot skill (which appends project
/// roots, possibly while no Harbor frontend is running); it may also be edited
/// by hand. Harbor frontends only read it: both the GUI and the TUI watch the
/// `~/.harbor` directory, so either picks up registrations live — including
/// the skill's atomic tmp+rename replacement of the store.
@MainActor
public final class ProjectRegistry: ObservableObject {
    @Published public private(set) var projects: [Project] = []

    public let storeURL: URL
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: [String: DispatchWorkItem] = [:]
    private var storeWatcher: DispatchSourceFileSystemObject?
    private var storeReloadDebounce: DispatchWorkItem?

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            self.storeURL = HarborStoreLocation.projectsURL
            try? FileManager.default.createDirectory(
                at: HarborStoreLocation.harborDirectory, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Store

    /// Canonical project root path used as `Project.id` and in `projects.json`.
    private func normalizedRoot(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).standardizingPath)
    }

    private func readStore() -> [String] {
        guard let data = FileManager.default.contents(atPath: storeURL.path) else { return [] }
        if let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths
        }
        return []
    }

    // MARK: - Loading

    public func load() {
        projects = readStore().map { buildProject(root: normalizedRoot(URL(fileURLWithPath: $0))) }
        restartWatchers()
        restartStoreWatcher()
    }

    /// Re-reads the store after the skill (or a hand edit) changed it. A no-op
    /// when nothing really changed — e.g. directory events caused by the other
    /// store file being written.
    private func loadFromStore() {
        let paths = readStore()
        guard paths != projects.map(\.id) else { return }
        projects = paths.map { buildProject(root: normalizedRoot(URL(fileURLWithPath: $0))) }
        restartWatchers()
    }

    public func buildProject(root: URL) -> Project {
        switch HarborConfigParser.parse(root: root) {
        case .success(let parsed):
            return Project(root: root, name: parsed.name, processes: parsed.processes,
                           portClaims: parsed.portClaims,
                           openProcessName: parsed.openProcessName, openURL: parsed.openURL,
                           configFileName: parsed.configName, configError: nil)
        case .failure(let error):
            return Project(root: root, name: root.lastPathComponent, processes: [],
                           portClaims: [],
                           openProcessName: nil, openURL: nil,
                           configFileName: HarborConfigParser.locateConfig(in: root)?.lastPathComponent,
                           configError: error.localizedDescription)
        }
    }

    /// Cheap refresh of every project's parsed config (used on window focus).
    public func reloadAll() {
        guard !projects.isEmpty else { return }
        projects = projects.map { buildProject(root: $0.root) }
        restartWatchers()
    }

    /// Re-parses one project's config (config file changed on disk).
    public func reload(projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let root = projects[index].root
        projects[index] = buildProject(root: root)
        watch(project: projects[index])
    }

    // MARK: - Config watching

    private func restartWatchers() {
        for project in projects {
            watch(project: project)
        }
    }

    private func watch(project: Project) {
        watchers[project.id]?.cancel()
        watchers[project.id] = nil
        reloadDebounce[project.id]?.cancel()
        reloadDebounce[project.id] = nil
        guard let configURL = HarborConfigParser.locateConfig(in: project.root) else { return }
        let fd = open(configURL.path, O_EVTONLY)
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
        watchers[project.id] = source
    }

    private func scheduleReload(projectID: String) {
        reloadDebounce[projectID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload(projectID: projectID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        reloadDebounce[projectID] = work
    }

    // MARK: - Store watching

    /// Watches the directory holding the store rather than the store file:
    /// `~/.harbor/projects.json` may not exist yet (fresh install, the app
    /// never creates it), and the skill replaces the file via atomic rename —
    /// both surface as directory events.
    private func restartStoreWatcher() {
        storeWatcher?.cancel()
        storeWatcher = nil
        let directory = storeURL.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleStoreReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        storeWatcher = source
    }

    private func scheduleStoreReload() {
        storeReloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadFromStore()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        storeReloadDebounce = work
    }
}
