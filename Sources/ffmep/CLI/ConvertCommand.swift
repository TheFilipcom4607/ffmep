import Foundation

/// One file in `ffmep convert --json` output. Fields that don't apply are left out.
struct FileReport: Encodable {
    enum Status: String, Encodable {
        case converted, failed, skipped, cancelled, planned
    }

    var input: String
    var status: Status
    var kind: MediaKind?
    var format: OutputFormat?
    var output: String?
    var livePhotoVideo: String?
    var inputBytes: Int64?
    var outputBytes: Int64?
    var note: String?
    var removedMetadata: [String]?
    var error: String?
    /// What ffmpeg printed, when it's what failed.
    var detail: String?
    // Dry runs only.
    var engine: String?
    var commands: [[String]]?
    var settings: ConversionSettings?
}

struct ConvertReport: Encodable {
    var ok: Bool
    var dryRun: Bool
    var converted: Int
    var failed: Int
    var skipped: Int
    var cancelled: Int
    /// Original sizes minus converted sizes, for the files that converted. Negative when they grew.
    var savedBytes: Int64
    var files: [FileReport]
}

@MainActor
enum ConvertCommand {
    /// A file ready to convert, or the reason it won't be.
    private struct Item {
        var url: URL
        var kind: MediaKind?
        var size: Int64
        var livePhotoVideo: URL?
        var settings: ConversionSettings?
        var skipReason: String?
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let options = try ConvertOptions.parse(arguments)
        let prefs = StoredPreferences.load()
        if let preset = options.preset, prefs.presets(named: preset).isEmpty {
            let names = prefs.presets.map { "  \($0.name) (\($0.kind.rawValue))" }.joined(separator: "\n")
            throw CLIError.usage("There’s no preset called “\(preset)”. The presets are:\n\(names)")
        }

        let inputs = try options.inputs.map { path -> URL in
            let url = CLI.fileURL(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.usage("No such file or folder: \(path)") }
            return url
        }
        var outputFolder: URL?
        if let output = options.output {
            let url = CLI.fileURL(output)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw CLIError.usage("--output has to be a folder, and \(output) is a file.")
            }
            outputFolder = url
        }

