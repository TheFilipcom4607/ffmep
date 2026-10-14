import Foundation

// The commands besides `convert`: looking at files, and listing what ffmep can do.

@MainActor
enum InfoCommand {
    struct MediaInfo: Encodable {
        var path: String
        var kind: MediaKind?
        var bytes: Int64
        var duration: Double?
        var width: Int?
        var height: Int?
        var fps: Double?
        var videoCodec: String?
        var audioCodec: String?
        var audioBitrateKbps: Int?
        var hasAudio: Bool?
        var frames: Int?
        var livePhoto: Bool?
        /// Metadata worth knowing about before sharing: location, date, camera…
        var metadata: [String] = []
        var convertsTo: [OutputFormat] = []
        var error: String?
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let args = try ArgumentParser.parse(arguments, options: [.flag("json")])
        guard !args.positionals.isEmpty else { throw CLIError.usage("Name at least one file to look at.") }
        let urls = try args.positionals.map { path -> URL in
            let url = CLI.fileURL(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.usage("No such file or folder: \(path)") }
            return url
        }
        let tools = try await CLI.loadTools(StoredPreferences.load(), quiet: true)
        let files = await Task.detached { AppState.expand(urls) }.value
        var infos: [MediaInfo] = []
        for (url, kind, size) in await AppState.classify(files, ffprobe: tools.ffprobe) {
            infos.append(await info(url: url, kind: kind, size: size, ffprobe: tools.ffprobe))
        }

        if args.has("json") {
            CLI.printJSON(infos)
        } else {
            for (i, info) in infos.enumerated() {
                if i > 0 { CLI.out("") }
                CLI.out(info.path)
                if let error = info.error { CLI.out("  \(error)"); continue }
                var facts = [info.kind?.title ?? "", CLI.bytes(info.bytes)]
                if let w = info.width, let h = info.height { facts.append("\(w)×\(h)") }
                if let d = info.duration, info.kind != .image { facts.append(Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond))) }
                if let fps = info.fps, info.kind == .video { facts.append("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps") }
                facts += [info.videoCodec, info.audioCodec].compactMap { $0 }
                if let kbps = info.audioBitrateKbps { facts.append("\(kbps) kbps") }
                if info.livePhoto == true { facts.append("Live Photo") }
                CLI.out("  " + facts.joined(separator: " · "))
                CLI.out("  Metadata: " + (info.metadata.isEmpty ? "none found" : info.metadata.joined(separator: ", ")))
                CLI.out("  Converts to: " + info.convertsTo.map(\.rawValue).joined(separator: ", "))
            }
        }
        return infos.contains { $0.kind == nil } ? 1 : 0
    }

    static func info(url: URL, kind: MediaKind?, size: Int64, ffprobe: URL) async -> MediaInfo {
        var info = MediaInfo(path: url.path, kind: kind, bytes: size)
        guard let kind else {
            info.error = "Not a video, audio file or image"
            return info
        }
        info.convertsTo = OutputFormat.choices(for: kind)
        if kind == .image, ImageIOConverter.canRead(url) {
            let size = ImageIOConverter.displaySize(url)
            info.width = size?.width
            info.height = size?.height
            info.frames = Probe.imageFrameCount(url)
            info.livePhoto = LivePhoto.isLivePhotoStill(url)
            info.metadata = categories(MetadataInspector.categories(ofImageAt: url) ?? [])
            return info
        }
        do {
            let probe = try await Probe.run(ffprobe: ffprobe, file: url)
            info.duration = probe.duration
            info.width = probe.width
            info.height = probe.height
            info.fps = probe.hasVideo && !probe.isStillImage ? probe.fps : nil
            info.videoCodec = probe.videoCodec
            info.audioCodec = probe.audioCodec
            info.audioBitrateKbps = probe.audioBitrateKbps
            info.hasAudio = probe.hasAudio
            info.metadata = categories(probe.metadata)
        } catch {
            info.error = error.localizedDescription
        }
        return info
    }

    private static func categories(_ set: Set<MetadataCategory>) -> [String] {
        MetadataCategory.allCases.filter(set.contains).map(\.rawValue)
    }
}

