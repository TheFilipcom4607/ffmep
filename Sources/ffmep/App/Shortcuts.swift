import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions. `scripts/make-app.sh` extracts their metadata into the app bundle,
// which is how the Shortcuts app finds them without an Xcode project.

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

struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()

    let id: UUID
    let name: String
    let kind: MediaKind

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        kind = preset.kind
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind.title)")
    }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await MainActor.run {
            AppState.shared.presets.filter { identifiers.contains($0.id) }.map(PresetEntity.init)
        }
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        await MainActor.run { AppState.shared.presets.map(PresetEntity.init) }
    }
}

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts videos, audio and images on this Mac and passes on the converted files. Without a preset or format, each file uses the settings in ffmep’s inspector.",
        categoryName: "Convert"
    )

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.audiovisual-content", "public.image"])
    var files: [IntentFile]

    @Parameter(title: "Preset", description: "Saved settings to use. The preset has to match the type of each file.")
    var preset: PresetEntity?

    @Parameter(title: "Format", description: "Overrides the format of the preset or the inspector settings.")
    var format: OutputFormat?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files)") {
            \.$preset
            \.$format
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let state = AppState.shared
        guard let tools = await state.readyTools() else {
            throw ShortcutError(state.toolsWarning ?? "ffmpeg is not available. Check ffmep’s settings.")
        }
        let converter = Converter(tools: tools, reservations: OutputReservations())
        let presetSettings = preset.flatMap { entity in state.presets.first { $0.id == entity.id } }
        if preset != nil, presetSettings == nil {
            throw ShortcutError("The preset “\(preset?.name ?? "")” no longer exists.")
        }

        var results: [IntentFile] = []
        for file in files {
            let input = try Self.localCopy(of: file)
            defer { input.stopAccessing() }
            guard let kind = await Probe.classify(url: input.url, ffprobe: tools.ffprobe) else {
                throw ShortcutError("\(input.url.lastPathComponent) isn’t a video, audio file or image.")
            }

            var settings = state.batch[kind]
            if let presetSettings {
                guard presetSettings.kind == kind else {
                    throw ShortcutError("“\(presetSettings.name)” is a preset for \(presetSettings.kind.pluralTitle.lowercased()), so it can’t convert \(input.url.lastPathComponent).")
                }
                settings = presetSettings.settings
            }
            if let format {
                guard OutputFormat.choices(for: kind).contains(format) else {
                    throw ShortcutError("\(kind.pluralTitle) can’t be converted to \(format.title).")
                }
                settings.format = format
            }

            // Replacing originals stays a choice made in the app, never from a shortcut.
            let location: SaveLocation = state.saveLocation == .folder ? .folder : .nextToOriginal
            let directory = OutputNaming.directory(for: input.url, location: location, folder: state.outputFolder)
            let request = ConversionRequest(source: input.url, kind: kind, settings: settings,
                                            outputDirectory: directory, nameTemplate: state.nameTemplate)
            let result = try await converter.convert(request) { _ in }
            results.append(IntentFile(fileURL: result.output, filename: result.output.lastPathComponent))
        }
        return .result(value: results)
    }

    private struct Input {
        var url: URL
        var isTemporary: Bool
        var scoped: Bool

        func stopAccessing() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Files from Finder arrive as URLs; anything else (Photos, Safari downloads) only as data, written to a temporary folder.
    private static func localCopy(of file: IntentFile) throws -> Input {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return Input(url: url, isTemporary: false, scoped: url.startAccessingSecurityScopedResource())
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmep-shortcuts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = file.filename.isEmpty ? "File" : file.filename
        if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let url = folder.appendingPathComponent(name)
        try file.data.write(to: url)
        return Input(url: url, isTemporary: true, scoped: false)
    }
}

struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct FfmepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFilesIntent(),
            phrases: ["Convert files with \(.applicationName)"],
            shortTitle: "Convert Files",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
