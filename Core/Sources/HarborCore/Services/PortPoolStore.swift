import Foundation
import Darwin

/// Loads/saves Harbor's port pool (`~/Library/Application Support/Harbor/port-pool.json`).
/// Shared by the GUI and TUI; the harbor-toml skill reads the same file.
///
/// Missing or unreadable files resolve to `PortPool.default` (8100–8199)
/// without writing, so a fresh install and the skill agree without a seed file.
@MainActor
public final class PortPoolStore: ObservableObject {
    @Published public private(set) var pool: PortPool = .default

    public let storeURL: URL
    private var storeWatcher: DispatchSourceFileSystemObject?
    private var storeReloadDebounce: DispatchWorkItem?

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Harbor", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("port-pool.json")
        }
        load()
    }

    /// Re-reads the file. Invalid / missing content keeps the in-memory default
    /// (or the last valid pool) rather than crashing the app.
    public func load() {
        pool = readStore() ?? .default
        restartStoreWatcher()
    }

    /// Validates and persists `pool`, then publishes it.
    public func save(_ pool: PortPool) throws {
        try PortPool.validate(pool)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pool)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        withStoreLock {
            try? data.write(to: storeURL, options: .atomic)
        }
        self.pool = pool
        restartStoreWatcher()
    }

    private func readStore() -> PortPool? {
        guard let data = FileManager.default.contents(atPath: storeURL.path) else { return nil }
        guard let decoded = try? JSONDecoder().decode(PortPool.self, from: data) else { return nil }
        do {
            try PortPool.validate(decoded)
            return decoded
        } catch {
            return nil
        }
    }

    private func withStoreLock<T>(_ body: () -> T) -> T {
        let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("port-pool.json.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private func restartStoreWatcher() {
        storeWatcher?.cancel()
        storeWatcher = nil
        let fd = open(storeURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
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

    private func loadFromStore() {
        let loaded = readStore() ?? .default
        guard loaded != pool else { return }
        pool = loaded
    }
}