@MainActor
enum FormatsCommand {
    struct FormatInfo: Encodable {
        var format: OutputFormat
        var name: String
        var fileExtension: String
        /// The kinds of file that can be converted to it.
        var from: [MediaKind]
        var codecs: [VideoCodec]?
        var quality: Bool
        var maxSize: Bool
        var transparency: Bool
        var keepsMetadata: Bool
    }

    struct Catalog: Encodable {
        var formats: [FormatInfo]
        /// The words each option takes, for scripts and assistants that build commands.
        var values: [String: [String]]
    }

    static var catalog: Catalog {
        let formats = OutputFormat.allCases.map { format in
            var settings = ConversionSettings(format: format)
            settings.videoCodec = settings.effectiveCodec
            return FormatInfo(
                format: format,
                name: format.title,
                fileExtension: format.fileExtension,
                from: MediaKind.allCases.filter { OutputFormat.choices(for: $0).contains(format) },
                codecs: format.codecChoices.isEmpty ? nil : format.codecChoices,
                quality: format.hasQuality,
                maxSize: settings.supportsTargetSize,
                transparency: format.supportsAlpha,
                keepsMetadata: format != .webp && format != .gif
            )
        }
        return Catalog(formats: formats, values: [
            "quality": QualityPreset.allCases.map(\.rawValue) + ["0-100"],
            "resize": ["original", "4k", "1080p", "720p", "480p", "50%", "2048", "1920x1080", "1280x", "x720"],
            "codec": VideoCodec.allCases.map(\.rawValue),
            "fps": FrameRateOption.allCases.map { $0.value.map { String(Int($0)) } ?? "original" },
            "rotate": ["90", "-90", "180"],
            "flip": ["horizontal", "vertical", "both"],
            "metadata": ["keep", "remove-location", "remove-all"],
            "background": BackgroundStyle.allCases.map(\.rawValue),
            "model": ["birefnet", "vision"],
            "live-photo": LivePhotoMode.allCases.map(\.rawValue),
        ])
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        let args = try ArgumentParser.parse(arguments, options: [.flag("json")])
        try CLI.rejectExtra(args, command: "formats")
        let catalog = catalog
        if args.has("json") {
            CLI.printJSON(catalog)
            return 0
        }
        for kind in MediaKind.allCases {
            let names = OutputFormat.choices(for: kind).map(\.rawValue).joined(separator: " ")
            CLI.out("\(kind.pluralTitle.padding(toLength: 7, withPad: " ", startingAt: 0)) → \(names)")
        }
        CLI.out("")
        let rows = [["Format", "Ext", "Codecs", "Quality", "Max size", "Transparency", "Metadata"]] + catalog.formats.map { f in
            [f.format.rawValue, f.fileExtension, f.codecs?.map(\.rawValue).joined(separator: " ") ?? "",
             f.quality ? "yes" : "", f.maxSize ? "yes" : "", f.transparency ? "yes" : "", f.keepsMetadata ? "kept" : "dropped"]
        }
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max()! }
        for row in rows {
            CLI.out(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        CLI.out("\nThe first codec is the one used when --codec is left out.")
        return 0
    }
}

@MainActor
enum PresetsCommand {
    struct PresetInfo: Encodable {
        var name: String
        var kind: MediaKind
        var summary: String
        var settings: ConversionSettings
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        let args = try ArgumentParser.parse(arguments, options: [.flag("json")])
        try CLI.rejectExtra(args, command: "presets")
        let presets = StoredPreferences.load().presets
        if args.has("json") {
            CLI.printJSON(presets.map { PresetInfo(name: $0.name, kind: $0.kind, summary: summary($0.settings), settings: $0.settings) })
            return 0
        }
        guard !presets.isEmpty else {
            CLI.err("There are no presets. Save one from the inspector in ffmep, or add the examples in Settings › Presets.")
            return 0
        }
        for kind in MediaKind.allCases {
            let group = presets.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            CLI.out(kind.pluralTitle)
            let width = group.map(\.name.count).max()!
            for preset in group {
                CLI.out("  \(preset.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(summary(preset.settings))")
            }
        }
        CLI.out("\nUse one with: ffmep convert FILE --preset \"\(presets[0].name)\"")
        return 0
    }

