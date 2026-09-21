import Foundation
import Combine

/// Thread-safe ring buffer of log lines (kept in memory, ~2000 lines per process).
/// Appends may come from any queue (process pipe readers); UI updates are coalesced
/// so fast-spewing processes don't flood the main thread.
public final class LogBuffer: ObservableObject {
    private let capacity: Int
    private var lines: [String] = []
    private var droppedLines = 0
    private let lock = NSLock()
    private var bumpScheduled = false

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public var capacityLimit: Int { capacity }

    /// Number of lines dropped from the front once the ring wrapped.
    public var droppedLineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedLines
    }

    public func appendLine(_ line: String) {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        lock.lock()
        lines.append(trimmed)
        if lines.count > capacity {
            droppedLines += lines.count - capacity
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
        scheduleBump()
    }

    /// Current lines (oldest first). Call again whenever `objectWillChange` fires.
    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    /// Snapshot plus the stable line number of `lines[0]` (`droppedLineCount`
    /// when the ring has wrapped). Line numbers stay unique across wraps, so
    /// views can key rows on them instead of array offsets.
    public func snapshotWithBase() -> (lines: [String], base: Int) {
        lock.lock(); defer { lock.unlock() }
        return (lines, droppedLines)
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        droppedLines = 0
        lock.unlock()
        objectWillChange.send()
    }

    private func scheduleBump() {
        lock.lock()
        let already = bumpScheduled
        bumpScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.bumpScheduled = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }
}
