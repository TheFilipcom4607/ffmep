import Foundation

/// Maps the 0–100 quality slider onto each encoder's native scale (higher slider = better quality).
enum QualityMap {
    static func videoToolboxQ(_ q: Double) -> Int { clamp(Int((30 + q * 0.5).rounded()), 1, 100) }
    static func x264CRF(_ q: Double) -> Int { clamp(Int((33 - q * 0.14).rounded()), 14, 40) }
    static func x265CRF(_ q: Double) -> Int { clamp(Int((35 - q * 0.17).rounded()), 16, 40) }
    static func svtAV1CRF(_ q: Double) -> Int { clamp(Int((52 - q * 0.3).rounded()), 18, 60) }
    static func vp9CRF(_ q: Double) -> Int { clamp(Int((50 - q * 0.25).rounded()), 15, 60) }
    static func webpQuality(_ q: Double) -> Int { clamp(Int((30 + q * 0.65).rounded()), 1, 100) }
    static func mjpegQScale(_ q: Double) -> Int { clamp(Int((31 - q * 0.29).rounded()), 2, 31) }
    static func imageIOQuality(_ q: Double) -> Double { min(max(0.3 + q * 0.0065, 0.05), 1) }

    /// ProRes profile index: 0 proxy, 1 LT, 2 standard, 3 HQ.
    static func proresProfile(_ q: Double) -> Int {
        switch q {
        case ..<25: 0
        case ..<50: 1
        case ..<80: 2
        default: 3
        }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

enum ResizeMath {
    /// Output dimensions for the resize option, or nil when no scaling is needed.
    /// `even` forces even dimensions (required by 4:2:0 video encoders), which may also apply at "Original".
    static func target(width: Int, height: Int, settings: ConversionSettings, even: Bool) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let w = Double(width), h = Double(height)
        var scale = 1.0

        switch settings.resize {
        case .original:
            break
        case .p2160, .p1080, .p720, .p480:
            scale = Double(settings.resize.shortSide!) / Double(min(width, height))
        case .custom:
            let sx = settings.customWidth > 0 ? Double(settings.customWidth) / w : .infinity
            let sy = settings.customHeight > 0 ? Double(settings.customHeight) / h : .infinity
            let s = min(sx, sy)
            scale = s.isFinite ? s : 1
        case .percent:
            scale = Double(max(settings.percent, 1)) / 100
        }
        if settings.noUpscale { scale = min(scale, 1) }

        var outW = max(1, Int((w * scale).rounded()))
        var outH = max(1, Int((h * scale).rounded()))
        if even {
            outW = max(2, outW - outW % 2)
            outH = max(2, outH - outH % 2)
        }
        if outW == width, outH == height { return nil }
        return (outW, outH)
    }
}

enum CommandBuilderError: LocalizedError, Equatable {
    case noAudioTrack
    case noVideoTrack
    case missingEncoder(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This file has no audio track"
        case .noVideoTrack: "This file has no video track"
        case .missingEncoder(let name): "The selected ffmpeg has no \(name) encoder (switch to Bundled in Settings)"
        case .unsupported(let message): message
        }
    }
}

struct CommandInput {
    var input: URL
    /// Where ffmpeg writes (the partial file); its extension matches the format.
    var output: URL
    var settings: ConversionSettings
    var probe: ProbeResult
    var encoders: Set<String>
    /// Set when retrying after a VideoToolbox failure.
    var forceSoftware = false
    /// Stats file prefix for two-pass encodes.
    var passLogPrefix: URL?
    /// Native encoder quality for image target-size search.
    var imageQualityOverride: Int?
    /// Input is an ImageIO-prepared bitmap that is already oriented, resized and rotated.
    var inputIsPrepared = false
}

struct EncodePlan: Equatable {
    var passes: [[String]]
    /// Share of total progress each pass accounts for.
    var passWeights: [Double]
    var usesHardware: Bool
    /// Something worth telling the user about the choices made here, e.g. a capped audio bitrate.
    var note: String?
}

