import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileRow: View {
    @Environment(AppState.self) private var state
    let job: Job
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: job.url, kind: job.kind)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(job.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if job.livePhotoVideo != nil {
                        Image(systemName: "livephoto")
                            .foregroundStyle(.secondary)
                            .help("Live Photo")
                    }
                }
                if case .running(let progress) = job.status {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 2)
                        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                } else {
                    DetailText(job: job, isBatchRunning: state.isRunning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(state.targetFormat(for: job).title)
                .font(.subheadline)
                .foregroundStyle(job.override != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(job.override != nil ? "Converts to \(state.targetFormat(for: job).title) with custom settings"
                                          : "Converts to \(state.targetFormat(for: job).title)")

            accessory
                .frame(width: 20, height: 20)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Mirrors Safari's download list: stop while running, reveal once finished.
    @ViewBuilder
    private var accessory: some View {
        switch job.status {
        case .running:
            RowButton(title: "Stop", systemImage: "xmark.circle.fill") { state.cancel(ids: [job.id]) }
        case .done where isHovering:
            RowButton(title: "Show in Finder", systemImage: "magnifyingglass.circle.fill") { state.reveal(job) }
        case .waiting where state.isRunning:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Waiting")
        default:
            StatusIcon(status: job.status)
        }
    }
}

private struct RowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

private struct DetailText: View {
    let job: Job
    let isBatchRunning: Bool

    var body: some View {
        switch job.status {
        case .done(let size):
            Text("\(bytes(job.fileSize)) → \(bytes(size))\(savings(size))\(note)")
        case .failed(let reason):
            Text(reason)
                .help(reason)
        case .running:
            Text(base)
        case .cancelled:
            Text("\(base) · Stopped")
        case .waiting:
            Text(base)
        }
    }

    private var base: String {
        "\(job.url.pathExtension.uppercased()) · \(bytes(job.fileSize))"
    }

    private var note: String {
        job.note.map { " · \($0)" } ?? ""
    }

    private func savings(_ size: Int64) -> String {
        guard job.fileSize > 0 else { return "" }
        let change = Double(size - job.fileSize) / Double(job.fileSize) * 100
        if change <= -1 { return " · \(Int((-change).rounded()))% smaller" }
        if change >= 1 { return " · \(Int(change.rounded()))% larger" }
        return ""
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct StatusIcon: View {
    let status: JobStatus

    var body: some View {
        switch status {
        case .waiting, .running:
            EmptyView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.large)
                .foregroundStyle(.green)
                .help("Converted")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .imageScale(.large)
                .foregroundStyle(.red)
                .help("Couldn’t Convert")
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .imageScale(.large)
                .foregroundStyle(.tertiary)
                .help("Stopped")
        }
    }
}

// MARK: Thumbnails

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

private struct Thumbnail: View {
    let url: URL
    let kind: MediaKind
    @State private var image: NSImage?

    private let size: CGFloat = 40

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .task(id: url) {
            guard kind != .audio else { return }
            if let cached = ThumbnailCache.shared.image(for: url) {
                image = cached
                return
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                ThumbnailCache.shared.store(rep.nsImage, for: url)
                image = rep.nsImage
            }
        }
    }
}
