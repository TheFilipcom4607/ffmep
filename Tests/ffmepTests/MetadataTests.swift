import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ffmep

/// Unit tests for sorting metadata into categories and building the ffmpeg arguments.
final class MetadataUnitTests: XCTestCase {
    func testTagCategories() {
        XCTAssertEqual(MetadataInspector.category(forTag: "com.apple.quicktime.location.ISO6709"), .location)
        XCTAssertEqual(MetadataInspector.category(forTag: "location-eng"), .location)
        XCTAssertEqual(MetadataInspector.category(forTag: "com.apple.quicktime.creationdate"), .date)
        XCTAssertEqual(MetadataInspector.category(forTag: "creation_time"), .date)
        XCTAssertEqual(MetadataInspector.category(forTag: "com.apple.quicktime.model"), .camera)
        XCTAssertEqual(MetadataInspector.category(forTag: "com.android.manufacturer"), .camera)
        XCTAssertEqual(MetadataInspector.category(forTag: "com.apple.quicktime.camera.lens_model"), .camera)
        XCTAssertEqual(MetadataInspector.category(forTag: "SERIAL_NUMBER"), .serialNumber)
        XCTAssertEqual(MetadataInspector.category(forTag: "com.apple.quicktime.author"), .owner)
        XCTAssertEqual(MetadataInspector.category(forTag: "artist"), .trackInfo)
        for technical in ["encoder", "handler_name", "major_brand", "vendor_id", "language", "com.apple.quicktime.software"] {
            XCTAssertNil(MetadataInspector.category(forTag: technical), technical)
        }
    }