enum CommandBuilder {
    static let baseArgs = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]

    static func plan(_ c: CommandInput) throws -> EncodePlan {
        let format = c.settings.format
        if format.isAudio { return try audioPlan(c) }
        if format == .gif { return try gifPlan(c) }
        if format.isVideoContainer { return try videoPlan(c) }
        return try imagePlan(c)
    }

    /// Encoding a lossy source above its own bitrate grows the file without adding quality,
    /// so the source acts as a ceiling, snapped down to a bitrate the encoder family offers.
    static func cappedAudioBitrate(_ wanted: Int, family: AudioEncoderFamily, probe: ProbeResult) -> (kbps: Int, note: String?) {
        guard let source = probe.lossyAudioKbps, source < wanted else { return (wanted, nil) }
        let kbps = family.allowedBitrates.last { $0 <= source } ?? family.allowedBitrates[0]
        return (kbps, "Kept the original \(kbps) kbps")
    }

    static func muxer(for format: OutputFormat) -> String {
        switch format {
        case .mp4: "mp4"
        case .mov: "mov"
        case .mkv: "matroska"
        case .webm: "webm"
        case .gif: "gif"
        case .mp3: "mp3"
        case .m4a, .alac: "ipod"
        case .wav: "wav"
        case .flac: "flac"
        case .opus: "opus"
        case .jpeg, .png, .heic: "image2"
        case .webp: "webp"
        }
    }

    // MARK: Video

    private static func videoPlan(_ c: CommandInput) throws -> EncodePlan {
        let s = c.settings
        let p = c.probe
        guard p.hasVideo else { throw CommandBuilderError.noVideoTrack }
        let codec = s.effectiveCodec
        let format = s.format
        let wantsHardware = !c.forceSoftware && !s.maxCompression

        var video: [String] = []
        var usesHardware = false
        var twoPass: TwoPassStyle?
        let target = s.usesTargetSize && (p.duration ?? 0) > 0
            ? TargetSize.videoBitrates(targetBytes: TargetSize.bytes(megabytes: s.targetSizeMB), duration: p.duration!, hasAudio: p.hasAudio)
            : nil

        func require(_ encoder: String) throws {
            guard c.encoders.contains(encoder) else { throw CommandBuilderError.missingEncoder(encoder) }
        }
        func hardwareRate(_ q: Int) -> [String] {
            if let target {
                return ["-b:v", "\(target.videoKbps)k", "-maxrate", "\(target.videoKbps * 3 / 2)k", "-bufsize", "\(target.videoKbps * 2)k"]
            }
            return ["-q:v", "\(q)"]
        }

        switch codec {
        case .h264:
            if wantsHardware, c.encoders.contains("h264_videotoolbox") {
                usesHardware = true
                video = ["-c:v", "h264_videotoolbox"] + hardwareRate(QualityMap.videoToolboxQ(s.quality)) + ["-pix_fmt", "yuv420p"]
            } else {
                try require("libx264")
                video = ["-c:v", "libx264", "-preset", s.maxCompression ? "slow" : "medium"]
                if let target {
                    video += ["-b:v", "\(target.videoKbps)k"]
                    twoPass = .ffmpegPass
                } else {
                    video += ["-crf", "\(QualityMap.x264CRF(s.quality))"]
                }
                video += ["-pix_fmt", "yuv420p"]
            }
        case .hevc:
            if wantsHardware, c.encoders.contains("hevc_videotoolbox") {
                usesHardware = true
                video = ["-c:v", "hevc_videotoolbox"] + hardwareRate(QualityMap.videoToolboxQ(s.quality))
                    + ["-pix_fmt", p.isHighBitDepth ? "p010le" : "yuv420p"]
            } else {
                try require("libx265")
                video = ["-c:v", "libx265", "-preset", "medium"]
                if let target {
                    video += ["-b:v", "\(target.videoKbps)k"]
                    twoPass = .x265
                } else {
                    video += ["-crf", "\(QualityMap.x265CRF(s.quality))", "-x265-params", "log-level=error"]
                }
                video += ["-pix_fmt", "yuv420p"]
            }
            if format == .mp4 || format == .mov { video += ["-tag:v", "hvc1"] }
        case .prores:
            let profile = QualityMap.proresProfile(s.quality)
            if !c.forceSoftware, c.encoders.contains("prores_videotoolbox") {
                usesHardware = true
                video = ["-c:v", "prores_videotoolbox", "-profile:v", "\(profile)"]
            } else {
                try require("prores_ks")
                video = ["-c:v", "prores_ks", "-profile:v", "\(profile)", "-vendor", "apl0", "-pix_fmt", "yuv422p10le"]
            }
        case .vp9:
            try require("libvpx-vp9")
            video = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", s.maxCompression ? "2" : "4"]
            if let target {
                video += ["-b:v", "\(target.videoKbps)k"]
                twoPass = .ffmpegPass
            } else {
                video += ["-crf", "\(QualityMap.vp9CRF(s.quality))", "-b:v", "0"]
            }
            video += ["-pix_fmt", "yuv420p"]
        case .av1:
            try require("libsvtav1")
            video = ["-c:v", "libsvtav1", "-preset", s.maxCompression ? "5" : "8"]
            if let target {
                video += ["-b:v", "\(target.videoKbps)k"]
            } else {
                video += ["-crf", "\(QualityMap.svtAV1CRF(s.quality))"]
            }
            video += ["-pix_fmt", p.isHighBitDepth ? "yuv420p10le" : "yuv420p"]
        }

        let filters = videoFilters(settings: s, probe: p, gifDefaults: false)
        let filterArgs = filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]

        var audio: [String] = []
        var note: String?
        if p.hasAudio {
            let wanted = target?.audioKbps ?? min(AudioEncoderFamily.aac.kbps(quality: s.quality), 256)
            if format == .webm {
                try require("libopus")
                let rate = cappedAudioBitrate(min(wanted, 192), family: .opus, probe: p)
                note = rate.note
                audio = ["-c:a", "libopus", "-b:a", "\(rate.kbps)k"]
            } else if codec == .prores {
                audio = ["-c:a", (p.audioBitDepth ?? 16) > 16 ? "pcm_s24le" : "pcm_s16le"]
            } else {
                let rate = cappedAudioBitrate(wanted, family: .aac, probe: p)
                note = rate.note
                audio = ["-c:a", c.encoders.contains("aac_at") ? "aac_at" : "aac", "-b:a", "\(rate.kbps)k"]
            }
        }

        let audioMap = (format == .mov || format == .mkv) ? "0:a?" : "0:a:0?"
        let container = containerArgs(settings: s, probe: p)
        let input = baseArgs + ["-i", c.input.path]

        var final = input + ["-map", "0:v:0"]
        if p.hasAudio { final += ["-map", audioMap] }
        final += filterArgs + video + audio + container

        guard let twoPass, let log = c.passLogPrefix else {
            final += ["-f", muxer(for: format), c.output.path]
            return EncodePlan(passes: [final], passWeights: [1], usesHardware: usesHardware, note: note)
        }

        // Pass 1 analyses video only and discards the output; pass 2 writes the file.
        var first = input + ["-map", "0:v:0"] + filterArgs + video
        switch twoPass {
        case .x265:
            first += ["-x265-params", "pass=1:stats=\(log.path).x265:log-level=error"]
            final += ["-x265-params", "pass=2:stats=\(log.path).x265:log-level=error"]
        case .ffmpegPass:
            first += ["-pass", "1", "-passlogfile", log.path]
            final += ["-pass", "2", "-passlogfile", log.path]
        }
        first += ["-an", "-f", "null", "/dev/null"]
        final += ["-f", muxer(for: format), c.output.path]
        return EncodePlan(passes: [first, final], passWeights: [0.35, 0.65], usesHardware: false, note: note)
    }

    private enum TwoPassStyle { case x265, ffmpegPass }

    /// fps → scale → rotate → flip, for real video and GIF.
    static func videoFilters(settings s: ConversionSettings, probe p: ProbeResult, gifDefaults: Bool) -> [String] {
        var filters: [String] = []
        if let fps = s.frameRate.value ?? (gifDefaults ? 15 : nil) {
            if p.fps == nil || p.fps! > fps + 0.01 {
                filters.append("fps=\(formatNumber(fps))")
            }
        }
        var resize = s
        if gifDefaults, s.resize == .original {
            resize.resize = .custom
            resize.customWidth = 640
            resize.customHeight = 640
            resize.noUpscale = true
        }
        if let w = p.width, let h = p.height,
           let size = ResizeMath.target(width: w, height: h, settings: resize, even: !gifDefaults) {
            filters.append(gifDefaults ? "scale=\(size.width):\(size.height):flags=lanczos" : "scale=\(size.width):\(size.height)")
        }
        filters += orientationFilters(s)
        return filters
    }

    static func orientationFilters(_ s: ConversionSettings) -> [String] {
        var filters: [String] = []
        switch s.rotation {
        case .none: break
        case .cw90: filters.append("transpose=1")
        case .ccw90: filters.append("transpose=2")
        case .r180: filters += ["hflip", "vflip"]
        }
        if s.flipHorizontal { filters.append("hflip") }
        if s.flipVertical { filters.append("vflip") }
        return filters
    }

    private static func containerArgs(settings s: ConversionSettings, probe p: ProbeResult) -> [String] {
        var args = metadataArgs(settings: s, probe: p)
        switch s.format {
        case .mp4, .mov:
            args += ["-movflags", keepsQuickTimeKeys(settings: s, probe: p) ? "+faststart+use_metadata_tags" : "+faststart"]
        case .m4a, .alac:
            args += ["-movflags", "+faststart"]
        default:
            break
        }
        return args
    }

    /// iPhone and Mac recordings keep location, capture date and camera in `com.apple.quicktime.*` keys,
    /// which the MP4/MOV muxer only writes back with `use_metadata_tags`.
    private static func keepsQuickTimeKeys(settings s: ConversionSettings, probe p: ProbeResult) -> Bool {
        s.metadata != .removeAll && p.formatTags.keys.contains { $0.hasPrefix("com.apple.quicktime.") }
    }

    static func metadataArgs(settings s: ConversionSettings, probe p: ProbeResult) -> [String] {
        if s.metadata == .removeAll { return ["-map_metadata", "-1", "-map_chapters", "-1"] }
        var args: [String] = []
        // ffmpeg leaves out creation_time unless it's set explicitly.
        if let created = p.formatTags["creation_time"] {
            args += ["-metadata", "creation_time=\(created)"]
        }
        if keepsQuickTimeKeys(settings: s, probe: p) {
            // use_metadata_tags would otherwise write the source's brands as keys too.
            args += ["-metadata", "major_brand=", "-metadata", "minor_version=", "-metadata", "compatible_brands="]
        }
        if s.metadata == .removeLocation {
            // An empty value deletes the tag.
            for key in p.formatTags.keys.sorted() where MetadataInspector.category(forTag: key) == .location {
                args += ["-metadata", "\(key)="]
            }
        }
        return args
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    // MARK: Audio

    private static func audioPlan(_ c: CommandInput) throws -> EncodePlan {
        let s = c.settings
        guard c.probe.hasAudio else { throw CommandBuilderError.noAudioTrack }
        let duration = c.probe.duration ?? 0
        let targetBytes = s.usesTargetSize && duration > 0 ? TargetSize.bytes(megabytes: s.targetSizeMB) : nil

        var note: String?
        func bitrate(_ family: AudioEncoderFamily) -> String {
            let wanted = targetBytes.map { TargetSize.audioBitrate(targetBytes: $0, duration: duration, family: family) }
                ?? family.kbps(quality: s.quality)
            let rate = cappedAudioBitrate(wanted, family: family, probe: c.probe)
            note = rate.note
            return "\(rate.kbps)k"
        }

        let codec: [String]
        switch s.format {
        case .mp3:
            guard c.encoders.contains("libmp3lame") else { throw CommandBuilderError.missingEncoder("libmp3lame") }
            codec = ["-c:a", "libmp3lame", "-b:a", bitrate(.mp3)]
        case .m4a:
            codec = ["-c:a", c.encoders.contains("aac_at") ? "aac_at" : "aac", "-b:a", bitrate(.aac)]
        case .opus:
            guard c.encoders.contains("libopus") else { throw CommandBuilderError.missingEncoder("libopus") }
            codec = ["-c:a", "libopus", "-b:a", bitrate(.opus)]
        case .wav:
            codec = ["-c:a", (c.probe.audioBitDepth ?? 16) > 16 ? "pcm_s24le" : "pcm_s16le"]
        case .flac:
            codec = ["-c:a", "flac"]
        case .alac:
            codec = ["-c:a", "alac"]
        default:
            throw CommandBuilderError.unsupported("\(s.format.title) is not an audio format")
        }

        let args = baseArgs + ["-i", c.input.path, "-map", "0:a:0", "-vn", "-sn", "-dn"]
            + codec + containerArgs(settings: s, probe: c.probe)
            + ["-f", muxer(for: s.format), c.output.path]
        return EncodePlan(passes: [args], passWeights: [1], usesHardware: false, note: note)
    }

    // MARK: GIF

    private static func gifPlan(_ c: CommandInput) throws -> EncodePlan {
        let s = c.settings
        guard c.probe.hasVideo || c.inputIsPrepared else { throw CommandBuilderError.noVideoTrack }
        let chain = c.inputIsPrepared ? [] : videoFilters(settings: s, probe: c.probe, gifDefaults: !c.probe.isStillImage)
        let prefix = chain.isEmpty ? "[0:v]" : "[0:v]\(chain.joined(separator: ",")),"
        let graph = "\(prefix)split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        let args = baseArgs + ["-i", c.input.path, "-filter_complex", graph, "-an", "-loop", "0", "-f", "gif", c.output.path]
        return EncodePlan(passes: [args], passWeights: [1], usesHardware: false)
    }

    // MARK: Still images (ffmpeg path)

    private static func imagePlan(_ c: CommandInput) throws -> EncodePlan {
        let s = c.settings
        var filters: [String] = []
        if !c.inputIsPrepared {
            if let w = c.probe.width, let h = c.probe.height,
               let size = ResizeMath.target(width: w, height: h, settings: s, even: false) {
                filters.append("scale=\(size.width):\(size.height):flags=lanczos")
            }
            filters += orientationFilters(s)
        }

        let codec: [String]
        switch s.format {
        case .webp:
            guard c.encoders.contains("libwebp") else { throw CommandBuilderError.missingEncoder("libwebp") }
            let q = c.imageQualityOverride ?? QualityMap.webpQuality(s.quality)
            codec = ["-c:v", "libwebp", "-quality", "\(q)", "-compression_level", "4", "-preset", "picture"]
        case .jpeg:
            let q = c.imageQualityOverride.map { QualityMap.mjpegQScale(Double($0)) } ?? QualityMap.mjpegQScale(s.quality)
            codec = ["-c:v", "mjpeg", "-q:v", "\(q)", "-pix_fmt", "yuvj420p"]
        case .png:
            codec = ["-c:v", "png"]
        default:
            throw CommandBuilderError.unsupported("ffmpeg can't write \(s.format.title)")
        }

        var args = baseArgs + ["-i", c.input.path]
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += codec + ["-frames:v", "1"]
        if s.metadata == .removeAll { args += ["-map_metadata", "-1"] }
        if muxer(for: s.format) == "image2" { args += ["-update", "1"] }
        args += ["-f", muxer(for: s.format), c.output.path]
        return EncodePlan(passes: [args], passWeights: [1], usesHardware: false)
    }
}
