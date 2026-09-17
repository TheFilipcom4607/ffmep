import Foundation

enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    case small, balanced, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var value: Double {
        switch self {
        case .small: 35
        case .balanced: 65
        case .high: 88
        }
    }
}

enum ResizeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, p2160, p1080, p720, p480, custom, percent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "2160p (4K)"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .custom: "Custom"
        case .percent: "Percentage"
        }
    }

    /// Presets cap the shorter side, so portrait phone video works as expected.
    var shortSide: Int? {
        switch self {
        case .p2160: 2160
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        default: nil
        }
    }

    static func choices(for kind: MediaKind) -> [ResizeOption] {
        kind == .image ? allCases : [.original, .p2160, .p1080, .p720, .p480, .custom]
    }
}

enum Rotation: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, cw90, ccw90, r180

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .cw90: "90° Clockwise"
        case .ccw90: "90° Counterclockwise"
        case .r180: "180°"
        }
    }

    var swapsDimensions: Bool { self == .cw90 || self == .ccw90 }
}

enum FrameRateOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, fps60, fps30, fps24, fps15, fps10

    var id: String { rawValue }

    var value: Double? {
        switch self {
        case .original: nil
        case .fps60: 60
        case .fps30: 30
        case .fps24: 24
        case .fps15: 15
        case .fps10: 10
        }
    }

    var title: String { value.map { "\(Int($0)) fps" } ?? "Original" }
}

struct ConversionSettings: Codable, Equatable, Sendable {
    var format: OutputFormat
    var quality: Double = QualityPreset.balanced.value
    var targetSizeEnabled = false
    var targetSizeMB: Double = 10
    var resize: ResizeOption = .original
    var customWidth = 1920
    var customHeight = 1080
    var percent = 50
    var noUpscale = true
    var videoCodec: VideoCodec = .hevc
    var maxCompression = false
    var metadata: MetadataMode = .keep
    var rotation: Rotation = .none
    var flipHorizontal = false
    var flipVertical = false
    var frameRate: FrameRateOption = .original
    var background: BackgroundStyle = .keep
    var subjectDetector: SubjectDetector = .biRefNet
    var livePhotoMode: LivePhotoMode = .still

    init(format: OutputFormat) {
        self.format = format
    }

    static func defaults(for kind: MediaKind) -> ConversionSettings {
        switch kind {
        case .video: ConversionSettings(format: .mp4)
        case .audio: ConversionSettings(format: .mp3)
        case .image: ConversionSettings(format: .webp)
        }
    }

    var preset: QualityPreset? {
        QualityPreset.allCases.first { abs($0.value - quality) < 0.5 }
    }

    /// The codec actually used, falling back when the stored codec doesn't fit the format.
    var effectiveCodec: VideoCodec {
        let choices = format.codecChoices
        return choices.contains(videoCodec) ? videoCodec : (choices.first ?? .h264)
    }

    var showsQuality: Bool {
        format.hasQuality
    }

    var supportsTargetSize: Bool {
        format.hasQuality && !(format.isVideoContainer && effectiveCodec == .prores)
    }

    var usesTargetSize: Bool { targetSizeEnabled && supportsTargetSize && targetSizeMB > 0 }

    /// Settings for the video part of a Live Photo, or nil when only the still is exported.
    /// Size and orientation carry over from the image settings.
    func motionSettings() -> ConversionSettings? {
        guard let format = livePhotoMode.outputFormat else { return nil }
        var motion = ConversionSettings(format: format)
        motion.quality = quality
        motion.resize = resize
        motion.customWidth = customWidth
        motion.customHeight = customHeight
        motion.percent = percent
        motion.noUpscale = noUpscale
        motion.rotation = rotation
        motion.flipHorizontal = flipHorizontal
        motion.flipVertical = flipVertical
        motion.metadata = metadata
        motion.videoCodec = .h264
        return motion
    }

    /// Whether video encoding runs on the CPU (affects scheduling lane).
    var usesSoftwareVideo: Bool {
        guard format.isVideoContainer else { return format == .gif }
        switch effectiveCodec {
        case .vp9, .av1: return true
        case .prores: return false
        case .h264, .hevc: return maxCompression
        }
    }

    // Tolerant decoding so settings saved by older versions still load.
    enum CodingKeys: String, CodingKey {
        case format, quality, targetSizeEnabled, targetSizeMB, resize, customWidth, customHeight,
             percent, noUpscale, videoCodec, maxCompression, metadata, rotation,
             flipHorizontal, flipVertical, frameRate, background, subjectDetector, livePhotoMode
    }

    /// Before Remove Location existed, metadata was a single on/off switch.
    private enum LegacyKeys: String, CodingKey {
        case stripMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(format: try c.decode(OutputFormat.self, forKey: .format))
        quality = (try? c.decode(Double.self, forKey: .quality)) ?? quality
        targetSizeEnabled = (try? c.decode(Bool.self, forKey: .targetSizeEnabled)) ?? targetSizeEnabled
        targetSizeMB = (try? c.decode(Double.self, forKey: .targetSizeMB)) ?? targetSizeMB
        resize = (try? c.decode(ResizeOption.self, forKey: .resize)) ?? resize
        customWidth = (try? c.decode(Int.self, forKey: .customWidth)) ?? customWidth
        customHeight = (try? c.decode(Int.self, forKey: .customHeight)) ?? customHeight
        percent = (try? c.decode(Int.self, forKey: .percent)) ?? percent
        noUpscale = (try? c.decode(Bool.self, forKey: .noUpscale)) ?? noUpscale
        videoCodec = (try? c.decode(VideoCodec.self, forKey: .videoCodec)) ?? videoCodec
        maxCompression = (try? c.decode(Bool.self, forKey: .maxCompression)) ?? maxCompression
        if let mode = try? c.decode(MetadataMode.self, forKey: .metadata) {
            metadata = mode
        } else if (try? decoder.container(keyedBy: LegacyKeys.self).decode(Bool.self, forKey: .stripMetadata)) == true {
            metadata = .removeAll
        }
        rotation = (try? c.decode(Rotation.self, forKey: .rotation)) ?? rotation
        flipHorizontal = (try? c.decode(Bool.self, forKey: .flipHorizontal)) ?? flipHorizontal
        flipVertical = (try? c.decode(Bool.self, forKey: .flipVertical)) ?? flipVertical
        frameRate = (try? c.decode(FrameRateOption.self, forKey: .frameRate)) ?? frameRate
        background = (try? c.decode(BackgroundStyle.self, forKey: .background)) ?? background
        subjectDetector = (try? c.decode(SubjectDetector.self, forKey: .subjectDetector)) ?? subjectDetector
        livePhotoMode = (try? c.decode(LivePhotoMode.self, forKey: .livePhotoMode)) ?? livePhotoMode
    }
}

struct BatchSettings: Codable, Equatable, Sendable {
    var video = ConversionSettings.defaults(for: .video)
    var audio = ConversionSettings.defaults(for: .audio)
    var image = ConversionSettings.defaults(for: .image)

    subscript(kind: MediaKind) -> ConversionSettings {
        get {
            switch kind {
            case .video: video
            case .audio: audio
            case .image: image
            }
        }
        set {
            switch kind {
            case .video: video = newValue
            case .audio: audio = newValue
            case .image: image = newValue
            }
        }
    }
}
