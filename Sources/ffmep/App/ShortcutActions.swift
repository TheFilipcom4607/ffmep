import AppIntents
import Foundation

// One action per media type, with that type's settings in the action itself,
// so a shortcut does the same thing whatever the inspector is set to.

struct ConvertImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Images"
    static let description = IntentDescription(
        "Converts images to JPEG, WebP, PNG, HEIC or GIF on this Mac, and passes on the converted images.",
        categoryName: "Images",
        searchKeywords: ["HEIC", "WebP", "JPEG", "PNG", "resize", "compress", "photo"]
    )

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormat

    @Parameter(title: "Quality", default: .balanced)
    var quality: QualityPreset

    @Parameter(title: "Max Width or Height", description: "In pixels. Smaller images aren’t enlarged.", inclusiveRange: (16, 16384))
    var maxDimension: Int?

    @Parameter(title: "File Size Limit (MB)", description: "Lowers the quality until each image fits. Not for PNG or GIF.", inclusiveRange: (0.01, 10000))
    var sizeLimit: Double?

    @Parameter(title: "Background", default: .keep)
    var background: BackgroundStyle

    @Parameter(title: "Model", description: "Which model finds the subject when the background is removed.", default: .biRefNet)
    var model: SubjectDetector

    @Parameter(title: "Metadata", default: .keep)
    var metadata: MetadataMode

    @Parameter(title: "Save To", description: "A folder for the converted files. Leave empty to follow ffmep’s save setting.",
               supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)") {
            \.$quality
            \.$maxDimension
            \.$sizeLimit
            \.$background
            \.$model
            \.$metadata
            \.$folder
        }
    }

    static func settings(format: ImageFormat, quality: QualityPreset, maxDimension: Int?, sizeLimit: Double?,
                         background: BackgroundStyle, model: SubjectDetector, metadata: MetadataMode) -> ConversionSettings {
        var s = ConversionSettings(format: format.outputFormat)
        s.quality = quality.value
        if let maxDimension {
            s.resize = .custom
            s.customWidth = maxDimension
            s.customHeight = maxDimension
            s.noUpscale = true
        }
        if let sizeLimit {
            s.targetSizeEnabled = true
            s.targetSizeMB = sizeLimit
        }
        s.background = background
        s.subjectDetector = model
        s.metadata = metadata
        return s
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let settings = Self.settings(format: format, quality: quality, maxDimension: maxDimension, sizeLimit: sizeLimit,
                                     background: background, model: model, metadata: metadata)
        let results = try await ShortcutRunner.convert(files, saveTo: folder) { kind, url in
            guard kind == .image else { throw ShortcutError("\(url.lastPathComponent) isn’t an image. Use Convert Videos or Convert Audio for it.") }
            return settings
        }
        return .result(value: results)
    }
}

struct ConvertVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Videos"
    static let description = IntentDescription(
        "Converts videos to MP4, MOV, MKV, WebM or GIF on this Mac, optionally to fit a file size, and passes on the converted videos.",
        categoryName: "Video",
        searchKeywords: ["MP4", "MOV", "HEVC", "H.264", "ProRes", "AV1", "GIF", "compress", "resize"]
    )

    @Parameter(title: "Videos", supportedTypeIdentifiers: ["public.movie", "public.video", "com.compuserve.gif"])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .mp4)
    var format: VideoFormat

    @Parameter(title: "Codec", description: "Leave empty for the format’s usual codec: HEVC for MP4, MOV and MKV, VP9 for WebM.")
    var codec: VideoCodec?

    @Parameter(title: "Quality", default: .balanced)
    var quality: QualityPreset

    @Parameter(title: "Resolution", description: "Caps the shorter side. Smaller videos aren’t enlarged.", default: .original)
    var resolution: VideoResolution

    @Parameter(title: "Frame Rate", description: "Only ever lowers the frame rate.", default: .original)
    var frameRate: FrameRateOption

    @Parameter(title: "File Size Limit (MB)", description: "Picks the bitrate that fits. Not for GIF or ProRes.", inclusiveRange: (0.1, 100000))
    var sizeLimit: Double?

    @Parameter(title: "Metadata", default: .keep)
    var metadata: MetadataMode

    @Parameter(title: "Save To", description: "A folder for the converted files. Leave empty to follow ffmep’s save setting.",
               supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)") {
            \.$codec
            \.$quality
            \.$resolution
            \.$frameRate
            \.$sizeLimit
            \.$metadata
            \.$folder
        }
    }

    static func settings(format: VideoFormat, codec: VideoCodec?, quality: QualityPreset, resolution: VideoResolution,
                         frameRate: FrameRateOption, sizeLimit: Double?, metadata: MetadataMode) -> ConversionSettings {
        var s = ConversionSettings(format: format.outputFormat)
        s.videoCodec = codec ?? s.format.codecChoices.first ?? .h264
        s.quality = quality.value
        s.resize = resolution.resize
        s.frameRate = frameRate
        if let sizeLimit {
            s.targetSizeEnabled = true
            s.targetSizeMB = sizeLimit
        }
        s.metadata = metadata
        return s
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let settings = Self.settings(format: format, codec: codec, quality: quality, resolution: resolution,
                                     frameRate: frameRate, sizeLimit: sizeLimit, metadata: metadata)
        let results = try await ShortcutRunner.convert(files, saveTo: folder) { kind, url in
            guard kind == .video else { throw ShortcutError("\(url.lastPathComponent) isn’t a video. Use Convert Images or Convert Audio for it.") }
            return settings
        }
        return .result(value: results)
    }
}

