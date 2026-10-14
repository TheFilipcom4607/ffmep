import Foundation

/// What went wrong on the command line. Usage errors exit with 2, everything else with 1.
enum CLIError: Error, Equatable {
    case usage(String)
    case failure(String)

    var message: String {
        switch self {
        case .usage(let message), .failure(let message): message
        }
    }
}

struct OptionSpec {
    var name: String
    var short: Character?
    var takesValue: Bool
    var aliases: [String] = []

    static func value(_ name: String, _ short: Character? = nil, aliases: [String] = []) -> OptionSpec {
        OptionSpec(name: name, short: short, takesValue: true, aliases: aliases)
    }

    static func flag(_ name: String, _ short: Character? = nil, aliases: [String] = []) -> OptionSpec {
        OptionSpec(name: name, short: short, takesValue: false, aliases: aliases)
    }
}

struct ParsedArguments: Equatable {
    var positionals: [String] = []
    /// Option values by canonical name. A repeated option keeps the last value.
    var values: [String: String] = [:]
    var flags: Set<String> = []

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

/// `--name value`, `--name=value`, `-n value`, bundled short flags like `-jq`, and `--` to end options.
enum ArgumentParser {
    static func parse(_ arguments: [String], options: [OptionSpec]) throws -> ParsedArguments {
        var byName: [String: OptionSpec] = [:]
        var byShort: [Character: OptionSpec] = [:]
        for option in options {
            for name in [option.name] + option.aliases { byName[name] = option }
            if let short = option.short { byShort[short] = option }
        }

        var parsed = ParsedArguments()
        var index = 0
        var optionsEnded = false
        func take(_ option: OptionSpec, inline: String?, shown: String) throws {
            guard option.takesValue else {
                if inline != nil { throw CLIError.usage("\(shown) doesn’t take a value.") }
                parsed.flags.insert(option.name)
                return
            }
            if let inline {
                parsed.values[option.name] = inline
            } else {
                index += 1
                guard index < arguments.count else { throw CLIError.usage("\(shown) needs a value.") }
                parsed.values[option.name] = arguments[index]
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded || argument == "-" || !argument.hasPrefix("-") || isNegativeNumber(argument) {
                parsed.positionals.append(argument)
            } else if argument == "--" {
                optionsEnded = true
            } else if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard let option = byName[name] else {
                    throw CLIError.usage("Unknown option --\(name).\(suggestion(for: name, among: Array(byName.keys)))")
                }
                try take(option, inline: parts.count > 1 ? String(parts[1]) : nil, shown: "--\(name)")
            } else {
                // -abc is -a -b -c, and the first one that takes a value swallows the rest: -oOut is -o Out.
                var letters = Substring(argument.dropFirst())
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    guard let option = byShort[letter] else { throw CLIError.usage("Unknown option -\(letter).") }
                    if option.takesValue {
                        try take(option, inline: letters.isEmpty ? nil : String(letters), shown: "-\(letter)")
                        break
                    }
                    try take(option, inline: nil, shown: "-\(letter)")
                }
            }
            index += 1
        }
        return parsed
    }

    /// `-90` is a rotation, not an option.
    private static func isNegativeNumber(_ argument: String) -> Bool {
        argument.count > 1 && Double(argument) != nil
    }