        let tools = try await CLI.loadTools(prefs, quiet: options.quiet)
        let items = try await prepare(inputs, options: options, prefs: prefs, tools: tools)
        if options.dryRun {
            return await plan(items, options: options, outputFolder: outputFolder, tools: tools)
        }
        return await convert(items, options: options, prefs: prefs, outputFolder: outputFolder, tools: tools)
    }

    // MARK: Preparing

    private static func prepare(_ inputs: [URL], options: ConvertOptions, prefs: StoredPreferences,
                                tools: FFmpegTools) async throws -> [Item] {
        var seen = Set<String>()
        let files = await Task.detached(priority: .userInitiated) { AppState.expand(inputs) }.value
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path.lowercased()).inserted }
        if files.isEmpty { throw CLIError.failure("There are no files in \(options.inputs.joined(separator: ", ")).") }
        var items = await AppState.classify(files, ffprobe: tools.ffprobe).map { url, kind, size in
            Item(url: url, kind: kind, size: size, skipReason: kind == nil ? "Not a video, audio file or image" : nil)
        }

        // A Live Photo's still and video become one item, as they do in the app.
        var videos: [String: Int] = [:]
        for (i, item) in items.enumerated() where item.kind == .video && LivePhoto.isPairableVideo(item.url) {
            videos[LivePhoto.pairingKey(item.url)] = i
        }
        var absorbed = Set<Int>()
        if !videos.isEmpty {
            for i in items.indices where items[i].kind == .image {
                guard let v = videos[LivePhoto.pairingKey(items[i].url)], !absorbed.contains(v),
                      LivePhoto.isLivePhotoStill(items[i].url) else { continue }
                items[i].livePhotoVideo = items[v].url
                absorbed.insert(v)
            }
        }

        // Paired videos get settings too, in case their still turns out not to take the options.
        for i in items.indices {
            guard let kind = items[i].kind else { continue }
            do {
                let base = try options.baseSettings(for: kind, preferences: prefs)
                items[i].settings = try options.settings(for: kind, base: base, isLivePhoto: items[i].livePhotoVideo != nil)
            } catch let error as CLIError {
                items[i].skipReason = error.message
                // A still that can't take these options lets its video convert on its own, so
                // `convert iPhone/ --to mp4` still converts the iPhone's videos.
                if let video = items[i].livePhotoVideo, let v = items.firstIndex(where: { $0.url == video }) {
                    absorbed.remove(v)
                    items[i].livePhotoVideo = nil
                }
            }
        }
        return items.enumerated().filter { !absorbed.contains($0.offset) }.map(\.element)
    }

    private static func request(for item: Item, settings: ConversionSettings, options: ConvertOptions, outputFolder: URL?) -> ConversionRequest {
        ConversionRequest(
            source: item.url,
            kind: item.kind!,
            settings: settings,
            outputDirectory: outputFolder ?? item.url.deletingLastPathComponent(),
            livePhotoVideo: item.livePhotoVideo,
            replacesOriginal: options.replace,
            nameTemplate: options.nameTemplate ?? OutputNaming.defaultTemplate
        )
    }

    private static func skipped(_ item: Item) -> FileReport {
        FileReport(input: item.url.path, status: .skipped, kind: item.kind, error: item.skipReason)
    }

    // MARK: Dry run

    private static func plan(_ items: [Item], options: ConvertOptions, outputFolder: URL?, tools: FFmpegTools) async -> Int32 {
        var reports: [FileReport] = []
        var reserved = Set<String>()
        for item in items {
            guard let settings = item.settings else { reports.append(skipped(item)); continue }
            let req = request(for: item, settings: settings, options: options, outputFolder: outputFolder)
            let work = req.resolved
            let baseName = OutputNaming.baseName(template: req.nameTemplate, source: req.source, format: work.settings.format)
            let output = OutputNaming.uniqueURL(in: req.outputDirectory, baseName: baseName, ext: work.settings.format.fileExtension,
                                                sourceExtension: req.source.pathExtension) { candidate in
                reserved.contains(candidate.path.lowercased()) || FileManager.default.fileExists(atPath: candidate.path)
            }
            reserved.insert(output.path.lowercased())

            var report = FileReport(input: item.url.path, status: .planned, kind: item.kind, format: work.settings.format,
                                    output: output.path, livePhotoVideo: item.livePhotoVideo?.path, inputBytes: item.size,
                                    settings: work.settings)
            if work.kind == .image {
                // Images are read, cut out and resized by ImageIO first; only WebP and GIF are then written by ffmpeg.
                report.engine = work.settings.format.isImageIOWritable ? "imageio" : "imageio+ffmpeg"
            } else {
                report.engine = "ffmpeg"
                do {
                    let probe = try await Probe.run(ffprobe: tools.ffprobe, file: work.source)
                    let input = CommandInput(input: work.source, output: output, settings: work.settings, probe: probe,
                                             encoders: tools.encoders,
                                             passLogPrefix: FileManager.default.temporaryDirectory.appendingPathComponent("ffmep-pass"))
                    let plan = try CommandBuilder.plan(input)
                    report.commands = plan.passes.map { [tools.ffmpeg.path] + $0 }
                    report.note = plan.note
                } catch {
                    report.status = .skipped
                    report.error = error.localizedDescription
                }
            }
            reports.append(report)
        }

        let planned = reports.filter { $0.status == .planned }.count
        if options.json {
            CLI.printJSON(ConvertReport(ok: planned > 0, dryRun: true, converted: 0, failed: 0,
                                        skipped: reports.count - planned, cancelled: 0, savedBytes: 0, files: reports))
        } else {
            for report in reports {
                guard report.status == .planned, let output = report.output else {
                    CLI.err("– \(report.input): \(report.error ?? "skipped")")
                    continue
                }
                CLI.out("\(report.input)\n  → \(output)  [\(report.engine ?? "")]")
                if let video = report.livePhotoVideo { CLI.out("  Live Photo video: \(video)") }
                if let note = report.note { CLI.out("  \(note)") }
                for command in report.commands ?? [] { CLI.out("  $ " + command.map(CLI.shellQuoted).joined(separator: " ")) }
            }
        }
        return planned > 0 ? 0 : 1
    }

    // MARK: Converting

    private static func convert(_ items: [Item], options: ConvertOptions, prefs: StoredPreferences,
                                outputFolder: URL?, tools: FFmpegTools) async -> Int32 {
        var jobs: [Job] = []
        var settingsByJob: [UUID: ConversionSettings] = [:]
        var reportsByIndex: [Int: FileReport] = [:]
        var jobIndex: [UUID: Int] = [:]
        for (i, item) in items.enumerated() {
            guard let settings = item.settings, let kind = item.kind else { reportsByIndex[i] = skipped(item); continue }
            let job = Job(url: item.url, kind: kind, fileSize: item.size)
            job.livePhotoVideo = item.livePhotoVideo
            jobs.append(job)
            settingsByJob[job.id] = settings
            jobIndex[job.id] = i
        }

        let console = ConsoleReporter(json: options.json, quiet: options.quiet)
        for report in reportsByIndex.values.sorted(by: { $0.input < $1.input }) { console.skipped(report) }

        var interrupted = false
        if !jobs.isEmpty {
            var limits = prefs.limits
            if let n = options.jobs { limits = ConcurrencyLimits(image: n, audio: n, hardwareVideo: n, softwareVideo: n) }
            let scheduler = JobScheduler()
            let converter = Converter(tools: tools, reservations: OutputReservations())

            // Ctrl-C stops the batch and removes unfinished files, like Stop in the app. A second one quits at once.
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        if interrupted { exit(130) }
                        interrupted = true
                        console.message("Stopping…")
                        scheduler.cancelAll()
                    }
                }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }

            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    console.update(jobs)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                scheduler.start(
                    jobs: jobs,
                    limits: limits,
                    converter: converter,
                    request: { job in
                        request(for: items[jobIndex[job.id]!], settings: settingsByJob[job.id]!, options: options, outputFolder: outputFolder)
                    },
                    lane: { job in
                        let settings = settingsByJob[job.id]!
                        if job.livePhotoVideo != nil, let motion = settings.motionSettings() {
                            return Lane.of(kind: .video, settings: motion)
                        }
                        return Lane.of(kind: job.kind, settings: settings)
                    },
                    completion: { continuation.resume() }
                )
            }
            ticker.cancel()
            console.update(jobs)
            console.clearProgress()
        }

        for job in jobs {
            let settings = settingsByJob[job.id]!
            let format = job.livePhotoVideo != nil ? (settings.motionSettings()?.format ?? settings.format)
                : settings.resolvingFormat(for: job.url).format
            var report = FileReport(input: job.url.path, status: .failed, kind: job.kind, format: format,
                                    livePhotoVideo: job.livePhotoVideo?.path, inputBytes: job.fileSize, note: job.note)
            switch job.status {
            case .done(let size):
                report.status = .converted
                report.output = job.outputURL?.path
                report.outputBytes = size
                report.removedMetadata = job.removedMetadata.isEmpty ? nil : job.removedMetadata.map(\.rawValue)
            case .failed(let message):
                report.error = message
                report.detail = job.failureDetail
            case .cancelled, .waiting, .running:
                report.status = .cancelled
            }
            reportsByIndex[jobIndex[job.id]!] = report
        }

        let reports = items.indices.compactMap { reportsByIndex[$0] }
        let count = { (status: FileReport.Status) in reports.filter { $0.status == status }.count }
        let saved = reports.filter { $0.status == .converted }
            .reduce(Int64(0)) { $0 + ($1.inputBytes ?? 0) - ($1.outputBytes ?? 0) }
        let summary = ConvertReport(ok: count(.converted) > 0 && count(.failed) == 0 && count(.cancelled) == 0,
                                    dryRun: false, converted: count(.converted), failed: count(.failed),
                                    skipped: count(.skipped), cancelled: count(.cancelled), savedBytes: saved, files: reports)
        if options.json {
            CLI.printJSON(summary)
        } else {
            console.summary(summary)
        }
        if interrupted { return 130 }
        return summary.ok ? 0 : 1
    }
}

