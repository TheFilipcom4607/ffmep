import QuickLook
import SwiftUI

struct FileQueueView: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    var body: some View {
        @Bindable var state = state
        Group {
            if state.jobs.isEmpty {
                ContentUnavailableView {
                    Label(state.isAdding ? "Adding Files…" : "Drop Files to Convert", systemImage: "arrow.down.doc")
                } description: {
                    Text("Add videos, audio and photos, or drop a whole folder.")
                } actions: {
                    Button("Choose Files…") { state.showAddPanel() }
                        .glassButton()
                        .controlSize(.large)
                }
            } else {
                List(selection: $state.selection) {
                    ForEach(state.groupedJobs) { group in
                        Section {
                            ForEach(group.jobs) { job in
                                FileRow(job: job)
                                    .tag(job.id)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            HStack {
                                Text(group.kind.pluralTitle)
                                Spacer()
                                Text("\(group.jobs.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(for: ids)
                } primaryAction: { ids in
                    state.reveal(state.jobs.filter { ids.contains($0.id) })
                }
                .onKeyPress(.space) {
                    guard !state.selection.isEmpty else { return .ignored }
                    state.toggleQuickLook()
                    return .handled
                }
                .quickLookPreview($state.quickLookURL, in: state.quickLookItems)
                .onDeleteCommand {
                    state.remove(ids: state.selection)
                }
                .onExitCommand {
                    state.clearSelection()
                }
                .onChange(of: state.selection) {
                    state.syncInspectorWithSelection()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.tint.opacity(0.06)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            state.add(urls: files)
            return !files.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let jobs = state.jobs.filter { ids.contains($0.id) }
        if !jobs.isEmpty {
            Button("Quick Look") {
                state.selection = ids
                state.quickLookURL = state.bestURL(for: jobs[0])
            }
            Button("Show in Finder") {
                state.reveal(jobs)
            }
            Divider()
            if jobs.contains(where: { $0.status.isRunning }) {
                Button("Stop") { state.cancel(ids: ids) }
            } else {
                Button(jobs.contains { $0.status.isDone } ? "Convert Again" : "Convert") {
                    state.retry(ids: ids)
                }
                .disabled(state.isRunning)
            }
            Divider()
            Button(jobs.count == 1 ? "Remove from List" : "Remove \(jobs.count) Files from List") {
                state.remove(ids: ids)
            }
        }
    }
}
