import Foundation

/// What to export from a Live Photo (a still paired with a short video).
enum LivePhotoMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case still, gif, video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .still: "Still Image"
        case .gif: "Animated GIF"
        case .video: "Video"
        }
    }

    /// The format the motion part is written as, or nil when only the still is used.
    var outputFormat: OutputFormat? {
        switch self {
        case .still: nil
        case .gif: .gif
        case .video: .mp4
        }
    }
}
