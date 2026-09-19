import Foundation

/// Keeps the machine awake while enabled: blocks idle **system** sleep (the
/// display may still sleep) so long tasks — builds, downloads, training runs —
/// can run to completion. Backed by `ProcessInfo.beginActivity`; the assertion
/// is released automatically when Harbor exits, so sleep can never get stuck.
///
/// The choice persists in UserDefaults and is re-asserted on the next launch.
@MainActor
final class SleepGuard: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private var activity: NSObjectProtocol?

    private static let defaultsKey = "preventSleepEnabled"
    private static let reason = "Harbor: keep the machine awake for long tasks"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if isEnabled {
            begin()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            begin()
        } else {
            end()
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
    }

    private func begin() {
        // macOS has no .reasonString option; the reason still shows in
        // `pmset -g assertions` via the activity's naming.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: Self.reason
        )
    }

    private func end() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}