struct ConvertAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Audio"
    static let description = IntentDescription(
        "Converts audio to MP3, M4A, WAV, FLAC, ALAC or Opus on this Mac, or pulls the soundtrack out of a video, and passes on the converted files.",
        categoryName: "Audio",
        searchKeywords: ["MP3", "AAC", "FLAC", "WAV", "extract audio", "soundtrack"]
    )

    @Parameter(title: "Audio or Videos", supportedTypeIdentifiers: ["public.audiovisual-content"])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .mp3)
    var format: AudioFormat

    @Parameter(title: "Quality", description: "Sets the bitrate. WAV, FLAC and ALAC are lossless and ignore it.", default: .balanced)
    var quality: QualityPreset

    @Parameter(title: "File Size Limit (MB)", description: "Picks the bitrate that fits. Not for WAV, FLAC or ALAC.", inclusiveRange: (0.01, 10000))
    var sizeLimit: Double?

    @Parameter(title: "Metadata", default: .keep)
    var metadata: MetadataMode

    @Parameter(title: "Save To", description: "A folder for the converted files. Leave empty to follow ffmep’s save setting.",
               supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)") {
            \.$quality
            \.$sizeLimit
            \.$metadata
            \.$folder
        }
    }

    static func settings(format: AudioFormat, quality: QualityPreset, sizeLimit: Double?, metadata: MetadataMode) -> ConversionSettings {
        var s = ConversionSettings(format: format.outputFormat)
        s.quality = quality.value
        if let sizeLimit {
            s.targetSizeEnabled = true
            s.targetSizeMB = sizeLimit
        }
        s.metadata = metadata
        return s
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let settings = Self.settings(format: format, quality: quality, sizeLimit: sizeLimit, metadata: metadata)
        let results = try await ShortcutRunner.convert(files, saveTo: folder) { kind, url in
            guard kind != .image else { throw ShortcutError("\(url.lastPathComponent) is an image, so it has no audio.") }
            return settings
        }
        return .result(value: results)
    }
}

struct RemoveBackgroundIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Background"
    static let description = IntentDescription(
        "Cuts the subject out of photos on this Mac, on a transparent or white background, and passes on the results.",
        categoryName: "Images",
        searchKeywords: ["cutout", "subject", "transparent", "lift", "BiRefNet"]
    )

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var files: [IntentFile]

    @Parameter(title: "Background", default: .transparent)
    var background: CutoutBackground

    @Parameter(title: "Format", description: "JPEG can’t be transparent, so it always gets white.", default: .png)
    var format: ImageFormat

    @Parameter(title: "Model", description: "BiRefNet has the cleanest edges once it’s downloaded. Apple Vision is faster.", default: .biRefNet)
    var model: SubjectDetector

    @Parameter(title: "Save To", description: "A folder for the converted files. Leave empty to follow ffmep’s save setting.",
               supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Remove the background from \(\.$files)") {
            \.$background
            \.$format
            \.$model
            \.$folder
        }
    }

    static func settings(background: CutoutBackground, format: ImageFormat, model: SubjectDetector) -> ConversionSettings {
        var s = ConversionSettings(format: format.outputFormat)
        s.quality = QualityPreset.high.value
        s.background = background.style
        s.subjectDetector = model
        return s
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let settings = Self.settings(background: background, format: format, model: model)
        let results = try await ShortcutRunner.convert(files, saveTo: folder) { kind, url in
            guard kind == .image else { throw ShortcutError("\(url.lastPathComponent) isn’t an image.") }
            return settings
        }
        return .result(value: results)
    }
}
