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
        Task { @MainActor in
            do {
                let app = try TuiApp()
                _ = app // strong ref kept in TuiApp.current; exit happens inside TuiApp
            } catch {
                // Startup failed (no TTY, …): there is no terminal session to
                // restore, and dispatchMain would park us forever with the
                // error unheard — report and bail out now.
                FileHandle.standardError.write(Data("harbor-tui: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        dispatchMain()
    }
}

HarborTUI.main()
