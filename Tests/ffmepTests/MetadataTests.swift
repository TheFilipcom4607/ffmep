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
