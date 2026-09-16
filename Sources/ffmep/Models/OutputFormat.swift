import Foundation

enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    // Video
    case mp4, mov, mkv, webm, gif
    // Audio
    case mp3, m4a, wav, flac, alac, opus
    // Image
    case jpeg, png, webp, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webp: "WebP"
        case .webm: "WebM"
        case .opus: "Opus"
        default: rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .alac: "m4a"
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    var isAudio: Bool {
        switch self {
        case .mp3, .m4a, .wav, .flac, .alac, .opus: true
        default: false
        }
    }

    /// Real video containers (GIF is handled separately).
    var isVideoContainer: Bool {
        switch self {
        case .mp4, .mov, .mkv, .webm: true
        default: false
        }
    }

    var isStillImage: Bool {
        switch self {
        case .jpeg, .png, .webp, .heic: true
        default: false
        }
    }

    /// Formats ImageIO writes natively (fast path, no ffmpeg).
    var isImageIOWritable: Bool {
        switch self {
        case .jpeg, .png, .heic: true
        default: false
        }
    }

    /// Formats that can store transparency.
    var supportsAlpha: Bool {
        switch self {
        case .png, .webp, .heic, .gif: true
        default: false
        }
    }

    /// Lossless or quality-less formats: no quality slider, no target size.
    var hasQuality: Bool {
        switch self {
        case .wav, .flac, .alac, .png, .gif: false
        default: true
        }
    }

    var codecChoices: [VideoCodec] {
        switch self {
        case .mp4: [.hevc, .h264]
        case .mov: [.hevc, .h264, .prores]
        case .mkv: [.hevc, .h264, .av1]
        case .webm: [.vp9, .av1]
        default: []
        }
    }

    static func choices(for kind: MediaKind) -> [OutputFormat] {
        switch kind {
        case .video: [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a, .wav, .flac, .alac, .opus]
        case .audio: [.mp3, .m4a, .wav, .flac, .alac, .opus]
        case .image: [.webp, .jpeg, .png, .heic, .gif]
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc, prores, vp9, av1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .prores: "ProRes"
        case .vp9: "VP9"
        case .av1: "AV1"
        }
    }
}
