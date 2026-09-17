import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions. `scripts/make-app.sh` extracts their metadata into the app bundle,
// which is how the Shortcuts app finds them without an Xcode project.
// The actions for each media type live in ShortcutActions.swift.

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
        "Converts videos, audio and images with one of your presets, or with the settings in ffmep’s inspector, and passes on the converted files.",
        categoryName: "Presets"
    )

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.audiovisual-content", "public.image"])
    var files: [IntentFile]

    @Parameter(title: "Preset", description: "Saved settings to use. The preset has to match the type of each file.")
    var preset: PresetEntity?

    @Parameter(title: "Format", description: "Overrides the format of the preset or the inspector settings.")
    var format: OutputFormat?

    @Parameter(title: "Save To", description: "A folder for the converted files. Leave empty to follow ffmep’s save setting.",
               supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) with \(\.$preset)") {
            \.$format
            \.$folder
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let state = AppState.shared
        let presetSettings = preset.flatMap { entity in state.presets.first { $0.id == entity.id } }
        if preset != nil, presetSettings == nil {
            throw ShortcutError("The preset “\(preset?.name ?? "")” no longer exists.")
        }
        let results = try await ShortcutRunner.convert(files, saveTo: folder) { kind, url in
            var settings = state.batch[kind]
            if let presetSettings {
                guard presetSettings.kind == kind else {
                    throw ShortcutError("“\(presetSettings.name)” is a preset for \(presetSettings.kind.pluralTitle.lowercased()), so it can’t convert \(url.lastPathComponent).")
                }
                settings = presetSettings.settings
            }
            if let format {
                guard OutputFormat.choices(for: kind).contains(format) else {
                    throw ShortcutError("\(kind.pluralTitle) can’t be converted to \(format.title).")
                }
                settings.format = format
            }
            // Saved settings can hold a codec or size limit the format doesn't use; the app ignores those, so do the same.
            settings.videoCodec = settings.effectiveCodec
            settings.targetSizeEnabled = settings.usesTargetSize
            return settings
        }
        return .result(value: results)
    }
}

/// Converting, naming and saving, shared by every action.
@MainActor
enum ShortcutRunner {
    /// `settings` picks how to convert each file, and throws when the action doesn't take that kind of file.
    static func convert(
        _ files: [IntentFile],
        saveTo folder: IntentFile?,
        settings: (MediaKind, URL) throws -> ConversionSettings
    ) async throws -> [IntentFile] {
        let state = AppState.shared
        guard let tools = await state.readyTools() else {
            throw ShortcutError(state.toolsWarning ?? "ffmpeg is not available. Check ffmep’s settings.")
        }
        guard !files.isEmpty else { throw ShortcutError("There are no files to convert.") }

        var chosenFolder: URL?
        if let folder {
            guard let url = folder.fileURL else { throw ShortcutError("Choose a folder on this Mac to save to.") }
            chosenFolder = url
        }
        let folderAccess = chosenFolder?.startAccessingSecurityScopedResource() ?? false
        defer { if folderAccess { chosenFolder?.stopAccessingSecurityScopedResource() } }

        let converter = Converter(tools: tools, reservations: OutputReservations())
        var results: [IntentFile] = []
        for file in files {
            let input = try localCopy(of: file)
            defer { input.stopAccessing() }
            guard let kind = await Probe.classify(url: input.url, ffprobe: tools.ffprobe) else {
                throw ShortcutError("\(input.url.lastPathComponent) isn’t a video, audio file or image.")
            }
            let fileSettings = try settings(kind, input.url)
            try validate(fileSettings)

            // Replacing originals stays a choice made in the app, never from a shortcut.
            let directory: URL
            if let chosenFolder {
                directory = chosenFolder
            } else {
                let location: SaveLocation = state.saveLocation == .folder ? .folder : .nextToOriginal
                directory = OutputNaming.directory(for: input.url, location: location, folder: state.outputFolder)
            }
            let request = ConversionRequest(source: input.url, kind: kind, settings: fileSettings,
                                            outputDirectory: directory, nameTemplate: state.nameTemplate)
            let result = try await converter.convert(request) { _ in }
            results.append(IntentFile(fileURL: result.output, filename: result.output.lastPathComponent))
        }
        return results
    }

    /// Settings a shortcut can ask for that ffmep can't honour, reported instead of quietly ignored.
    nonisolated static func validate(_ settings: ConversionSettings) throws {
        let format = settings.format
        if format.isVideoContainer, !format.codecChoices.contains(settings.videoCodec) {
            let names = format.codecChoices.map(\.title)
            let codecs = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names.joined()
            throw ShortcutError("\(format.title) can’t hold \(settings.videoCodec.title) video. Choose \(codecs) instead.")
        }
        if settings.targetSizeEnabled {
            guard settings.targetSizeMB > 0 else { throw ShortcutError("The file size limit has to be more than 0 MB.") }
            guard settings.supportsTargetSize else {
                let name = format.hasQuality ? "ProRes" : format.title
                throw ShortcutError("\(name) has no quality setting to lower, so it can’t aim for a file size.")
            }
        }
    }

    private struct Input {
        var url: URL
        var scoped: Bool

        func stopAccessing() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Files from Finder arrive as URLs; anything else (Photos, Safari downloads) only as data, written to a temporary folder.
    private static func localCopy(of file: IntentFile) throws -> Input {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return Input(url: url, scoped: url.startAccessingSecurityScopedResource())
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
        return Input(url: url, scoped: false)
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
            intent: ConvertImagesIntent(),
            phrases: ["Convert images with \(.applicationName)"],
            shortTitle: "Convert Images",
            systemImageName: "photo"
        )
        AppShortcut(
            intent: ConvertVideosIntent(),
            phrases: ["Convert videos with \(.applicationName)"],
            shortTitle: "Convert Videos",
            systemImageName: "film"
        )
        AppShortcut(
            intent: ConvertAudioIntent(),
            phrases: ["Convert audio with \(.applicationName)"],
            shortTitle: "Convert Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RemoveBackgroundIntent(),
            phrases: ["Remove the background with \(.applicationName)"],
            shortTitle: "Remove Background",
            systemImageName: "person.crop.rectangle"
        )
        AppShortcut(
            intent: ConvertFilesIntent(),
            phrases: ["Convert files with \(.applicationName)"],
            shortTitle: "Convert with Preset",
            systemImageName: "slider.horizontal.3"
        )
    }
}
