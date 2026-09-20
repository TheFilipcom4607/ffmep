import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProbeResult: Sendable, Equatable {
    var duration: Double?
    /// Display dimensions (container rotation already applied).
    var width: Int?
    var height: Int?
    var fps: Double?
    var hasVideo = false
    var hasAudio = false
    var videoCodec: String?
    var pixelFormat: String?
    var audioBitDepth: Int?
    var audioCodec: String?
    var audioBitrateKbps: Int?
    var isStillImage = false
    /// Container-level tags, keys as ffprobe prints them.
    var formatTags: [String: String] = [:]
    /// Metadata found in the container and its streams, cover art included.
    var metadata: Set<MetadataCategory> = []

    var isHighBitDepth: Bool {
        guard let pixelFormat else { return false }
        return pixelFormat.contains("10") || pixelFormat.contains("12")
    }

    /// Codecs that keep every sample, where a higher output bitrate can still buy quality.
    private static let losslessAudioCodecs: Set<String> = ["flac", "alac", "tta", "wavpack"]

    /// The bitrate of a lossy source. Re-encoding above it only grows the file, so it acts as a ceiling.
    var lossyAudioKbps: Int? {
        guard let audioBitrateKbps, audioBitrateKbps > 0, let codec = audioCodec?.lowercased() else { return nil }
        guard !codec.hasPrefix("pcm_"), !Self.losslessAudioCodecs.contains(codec) else { return nil }
        return audioBitrateKbps
    }
}

enum ProbeError: LocalizedError, DetailedError {
    case unreadable(String, detail: String? = nil)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message, _): message
        }
    }

    var failureDetail: String? {
        switch self {
        case .unreadable(_, let detail): detail
        }
    }
}

enum Probe {
    static func run(ffprobe: URL, file: URL) async throws -> ProbeResult {
        let output = try await ProcessRunner.capture(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path,
        ])
        guard output.status == 0 else {
            let raw = FFmpegRunner.summarize(stderr: output.stderrString)
            let reason = FFmpegRunner.explain(stderr: output.stderrString)
            throw ProbeError.unreadable(reason.isEmpty ? "Not a readable media file" : reason,
                                        detail: raw.isEmpty ? nil : raw)
        }
        return try parse(json: output.stdout)
    }

    static func parse(json: Data) throws -> ProbeResult {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProbeError.unreadable("Unexpected ffprobe output")
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]
        var result = ProbeResult()

        result.duration = double(format["duration"])
        result.formatTags = (format["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        result.metadata = MetadataInspector.categories(ofTags: result.formatTags.keys)
        for stream in streams {
            result.metadata.formUnion(MetadataInspector.categories(ofTags: (stream["tags"] as? [String: Any] ?? [:]).keys))
            if (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1 {
                result.metadata.insert(.artwork)
            }
        }

        let videoStreams = streams.filter { stream in
            let attached = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
            return stream["codec_type"] as? String == "video" && !attached
        }
        if let v = videoStreams.first {
            result.hasVideo = true
            result.videoCodec = v["codec_name"] as? String
            result.pixelFormat = v["pix_fmt"] as? String
            var w = v["width"] as? Int
            var h = v["height"] as? Int
            if let rotation = rotation(of: v), Int(abs(rotation).rounded()) % 180 == 90 {
                swap(&w, &h)
            }
            result.width = w
            result.height = h
            result.fps = frameRate(v["avg_frame_rate"] as? String) ?? frameRate(v["r_frame_rate"] as? String)
            if result.duration == nil { result.duration = double(v["duration"]) }

            let formatName = format["format_name"] as? String ?? ""
            let frames = Int(v["nb_frames"] as? String ?? "")
            result.isStillImage = formatName.hasSuffix("_pipe") || formatName == "image2" || frames == 1
        }
        if let a = streams.first(where: { $0["codec_type"] as? String == "audio" }) {
            result.hasAudio = true
            result.audioCodec = a["codec_name"] as? String
            let raw = Int(a["bits_per_raw_sample"] as? String ?? "") ?? 0
            let coded = a["bits_per_sample"] as? Int ?? 0
            let bits = max(raw, coded)
            result.audioBitDepth = bits > 0 ? bits : nil
            // Some containers (MP3, most notably) only report a bitrate for the file as a whole,
            // which is the audio bitrate when there's nothing else in there.
            let kbps = double(a["bit_rate"]) ?? (result.hasVideo ? nil : double(format["bit_rate"]))
            if let kbps, kbps > 0 { result.audioBitrateKbps = Int((kbps / 1000).rounded()) }
        }
        return result
    }

    private static func double(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        return value as? Double
    }

    private static func rotation(of stream: [String: Any]) -> Double? {
        if let sideData = stream["side_data_list"] as? [[String: Any]] {
            for entry in sideData {
                if let r = entry["rotation"] as? Double { return r }
                if let r = entry["rotation"] as? Int { return Double(r) }
            }
        }
        if let tags = stream["tags"] as? [String: Any], let r = tags["rotate"] as? String {
            return Double(r)
        }
        return nil
    }

    static func frameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 {
            return n / d
        }
        return Double(text).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: Classification

    /// Media kind from the file type, falling back to ffprobe for types macOS doesn't know (mkv, webm, opus…).
    static func classify(url: URL, ffprobe: URL?) async -> MediaKind? {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            if type.conforms(to: .gif) {
                return imageFrameCount(url) > 1 ? .video : .image
            }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .archive)
                || type.conforms(to: .executable) || type.conforms(to: .application) {
                return nil
            }
        }
        guard let ffprobe, let probe = try? await run(ffprobe: ffprobe, file: url) else { return nil }
        if probe.hasVideo, !probe.isStillImage { return .video }
        if probe.hasAudio { return .audio }
        if probe.hasVideo { return .image }
        return nil
    }

    static func imageFrameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}
