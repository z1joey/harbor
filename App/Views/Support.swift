import SwiftUI
import AppKit

/// Menu bar icon: ferry when idle, filled ferry + running count when anything
/// is up, warning triangle when a declared port is taken by a foreign PID.
struct MenubarLabel: View {
    let runningCount: Int
    let hasConflict: Bool

    var body: some View {
        if hasConflict {
            Label(runningCount > 0 ? "\(runningCount)" : "Harbor",
                  systemImage: "exclamationmark.triangle.fill")
        } else if runningCount > 0 {
            Label("\(runningCount)", systemImage: "ferry.fill")
        } else {
            Label("Harbor", systemImage: "ferry")
        }
    }
}

func statusColor(_ state: ProcessState) -> Color {
    switch state {
    case .stopped: return .gray
    case .starting: return .yellow
    case .running: return .green
    case .stopping: return .orange
    case .failed: return .red
    }
}

func statusText(_ status: ProcessStatus) -> String {
    switch status.state {
    case .running:
        if status.ready == true { return "running (ready)" }
        if status.ready == false { return "running (not ready)" }
        return "running"
    default:
        return status.state.rawValue
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
