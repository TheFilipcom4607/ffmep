import Foundation

/// Everything `ffmep convert` was asked to do, before any file is looked at.
struct ConvertOptions: Equatable {
    var inputs: [String] = []
    var format: OutputFormat?
    /// `--to same`: images keep their own format.
    var keepsFormat = false
    var preset: String?
    var appSettings = false
    var quality: Double?
    var maxSizeMB: Double?
    var resize: ResizeRequest?
    var upscale = false
    var codec: VideoCodec?
    var frameRate: FrameRateOption?
    var rotation: Rotation?
    var flip: Flip?
    var metadata: MetadataMode?
    var background: BackgroundStyle?
    var model: SubjectDetector?
    var livePhoto: LivePhotoMode?
    var maxCompression = false
    var output: String?
    var nameTemplate: String?
    var replace = false
    var jobs: Int?
    var dryRun = false
    var json = false
    var quiet = false

    static let specs: [OptionSpec] = [
        .value("to", "t", aliases: ["format"]),
        .value("preset", "p"),
        .flag("app-settings"),
        .value("quality", "q"),
        .value("max-size", "s", aliases: ["size-limit", "target-size"]),
        .value("resize", "r", aliases: ["size"]),
        .flag("upscale"),
        .value("codec", "c"),
        .value("fps", aliases: ["frame-rate"]),
        .value("rotate"),
        .value("flip"),
        .value("metadata", "m"),
        .flag("strip-metadata"),
        .value("background", "b"),
        .value("model"),
        .value("live-photo"),
        .flag("max-compression"),
        .value("output", "o", aliases: ["out"]),
        .value("name", "n"),
        .flag("replace"),
        .value("jobs", "j"),
        .flag("dry-run", aliases: ["plan"]),
        .flag("json"),
        .flag("quiet"),
    ]

    static func parse(_ arguments: [String]) throws -> ConvertOptions {
        let args = try ArgumentParser.parse(arguments, options: specs)
        var o = ConvertOptions()
        o.inputs = args.positionals
        if let to = args.values["to"], ["same", "original", "keep"].contains(CLIValue.key(to)) {
            o.keepsFormat = true
        } else {
            o.format = try args.values["to"].map(CLIValue.format)
        }
        o.preset = args.values["preset"]
        o.appSettings = args.has("app-settings")
        o.quality = try args.values["quality"].map(CLIValue.quality)
        o.maxSizeMB = try args.values["max-size"].map(CLIValue.megabytes)
        o.resize = try args.values["resize"].map(CLIValue.resize)
        o.upscale = args.has("upscale")
        o.codec = try args.values["codec"].map(CLIValue.codec)
        o.frameRate = try args.values["fps"].map(CLIValue.frameRate)
        o.rotation = try args.values["rotate"].map(CLIValue.rotation)
        o.flip = try args.values["flip"].map(CLIValue.flip)
        o.metadata = try args.values["metadata"].map(CLIValue.metadata)
        if args.has("strip-metadata") {
            if o.metadata != nil, o.metadata != .removeAll {
                throw CLIError.usage("--strip-metadata and --metadata \(args.values["metadata"]!) disagree. Use one of them.")
            }
            o.metadata = .removeAll
        }
        o.background = try args.values["background"].map(CLIValue.background)
        o.model = try args.values["model"].map(CLIValue.model)
        o.livePhoto = try args.values["live-photo"].map(CLIValue.livePhoto)
        o.maxCompression = args.has("max-compression")
        o.output = args.values["output"]
        o.nameTemplate = args.values["name"]
        o.replace = args.has("replace")
        if let jobs = args.values["jobs"] {
            guard let n = Int(jobs), n > 0 else { throw CLIError.usage("--jobs needs a whole number above 0.") }
            o.jobs = n
        }
        o.dryRun = args.has("dry-run")
        o.json = args.has("json")
        o.quiet = args.has("quiet")

        guard !o.inputs.isEmpty else { throw CLIError.usage("Name at least one file or folder to convert.") }
        if o.preset != nil, o.appSettings {
            throw CLIError.usage("--preset and --app-settings both pick the starting settings. Use one of them.")
        }
        if o.replace, o.output != nil {
            throw CLIError.usage("--replace puts the new file where the original was, so it can’t be combined with --output.")
        }
        if o.replace, o.nameTemplate != nil {
            throw CLIError.usage("--replace keeps the original’s name, so it can’t be combined with --name.")
        }
        return o
    }

