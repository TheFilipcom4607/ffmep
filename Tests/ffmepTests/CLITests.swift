import XCTest
@testable import ffmep

/// How `ffmep convert` reads its arguments and turns them into settings.
final class CLITests: XCTestCase {
    func testOnlyCommandsStartTheCommandLine() {
        XCTAssertTrue(CLI.handles(["convert", "a.mov"]))
        XCTAssertTrue(CLI.handles(["--help"]))
        XCTAssertFalse(CLI.handles([], interactive: false))
        XCTAssertTrue(CLI.handles([], interactive: true))
        XCTAssertFalse(CLI.handles(["-NSDocumentRevisionsDebugMode", "YES"], interactive: true))
        XCTAssertFalse(CLI.handles(["-FFMEPAppearance", "light"]))
    }

    func testParsesOptionSpellings() throws {
        let o = try ConvertOptions.parse(["a.mov", "--to=MP4", "-c", "h.264", "-s", "19 MB", "-r", "1080p",
                                          "--rotate", "-90", "--metadata", "removeLocation", "-o", "out", "--json"])
        XCTAssertEqual(o.inputs, ["a.mov"])
        XCTAssertEqual(o.format, .mp4)
        XCTAssertEqual(o.codec, .h264)
        XCTAssertEqual(o.maxSizeMB, 19)
        XCTAssertEqual(o.resize, .option(.p1080))
        XCTAssertEqual(o.rotation, .ccw90)
        XCTAssertEqual(o.metadata, .removeLocation)
        XCTAssertEqual(o.output, "out")
        XCTAssertTrue(o.json)
    }

    func testRejectsMistakes() {
        XCTAssertThrowsError(try ConvertOptions.parse([]))
        XCTAssertThrowsError(try ConvertOptions.parse(["a.mov", "--qualty", "high"])) { error in
            XCTAssertTrue((error as? CLIError)?.message.contains("--quality") == true)
        }
        XCTAssertThrowsError(try ConvertOptions.parse(["a.mov", "--to", "wbep"]))
        XCTAssertThrowsError(try ConvertOptions.parse(["a.mov", "--replace", "-o", "x"]))
        XCTAssertThrowsError(try ConvertOptions.parse(["a.mov", "--quality", "101"]))
    }

    func testValues() throws {
        XCTAssertEqual(try CLIValue.megabytes("500KB"), 0.5)
        XCTAssertEqual(try CLIValue.megabytes("1.5gb"), 1500)
        XCTAssertEqual(try CLIValue.megabytes("10"), 10)
        XCTAssertEqual(try CLIValue.quality("high"), QualityPreset.high.value)
        XCTAssertEqual(try CLIValue.quality("80"), 80)
        XCTAssertEqual(try CLIValue.resize("2048"), .box(width: 2048, height: 2048))
        XCTAssertEqual(try CLIValue.resize("1280x"), .box(width: 1280, height: 0))
        XCTAssertEqual(try CLIValue.resize("x720"), .box(width: 0, height: 720))
        XCTAssertEqual(try CLIValue.resize("50%"), .percent(50))
        XCTAssertEqual(try CLIValue.frameRate("30fps"), .fps30)
        XCTAssertEqual(try CLIValue.format("jpg"), .jpeg)
        XCTAssertThrowsError(try CLIValue.frameRate("29"))
    }

    func testSettingsStartFromTheKindsDefaults() throws {
        let o = try ConvertOptions.parse(["a.mov", "--to", "webm"])
        let s = try o.settings(for: .video, base: ConversionSettings.defaults(for: .video))
        XCTAssertEqual(s.format, .webm)
        XCTAssertEqual(s.videoCodec, .vp9, "the stored HEVC doesn't fit WebM, so the format's own codec is used")
    }