    /// "MP4 · H.264 · 1080p · up to 19 MB"
    static func summary(_ s: ConversionSettings) -> String {
        var parts = [s.format.title]
        if s.format.isVideoContainer { parts.append(s.effectiveCodec.title) }
        if s.usesTargetSize {
            parts.append("up to \(s.targetSizeMB.formatted()) MB")
        } else if s.format.hasQuality {
            parts.append(s.preset.map { "\($0.title) quality" } ?? "quality \(Int(s.quality))")
        }
        switch s.resize {
        case .original: break
        case .custom:
            let w = s.customWidth > 0 ? "\(s.customWidth)" : ""
            let h = s.customHeight > 0 ? "\(s.customHeight)" : ""
            parts.append("fits \(w)×\(h)")
        case .percent: parts.append("\(s.percent)%")
        default: parts.append(s.resize.title)
        }
        if s.frameRate != .original { parts.append(s.frameRate.title) }
        if s.metadata != .keep { parts.append(s.metadata.title.lowercased()) }
        if s.background != .keep { parts.append("\(s.background.title.lowercased()) background") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum ModelCommand {
    struct Status: Encodable {
        var name = SubjectModel.name
        var installed: Bool
        var path: String
        var downloadBytes = SubjectModel.downloadBytes
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let args = try ArgumentParser.parse(arguments, options: [.flag("json")])
        let action = args.positionals.first ?? "status"
        guard args.positionals.count <= 1 else { throw CLIError.usage("`ffmep model` takes one of status, install or remove.") }
        switch action {
        case "status":
            let status = Status(installed: SubjectModel.isInstalled, path: SubjectModel.compiledURL.path)
            if args.has("json") {
                CLI.printJSON(status)
            } else if status.installed {
                CLI.out("BiRefNet is installed, at \(status.path).")
                CLI.out("--model birefnet uses it, --model vision uses Apple Vision instead.")
            } else {
                CLI.out("BiRefNet isn’t installed, so background removal uses Apple Vision.")
                CLI.out("`ffmep model install` downloads it (\(SubjectModelStore.sizeText)) for cleaner edges on fur and hair.")
            }
            return 0
        case "install":
            if SubjectModel.isInstalled {
                CLI.err("BiRefNet is already installed.")
                return 0
            }
            let interactive = isatty(STDERR_FILENO) == 1
            CLI.err("Downloading BiRefNet (\(SubjectModelStore.sizeText)) from \(SubjectModel.downloadURL.host ?? "GitHub")…")
            let zip = try await SubjectModelStore.fetch { fraction in
                if interactive { CLI.writeErr("\r\u{1B}[2K\(Int(fraction * 100))%") }
            }
            if interactive { CLI.writeErr("\r\u{1B}[2K") }
            CLI.err("Compiling it for this Mac…")
            try await Task.detached(priority: .userInitiated) { try await SubjectModelStore.install(zip: zip) }.value
            CLI.err("Installed. Background removal now uses BiRefNet unless you pass --model vision.")
            return 0
        case "remove":
            guard SubjectModel.isInstalled else {
                CLI.err("BiRefNet isn’t installed.")
                return 0
            }
            try FileManager.default.removeItem(at: SubjectModel.compiledURL)
            CLI.err("Removed BiRefNet. Background removal uses Apple Vision now.")
            return 0
        default:
            throw CLIError.usage("Unknown model action “\(action)”. Use status, install or remove.")
        }
    }
}

@MainActor
enum VersionCommand {
    struct Version: Encodable {
        var version: String
        var ffmpeg: String
        var ffmpegPath: String
        var ffmpegSource: FFmpegSource
        var backgroundModel: Bool
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let args = try ArgumentParser.parse(arguments, options: [.flag("json")])
        try CLI.rejectExtra(args, command: "version")
        guard args.has("json") else {
            CLI.out("ffmep \(CLI.version)")
            return 0
        }
        // Reading ffmpeg's version means running it, which only --json asks for.
        let tools = try await CLI.loadTools(StoredPreferences.load(), quiet: true)
        CLI.printJSON(Version(version: CLI.version, ffmpeg: tools.version, ffmpegPath: tools.ffmpeg.path,
                              ffmpegSource: tools.source, backgroundModel: SubjectModel.isInstalled))
        return 0
    }
}
