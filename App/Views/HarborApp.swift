import SwiftUI

@main
struct HarborApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        AppDelegate.sharedState = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appState)
        } label: {
            MenubarLabel(runningCount: appState.managedRunningCount,
                         hasConflict: appState.hasVisibleConflict)
        }
        .menuBarExtraStyle(.window)

        Window("Harbor", id: HarborApp.mainWindowID) {
            MainWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1020, height: 660)
        .commands {
            HarborCommands(appState: appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        // Kill managed trees so quitting Harbor doesn't orphan dev servers.
        MainActor.assumeIsolated {
            Self.sharedState?.stopEverythingForQuit()
        }
    }
}
