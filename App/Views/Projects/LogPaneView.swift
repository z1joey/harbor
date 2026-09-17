import SwiftUI
import AppKit
import HarborCore

/// Live log tail for one managed process: ring buffer rendered as monospaced
/// lines, auto-scrolls to the bottom unless the user scrolls up.
struct LogPaneView: View {
    @ObservedObject var buffer: LogBuffer

    let processName: String
    var port: Int?
    var readyURL: URL?
    var isReady: Bool?

    @State private var lines: [String] = []
    @State private var follow = true

    private var openInBrowserURL: URL? {
        if let readyURL { return readyURL }
        if let port { return URL(string: "http://127.0.0.1:\(port)/") }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if buffer.droppedLineCount > 0 {
                            Text("… \(buffer.droppedLineCount) earlier lines dropped (ring buffer holds \(buffer.capacityLimit)) …")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .simultaneousGesture(
                    DragGesture().onChanged { value in
                        if value.translation.height > 8 { follow = false }
                    }
                )
                .onReceive(buffer.objectWillChange) { _ in
                    refreshLines(proxy: proxy)
                }
                .onAppear {
                    refreshLines(proxy: proxy)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func refreshLines(proxy: ScrollViewProxy) {
        lines = buffer.snapshot()
        guard follow, !lines.isEmpty else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(lines.count - 1, anchor: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.justify.left")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Logs — \(processName)")
                .font(.caption)
                .fontWeight(.medium)
            if let ready = isReady {
                Text(ready ? "ready" : "waiting…")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ready ? Color.green.opacity(0.25) : Color.yellow.opacity(0.25)))
            }
            Spacer()
            if let url = openInBrowserURL {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
            Button("Clear") {
                buffer.clear()
                lines = []
            }
            .controlSize(.small)
        }
    }
}
