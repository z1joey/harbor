import Foundation

/// A plain error carrying a user-readable message (usable as a Result failure type).
struct HarborError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
