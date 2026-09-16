import SwiftUI

/// Download status and actions for the BiRefNet background model.
struct SubjectModelRow: View {
    let store: SubjectModelStore
    /// Settings shows the installed state with a Remove button; the inspector hides the row instead.
    var showsInstalled = false

    var body: some View {
        switch store.phase {
        case .notInstalled:
            LabeledContent {
                Button("Download") { store.download() }
            } label: {
                Text("High-Quality Model")
                Text("Cleaner edges · \(SubjectModelStore.sizeText) download")
            }
        case .downloading(let fraction):
            LabeledContent {
                Button("Cancel") { store.cancel() }
            } label: {
                Text("Downloading Model… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                ProgressView(value: fraction)
            }
        case .installing:
            LabeledContent {
                ProgressView().controlSize(.small)
            } label: {
                Text("Installing Model…")
                Text("Preparing it for this Mac")
            }
        case .installed:
            if showsInstalled {
                LabeledContent {
                    Button("Remove") { store.remove() }
                } label: {
                    Text("BiRefNet")
                    Text("Installed")
                }
            }
        case .failed(let message):
            LabeledContent {
                Button("Try Again") { store.download() }
            } label: {
                Label("Download Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
            }
        }
    }
}
