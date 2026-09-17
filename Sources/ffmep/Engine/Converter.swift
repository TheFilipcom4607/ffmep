import Foundation

struct ConversionRequest: Sendable {
    var source: URL
    var kind: MediaKind
    var settings: ConversionSettings
    var outputDirectory: URL
    /// Paired Live Photo video, exported instead of the still when the mode asks for it.
    var livePhotoVideo: URL?
    /// Move the original (and its Live Photo video) to the Trash once the output is safely written.
    var replacesOriginal = false

    /// Live Photo motion export swaps in the paired video and video settings.
    /// The output keeps the still's name, so IMG_1234.HEIC becomes IMG_1234.mp4.
    var resolved: ConversionRequest {
        guard let livePhotoVideo, let motion = settings.motionSettings() else { return self }
        var copy = self
        copy.source = livePhotoVideo
        copy.kind = .video
        copy.settings = motion
        return copy
    }
}

struct ConversionResult: Sendable {
    var output: URL
    var bytes: Int64
    var note: String?
    /// Metadata the original had and the output doesn't, whether removed on request or because the format can't hold it.
    var removedMetadata: [MetadataCategory] = []
}

/// What an encode step reports back besides the file itself.
private struct EncodeOutcome {
    var note: String?
    /// Nil when the original's metadata couldn't be read, so nothing is reported.
    var sourceMetadata: Set<MetadataCategory>?
}