/// What a person watching the terminal sees: a progress line while it runs, a line per finished
/// file on stderr, and each converted file's path on stdout so it can be piped on.
@MainActor
final class ConsoleReporter {
    private let json: Bool
    private let quiet: Bool
    private let isTerminal = isatty(STDERR_FILENO) == 1
    private var reported = Set<UUID>()
    private var progressShown = false

    init(json: Bool, quiet: Bool) {
        self.json = json
        self.quiet = quiet
    }

    func message(_ text: String) {
        guard !json, !quiet else { return }
        clearProgress()
        CLI.err(text)
    }

    func skipped(_ report: FileReport) {
        guard !json else { return }
        clearProgress()
        if !quiet { CLI.err("– \((report.input as NSString).lastPathComponent): \(report.error ?? "skipped")") }
    }

    func update(_ jobs: [Job]) {
        guard !json else { return }
        for job in jobs where !reported.contains(job.id) {
            switch job.status {
            case .done(let size):
                reported.insert(job.id)
                clearProgress()
                let output = job.outputURL?.path ?? ""
                if !quiet {
                    var line = "✓ \(job.name) → \((output as NSString).lastPathComponent)  \(CLI.bytes(job.fileSize)) → \(CLI.bytes(size))"
                    let notes = [job.note, MetadataCategory.removedSummary(job.removedMetadata)].compactMap { $0 }
                    if !notes.isEmpty { line += "  (\(notes.joined(separator: " · ")))" }
                    CLI.err(line)
                }
                CLI.out(output)
            case .failed(let message):
                reported.insert(job.id)
                clearProgress()
                CLI.err("✗ \(job.name): \(message)")
                if let detail = job.failureDetail, !quiet { CLI.err(detail.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")) }
            case .cancelled:
                reported.insert(job.id)
            case .waiting, .running:
                break
            }
        }
        showProgress(jobs)
    }

    private func showProgress(_ jobs: [Job]) {
        guard isTerminal, !quiet, !jobs.isEmpty else { return }
        var finished = 0
        var total = 0.0
        var running: [String] = []
        for job in jobs {
            switch job.status {
            case .waiting: break
            case .running(let p):
                total += p
                running.append(job.name)
            case .done, .failed, .cancelled:
                finished += 1
                total += 1
            }
        }
        guard finished < jobs.count else { return }
        var line = "[\(finished)/\(jobs.count)] \(Int(total / Double(jobs.count) * 100))%"
        if !running.isEmpty { line += "  \(running.joined(separator: ", "))" }
        let width = CLI.terminalWidth()
        if line.count > width - 1 { line = String(line.prefix(max(width - 2, 10))) + "…" }
        CLI.writeErr("\r\u{1B}[2K" + line)
        progressShown = true
    }

    func clearProgress() {
        guard progressShown else { return }
        CLI.writeErr("\r\u{1B}[2K")
        progressShown = false
    }

    func summary(_ report: ConvertReport) {
        guard !quiet || report.failed > 0 else { return }
        var parts: [String] = []
        if report.converted > 0 || report.failed == 0 {
            var converted = "Converted \(report.converted) file\(report.converted == 1 ? "" : "s")"
            if report.savedBytes > 0 { converted += ", saved \(CLI.bytes(report.savedBytes))" }
            parts.append(converted)
        }
        if report.failed > 0 { parts.append("\(report.failed) failed") }
        if report.skipped > 0 { parts.append("\(report.skipped) skipped") }
        if report.cancelled > 0 { parts.append("\(report.cancelled) stopped") }
        CLI.err(parts.joined(separator: " · "))
    }
}