    private static func suggestion(for name: String, among names: [String]) -> String {
        let close = names
            .map { ($0, distance($0, name)) }
            .filter { $0.1 <= max(2, name.count / 3) }
            .min { $0.1 < $1.1 }
        return close.map { " Did you mean --\($0.0)?" } ?? ""
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: Values

/// Turns the words people type into ffmep's settings. Each accepts a few spellings, so
/// `remove-location`, `removeLocation` and `remove_location` all work.
enum CLIValue {
    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func format(_ text: String) throws -> OutputFormat {
        switch key(text) {
        case "jpg", "jpeg": return .jpeg
        case "aac": return .m4a
        case "heif": return .heic
        case "applelossless": return .alac
        case let k: if let format = OutputFormat.allCases.first(where: { $0.rawValue == k }) { return format }
        }
        throw invalid("format", text, OutputFormat.allCases.map(\.rawValue))
    }

    /// A preset word or 0–100, the same scale as the app's slider.
    static func quality(_ text: String) throws -> Double {
        if let preset = QualityPreset.allCases.first(where: { $0.rawValue == key(text) }) { return preset.value }
        guard let value = Double(text), (0...100).contains(value) else {
            throw CLIError.usage("Invalid quality “\(text)”. Use small, balanced, high or a number from 0 to 100.")
        }
        return value
    }

    /// `10MB`, `10 mb`, `500KB`, `1.5GB` or a bare number of megabytes. Sizes are decimal, like Finder's.
    static func megabytes(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let scale: Double? = switch unit {
        case "", "m", "mb": 1
        case "k", "kb": 0.001
        case "g", "gb": 1000
        default: nil
        }
        guard let value = Double(number), let scale, value > 0 else {
            throw CLIError.usage("Invalid size “\(text)”. Use something like 10MB, 500KB or 1.5GB.")
        }
        return value * scale
    }

    static func codec(_ text: String) throws -> VideoCodec {
        switch key(text) {
        case "h264", "avc", "x264": return .h264
        case "hevc", "h265", "x265": return .hevc
        case "prores": return .prores
        case "vp9": return .vp9
        case "av1": return .av1
        default: throw invalid("codec", text, VideoCodec.allCases.map(\.rawValue))
        }
    }

    static func frameRate(_ text: String) throws -> FrameRateOption {
        if key(text) == "original" { return .original }
        let number = Double(key(text).replacingOccurrences(of: "fps", with: ""))
        guard let match = FrameRateOption.allCases.first(where: { $0.value != nil && $0.value == number }) else {
            throw CLIError.usage("Invalid frame rate “\(text)”. Use original, 60, 30, 24, 15 or 10.")
        }
        return match
    }

    /// Degrees clockwise, as in the app's 90° Clockwise. `-90` and `270` are the same turn.
    static func rotation(_ text: String) throws -> Rotation {
        switch text.lowercased().replacingOccurrences(of: "°", with: "") {
        case "0", "none": return .none
        case "90", "cw", "-270": return .cw90
        case "-90", "270", "ccw": return .ccw90
        case "180", "-180": return .r180
        default: throw CLIError.usage("Invalid rotation “\(text)”. Use 90, -90 or 180 (degrees clockwise).")
        }
    }

    static func flip(_ text: String) throws -> Flip {
        switch key(text) {
        case "h", "horizontal": return Flip(horizontal: true, vertical: false)
        case "v", "vertical": return Flip(horizontal: false, vertical: true)
        case "hv", "vh", "both": return Flip(horizontal: true, vertical: true)
        default: throw CLIError.usage("Invalid flip “\(text)”. Use horizontal, vertical or both.")
        }
    }

    static func metadata(_ text: String) throws -> MetadataMode {
        switch key(text) {
        case "keep", "all": return .keep
        case "removelocation", "nolocation", "location": return .removeLocation
        case "removeall", "strip", "none": return .removeAll
        default: throw CLIError.usage("Invalid metadata “\(text)”. Use keep, remove-location or remove-all.")
        }
    }

    static func background(_ text: String) throws -> BackgroundStyle {
        guard let style = BackgroundStyle.allCases.first(where: { $0.rawValue == key(text) }) else {
            throw invalid("background", text, BackgroundStyle.allCases.map(\.rawValue))
        }
        return style
    }

    static func model(_ text: String) throws -> SubjectDetector {
        switch key(text) {
        case "birefnet": return .biRefNet
        case "vision", "applevision", "apple": return .vision
        default: throw CLIError.usage("Invalid model “\(text)”. Use birefnet or vision.")
        }
    }

    static func livePhoto(_ text: String) throws -> LivePhotoMode {
        switch key(text) {
        case "still", "image", "photo": return .still
        case "gif": return .gif
        case "video", "mp4", "motion": return .video
        default: throw CLIError.usage("Invalid Live Photo export “\(text)”. Use still, gif or video.")
        }
    }

    /// A resize request, written into settings by `ResizeRequest.apply`.
    static func resize(_ text: String) throws -> ResizeRequest {
        let k = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch k {
        case "original", "none": return .option(.original)
        case "4k", "2160p", "2160": return .option(.p2160)
        case "1080p": return .option(.p1080)
        case "720p": return .option(.p720)
        case "480p": return .option(.p480)
        default: break
        }
        if k.hasSuffix("%"), let percent = Int(k.dropLast()), (1...1000).contains(percent) {
            return .percent(percent)
        }
        if let side = Int(k), side > 0 { return .box(width: side, height: side) }
        let parts = k.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let width = parts[0].isEmpty ? 0 : Int(parts[0])
            let height = parts[1].isEmpty ? 0 : Int(parts[1])
            if let width, let height, width >= 0, height >= 0, width + height > 0 {
                return .box(width: width, height: height)
            }
        }
        throw CLIError.usage("Invalid size “\(text)”. Use 1080p, 720p, 480p, 4k, 50%, 2048 (longest side), 1920x1080, 1280x or x720.")
    }

    private static func invalid(_ what: String, _ text: String, _ choices: [String]) -> CLIError {
        .usage("Invalid \(what) “\(text)”. Use one of: \(choices.joined(separator: ", ")).")
    }
}

struct Flip: Equatable {
    var horizontal: Bool
    var vertical: Bool
}

enum ResizeRequest: Equatable {
    case option(ResizeOption)
    case percent(Int)
    /// Fits inside the box; a 0 side is left free.
    case box(width: Int, height: Int)

    func apply(to settings: inout ConversionSettings) {
        switch self {
        case .option(let option):
            settings.resize = option
        case .percent(let percent):
            settings.resize = .percent
            settings.percent = percent
        case .box(let width, let height):
            settings.resize = .custom
            settings.customWidth = width
            settings.customHeight = height
        }
    }
}