    func testSettingsRefuseWhatTheFileCantDo() throws {
        let toJPEG = try ConvertOptions.parse(["a.mov", "--to", "jpeg"])
        XCTAssertThrowsError(try toJPEG.settings(for: .video, base: .defaults(for: .video)))

        let prores = try ConvertOptions.parse(["a.mov", "--to", "mp4", "--codec", "prores"])
        XCTAssertThrowsError(try prores.settings(for: .video, base: .defaults(for: .video)))

        let losslessSize = try ConvertOptions.parse(["a.wav", "--to", "flac", "--max-size", "5MB"])
        XCTAssertThrowsError(try losslessSize.settings(for: .audio, base: .defaults(for: .audio)))

        let audioLocation = try ConvertOptions.parse(["a.wav", "--metadata", "remove-location"])
        XCTAssertThrowsError(try audioLocation.settings(for: .audio, base: .defaults(for: .audio)))
    }

    func testLivePhotoMotionTakesAVideoFormat() throws {
        let o = try ConvertOptions.parse(["IMG.HEIC", "IMG.MOV", "--to", "mp4", "--live-photo", "video"])
        let s = try o.settings(for: .image, base: .defaults(for: .image), isLivePhoto: true)
        XCTAssertEqual(s.livePhotoMode, .video)
        XCTAssertEqual(s.motionSettings()?.format, .mp4)
        XCTAssertThrowsError(try o.settings(for: .image, base: .defaults(for: .image), isLivePhoto: false))
    }

    func testPresetIsTheStartingPoint() throws {
        var prefs = StoredPreferences()
        prefs.presets = Preset.examples
        let o = try ConvertOptions.parse(["a.mov", "--preset", "discord (20 mb)", "--resize", "720p"])
        let base = try o.baseSettings(for: .video, preferences: prefs)
        let s = try o.settings(for: .video, base: base)
        XCTAssertEqual(s.videoCodec, .h264)
        XCTAssertTrue(s.usesTargetSize)
        XCTAssertEqual(s.resize, .p720)
        XCTAssertThrowsError(try o.baseSettings(for: .image, preferences: prefs))
    }
}

/// Same as Original: photos keep their format and only get smaller.
final class SameFormatTests: XCTestCase {
    func testEachPhotoKeepsItsFormat() {
        var s = ConversionSettings(format: .jpeg)
        s.keepsFormat = true
        func format(_ name: String) -> OutputFormat { s.resolvingFormat(for: URL(fileURLWithPath: "/x/\(name)")).format }
        XCTAssertEqual(format("a.JPG"), .jpeg)
        XCTAssertEqual(format("a.heic"), .heic)
        XCTAssertEqual(format("a.png"), .png)
        XCTAssertEqual(format("a.webp"), .webp)
        XCTAssertEqual(format("a.dng"), .jpeg, "RAW can't be written back, so it becomes the fallback")

        s.keepsFormat = false
        XCTAssertEqual(format("a.heic"), .jpeg)
    }

    func testRequestsResolveTheFormat() {
        var s = ConversionSettings(format: .jpeg)
        s.keepsFormat = true
        let request = ConversionRequest(source: URL(fileURLWithPath: "/x/a.heic"), kind: .image, settings: s,
                                        outputDirectory: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(request.resolved.settings.format, .heic)
    }

    func testOlderSavedSettingsDecode() throws {
        let data = Data(#"{"format":"webp","quality":40}"#.utf8)
        let s = try JSONDecoder().decode(ConversionSettings.self, from: data)
        XCTAssertFalse(s.keepsFormat)
    }

    func testCommandLine() throws {
        let o = try ConvertOptions.parse(["a.heic", "--to", "same", "-q", "small"])
        XCTAssertTrue(o.keepsFormat)
        let s = try o.settings(for: .image, base: .defaults(for: .image))
        XCTAssertTrue(s.keepsFormat)
        XCTAssertEqual(s.resolvingFormat(for: URL(fileURLWithPath: "/a.heic")).format, .heic)
        XCTAssertThrowsError(try o.settings(for: .video, base: .defaults(for: .video)))
    }
}
