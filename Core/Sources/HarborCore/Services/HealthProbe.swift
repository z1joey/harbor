import Foundation

/// Polls a `ready_url` with short HTTP GETs until it succeeds or times out.
public enum HealthProbe {
    /// Returns true once the URL answers with HTTP 2xx/3xx; false on timeout or cancellation.
    public static func waitUntilReady(url: URL, timeout: TimeInterval = 45) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3.5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let (_, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