    func testImageCategories() {
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.2],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "123", kCGImagePropertyExifLensModel: " "],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane"],
        ]
        XCTAssertEqual(MetadataInspector.categories(ofImage: props), [.location, .serialNumber, .owner])
        XCTAssertEqual(MetadataInspector.categories(ofImage: [:]), [])
    }

    func testSummary() {
        XCTAssertNil(MetadataCategory.removedSummary([]))
        XCTAssertEqual(MetadataCategory.removedSummary([.location]), "Removed location")
        XCTAssertTrue(MetadataCategory.removedSummary([.camera, .location])!.hasPrefix("Removed location"))
    }

    func testLegacyStripMetadataDecodes() throws {
        let on = try JSONDecoder().decode(ConversionSettings.self, from: Data(#"{"format":"jpeg","stripMetadata":true}"#.utf8))
        XCTAssertEqual(on.metadata, .removeAll)
        let off = try JSONDecoder().decode(ConversionSettings.self, from: Data(#"{"format":"jpeg","stripMetadata":false}"#.utf8))
        XCTAssertEqual(off.metadata, .keep)
        var s = ConversionSettings(format: .mp4)
        s.metadata = .removeLocation
        let roundTrip = try JSONDecoder().decode(ConversionSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTrip.metadata, .removeLocation)
    }

    private let iPhoneTags = [
        "major_brand": "qt  ",
        "creation_time": "2025-06-01T10:00:00.000000Z",
        "com.apple.quicktime.location.ISO6709": "+52.2297+021.0122+100.000/",
        "com.apple.quicktime.make": "Apple",
    ]

    func testKeepPreservesQuickTimeKeysAndCreationTime() {
        var s = ConversionSettings(format: .mp4)
        s.metadata = .keep
        let args = CommandBuilder.metadataArgs(settings: s, probe: ProbeResult(formatTags: iPhoneTags))
        XCTAssertTrue(args.contains("creation_time=2025-06-01T10:00:00.000000Z"))
        XCTAssertTrue(args.contains("major_brand="))
        XCTAssertFalse(args.contains("-map_metadata"))
        XCTAssertFalse(args.contains { $0.hasPrefix("com.apple.quicktime.location") })
    }

    func testRemoveLocationDeletesOnlyLocationTags() {
        var s = ConversionSettings(format: .mov)
        s.metadata = .removeLocation
        let args = CommandBuilder.metadataArgs(settings: s, probe: ProbeResult(formatTags: iPhoneTags))
        XCTAssertTrue(args.contains("com.apple.quicktime.location.ISO6709="))
        XCTAssertFalse(args.contains("com.apple.quicktime.make="))
        XCTAssertFalse(args.contains("-map_metadata"))
    }

    func testPlainMP4DoesNotSwitchToMetadataTags() throws {
        let s = ConversionSettings(format: .mp4)
        let probe = ProbeResult(duration: 5, width: 640, height: 360, hasVideo: true, formatTags: ["title": "Clip"])
        let args = try CommandBuilder.plan(CommandInput(input: URL(fileURLWithPath: "/in.mp4"), output: URL(fileURLWithPath: "/out.mp4"),
                                                        settings: s, probe: probe, encoders: ["hevc_videotoolbox"])).passes[0]
        let i = try XCTUnwrap(args.firstIndex(of: "-movflags"))
        XCTAssertEqual(args[i + 1], "+faststart")
    }
}

/// Real conversions of generated files that carry location, date, camera, serial number and owner,
/// checking what each metadata setting actually leaves in the output. Needs ffmpeg in vendor/ (or Homebrew's).
final class MetadataLeakTests: XCTestCase {
    var tools: FFmpegTools!
    var dir: URL!

    override func setUp() async throws {
        let source = FFmpegSource(rawValue: ProcessInfo.processInfo.environment["FFMEP_FFMPEG"] ?? "bundled") ?? .bundled
        guard let loaded = await FFmpegLocator.load(source: source, customPath: "").tools else {
            throw XCTSkip("No ffmpeg found; run scripts/build-ffmpeg.sh")
        }
        tools = loaded
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffmep-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private let everything: Set<MetadataCategory> = [.location, .date, .camera, .serialNumber, .owner]

    // MARK: Fixtures

    private func makePhoto(_ type: UTType, name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 52.2297, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 21.0122, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5", kCGImagePropertyTIFFArtist: "Jane Owner",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2025:06:01 12:00:00",
                kCGImagePropertyExifBodySerialNumber: "0123456789",
                kCGImagePropertyExifCameraOwnerName: "Jane Owner",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(MetadataInspector.categories(ofImageAt: url), everything, "\(name) fixture must carry every category")
        return url
    }

    /// A clip tagged the way an iPhone tags its recordings.
    private func makeiPhoneVideo() async throws -> URL {
        let url = dir.appendingPathComponent("iphone.mov")
        let result = try await ProcessRunner.capture(tools.ffmpeg, [
            "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=1",
            "-f", "lavfi", "-i", "sine=duration=1",
            "-c:v", "libx264", "-c:a", "aac", "-movflags", "use_metadata_tags",
            "-metadata", "com.apple.quicktime.location.ISO6709=+52.2297+021.0122+100.000/",
            "-metadata", "com.apple.quicktime.make=Apple",
            "-metadata", "com.apple.quicktime.model=iPhone 15 Pro",
            "-metadata", "com.apple.quicktime.creationdate=2025-06-01T12:00:00+0200",
            "-metadata", "com.apple.quicktime.author=Jane Owner",
            "-metadata", "creation_time=2025-06-01T10:00:00Z",
            url.path,
        ])
        XCTAssertEqual(result.status, 0, result.stderrString)
        let probe = try await Probe.run(ffprobe: tools.ffprobe, file: url)
        XCTAssertEqual(probe.metadata, [.location, .date, .camera, .owner], "video fixture must carry its tags")
        return url
    }

    private func convert(_ source: URL, kind: MediaKind, format: OutputFormat, metadata: MetadataMode) async throws -> ConversionResult {
        var settings = ConversionSettings(format: format)
        settings.metadata = metadata
        let out = dir.appendingPathComponent("out-\(UUID().uuidString)")
        let request = ConversionRequest(source: source, kind: kind, settings: settings, outputDirectory: out)
        return try await Converter(tools: tools, reservations: OutputReservations()).convert(request) { _ in }
    }

    private func remaining(_ result: ConversionResult, format: OutputFormat) async throws -> Set<MetadataCategory> {
        if format.isStillImage || format == .gif {
            return try XCTUnwrap(MetadataInspector.categories(ofImageAt: result.output))
        }
        return try await Probe.run(ffprobe: tools.ffprobe, file: result.output).metadata
    }

    // MARK: Photos

    func testPhotoRemoveAllLeavesNothing() async throws {
        for source in [try makePhoto(.jpeg, name: "photo.jpg"), try makePhoto(.heic, name: "photo.heic")] {
            for format in [OutputFormat.jpeg, .png, .heic, .webp, .gif] {
                let result = try await convert(source, kind: .image, format: format, metadata: .removeAll)
                let left = try await remaining(result, format: format)
                XCTAssertEqual(left, [], "\(source.lastPathComponent) → \(format.title) kept \(left)")
                XCTAssertEqual(Set(result.removedMetadata), everything, "\(source.lastPathComponent) → \(format.title) report")
            }
        }
    }

    func testPhotoRemoveLocationKeepsTheRest() async throws {
        for source in [try makePhoto(.jpeg, name: "photo.jpg"), try makePhoto(.heic, name: "photo.heic")] {
            for format in [OutputFormat.jpeg, .heic] {
                let result = try await convert(source, kind: .image, format: format, metadata: .removeLocation)
                let left = try await remaining(result, format: format)
                XCTAssertEqual(left, everything.subtracting([.location]), "\(source.lastPathComponent) → \(format.title)")
                XCTAssertEqual(result.removedMetadata, [.location])
            }
        }
    }

    func testPhotoKeepReportsNothingRemoved() async throws {
        let source = try makePhoto(.heic, name: "photo.heic")
        for format in [OutputFormat.jpeg, .heic] {
            let result = try await convert(source, kind: .image, format: format, metadata: .keep)
            let left = try await remaining(result, format: format)
            XCTAssertEqual(left, everything, format.title)
            XCTAssertEqual(result.removedMetadata, [], format.title)
        }
    }

    /// ffmpeg can't write metadata into WebP, so even Keep loses it, and the report has to say so.
    func testWebPReportsWhatItCannotKeep() async throws {
        let result = try await convert(try makePhoto(.jpeg, name: "photo.jpg"), kind: .image, format: .webp, metadata: .keep)
        XCTAssertEqual(Set(result.removedMetadata), everything)
    }

    // MARK: Video & audio

    func testVideoRemoveAllLeavesNothing() async throws {
        let source = try await makeiPhoneVideo()
        for format in [OutputFormat.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a] {
            let result = try await convert(source, kind: .video, format: format, metadata: .removeAll)
            let left = try await remaining(result, format: format)
            XCTAssertEqual(left, [], "\(format.title) kept \(left)")
            XCTAssertEqual(Set(result.removedMetadata), [.location, .date, .camera, .owner], "\(format.title) report")
        }
    }

    func testVideoKeepPreservesiPhoneTags() async throws {
        let source = try await makeiPhoneVideo()
        for format in [OutputFormat.mp4, .mov] {
            let result = try await convert(source, kind: .video, format: format, metadata: .keep)
            let left = try await remaining(result, format: format)
            XCTAssertEqual(left, [.location, .date, .camera, .owner], format.title)
            XCTAssertEqual(result.removedMetadata, [], format.title)
            let tags = try await Probe.run(ffprobe: tools.ffprobe, file: result.output).formatTags
            XCTAssertNil(tags["major_brand"].flatMap { $0.contains(";") ? $0 : nil }, "brands written twice")
        }
    }

    func testVideoRemoveLocationKeepsTheRest() async throws {
        let source = try await makeiPhoneVideo()
        for format in [OutputFormat.mp4, .mov] {
            let result = try await convert(source, kind: .video, format: format, metadata: .removeLocation)
            let left = try await remaining(result, format: format)
            XCTAssertEqual(left, [.date, .camera, .owner], format.title)
            XCTAssertEqual(result.removedMetadata, [.location], format.title)
        }
    }
}