/// Runs one file end to end: probe → encode into a hidden partial file → rename into place.
struct Converter: Sendable {
    let tools: FFmpegTools
    let reservations: OutputReservations
    /// How a replaced original is thrown away. Tests delete instead of filling the Trash.
    var discardOriginal: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func convert(_ request: ConversionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionResult {
        let fm = FileManager.default
        let work = request.resolved
        let settings = work.settings
        try fm.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        // Naming always follows the file the user dropped, not the hidden Live Photo video.
        let final = await reservations.reserve(source: request.source, directory: request.outputDirectory, ext: settings.format.fileExtension)
        let partial = OutputNaming.partialURL(for: final)
        let scratch = fm.temporaryDirectory.appendingPathComponent("ffmep-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        do {
            let outcome: EncodeOutcome
            if work.kind == .image {
                outcome = try await convertImage(work, partial: partial, scratch: scratch, progress: progress)
            } else {
                outcome = try await convertMedia(work, partial: partial, scratch: scratch, progress: progress)
            }
            try Task.checkCancellation()
            var output = try await reservations.commit(partial: partial, to: final, source: request.source)
            let bytes = (try? fm.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
            let removed = await removedMetadata(from: outcome.sourceMetadata, output: output, format: settings.format)
            var notes = [outcome.note ?? targetSizeNote(settings, bytes: bytes)]
            if request.replacesOriginal {
                let replaced = await replaceOriginals(of: request, with: output, bytes: bytes)
                output = replaced.output
                notes.append(replaced.note)
            }
            progress(1)
            let joined = notes.compactMap { $0 }.joined(separator: " · ")
            return ConversionResult(output: output, bytes: bytes, note: joined.isEmpty ? nil : joined, removedMetadata: removed)
        } catch {
            try? fm.removeItem(at: partial)
            await reservations.release(final)
            throw error
        }
    }

    private func replaceOriginals(of request: ConversionRequest, with output: URL, bytes: Int64) async -> (output: URL, note: String?) {
        // Only give up an original once a non-empty replacement is on disk.
        guard bytes > 0 else { return (output, "Original kept") }
        var note: String?
        for original in [request.source, request.livePhotoVideo].compactMap({ $0 })
        where original.standardizedFileURL.path.lowercased() != output.standardizedFileURL.path.lowercased() {
            do {
                try discardOriginal(original)
            } catch {
                note = "Couldn’t move the original to the Trash"
            }
        }
        guard note == nil else { return (output, note) }
        return (await reservations.takeOriginalName(of: request.source, output: output), nil)
    }

    private func removedMetadata(from source: Set<MetadataCategory>?, output: URL, format: OutputFormat) async -> [MetadataCategory] {
        guard let source, !source.isEmpty else { return [] }
        let remaining: Set<MetadataCategory>?
        if format.isStillImage || format == .gif {
            remaining = MetadataInspector.categories(ofImageAt: output)
        } else {
            remaining = try? await Probe.run(ffprobe: tools.ffprobe, file: output).metadata
        }
        guard let remaining else { return [] }
        return MetadataCategory.allCases.filter { source.contains($0) && !remaining.contains($0) }
    }

    private func targetSizeNote(_ settings: ConversionSettings, bytes: Int64) -> String? {
        guard settings.usesTargetSize else { return nil }
        let limit = TargetSize.bytes(megabytes: settings.targetSizeMB)
        guard Double(bytes) > Double(limit) * 1.05 else { return nil }
        return "Over target size"
    }

    // MARK: Video & audio

    private func convertMedia(_ request: ConversionRequest, partial: URL, scratch: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> EncodeOutcome {
        let probe = try await Probe.run(ffprobe: tools.ffprobe, file: request.source)
        try Task.checkCancellation()
        var input = CommandInput(
            input: request.source,
            output: partial,
            settings: request.settings,
            probe: probe,
            encoders: tools.encoders,
            passLogPrefix: scratch.appendingPathComponent("pass")
        )
        let plan = try CommandBuilder.plan(input)
        do {
            try await run(plan, duration: probe.duration, progress: progress)
            return EncodeOutcome(sourceMetadata: probe.metadata)
        } catch let error where plan.usesHardware && !(error is CancellationError) && !Task.isCancelled {
            // VideoToolbox can refuse some inputs (odd sizes, unsupported profiles, busy encoder): retry on the CPU.
            try? FileManager.default.removeItem(at: partial)
            input.forceSoftware = true
            let fallback = try CommandBuilder.plan(input)
            try await run(fallback, duration: probe.duration, progress: progress)
            return EncodeOutcome(note: "Hardware encoder failed, used software", sourceMetadata: probe.metadata)
        }
    }

    private func run(_ plan: EncodePlan, duration: Double?, progress: @escaping @Sendable (Double) -> Void) async throws {
        var base = 0.0
        for (pass, weight) in zip(plan.passes, plan.passWeights) {
            let start = base
            try await FFmpegRunner.run(ffmpeg: tools.ffmpeg, arguments: pass, duration: duration) { p in
                progress(min(start + p * weight, 0.99))
            }
            base += weight
        }
    }

    // MARK: Images

    private func convertImage(_ request: ConversionRequest, partial: URL, scratch: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> EncodeOutcome {
        let settings = request.settings
        var source = request.source
        var readsOriginal = true

        // Formats macOS can't decode go through ffmpeg once, then share the ImageIO path.
        if !ImageIOConverter.canRead(source) {
            let decoded = scratch.appendingPathComponent("decoded.png")
            try await FFmpegRunner.run(
                ffmpeg: tools.ffmpeg,
                arguments: CommandBuilder.baseArgs + ["-i", source.path, "-frames:v", "1", "-update", "1", "-f", "image2", decoded.path],
                duration: nil
            ) { _ in }
            source = decoded
            readsOriginal = false
        }

        // Background removal needs full-resolution pixels, so resizing waits until afterwards.
        let background = settings.background.resolved(for: settings.format)
        let resizeAfterwards = background.removesBackground
        var prepared = try await blocking {
            try ImageIOConverter.prepare(url: source, settings: settings, applyResize: !resizeAfterwards)
        }
        try Task.checkCancellation()
        progress(0.3)

        var backgroundNote: String?
        if resizeAfterwards {
            let image = prepared.image
            let outcome = try await blocking { try BackgroundRemover.apply(background, to: image) }
            if let lifted = outcome.image {
                prepared.image = lifted
                backgroundNote = outcome.note
            } else {
                backgroundNote = [outcome.note, "No subject found, background kept"].compactMap { $0 }.joined(separator: " · ")
            }
            try Task.checkCancellation()

            let current = prepared.image
            if let size = ResizeMath.target(width: current.width, height: current.height, settings: settings, even: false) {
                prepared.image = try await blocking { ImageIOConverter.resize(current, to: size) }
            }
        }
        progress(0.4)

        // The ffmpeg-decoded stand-in has no metadata of its own, so there's nothing to compare against.
        let sourceMetadata = readsOriginal ? MetadataInspector.categories(ofImage: prepared.properties) : nil
        func merged(_ note: String?) -> EncodeOutcome {
            let parts = [backgroundNote, note].compactMap { $0 }
            return EncodeOutcome(note: parts.isEmpty ? nil : parts.joined(separator: " · "), sourceMetadata: sourceMetadata)
        }

        switch settings.format {
        case .jpeg, .png, .heic:
            if settings.format == .heic, !ImageIOConverter.canWriteHEIC {
                throw ImageIOError.encodeFailed("HEIC (not supported on this Mac)")
            }
            var note: String?
            let data: Data
            if settings.usesTargetSize {
                var attempts: [Int: Data] = [:]
                let result = try await TargetSize.searchQuality(limit: TargetSize.bytes(megabytes: settings.targetSizeMB)) { q in
                    try Task.checkCancellation()
                    let encoded = try await blocking {
                        try ImageIOConverter.encode(prepared, format: settings.format, quality: Double(q) / 100, metadata: settings.metadata)
                    }
                    attempts[q] = encoded
                    return Int64(encoded.count)
                }
                guard let result, let best = attempts[result.quality] else { throw ImageIOError.encodeFailed(settings.format.title) }
                if !result.fits { note = "Target size not reachable" }
                data = best
            } else {
                data = try await blocking {
                    try ImageIOConverter.encode(prepared, format: settings.format,
                                                quality: QualityMap.imageIOQuality(settings.quality),
                                                metadata: settings.metadata)
                }
            }
            try data.write(to: partial)
            return merged(note)

        case .webp, .gif:
            let bitmap = scratch.appendingPathComponent("prepared.tiff")
            try await blocking { try ImageIOConverter.writeBitmapForFFmpeg(prepared, to: bitmap) }
            try Task.checkCancellation()
            progress(0.6)
            let probe = ProbeResult(width: prepared.image.width, height: prepared.image.height, hasVideo: true, isStillImage: true)
            func input(output: URL, quality: Int?) -> CommandInput {
                CommandInput(input: bitmap, output: output, settings: settings, probe: probe,
                             encoders: tools.encoders, imageQualityOverride: quality, inputIsPrepared: true)
            }

            if settings.format == .webp, settings.usesTargetSize {
                var attempts: [Int: URL] = [:]
                let result = try await TargetSize.searchQuality(limit: TargetSize.bytes(megabytes: settings.targetSizeMB)) { q in
                    let out = scratch.appendingPathComponent("q\(q).webp")
                    try await run(CommandBuilder.plan(input(output: out, quality: q)), duration: nil) { _ in }
                    attempts[q] = out
                    let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64
                    return size ?? .max
                }
                guard let result, let best = attempts[result.quality] else { throw ImageIOError.encodeFailed("WebP") }
                try FileManager.default.moveItem(at: best, to: partial)
                return merged(result.fits ? nil : "Target size not reachable")
            }
            try await run(CommandBuilder.plan(input(output: partial, quality: nil)), duration: nil) { _ in }
            return merged(nil)

        default:
            throw CommandBuilderError.unsupported("Images can't be converted to \(settings.format.title)")
        }
    }
}

/// Runs synchronous CPU-heavy work (ImageIO) off the Swift concurrency pool.
func blocking<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
