import SwiftUI
import AppKit

/// Add Project flow: pick a folder → register it; if there's no harbor.toml,
/// offer to create a template or import one from Procfile / package.json.
struct AddProjectSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case pick
        case missingConfig(URL)
        case error(String)
    }

    @State private var step: Step = .pick
    @State private var addedProject: Project?
    @State private var drafts: [ConfigImporter.Draft] = []
    @State private var importDraft: ConfigImporter.Draft?
    @State private var importDraftText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .pick:
                pickStep
            case .missingConfig(let url):
                missingConfigStep(url)
            case .error(let message):
                errorStep(message)
            }
        }
        .padding(16)
        .frame(width: 480)
        .sheet(item: $importDraft) { draft in
            importEditor(draft)
        }
    }

    // MARK: - Steps

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Project").font(.headline)
            Text("Choose a folder that contains (or will contain) a harbor.toml.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Choose Folder…") { pickFolder() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func missingConfigStep(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Project").font(.headline)
            Text("No harbor.toml found in “\(url.lastPathComponent)”.")
                .font(.callout)
            if !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Harbor can generate a draft config from:").font(.caption).foregroundStyle(.secondary)
                    ForEach(drafts) { draft in
                        Button("Import from \(draft.sourceName)…") {
                            importDraft = draft
                            importDraftText = draft.toml
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Back", role: .cancel) { step = .pick }
                Button("Create Template & Add") {
                    register(url: url, createTemplate: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func errorStep(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Could Not Add Project").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Back", role: .cancel) { step = .pick }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func importEditor(_ draft: ConfigImporter.Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review generated harbor.toml").font(.headline)
            Text("Source: \(draft.sourceName) — edit below, then save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(draft.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $importDraftText)
                .font(.system(size: 11, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { importDraft = nil }
                Button("Save harbor.toml & Add") {
                    if case .missingConfig(let url) = step {
                        saveDraft(url: url)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 540, height: 400)
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a project folder"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if appState.configExists(at: url) {
            register(url: url, createTemplate: false)
        } else {
            drafts = appState.importDrafts(at: url)
            step = .missingConfig(url)
        }
    }

    private func register(url: URL, createTemplate: Bool) {
        switch appState.addProject(root: url, createTemplateIfMissing: createTemplate) {
        case .success(.added(let project)):
            addedProject = project
            dismiss()
        case .success(.missingConfig):
            drafts = appState.importDrafts(at: url)
            step = .missingConfig(url)
        case .failure(let error):
            step = .error(error.message)
        }
    }

    private func saveDraft(url: URL) {
        switch appState.writeConfig(text: importDraftText, at: url) {
        case .success:
            importDraft = nil
            register(url: url, createTemplate: false)
        case .failure(let error):
            importDraft = nil
            step = .error(error.message)
        }
    }
}
