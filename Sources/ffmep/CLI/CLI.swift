import Foundation

/// `ffmep convert`, `ffmep info` and the rest. Results go to stdout (paths, or JSON with `--json`),
/// everything meant for a person goes to stderr.
@MainActor
enum CLI {
    nonisolated static let commands = ["convert", "info", "formats", "presets", "model", "help", "version"]

    /// Whether these arguments are for the command line rather than the app. macOS can hand the app
    /// arguments of its own (`-NSDocumentRevisionsDebugMode YES`, `-psn_…`), so only a command counts.
    /// A bare `ffmep` typed in a terminal prints help; from Finder or `open` there's no terminal, so the app starts.
    nonisolated static func handles(_ arguments: [String], interactive: Bool = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains { isatty($0) == 1 }) -> Bool {
        guard let first = arguments.first else { return interactive }
        return commands.contains(first) || ["--help", "-h", "--version", "-v", "-V"].contains(first)
    }

    static func run(_ arguments: [String]) async -> Int32 {
        var arguments = arguments
        let command = arguments.isEmpty ? "help" : arguments.removeFirst()
        // `ffmep convert --help`, like most tools.
        if command != "help", arguments.contains("--help") || arguments.contains("-h") {
            out(Help.text(for: command))
            return 0
        }
        do {
            switch command {
            case "convert": return try await ConvertCommand.run(arguments)
            case "info": return try await InfoCommand.run(arguments)
            case "formats": return try FormatsCommand.run(arguments)
            case "presets": return try PresetsCommand.run(arguments)
            case "model": return try await ModelCommand.run(arguments)
            case "version", "--version", "-v", "-V": return try await VersionCommand.run(arguments)
            case "help", "--help", "-h":
                out(Help.text(for: arguments.first))
                return 0
            default:
                throw CLIError.usage("Unknown command “\(command)”.")
            }
        } catch let error as CLIError {
            switch error {
            case .usage(let message):
                err("ffmep: \(message)")
                err("Run `ffmep help` for the commands, or `ffmep \(commands.contains(command) ? command : "convert") --help` for the options.")
                return 2
            case .failure(let message):
                err("ffmep: \(message)")
                return 1
            }
        } catch {
            err("ffmep: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: Shared

    /// Run through a symlink, like Homebrew's, `Bundle.main` isn't the app, so the app is found from the real path.
    static var version: String {
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] == nil
            ? app.flatMap(Bundle.init(url:))?.infoDictionary : Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    static func loadTools(_ prefs: StoredPreferences, quiet: Bool) async throws -> FFmpegTools {
        let (tools, warning) = await FFmpegLocator.load(source: prefs.ffmpegSource, customPath: prefs.customFFmpegPath)
        if let warning, !quiet || tools == nil { err("ffmep: \(warning)") }
        guard let tools else { throw CLIError.failure("ffmpeg isn’t available, so nothing can be converted. Check ffmpeg in ffmep’s Settings.") }
        return tools
    }

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    nonisolated static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    nonisolated static func err(_ text: String) {
        writeErr(text + "\n")
    }

    nonisolated static func writeErr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func printJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        out(String(decoding: data, as: UTF8.self))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,+%@"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    static func rejectExtra(_ args: ParsedArguments, command: String) throws {
        if let extra = args.positionals.first { throw CLIError.usage("`ffmep \(command)` doesn’t take “\(extra)”.") }
    }
}
