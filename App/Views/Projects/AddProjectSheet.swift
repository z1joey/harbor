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
        case reviewOverlap(URL)
        case error(String)
    }

    @State private var step: Step = .pick
    @State private var addedProject: Project?
    @State private var drafts: [ConfigImporter.Draft] = []
    @State private var importDraft: ConfigImporter.Draft?
    @State private var importDraftText = ""
    @State private var pendingOverlaps: [PortPlanner.StaticOverlap] = []
    @State private var overlapCandidateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .pick:
                pickStep
            case .missingConfig(let url):
                missingConfigStep(url)
            case .reviewOverlap(let url):
                reviewOverlapStep(url)
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
            Text("Suggested free ports: \(formatPorts(appState.suggestedFreePorts()))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back", role: .cancel) { step = .pick }
                Button("Create Template & Add") {
                    register(url: url, createTemplate: true,
                             suggestedPort: appState.suggestedFreePorts(count: 1).first)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Shown when the folder's config claims ports that other registered
    /// projects claim too — the user can still add it, knowingly.
    private func reviewOverlapStep(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port Overlaps").font(.headline)
            Text("“\(overlapCandidateName)” claims ports that other projects claim as well:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pendingOverlaps) { overlap in
                    Label("Port \(overlap.port) — also claimed by \(overlap.projects.filter { $0 != overlapCandidateName }.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("Only one project can bind a port at a time. Pick distinct ports per project, or let Harbor help you free them at start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Free right now: \(formatPorts(appState.suggestedFreePorts()))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back", role: .cancel) { step = .pick }
                Button("Add Anyway") { register(url: url, createTemplate: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func formatPorts(_ ports: [Int]) -> String {
        ports.isEmpty ? "none" : ports.map(String.init).joined(separator: ", ")
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
            ForEach(appState.overlapsInDraft(importDraftText)) { overlap in
                Label("Port \(overlap.port) is also claimed by \(overlap.projects.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Label("Free ports right now: \(appState.suggestedFreePorts(count: 3).map(String.init).joined(separator: ", "))",
                  systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            reviewThenRegister(url: url)
        } else {
            drafts = appState.importDrafts(at: url)
            step = .missingConfig(url)
        }
    }

    /// Projects whose config claims ports that registered projects claim too
    /// get one explicit review screen before they are added.
    private func reviewThenRegister(url: URL) {
        let overlaps = appState.overlapsWhenAdding(root: url)
        guard !overlaps.isEmpty else {
            register(url: url, createTemplate: false)
            return
        }
        pendingOverlaps = overlaps
        if case .success(let parsed) = HarborConfigParser.parse(root: url) {
            overlapCandidateName = parsed.name
        } else {
            overlapCandidateName = url.lastPathComponent
        }
        step = .reviewOverlap(url)
    }

    private func register(url: URL, createTemplate: Bool, suggestedPort: Int? = nil) {
        switch appState.addProject(root: url, createTemplateIfMissing: createTemplate, suggestedPort: suggestedPort) {
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
