import SwiftUI

/// Editor for a generated harbor.toml draft (from Procfile / package.json import):
/// the user reviews/edits the TOML before it is written to disk.
struct ImportDraftEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let root: URL
    @Binding var draft: ConfigImporter.Draft?
    @Binding var draftText: String
    var onSaved: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review generated harbor.toml").font(.headline)
            Text("Source: \(draft?.sourceName ?? "manual template") — edit below, then save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(draft?.notes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $draftText)
                .font(.system(size: 11, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save harbor.toml") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 540, height: 400)
    }

    private func save() {
        switch appState.writeConfig(text: draftText, at: root) {
        case .success:
            onSaved()
            dismiss()
        case .failure(let error):
            errorMessage = error.message
        }
    }
}
