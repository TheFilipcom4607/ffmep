import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // Queue
    var jobs: [Job] = []
    var selection: Set<UUID> = []
    var isAdding = false
    var statusMessage: String?
    /// True when `statusMessage` is a successful batch summary.
    var statusIsSuccess = false
    /// Which media type the inspector is showing.
    var inspectorKind: MediaKind = .image
    @ObservationIgnored private var toolsTask: Task<Void, Never>?

    // Run
    private(set) var isRunning = false
    private var runJobIDs: [UUID] = []
    /// Set when the user quits mid-batch: the app terminates once cancelled jobs have cleaned up.
    @ObservationIgnored var terminateWhenFinished = false

    // Persisted settings
    var batch: BatchSettings { didSet { save(batch, key: Keys.batch) } }
    var saveLocation: SaveLocation { didSet { defaults.set(saveLocation.rawValue, forKey: Keys.saveLocation) } }
    var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: Keys.outputFolder) } }
    /// Output file names, e.g. `{name} ({format})`. Replace Originals always keeps the original name.
    var nameTemplate: String { didSet { defaults.set(nameTemplate, forKey: Keys.nameTemplate) } }
    var presets: [Preset] { didSet { save(presets, key: Keys.presets) } }
    /// Always open at launch; hiding it lasts only for the session.
    var showInspector = true
    var ffmpegSource: FFmpegSource {
        didSet {
            defaults.set(ffmpegSource.rawValue, forKey: Keys.ffmpegSource)
            Task { await reloadTools() }
        }
    }
    var customFFmpegPath: String { didSet { defaults.set(customFFmpegPath, forKey: Keys.customPath) } }
    var limits: ConcurrencyLimits { didSet { save(limits, key: Keys.limits) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) } }
    /// Takes successfully converted files off the list when a batch finishes.
    var removeConvertedFiles: Bool { didSet { defaults.set(removeConvertedFiles, forKey: Keys.removeConverted) } }

    // Background model
    let subjectModel = SubjectModelStore()
    var showSubjectModelOffer = false

    // Replace Originals
    var showReplaceConfirmation = false
    @ObservationIgnored private(set) var pendingReplace: [Job] = []

    // ffmpeg
    private(set) var tools: FFmpegTools?
    private(set) var toolsWarning: String?
    private(set) var isLoadingTools = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let scheduler = JobScheduler()
    @ObservationIgnored private let reservations = OutputReservations()

    private enum Keys {
        static let batch = "batchSettings"
        static let saveLocation = "saveLocation"
        static let outputFolder = "outputFolder"
        static let ffmpegSource = "ffmpegSource"
        static let customPath = "customFFmpegPath"
        static let limits = "concurrencyLimits"
        static let notifications = "notificationsEnabled"
        static let removeConverted = "removeConvertedFiles"
        static let nameTemplate = "nameTemplate"
        static let presets = "presets"
        static let offeredExamples = "offeredExamplePresets"
    }

    private init() {
        let d = UserDefaults.standard
        batch = Self.load(BatchSettings.self, key: Keys.batch, from: d) ?? BatchSettings()
        saveLocation = d.string(forKey: Keys.saveLocation).flatMap(SaveLocation.init(rawValue:)) ?? .nextToOriginal
        outputFolder = d.string(forKey: Keys.outputFolder).map { URL(fileURLWithPath: $0) }
        ffmpegSource = d.string(forKey: Keys.ffmpegSource).flatMap(FFmpegSource.init(rawValue:)) ?? .bundled
        customFFmpegPath = d.string(forKey: Keys.customPath) ?? ""
        limits = Self.load(ConcurrencyLimits.self, key: Keys.limits, from: d) ?? .default
        notificationsEnabled = d.object(forKey: Keys.notifications) as? Bool ?? true
        removeConvertedFiles = d.object(forKey: Keys.removeConverted) as? Bool ?? true
        nameTemplate = d.string(forKey: Keys.nameTemplate) ?? OutputNaming.defaultTemplate
        presets = Self.load([Preset].self, key: Keys.presets, from: d) ?? []
        addNewExamplePresets()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            NSApp.dockTile.badgeLabel = nil
        }
        toolsTask = Task { await reloadTools() }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: ffmpeg

    /// Waits for the first lookup at launch, for callers that need ffmpeg right away (Shortcuts).
    func readyTools() async -> FFmpegTools? {
        if tools == nil { await toolsTask?.value }
        return tools
    }

    func reloadTools() async {
        isLoadingTools = true
        let result = await FFmpegLocator.load(source: ffmpegSource, customPath: customFFmpegPath)
        tools = result.tools
        toolsWarning = result.warning
        isLoadingTools = false
    }

    // MARK: Background model

    /// Asks once, the first time someone turns on background removal, whether to get the better model.
    func offerSubjectModelIfNeeded() {
        guard !subjectModel.hasOffered, !subjectModel.isInstalled, !subjectModel.isBusy else { return }
        subjectModel.hasOffered = true
        showSubjectModelOffer = true
    }

    // MARK: Queue

    var kindsInQueue: [MediaKind] {
        let kinds = Set(jobs.map(\.kind))
        return MediaKind.allCases.filter(kinds.contains)
    }

    var pendingJobs: [Job] { jobs.filter { $0.status.isPending } }
    var selectedJobs: [Job] { jobs.filter { selection.contains($0.id) } }

    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isAdding = true
        Task {
            // Files opened at launch arrive before ffmpeg is located; ffprobe is needed for mkv/webm/opus.
            if tools == nil { await toolsTask?.value }
            let ffprobe = tools?.ffprobe
            let files = await Task.detached(priority: .userInitiated) { Self.expand(urls) }.value
            let known = Set(jobs.map { $0.url.standardizedFileURL.path })
            let fresh = files.filter { !known.contains($0.standardizedFileURL.path) }
            let classified = await Self.classify(fresh, ffprobe: ffprobe)

            var skipped = 0
            var seen = Set(jobs.map { $0.url.standardizedFileURL.path })
            for (url, kind, size) in classified {
                guard let kind else { skipped += 1; continue }
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                jobs.append(Job(url: url, kind: kind, fileSize: size))
            }
            mergeLivePhotoPairs()
            statusMessage = skipped > 0 ? "Skipped \(skipped) unsupported file\(skipped == 1 ? "" : "s")" : nil
            statusIsSuccess = false
            isAdding = false
            if let first = jobs.first, !kindsInQueue.contains(inspectorKind) { inspectorKind = first.kind }

            #if DEBUG
            // Screenshot/automation hooks: `open -a ffmep.app files --args -FFMEPSelectFirst 3 -FFMEPAutoConvert YES`
            let selectCount = UserDefaults.standard.integer(forKey: "FFMEPSelectFirst")
            if selectCount > 0 { selection = Set(displayOrder.prefix(selectCount)) }
            if UserDefaults.standard.bool(forKey: "FFMEPAutoConvert") { convert() }
            #endif
        }
    }

    /// Folds an AirDropped Live Photo's video into its still, so the pair shows as one row.
    private func mergeLivePhotoPairs() {
        var videosByKey: [String: Job] = [:]
        for job in jobs where job.kind == .video && job.status.isPending && LivePhoto.isPairableVideo(job.url) {
            videosByKey[LivePhoto.pairingKey(job.url)] = job
        }
        guard !videosByKey.isEmpty else { return }

        var paired = Set<UUID>()
        for job in jobs where job.kind == .image && job.livePhotoVideo == nil {
            guard let video = videosByKey[LivePhoto.pairingKey(job.url)], !paired.contains(video.id) else { continue }
            guard LivePhoto.isLivePhotoStill(job.url) else { continue }
            job.livePhotoVideo = video.url
            paired.insert(video.id)
        }
        if !paired.isEmpty {
            jobs.removeAll { paired.contains($0.id) }
            selection.subtract(paired)
        }
    }

    /// The format a job actually produces, taking Live Photo export into account.
    func targetFormat(for job: Job) -> OutputFormat {
        let settings = effectiveSettings(for: job)
        if job.livePhotoVideo != nil, let motion = settings.motionSettings() { return motion.format }
        return settings.format
    }

    // MARK: Display & selection

    struct JobGroup: Identifiable {
        let kind: MediaKind
        let jobs: [Job]
        var id: MediaKind { kind }
    }

    var groupedJobs: [JobGroup] {
        MediaKind.allCases.compactMap { kind in
            let group = jobs.filter { $0.kind == kind }
            return group.isEmpty ? nil : JobGroup(kind: kind, jobs: group)
        }
    }

    var displayOrder: [UUID] { groupedJobs.flatMap { $0.jobs.map(\.id) } }

    /// Keeps the inspector on a media type that is part of the current selection.
    func syncInspectorWithSelection() {
        let kinds = Set(selectedJobs.map(\.kind))
        if !kinds.isEmpty, !kinds.contains(inspectorKind), let kind = MediaKind.allCases.first(where: kinds.contains) {
            inspectorKind = kind
        }
    }

    func selectAll() {
        selection = Set(jobs.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    var runCounts: (finished: Int, total: Int) {
        let runJobs = jobs.filter { runJobIDs.contains($0.id) }
        let finished = runJobs.filter {
            switch $0.status {
            case .done, .failed, .cancelled: true
            default: false
            }
        }.count
        return (finished, runJobs.count)
    }

    /// Files dropped directly plus the contents of dropped folders (recursive, hidden files skipped).
    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var found: [URL] = []
                for case let file as URL in enumerator
                where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    found.append(file)
                }
                result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else {
                result.append(url)
            }
        }
        return result
    }

    nonisolated static func classify(_ urls: [URL], ffprobe: URL?) async -> [(URL, MediaKind?, Int64)] {
        await withTaskGroup(of: (Int, MediaKind?, Int64).self) { group in
            var results = [(URL, MediaKind?, Int64)](repeating: (URL(fileURLWithPath: "/"), nil, 0), count: urls.count)
            var next = 0
            let width = 8
            func add(_ i: Int) {
                let url = urls[i]
                group.addTask {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    return (i, await Probe.classify(url: url, ffprobe: ffprobe), size)
                }
            }
            while next < min(width, urls.count) { add(next); next += 1 }
            while let (i, kind, size) = await group.next() {
                results[i] = (urls[i], kind, size)
                if next < urls.count { add(next); next += 1 }
            }
            return results
        }
    }

    func remove(ids: Set<UUID>) {
        for id in ids { scheduler.cancel(jobID: id) }
        jobs.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clearAll() {
        if isRunning { scheduler.cancelAll() }
        jobs.removeAll()
        selection.removeAll()
        statusMessage = nil
    }

    func clearCompleted() {
        let done = Set(jobs.filter { $0.status.isDone }.map(\.id))
        jobs.removeAll { done.contains($0.id) }
        selection.subtract(done)
    }

    func retry(ids: Set<UUID>) {
        // A replaced original is in the Trash, so there's nothing left to convert again.
        let targets = jobs.filter { ids.contains($0.id) && !$0.status.isRunning && FileManager.default.fileExists(atPath: $0.url.path) }
        targets.forEach { $0.status = .waiting; $0.note = nil; $0.removedMetadata = [] }
        if !isRunning { start(targets) }
    }

    /// Stops the given files without affecting the rest of the batch.
    func cancel(ids: Set<UUID>) {
        for id in ids { scheduler.cancel(jobID: id) }
    }

    /// The converted file when it exists, otherwise the original.
    func bestURL(for job: Job) -> URL {
        job.outputURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? job.url
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([bestURL(for: job)])
    }

    func reveal(_ jobs: [Job]) {
        NSWorkspace.shared.activateFileViewerSelecting(jobs.map(bestURL(for:)))
    }

    // MARK: Quick Look

    var quickLookURL: URL?

    /// Toggles Quick Look for the selection, like pressing Space in Finder.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let job = jobs.first(where: { selection.contains($0.id) }) {
            quickLookURL = bestURL(for: job)
        }
    }

    var quickLookItems: [URL] {
        let chosen = selection.count > 1 ? jobs.filter { selection.contains($0.id) } : jobs
        return chosen.map(bestURL(for:))
    }

    // MARK: Settings & overrides

    func effectiveSettings(for job: Job) -> ConversionSettings {
        job.override ?? batch[job.kind]
    }

    /// Batch settings when nothing is selected; otherwise per-file overrides applied to every selected file of that kind.
    func settingsBinding(for kind: MediaKind) -> Binding<ConversionSettings> {
        Binding(
            get: { [self] in
                if selection.isEmpty { return batch[kind] }
                let first = selectedJobs.first { $0.kind == kind }
                return first?.override ?? batch[kind]
            },
            set: { [self] newValue in
                if selection.isEmpty {
                    batch[kind] = newValue
                } else {
                    for job in selectedJobs where job.kind == kind {
                        job.override = newValue == batch[kind] ? nil : newValue
                    }
                }
            }
        )
    }

    func resetSelectedOverrides() {
        selectedJobs.forEach { $0.override = nil }
    }

    // MARK: Presets

    func presets(for kind: MediaKind) -> [Preset] {
        presets.filter { $0.kind == kind }
    }

    /// Saving under a name that's already taken for this media type updates that preset.
    func savePreset(named name: String, kind: MediaKind, settings: ConversionSettings) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.kind == kind && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            presets[index].name = name
            presets[index].settings = settings
        } else {
            presets.append(Preset(name: name, kind: kind, settings: settings))
        }
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    /// Adds built-in presets that are new since the last launch. Each one is offered once,
    /// so deleting it sticks, and presets added in later versions still show up.
    private func addNewExamplePresets() {
        let key = { (preset: Preset) in "\(preset.kind.rawValue)/\(preset.name)" }
        let existing = Set(presets.map(key))
        // Before this was tracked, the examples in the saved list were the ones that had been offered.
        var offered = Set(defaults.stringArray(forKey: Keys.offeredExamples) ?? Array(existing))
        let fresh = Preset.examples.filter { !offered.contains(key($0)) && !existing.contains(key($0)) }
        // New presets go after the existing ones of the same media type.
        for preset in fresh {
            let index = presets.lastIndex { $0.kind == preset.kind }.map { $0 + 1 } ?? presets.endIndex
            presets.insert(preset, at: index)
        }
        if !fresh.isEmpty { save(presets, key: Keys.presets) }
        offered.formUnion(Preset.examples.map(key))
        defaults.set(offered.sorted(), forKey: Keys.offeredExamples)
    }

    // MARK: Running

    var overallProgress: Double {
        let runJobs = jobs.filter { runJobIDs.contains($0.id) }
        guard !runJobs.isEmpty else { return 0 }
        let total = runJobs.reduce(0.0) { sum, job in
            switch job.status {
            case .waiting: sum
            case .running(let p): sum + p
            case .done, .failed, .cancelled: sum + 1
            }
        }
        return total / Double(runJobs.count)
    }

    func convert() {
        start(pendingJobs)
    }

    private func start(_ targets: [Job], confirmed: Bool = false) {
        guard !isRunning, !targets.isEmpty else { return }
        if saveLocation == .replaceOriginal, !confirmed {
            pendingReplace = targets
            showReplaceConfirmation = true
            return
        }
        guard let tools else {
            statusMessage = toolsWarning ?? "ffmpeg is not available. Check Settings."
            return
        }
        if saveLocation == .folder, outputFolder == nil {
            chooseOutputFolder()
            guard outputFolder != nil else { return }
        }

        isRunning = true
        runJobIDs = targets.map(\.id)
        statusMessage = nil
        NSApp.dockTile.badgeLabel = nil
        if notificationsEnabled { requestNotificationPermission() }

        let converter = Converter(tools: tools, reservations: reservations)
        let location = saveLocation
        let folder = outputFolder
        let template = nameTemplate
        scheduler.start(
            jobs: targets,
            limits: limits,
            converter: converter,
            request: { [self] job in
                ConversionRequest(
                    source: job.url,
                    kind: job.kind,
                    settings: effectiveSettings(for: job),
                    outputDirectory: OutputNaming.directory(for: job.url, location: location, folder: folder),
                    livePhotoVideo: job.livePhotoVideo,
                    replacesOriginal: location == .replaceOriginal,
                    nameTemplate: template
                )
            },
            lane: { [self] job in
                let settings = effectiveSettings(for: job)
                if job.livePhotoVideo != nil, let motion = settings.motionSettings() {
                    return Lane.of(kind: .video, settings: motion)
                }
                return Lane.of(kind: job.kind, settings: settings)
            },
            completion: { [self] in finished() }
        )
    }

    func confirmReplace() {
        let targets = pendingReplace
        pendingReplace = []
        start(targets, confirmed: true)
    }

    func cancel() {
        scheduler.cancelAll()
    }

    private func finished() {
        isRunning = false
        if terminateWhenFinished {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let runJobs = jobs.filter { runJobIDs.contains($0.id) }
        let done = runJobs.filter { $0.status.isDone }
        let failed = runJobs.filter { if case .failed = $0.status { true } else { false } }
        let saved = done.reduce(Int64(0)) { sum, job in
            guard case .done(let size) = job.status else { return sum }
            return sum + (job.fileSize - size)
        }

        var summary = "Converted \(done.count) file\(done.count == 1 ? "" : "s")"
        if saved > 0 { summary += ", saved \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))" }
        if !failed.isEmpty { summary += " · \(failed.count) failed" }
        statusMessage = runJobs.isEmpty ? nil : summary
        statusIsSuccess = failed.isEmpty && !done.isEmpty
        if removeConvertedFiles { clearCompleted() }

        guard !done.isEmpty || !failed.isEmpty else { return }
        if !NSApp.isActive {
            NSApp.dockTile.badgeLabel = failed.isEmpty ? "\(done.count)" : "!"
        }
        if notificationsEnabled { postNotification(summary) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Converted files will be saved here"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            saveLocation = .folder
        }
    }

    func showAddPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    // MARK: Notifications

    /// UserNotifications needs a real app bundle; skip when running unbundled via `swift run`.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(_ body: String) {
        guard canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "ffmep"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
