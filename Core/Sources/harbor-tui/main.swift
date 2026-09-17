import ArgumentParser
import HarborCore

struct HarborTUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harbor-tui",
        abstract: "Terminal UI for Harbor — supervise projects and ports from your terminal.",
        version: harborVersion
    )

    func run() throws {
        // Interactive TUI lands with the panels PR; the library surface
        // (HarborTUIKit) is exercised by unit tests in the meantime.
        print("harbor-tui \(harborVersion) — interactive UI not wired up yet.")
    }
}

HarborTUI.main()
