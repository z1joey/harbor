import Foundation

/// One inclusive TCP port range in Harbor's allocation pool.
public struct PortRange: Hashable, Codable, Equatable, Sendable {
    public var from: Int
    public var to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    public var closedRange: ClosedRange<Int> { from...to }

    public var count: Int { max(0, to - from + 1) }

    public var label: String { "\(from)–\(to)" }
}

/// Configurable set of ports Harbor (and the harbor-toml skill) may hand out
/// as sticky `[[process]].port` leases. Persisted as `port-pool.json`.
public struct PortPool: Hashable, Codable, Equatable, Sendable {
    public var ranges: [PortRange]

    public static let defaultRange = PortRange(from: 8100, to: 8199)
    public static let `default` = PortPool(ranges: [defaultRange])

    public init(ranges: [PortRange]) {
        self.ranges = ranges
    }

    /// Every port in the pool, in range order (duplicates impossible after validate).
    public var ports: [Int] {
        ranges.flatMap { Array($0.from...$0.to) }
    }

    public var capacity: Int {
        ranges.reduce(0) { $0 + $1.count }
    }

    public func contains(_ port: Int) -> Bool {
        ranges.contains { $0.from <= port && port <= $0.to }
    }

    /// Compact range list, e.g. `8100–8199` or `8100–8199, 9000–9009`.
    public var summary: String {
        ranges.map(\.label).joined(separator: ", ")
    }

    public static func validate(_ pool: PortPool) throws {
        guard !pool.ranges.isEmpty else {
            throw PortPoolError.empty
        }
        for range in pool.ranges {
            guard (1...65535).contains(range.from), (1...65535).contains(range.to) else {
                throw PortPoolError.outOfRange(from: range.from, to: range.to)
            }
            guard range.from <= range.to else {
                throw PortPoolError.inverted(from: range.from, to: range.to)
            }
        }
        let ordered = pool.ranges.enumerated().sorted { $0.element.from < $1.element.from }
        for index in 1..<ordered.count {
            let previous = ordered[index - 1].element
            let current = ordered[index].element
            if current.from <= previous.to {
                throw PortPoolError.overlapping(previous, current)
            }
        }
    }
}

public enum PortPoolError: LocalizedError, Equatable {
    case empty
    case outOfRange(from: Int, to: Int)
    case inverted(from: Int, to: Int)
    case overlapping(PortRange, PortRange)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Port pool must contain at least one range."
        case .outOfRange(let from, let to):
            return "Port range \(from)–\(to) is outside 1–65535."
        case .inverted(let from, let to):
            return "Port range \(from)–\(to) is inverted (from must be ≤ to)."
        case .overlapping(let a, let b):
            return "Port ranges \(a.label) and \(b.label) overlap."
        }
    }
}
