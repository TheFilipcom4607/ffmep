import Foundation

enum FFmpegSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case bundled, homebrew, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled: "Bundled"
        case .homebrew: "Homebrew"
        case .custom: "Custom path"
        }
    }
}

struct FFmpegTools: Sendable, Equatable {
    var ffmpeg: URL
    var ffprobe: URL
    var version: String
    var source: FFmpegSource
    var encoders: Set<String>

    func has(_ encoder: String) -> Bool { encoders.contains(encoder) }
}

enum FFmpegLocator {
    /// `Contents/MacOS` inside the app, or `vendor/` in the repo when running via `swift run`.
    static func bundledDirectory() -> URL {
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent(),
           FileManager.default.isExecutableFile(atPath: exeDir.appendingPathComponent("ffmpeg").path) {
            return exeDir
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // ffmep
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo
            .appendingPathComponent("vendor")
    }

    static let homebrewDirectory = URL(fileURLWithPath: "/opt/homebrew/bin")

    /// A custom path may be the ffmpeg binary itself or the folder containing it.
    static func directory(for source: FFmpegSource, customPath: String) -> URL {
        switch source {
        case .bundled:
            return bundledDirectory()
        case .homebrew:
            return homebrewDirectory
        case .custom:
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            return url.deletingLastPathComponent()
        }
    }

    /// Loads the selected source; if it's broken, falls back to bundled (then Homebrew) with a warning.
    static func load(source: FFmpegSource, customPath: String) async -> (tools: FFmpegTools?, warning: String?) {
        do {
            return (try await validate(directory: directory(for: source, customPath: customPath), source: source), nil)
        } catch {
            let reason = error.localizedDescription
            for fallback in [FFmpegSource.bundled, .homebrew] where fallback != source {
                if let tools = try? await validate(directory: directory(for: fallback, customPath: ""), source: fallback) {
                    return (tools, "\(source.title) ffmpeg unavailable (\(reason)). Using \(fallback.title) instead.")
                }
            }
            return (nil, "No working ffmpeg found: \(reason)")
        }
    }

    static func validate(directory: URL, source: FFmpegSource) async throws -> FFmpegTools {
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let ffprobe = directory.appendingPathComponent("ffprobe")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ffmpeg.path) else {
            throw FFmpegError.launch("ffmpeg not found in \(directory.path)")
        }
        guard fm.isExecutableFile(atPath: ffprobe.path) else {
            throw FFmpegError.launch("ffprobe not found next to ffmpeg")
        }
        let versionOutput = try await ProcessRunner.capture(ffmpeg, ["-hide_banner", "-version"])
        guard versionOutput.status == 0 else {
            throw FFmpegError.launch("ffmpeg -version failed")
        }
        let encoderOutput = try await ProcessRunner.capture(ffmpeg, ["-hide_banner", "-encoders"])
        return FFmpegTools(
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            version: parseVersion(versionOutput.stdoutString),
            source: source,
            encoders: parseEncoders(encoderOutput.stdoutString)
        )
    }

    /// "ffmpeg version 9.0.1 Copyright…" → "9.0.1"
    static func parseVersion(_ output: String) -> String {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        if let i = parts.firstIndex(of: "version"), i + 1 < parts.count {
            return String(parts[i + 1])
        }
        return firstLine.isEmpty ? "unknown" : firstLine
    }

    /// Encoder names from `ffmpeg -encoders` (lines after the "------" separator).
    static func parseEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        var pastHeader = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { pastHeader = true; continue }
            guard pastHeader else { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 { names.insert(String(fields[1])) }
        }
        return names
    }
}
