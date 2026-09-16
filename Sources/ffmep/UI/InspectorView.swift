import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let selected = state.selectedJobs
        let kinds = visibleKinds(selected: selected)
        let current = kinds.contains(state.inspectorKind) ? state.inspectorKind : (kinds.first ?? .image)

        Form {
            if !selected.isEmpty {
                let hasOverrides = selected.contains { $0.override != nil }
                Section {
                    LabeledContent {
                        Button("Revert") { state.resetSelectedOverrides() }
                            .disabled(!hasOverrides)
                            .help("Use the same settings as the other files")
                    } label: {
                        Text(selected.count == 1 ? "1 File Selected" : "\(selected.count) Files Selected")
                        Text(hasOverrides ? "Using custom settings" : "Changes apply only to the selection")
                    }
                }
            }

            KindSettingsView(kind: current, settings: state.settingsBinding(for: current))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Same surface as the file list, so the grouped cards read as the only raised layer.
        .background(Color(nsColor: .controlBackgroundColor))
        .toolbar {
            // SwiftUI keeps an inspector's toolbar items after it collapses, so only add them while it's open.
            if state.showInspector {
                if kinds.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Picker("Media Type", selection: Binding(get: { current }, set: { state.inspectorKind = $0 })) {
                            ForEach(kinds) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        Text("\(current.title) Settings")
                            .font(.headline)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItem(placement: .primaryAction) {
                    InspectorToggle()
                }
            }
        }
    }

    private func visibleKinds(selected: [Job]) -> [MediaKind] {
        if !selected.isEmpty {
            let kinds = Set(selected.map(\.kind))
            return MediaKind.allCases.filter(kinds.contains)
        }
        return state.jobs.isEmpty ? MediaKind.allCases : state.kindsInQueue
    }
}
