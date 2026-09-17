import AppIntents
import Foundation

// The choices Shortcuts shows for each action's settings. Display names have to be literals,
// because they're read from the compiled app rather than at run time.

extension OutputFormat: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"

    static let caseDisplayRepresentations: [OutputFormat: DisplayRepresentation] = [
        .mp4: "MP4",
        .mov: "MOV",
        .mkv: "MKV",
        .webm: "WebM",
        .gif: "GIF",
        .mp3: "MP3",
        .m4a: "M4A",
        .wav: "WAV",
        .flac: "FLAC",
        .alac: "ALAC",
        .opus: "Opus",
        .jpeg: "JPEG",
        .png: "PNG",
        .webp: "WebP",
        .heic: "HEIC",
    ]
}

enum ImageFormat: String, AppEnum, CaseIterable {
    case jpeg, webp, png, heic, gif

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"

    static let caseDisplayRepresentations: [ImageFormat: DisplayRepresentation] = [
        .jpeg: "JPEG",
        .webp: "WebP",
        .png: "PNG",
        .heic: "HEIC",
        .gif: "GIF",
    ]

    var outputFormat: OutputFormat { OutputFormat(rawValue: rawValue)! }
}

enum VideoFormat: String, AppEnum, CaseIterable {
    case mp4, mov, mkv, webm, gif

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Video Format"

    static let caseDisplayRepresentations: [VideoFormat: DisplayRepresentation] = [
        .mp4: "MP4",
        .mov: "MOV",
        .mkv: "MKV",
        .webm: "WebM",
        .gif: "GIF",
    ]

    var outputFormat: OutputFormat { OutputFormat(rawValue: rawValue)! }
}

enum AudioFormat: String, AppEnum, CaseIterable {
    case mp3, m4a, wav, flac, alac, opus

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audio Format"

    static let caseDisplayRepresentations: [AudioFormat: DisplayRepresentation] = [
        .mp3: "MP3",
        .m4a: DisplayRepresentation(title: "M4A", subtitle: "AAC"),
        .wav: "WAV",
        .flac: "FLAC",
        .alac: DisplayRepresentation(title: "ALAC", subtitle: "Apple Lossless"),
        .opus: "Opus",
    ]

    var outputFormat: OutputFormat { OutputFormat(rawValue: rawValue)! }
}

enum VideoResolution: String, AppEnum, CaseIterable {
    case original, p2160, p1080, p720, p480

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Resolution"

    static let caseDisplayRepresentations: [VideoResolution: DisplayRepresentation] = [
        .original: "Original",
        .p2160: "2160p (4K)",
        .p1080: "1080p",
        .p720: "720p",
        .p480: "480p",
    ]

    var resize: ResizeOption { ResizeOption(rawValue: rawValue)! }
}

/// Remove Background's choices: there's no "Keep" when removing the background is the point.
enum CutoutBackground: String, AppEnum, CaseIterable {
    case transparent, white

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Background"

    static let caseDisplayRepresentations: [CutoutBackground: DisplayRepresentation] = [
        .transparent: "Transparent",
        .white: "White",
    ]

    var style: BackgroundStyle { BackgroundStyle(rawValue: rawValue)! }
}

extension QualityPreset: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"

    static let caseDisplayRepresentations: [QualityPreset: DisplayRepresentation] = [
        .small: DisplayRepresentation(title: "Small", subtitle: "Smallest files"),
        .balanced: "Balanced",
        .high: DisplayRepresentation(title: "High", subtitle: "Best quality"),
    ]
}

extension VideoCodec: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Codec"

    static let caseDisplayRepresentations: [VideoCodec: DisplayRepresentation] = [
        .h264: DisplayRepresentation(title: "H.264", subtitle: "MP4, MOV, MKV"),
        .hevc: DisplayRepresentation(title: "HEVC", subtitle: "MP4, MOV, MKV"),
        .prores: DisplayRepresentation(title: "ProRes", subtitle: "MOV"),
        .vp9: DisplayRepresentation(title: "VP9", subtitle: "WebM"),
        .av1: DisplayRepresentation(title: "AV1", subtitle: "MKV, WebM"),
    ]
}

extension FrameRateOption: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Frame Rate"

    static let caseDisplayRepresentations: [FrameRateOption: DisplayRepresentation] = [
        .original: "Original",
        .fps60: "60 fps",
        .fps30: "30 fps",
        .fps24: "24 fps",
        .fps15: "15 fps",
        .fps10: "10 fps",
    ]
}

extension MetadataMode: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metadata"

    static let caseDisplayRepresentations: [MetadataMode: DisplayRepresentation] = [
        .keep: "Keep",
        .removeLocation: DisplayRepresentation(title: "Remove Location", subtitle: "Keeps date and camera"),
        .removeAll: "Remove All",
    ]
}

extension BackgroundStyle: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Background"

    static let caseDisplayRepresentations: [BackgroundStyle: DisplayRepresentation] = [
        .keep: "Keep",
        .white: "White",
        .transparent: "Transparent",
    ]
}

extension SubjectDetector: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"

    static let caseDisplayRepresentations: [SubjectDetector: DisplayRepresentation] = [
        .biRefNet: DisplayRepresentation(title: "BiRefNet", subtitle: "Cleanest edges, when downloaded"),
        .vision: DisplayRepresentation(title: "Apple Vision", subtitle: "Faster"),
    ]
}
