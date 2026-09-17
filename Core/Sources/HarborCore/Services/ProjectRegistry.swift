import Foundation
import Darwin

/// Loads/saves the list of registered project roots
/// (`~/Library/Application Support/Harbor/projects.json`) and keeps parsed
/// `Project` values up to date by watching each config file for changes.
///
/// The registry file is shared between frontends (GUI app and TUI may run at
/// the same time): writes take an flock on a sibling `projects.json.lock`
/// (atomic rename makes locking the store inode itself racy), and the store
/// is watched so a frontend picks up the other's registrations.
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
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Harbor", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("projects.json")
        }
        load()
    }

    // MARK: - Store

    /// Canonical project root path used as `Project.id` and in `projects.json`.
    private func normalizedRoot(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).standardizingPath)
    }

    private func syncStoreFromMemory() {
        writeStore(projects.map(\.id))
    }

    private func readStore() -> [String] {
        guard let data = FileManager.default.contents(atPath: storeURL.path) else { return [] }
        if let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths
        }
        return []
    }

    private func writeStore(_ paths: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(paths) else { return }
        withStoreLock {
            try? data.write(to: storeURL, options: .atomic)
        }
        restartStoreWatcher()
    }

    /// Serializes store writes across frontends. The lock lives in a sibling
    /// file because `writeStore` replaces the store inode via atomic rename.
    private func withStoreLock<T>(_ body: () -> T) -> T {
        let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("projects.json.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    // MARK: - Loading

    public func load() {
        projects = readStore().map { buildProject(root: normalizedRoot(URL(fileURLWithPath: $0))) }
        syncStoreFromMemory()
        restartWatchers()
        restartStoreWatcher()
    }

    /// Re-reads the store after another frontend changed it. No write-back
    /// (the content just came from the store) and a no-op when nothing really
    /// changed — e.g. our own write bouncing back through the watcher.
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

    // MARK: - Add / Remove

    public enum AddError: LocalizedError {
        case notADirectory
        case alreadyRegistered
        case missingConfig

        public var errorDescription: String? {
            switch self {
            case .notADirectory: return "That path is not a folder."
            case .alreadyRegistered: return "This folder is already registered."
            case .missingConfig: return "No harbor.toml found in that folder."
            }
        }
    }

    /// Registers a project root. If the folder has no config and
    /// `createTemplateIfMissing` is true, writes a starter `harbor.toml` first
    /// (`suggestedPort` is baked into the template as a conflict-free hint).
    public func add(root: URL, createTemplateIfMissing: Bool, suggestedPort: Int? = nil) -> Result<Project, Error> {
        let root = normalizedRoot(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(AddError.notADirectory)
        }
        guard !projects.contains(where: { $0.id == root.path }) else {
            return .failure(AddError.alreadyRegistered)
        }
        if HarborConfigParser.locateConfig(in: root) == nil {
            guard createTemplateIfMissing else { return .failure(AddError.missingConfig) }
            switch createTemplate(root: root, suggestedPort: suggestedPort) {
            case .success: break
            case .failure(let error): return .failure(error)
            }
        }
        let project = buildProject(root: root)
        projects.append(project)
        syncStoreFromMemory()
        watch(project: project)
        return .success(project)
    }

    /// Unregisters the project — files on disk are left alone.
    public func remove(projectID: String) {
        projects.removeAll { $0.id == projectID }
        syncStoreFromMemory()
        watchers[projectID]?.cancel()
        watchers[projectID] = nil
        reloadDebounce[projectID]?.cancel()
        reloadDebounce[projectID] = nil
    }

    public func createTemplate(root: URL, suggestedPort: Int? = nil) -> Result<URL, Error> {
        let url = root.appendingPathComponent("harbor.toml")
        do {
            try HarborConfigParser.templateText(projectName: root.lastPathComponent, suggestedPort: suggestedPort)
                .write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(HarborConfigError.readFailed("Could not write template harbor.toml: \(error.localizedDescription)"))
        }
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

    // MARK: - Store watching (cross-frontend)

    private func restartStoreWatcher() {
        storeWatcher?.cancel()
        storeWatcher = nil
        let fd = open(storeURL.path, O_EVTONLY)
        guard fd >= 0 else { return } // store may not exist yet; re-armed on first write
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
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
