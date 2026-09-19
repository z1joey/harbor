import SwiftUI
import HarborCore

/// Editor for Harbor's port pool (`port-pool.json`). One or more inclusive ranges.
struct PortPoolEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    struct DraftRange: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
    }

    @State private var drafts: [DraftRange]
    @State private var errorMessage: String?

    init(pool: PortPool) {
        _drafts = State(initialValue: pool.ranges.map {
            DraftRange(from: String($0.from), to: String($0.to))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit port pool").font(.headline)
            Text("Harbor and the harbor-pilot skill hand out sticky process ports from these ranges. Default is 8100–8199.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($drafts) { $draft in
                HStack(spacing: 8) {
                    TextField("from", text: $draft.from)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("–")
                    TextField("to", text: $draft.to)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                    Button(role: .destructive) {
                        drafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .disabled(drafts.count <= 1)
                    .help("Remove range")
                }
            }
            Button("Add range") {
                drafts.append(DraftRange(from: "", to: ""))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func save() {
        var ranges: [PortRange] = []
        for draft in drafts {
            guard let from = Int(draft.from.trimmingCharacters(in: .whitespaces)),
                  let to = Int(draft.to.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Each range needs integer from/to ports."
                return
            }
            ranges.append(PortRange(from: from, to: to))
        }
        let pool = PortPool(ranges: ranges)
        do {
            try appState.portPoolStore.save(pool)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
