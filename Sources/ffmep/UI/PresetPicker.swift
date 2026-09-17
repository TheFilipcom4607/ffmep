import SwiftUI

/// Pop-up of saved presets for one media type, with Save and Delete at the bottom like other macOS pop-ups.
struct PresetPicker: View {
    @Environment(AppState.self) private var state
    let kind: MediaKind
    @Binding var settings: ConversionSettings

    @State private var isNaming = false
    @State private var name = ""
    @State private var deleting: Preset?
    /// Two presets can hold the same settings, so remember which one was picked.
    @State private var picked: UUID?

    private enum Choice: Hashable {
        case custom
        case preset(UUID)
        case save
        case delete
    }

    var body: some View {
        let presets = state.presets(for: kind)
        let matches = presets.filter { $0.settings == settings }
        let current = matches.first { $0.id == picked } ?? matches.first

        Picker("Preset", selection: selection(presets: presets, current: current)) {
            if current == nil {
                Text("Custom").tag(Choice.custom)
                if !presets.isEmpty { Divider() }
            }
            ForEach(presets) { Text($0.name).tag(Choice.preset($0.id)) }
            Divider()
            Text("Save as Preset…").tag(Choice.save)
            if let current {
                Text("Delete “\(current.name)”…").tag(Choice.delete)
            }
        }
        .help("Saved settings, also available in the Shortcuts app")
        .alert("Save Preset", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Save") { state.savePreset(named: name, kind: kind, settings: settings) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current \(kind.title.lowercased()) settings. Using the name of an existing preset updates it.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: deletingBinding) {
            Button("Delete", role: .destructive) {
                if let deleting { state.deletePreset(id: deleting.id) }
            }
        } message: {
            Text("Shortcuts that use this preset will stop working.")
        }
    }

    private func selection(presets: [Preset], current: Preset?) -> Binding<Choice> {
        Binding(
            get: { current.map { .preset($0.id) } ?? .custom },
            set: { choice in
                switch choice {
                case .custom:
                    break
                case .preset(let id):
                    if let preset = presets.first(where: { $0.id == id }) {
                        picked = id
                        settings = preset.settings
                    }
                case .save:
                    name = ""
                    isNaming = true
                case .delete:
                    deleting = current
                }
            }
        )
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
