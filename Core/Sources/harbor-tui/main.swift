import ArgumentParser
import Dispatch
import Foundation
import HarborCore
import HarborTUIKit

struct HarborTUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harbor-tui",
        abstract: "Terminal UI for Harbor — supervise projects and ports from your terminal.",
        version: harborVersion
    )

    func run() throws {
        // TuiApp is main-actor isolated; hop there and hand control to GCD's
        // main queue, which drains both the repaint timer and actor tasks.
        final class StartupFailure: @unchecked Sendable { var message: String? }
        let startupFailure = StartupFailure()
        Task { @MainActor in
            do {
                let app = try TuiApp()
                _ = app // strong ref kept in TuiApp.current; exit happens inside TuiApp
            } catch {
                startupFailure.message = error.localizedDescription
            }
        }
        dispatchMain()
        // Unreachable (dispatchMain never returns); kept for clarity.
        if let message = startupFailure.message {
            FileHandle.standardError.write(Data("harbor-tui: \(message)\n".utf8))
            Foundation.exit(1)
        }
    }
}

HarborTUI.main()
