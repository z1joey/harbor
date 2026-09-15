import Foundation

/// Loads/saves the list of registered project roots
/// (`~/Library/Application Support/Harbor/projects.json`) and keeps parsed
/// `Project` values up to date by watching each config file for changes.
@MainActor
final class ProjectRegistry: ObservableObject {
    @Published private(set) var projects: [Project] = []

    let storeURL: URL
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: [String: DispatchWorkItem] = [:]

    init(storeURL: URL? = nil) {
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
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Loading

    func load() {
        projects = readStore().map { buildProject(root: URL(fileURLWithPath: $0)) }
        restartWatchers()
    }

    func buildProject(root: URL) -> Project {
        switch HarborConfigParser.parse(root: root) {
        case .success(let parsed):
            return Project(root: root, name: parsed.name, processes: parsed.processes,
                           configFileName: parsed.configName, configError: nil)
        case .failure(let error):
            return Project(root: root, name: root.lastPathComponent, processes: [],
                           configFileName: HarborConfigParser.locateConfig(in: root)?.lastPathComponent,
                           configError: error.localizedDescription)
        }
    }

    /// Cheap refresh of every project's parsed config (used on window focus).
    func reloadAll() {
        guard !projects.isEmpty else { return }
        projects = projects.map { buildProject(root: $0.root) }
        restartWatchers()
    }

    // MARK: - Add / Remove

    enum AddError: LocalizedError {
        case notADirectory
        case alreadyRegistered
        case missingConfig

        var errorDescription: String? {
            switch self {
            case .notADirectory: return "That path is not a folder."
            case .alreadyRegistered: return "This folder is already registered."
            case .missingConfig: return "No harbor.toml found in that folder."
            }
        }
    }

    /// Registers a project root. If the folder has no config and
    /// `createTemplateIfMissing` is true, writes a starter `harbor.toml` first.
    func add(root: URL, createTemplateIfMissing: Bool) -> Result<Project, Error> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(AddError.notADirectory)
        }
        guard !projects.contains(where: { $0.id == root.path }) else {
            return .failure(AddError.alreadyRegistered)
        }
        if HarborConfigParser.locateConfig(in: root) == nil {
            guard createTemplateIfMissing else { return .failure(AddError.missingConfig) }
            switch createTemplate(root: root) {
            case .success: break
            case .failure(let error): return .failure(error)
            }
        }
        var paths = readStore()
        paths.append(root.path)
        writeStore(paths)
        let project = buildProject(root: root)
        projects.append(project)
        watch(project: project)
        return .success(project)
    }

    /// Unregisters the project — files on disk are left alone.
    func remove(projectID: String) {
        projects.removeAll { $0.id == projectID }
        writeStore(readStore().filter { $0 != projectID })
        watchers[projectID]?.cancel()
        watchers[projectID] = nil
        reloadDebounce[projectID]?.cancel()
        reloadDebounce[projectID] = nil
    }

    func createTemplate(root: URL) -> Result<URL, Error> {
        let url = root.appendingPathComponent("harbor.toml")
        do {
            try HarborConfigParser.templateText(projectName: root.lastPathComponent)
                .write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(HarborConfigError.readFailed("Could not write template harbor.toml: \(error.localizedDescription)"))
        }
    }

    /// Re-parses one project's config (config file changed on disk).
    func reload(projectID: String) {
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
}
