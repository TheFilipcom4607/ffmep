import SwiftUI

/// Toolbar control: Convert, or progress with a Stop button while a batch runs.
struct ConvertControl: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let pending = state.pendingJobs.count
        if state.isRunning {
            let counts = state.runCounts
            HStack(spacing: 8) {
                ProgressView(value: state.overallProgress)
                    .frame(width: 110)
                Text("\(counts.finished) of \(counts.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    state.cancel()
                } label: {
                    Label("Stop", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop Converting (⌘.)")
            }
            .padding(.leading, 6)
        } else {
            Button {
                state.convert()
            } label: {
                Text(pending == 0 ? "Convert" : "Convert \(pending) \(pending == 1 ? "File" : "Files")")
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(pending == 0 || state.tools == nil)
            .help("Convert (⌘↩)")
        }
    }
}

/// Toolbar menu choosing where converted files are saved.
struct DestinationMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let location = locationBinding.wrappedValue
        Menu {
            Picker("Save To", selection: locationBinding) {
                Label("Next to Originals", systemImage: "arrow.turn.down.right")
                    .tag(SaveLocation.nextToOriginal)
                Label(state.outputFolder?.lastPathComponent ?? "Folder…", systemImage: "folder")
                    .tag(SaveLocation.folder)
                Label("Replace Originals", systemImage: SaveLocation.replaceSymbol)
                    .tag(SaveLocation.replaceOriginal)
            }
            .pickerStyle(.inline)

            Divider()
            Button("Choose Folder…") { state.chooseOutputFolder() }
            if let folder = state.outputFolder {
                Button("Show Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        } label: {
            switch location {
            case .folder:
                Label(state.outputFolder?.lastPathComponent ?? "Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            case .replaceOriginal:
                Label("Replace Originals", systemImage: SaveLocation.replaceSymbol)
                    .labelStyle(.titleAndIcon)
            case .nextToOriginal:
                Label("Next to Originals", systemImage: "arrow.turn.down.right")
                    .labelStyle(.titleAndIcon)
            }
        }
        .help(help(for: location))
    }

    private func help(for location: SaveLocation) -> String {
        switch location {
        case .folder: "Save to \(state.outputFolder?.path ?? "a folder")"
        case .replaceOriginal: "Replace each original with its converted file. Originals are moved to the Trash."
        case .nextToOriginal: "Save next to each original file"
        }
    }

    private var locationBinding: Binding<SaveLocation> {
        Binding(
            get: { state.saveLocation == .folder && state.outputFolder == nil ? .nextToOriginal : state.saveLocation },
            set: { location in
                if location == .folder, state.outputFolder == nil {
                    state.chooseOutputFolder()
                } else {
                    state.saveLocation = location
                }
            }
        )
    }
}

extension SaveLocation {
    static let replaceSymbol = "arrow.triangle.2.circlepath"
}
