import Foundation

/// A plain error carrying a user-readable message (usable as a Result failure type).
public struct HarborError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