    /// The settings to start from before any option is applied: a preset, the app's inspector, or
    /// the defaults for the kind of file, so the same command does the same thing on every Mac.
    func baseSettings(for kind: MediaKind, preferences: StoredPreferences) throws -> ConversionSettings {
        if let preset {
            let matches = preferences.presets(named: preset)
            guard let match = matches.first(where: { $0.kind == kind }) else {
                let kinds = matches.map { $0.kind.pluralTitle.lowercased() }
                throw CLIError.failure("“\(matches[0].name)” is a preset for \(ListFormatter.localizedString(byJoining: kinds)), not \(kind.pluralTitle.lowercased()).")
            }
            return match.settings
        }
        if appSettings { return preferences.batch[kind] }
        return ConversionSettings.defaults(for: kind)
    }

    /// The options laid over `base`. Throws for a file the options can't apply to, like a video asked to become a JPEG.
    func settings(for kind: MediaKind, base: ConversionSettings, isLivePhoto: Bool = false) throws -> ConversionSettings {
        var s = base
        if let livePhoto, kind == .image { s.livePhotoMode = livePhoto }
        if keepsFormat {
            guard kind == .image else {
                throw CLIError.failure("--to same is for images. Name a format for \(kind.pluralTitle.lowercased()).")
            }
            s.format = .jpeg
            s.keepsFormat = true
        } else if format != nil {
            s.keepsFormat = false
        }
        if let format {
            if OutputFormat.choices(for: kind).contains(format) {
                s.format = format
            } else if !(isLivePhoto && s.livePhotoMode.outputFormat == format) {
                // A Live Photo's motion is written as the mode's format, so --to mp4 --live-photo video is fine.
                var reason = "\(kind.pluralTitle) can’t be converted to \(format.title)"
                if kind == .image, format.isVideoContainer || format == .gif {
                    reason += isLivePhoto ? ". Add --live-photo video or gif to export this Live Photo’s motion" : ""
                }
                throw CLIError.failure("\(reason).")
            }
        }
        if let quality { s.quality = quality }
        if let maxSizeMB {
            s.targetSizeEnabled = true
            s.targetSizeMB = maxSizeMB
        }
        if let resize {
            if case .percent = resize, kind != .image, !(isLivePhoto && s.livePhotoMode != .still) {
                throw CLIError.failure("Resizing by percentage is for images. Use 720p or a size like 1280x720.")
            }
            resize.apply(to: &s)
        }
        if upscale { s.noUpscale = false }
        if let codec { s.videoCodec = codec }
        if let frameRate { s.frameRate = frameRate }
        if let rotation { s.rotation = rotation }
        if let flip {
            s.flipHorizontal = flip.horizontal
            s.flipVertical = flip.vertical
        }
        if let metadata {
            guard MetadataMode.choices(for: kind).contains(metadata) else {
                throw CLIError.failure("Audio has no location to remove. Use --metadata keep or remove-all.")
            }
            s.metadata = metadata
        }
        if let background { s.background = background }
        if let model { s.subjectDetector = model }
        if maxCompression { s.maxCompression = true }

        // Starting settings can hold a codec or size limit the format doesn't use; the app ignores those,
        // so do the same. What was asked for on the command line is checked instead.
        if codec == nil { s.videoCodec = s.effectiveCodec }
        if maxSizeMB == nil { s.targetSizeEnabled = s.usesTargetSize }
        let checked = isLivePhoto ? (s.motionSettings() ?? s) : s
        do {
            try ShortcutRunner.validate(checked)
            if checked.format != s.format { try ShortcutRunner.validate(s) }
        } catch let error as ShortcutError {
            throw CLIError.failure(error.message)
        }
        return s
    }
}
