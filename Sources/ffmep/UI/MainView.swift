import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        FileQueueView()
            .navigationTitle("ffmep")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: $state.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
            }
            .alert(replaceTitle, isPresented: $state.showReplaceConfirmation) {
                Button("Convert and Replace", role: .destructive) { state.confirmReplace() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each original is moved to the Trash once its converted file is saved. Files that fail to convert are kept.")
            }
            .alert("Download the High-Quality Background Model?", isPresented: $state.showSubjectModelOffer) {
                Button("Download (\(SubjectModelStore.sizeText))") { state.subjectModel.download() }
                    .keyboardShortcut(.defaultAction)
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Background removal already works with Apple's built-in model. BiRefNet cuts out subjects with much cleaner, more accurate edges, and runs entirely on this Mac.\n\nYou can download or remove it anytime in Settings.")
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            DestinationMenu()
                .disabled(state.isRunning)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.showAddPanel()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add Files (⌘O)")

            Menu {
                Button("Select All") { state.selectAll() }
                Button("Show in Finder") { state.reveal(state.selectedJobs) }
                    .disabled(state.selection.isEmpty)
                Divider()
                Button("Remove Converted Files") { state.clearCompleted() }
                    .disabled(!state.jobs.contains { $0.status.isDone })
                Button("Remove All Files", role: .destructive) { state.clearAll() }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .disabled(state.jobs.isEmpty)
            .help("More")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                ConvertControl()
            }
            .sharedBackgroundVisibility(state.isRunning ? .visible : .hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                ConvertControl()
            }
        }

        // While the inspector is open, its toggle lives in the inspector's half of the toolbar.
        if !state.showInspector {
            ToolbarItem(placement: .primaryAction) {
                InspectorToggle()
            }
        }
    }

    private var replaceTitle: String {
        let count = state.pendingReplace.count
        return count == 1 ? "Replace the Original File?" : "Replace \(count) Original Files?"
    }

    private var subtitle: String {
        if !state.isRunning, let message = state.statusMessage ?? state.toolsWarning {
            return message
        }
        let count = state.jobs.count
        guard count > 0 else { return "" }
        let bytes = state.jobs.reduce(Int64(0)) { $0 + $1.fileSize }
        return "\(count) \(count == 1 ? "File" : "Files") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

struct InspectorToggle: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.showInspector.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.right")
        }
        .help(state.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
    }
}
