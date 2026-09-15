import SwiftUI

@main
struct HarborApp: App {
    var body: some Scene {
        MenuBarExtra("Harbor", systemImage: "ferry") {
            Text("Harbor")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
