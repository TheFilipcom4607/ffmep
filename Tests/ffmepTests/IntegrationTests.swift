import ImageIO
import XCTest
@testable import ffmep

/// End-to-end conversions with a real ffmpeg. Skipped unless FFMEP_FIXTURES points at a fixture folder:
///   FFMEP_FIXTURES=/path/to/fixtures [FFMEP_FFMPEG=bundled|homebrew] swift test --filter IntegrationTests
final class IntegrationTests: XCTestCase {
    var tools: FFmpegTools!
    var fixtures: URL!
    var out: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FFMEP_FIXTURES"] else {
            throw XCTSkip("Set FFMEP_FIXTURES to run integration tests")
        }
        fixtures = URL(fileURLWithPath: dir)
        let source = FFmpegSource(rawValue: ProcessInfo.processInfo.environment["FFMEP_FFMPEG"] ?? "bundled") ?? .bundled
        let loaded = await FFmpegLocator.load(source: source, customPath: "")
        tools = try XCTUnwrap(loaded.tools, loaded.warning ?? "no ffmpeg")
        if let warning = loaded.warning { print("⚠️ \(warning)") }
        print("ffmpeg \(tools.version) from \(tools.source.title)")
        out = FileManager.default.temporaryDirectory.appendingPathComponent("ffmep-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let out { try? FileManager.default.removeItem(at: out) }
    }

    // MARK: Helpers

    private func convert(_ name: String, kind: MediaKind, _ settings: ConversionSettings,
                         reservations: OutputReservations = OutputReservations()) async throws -> ConversionResult {
        let converter = Converter(tools: tools, reservations: reservations)
        let request = ConversionRequest(source: fixtures.appendingPathComponent(name), kind: kind, settings: settings, outputDirectory: out)
        let start = Date()
        let result = try await converter.convert(request) { _ in }
        print(String(format: "%@ → %@: %.2fs, %@%@", name, result.output.lastPathComponent, Date().timeIntervalSince(start),
                     ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file), result.note.map { " (\($0))" } ?? ""))
        return result
    }

    private func probe(_ url: URL) async throws -> [String: Any] {
        let output = try await ProcessRunner.capture(tools.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
    }

    private func streams(_ info: [String: Any], _ type: String) -> [[String: Any]] {
        (info["streams"] as? [[String: Any]] ?? []).filter { $0["codec_type"] as? String == type }
    }

    private func duration(_ info: [String: Any]) -> Double {
        Double((info["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    }

    private func imageProperties(_ url: URL) throws -> [CFString: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    private func visibleAndHiddenFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: out.path)
    }

    // MARK: Images

    func testHEICBatchToWebP() async throws {
        let batch = fixtures.appendingPathComponent("heic-batch")
        let files = try FileManager.default.contentsOfDirectory(atPath: batch.path).filter { $0.hasSuffix(".HEIC") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var settings = ConversionSettings(format: .webp)
        settings.resize = .percent
        let reservations = OutputReservations()
        let converter = Converter(tools: tools, reservations: reservations)
        let limit = ConcurrencyLimits.default.image

        let start = Date()
        var results: [ConversionResult] = []
        try await withThrowingTaskGroup(of: ConversionResult.self) { group in
            var iterator = files.makeIterator()
            func next() -> Bool {
                guard let name = iterator.next() else { return false }
                let request = ConversionRequest(source: batch.appendingPathComponent(name), kind: .image, settings: settings, outputDirectory: out)
                group.addTask { try await converter.convert(request) { _ in } }
                return true
            }
            for _ in 0..<limit { _ = next() }
            while let result = try await group.next() {
                results.append(result)
                _ = next()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let inBytes = files.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: batch.appendingPathComponent($1).path)[.size] as? Int64) ?? 0) }
        let outBytes = results.reduce(Int64(0)) { $0 + $1.bytes }
        print(String(format: "HEIC→WebP 50%%: %d files in %.2fs (%.0f ms/file, %d parallel), %@ → %@",
                     files.count, elapsed, elapsed / Double(files.count) * 1000, limit,
                     ByteCountFormatter.string(fromByteCount: inBytes, countStyle: .file),
                     ByteCountFormatter.string(fromByteCount: outBytes, countStyle: .file)))

        XCTAssertEqual(results.count, files.count)
        let info = try await probe(results[0].output)
        let video = try XCTUnwrap(streams(info, "video").first)
        XCTAssertEqual(video["codec_name"] as? String, "webp")
        XCTAssertEqual(video["width"] as? Int, 2016)
        XCTAssertEqual(video["height"] as? Int, 1512)
        XCTAssertFalse(try visibleAndHiddenFiles().contains { $0.hasPrefix(".") }, "no partial files left behind")
    }

    func testHEICToJPEGStripsGPSAndBakesOrientation() async throws {
        let sourceProps = try imageProperties(fixtures.appendingPathComponent("gps.heic"))
        XCTAssertNotNil(sourceProps[kCGImagePropertyGPSDictionary], "fixture must carry GPS")
        XCTAssertEqual(sourceProps[kCGImagePropertyOrientation] as? Int, 6, "fixture must be rotated via EXIF")

        var settings = ConversionSettings(format: .jpeg)
        settings.metadata = .removeAll
        let stripped = try imageProperties(try await convert("gps.heic", kind: .image, settings).output)
        XCTAssertNil(stripped[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(stripped[kCGImagePropertyPixelWidth] as? Int, 3024)
        XCTAssertEqual(stripped[kCGImagePropertyPixelHeight] as? Int, 4032)
        XCTAssertEqual(stripped[kCGImagePropertyOrientation] as? Int ?? 1, 1)

        settings.metadata = .keep
        let kept = try imageProperties(try await convert("gps.heic", kind: .image, settings).output)
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(kept[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(kept[kCGImagePropertyPixelWidth] as? Int, 3024)
    }

    func testImageFormats() async throws {
        for format in [OutputFormat.png, .heic, .gif] {
            var settings = ConversionSettings(format: format)
            settings.resize = .p720
            let result = try await convert("frame.jpg", kind: .image, settings)
            XCTAssertEqual(result.output.pathExtension, format.fileExtension)
            let info = try await probe(result.output)
            let video = try XCTUnwrap(streams(info, "video").first)
            XCTAssertEqual(video["height"] as? Int, 720, "\(format)")
        }
    }

    func testWebPTargetSize() async throws {
        var settings = ConversionSettings(format: .webp)
        settings.targetSizeEnabled = true
        settings.targetSizeMB = 0.5
        let result = try await convert("frame.png", kind: .image, settings)
        XCTAssertLessThanOrEqual(result.bytes, 500_000)
        XCTAssertGreaterThan(result.bytes, 250_000, "should use most of the budget")
    }

    // MARK: Video

    func testVideoTo1080pMP4() async throws {
        var settings = ConversionSettings(format: .mp4)
        settings.resize = .p1080
        let result = try await convert("clip4k.mov", kind: .video, settings)
        let info = try await probe(result.output)
        let video = try XCTUnwrap(streams(info, "video").first)
        XCTAssertEqual(video["codec_name"] as? String, "hevc")
        XCTAssertEqual(video["codec_tag_string"] as? String, "hvc1")
        XCTAssertEqual(video["width"] as? Int, 1920)
        XCTAssertEqual(video["height"] as? Int, 1080)
        XCTAssertEqual(streams(info, "audio").first?["codec_name"] as? String, "aac")
        XCTAssertEqual(duration(info), 20, accuracy: 0.2)
    }

    func testPortraitVideoKeepsOrientation() async throws {
        var settings = ConversionSettings(format: .mp4)
        settings.resize = .p720
        settings.videoCodec = .h264
        let info = try await probe(try await convert("portrait.mov", kind: .video, settings).output)
        let video = try XCTUnwrap(streams(info, "video").first)
        XCTAssertEqual(video["codec_name"] as? String, "h264")
        XCTAssertEqual(video["width"] as? Int, 720)
        XCTAssertEqual(video["height"] as? Int, 1280)
    }

    func testTargetSizeHardware() async throws {
        var settings = ConversionSettings(format: .mp4)
        settings.targetSizeEnabled = true
        settings.targetSizeMB = 10
        let result = try await convert("clip4k.mov", kind: .video, settings)
        print("hardware target 10 MB → \(Double(result.bytes) / 1_000_000) MB")
        XCTAssertEqual(Double(result.bytes), 10_000_000, accuracy: 500_000)
    }

    func testTargetSizeTwoPassX265() async throws {
        var settings = ConversionSettings(format: .mp4)
        settings.targetSizeEnabled = true
        settings.targetSizeMB = 10
        settings.maxCompression = true
        settings.resize = .p1080
        let result = try await convert("clip4k.mov", kind: .video, settings)
        print("x265 two-pass target 10 MB → \(Double(result.bytes) / 1_000_000) MB")
        XCTAssertEqual(Double(result.bytes), 10_000_000, accuracy: 500_000)
    }

    func testWebMAndMKV() async throws {
        var webm = ConversionSettings(format: .webm)
        webm.resize = .p480
        let w = try await probe(try await convert("small.mkv", kind: .video, webm).output)
        XCTAssertEqual(streams(w, "video").first?["codec_name"] as? String, "vp9")

        var mkv = ConversionSettings(format: .mkv)
        mkv.videoCodec = .av1
        let m = try await probe(try await convert("small.mkv", kind: .video, mkv).output)
        XCTAssertEqual(streams(m, "video").first?["codec_name"] as? String, "av1")
    }

    func testGIFExport() async throws {
        let info = try await probe(try await convert("small.mkv", kind: .video, ConversionSettings(format: .gif)).output)
        let video = try XCTUnwrap(streams(info, "video").first)
        XCTAssertEqual(video["codec_name"] as? String, "gif")
        XCTAssertEqual(video["width"] as? Int, 640)
    }

    func testExtractAudio() async throws {
        let info = try await probe(try await convert("clip4k.mov", kind: .video, ConversionSettings(format: .mp3)).output)
        XCTAssertTrue(streams(info, "video").isEmpty)
        XCTAssertEqual(streams(info, "audio").first?["codec_name"] as? String, "mp3")
        XCTAssertEqual(duration(info), 20, accuracy: 0.3)
    }

    // MARK: Audio

    func testAudioFormats() async throws {
        let expected: [(OutputFormat, String)] = [(.m4a, "aac"), (.alac, "alac"), (.flac, "flac"), (.opus, "opus"), (.wav, "pcm_s16le")]
        for (format, codec) in expected {
            let info = try await probe(try await convert("tone.wav", kind: .audio, ConversionSettings(format: format)).output)
            XCTAssertEqual(streams(info, "audio").first?["codec_name"] as? String, codec, "\(format)")
        }
    }

    // MARK: Behaviour

    func testNoOverwriteOnSecondRun() async throws {
        let first = try await convert("tone.wav", kind: .audio, ConversionSettings(format: .mp3))
        let second = try await convert("tone.wav", kind: .audio, ConversionSettings(format: .mp3))
        XCTAssertEqual(first.output.lastPathComponent, "tone.mp3")
        XCTAssertEqual(second.output.lastPathComponent, "tone (1).mp3")
    }

    func testReplaceOriginalRemovesSourceAndKeepsName() async throws {
        // Generated inside the temp folder so nothing real is thrown away.
        let source = out.appendingPathComponent("tone.wav")
        _ = try await ProcessRunner.capture(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", source.path])
        var converter = Converter(tools: tools, reservations: OutputReservations())
        converter.discardOriginal = { try FileManager.default.removeItem(at: $0) }
        var request = ConversionRequest(source: source, kind: .audio, settings: ConversionSettings(format: .mp3), outputDirectory: out)
        request.replacesOriginal = true
        let result = try await converter.convert(request) { _ in }
        XCTAssertEqual(result.output.lastPathComponent, "tone.mp3")
        XCTAssertEqual(try visibleAndHiddenFiles(), ["tone.mp3"])

        // Same extension: the output is written as "clip (1).wav", then takes the original's name.
        let wav = out.appendingPathComponent("clip.wav")
        _ = try await ProcessRunner.capture(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=220:duration=1", "-c:a", "pcm_s24le", wav.path])
        var again = ConversionRequest(source: wav, kind: .audio, settings: ConversionSettings(format: .wav), outputDirectory: out)
        again.replacesOriginal = true
        let replaced = try await converter.convert(again) { _ in }
        XCTAssertEqual(replaced.output.lastPathComponent, "clip.wav")
        XCTAssertEqual(Set(try visibleAndHiddenFiles()), ["tone.mp3", "clip.wav"])
    }

    func testCancelRemovesPartialFile() async throws {
        var settings = ConversionSettings(format: .mkv)
        settings.maxCompression = true
        let converter = Converter(tools: tools, reservations: OutputReservations())
        let request = ConversionRequest(source: fixtures.appendingPathComponent("clip4k.mov"), kind: .video, settings: settings, outputDirectory: out)
        let task = Task { try await converter.convert(request) { _ in } }
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(try visibleAndHiddenFiles().isEmpty, "encoder should have started writing")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try visibleAndHiddenFiles(), [])
    }

    func testClassification() async throws {
        let ffprobe = tools.ffprobe
        let kind = { (name: String) async in await Probe.classify(url: self.fixtures.appendingPathComponent(name), ffprobe: ffprobe) }
        let mkv = await kind("small.mkv"), heic = await kind("photo.heic"), wav = await kind("tone.wav"), mov = await kind("clip4k.mov")
        XCTAssertEqual(mkv, .video)
        XCTAssertEqual(heic, .image)
        XCTAssertEqual(wav, .audio)
        XCTAssertEqual(mov, .video)
    }

    @MainActor
    func testSchedulerRunsMixedBatch() async throws {
        var video = ConversionSettings(format: .mp4)
        video.resize = .p720
        let jobs = [
            Job(url: fixtures.appendingPathComponent("small.mkv"), kind: .video, fileSize: 1),
            Job(url: fixtures.appendingPathComponent("tone.wav"), kind: .audio, fileSize: 1),
            Job(url: fixtures.appendingPathComponent("photo.heic"), kind: .image, fileSize: 1),
        ]
        let batch = BatchSettings(video: video, audio: ConversionSettings(format: .mp3), image: ConversionSettings(format: .webp))
        let scheduler = JobScheduler()
        let converter = Converter(tools: tools, reservations: OutputReservations())
        let outDir = out!
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.start(
                jobs: jobs, limits: .default, converter: converter,
                request: { job in ConversionRequest(source: job.url, kind: job.kind, settings: batch[job.kind], outputDirectory: outDir) },
                lane: { job in Lane.of(kind: job.kind, settings: batch[job.kind]) },
                completion: { done.resume() }
            )
        }
        for job in jobs {
            XCTAssertTrue(job.status.isDone, "\(job.name): \(job.status)")
        }
        XCTAssertEqual(Set(try visibleAndHiddenFiles()), ["small.mp4", "tone.mp3", "photo.webp"])
    }
}
