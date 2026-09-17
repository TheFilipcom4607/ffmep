import XCTest
@testable import ffmep

/// The settings each Shortcuts action builds from its parameters, and what it refuses.
final class ShortcutTests: XCTestCase {
    func testConvertImages() throws {
        let s = ConvertImagesIntent.settings(format: .webp, quality: .high, maxDimension: 2048, sizeLimit: 1.5,
                                             background: .transparent, model: .vision, metadata: .removeLocation)
        XCTAssertEqual(s.format, .webp)
        XCTAssertEqual(s.quality, QualityPreset.high.value)
        XCTAssertEqual(s.resize, .custom)
        XCTAssertEqual([s.customWidth, s.customHeight], [2048, 2048])
        XCTAssertTrue(s.noUpscale)
        XCTAssertTrue(s.usesTargetSize)
        XCTAssertEqual(s.targetSizeMB, 1.5)
        XCTAssertEqual(s.background, .transparent)
        XCTAssertEqual(s.subjectDetector, .vision)
        XCTAssertEqual(s.metadata, .removeLocation)
        XCTAssertNoThrow(try ShortcutRunner.validate(s))

        let plain = ConvertImagesIntent.settings(format: .jpeg, quality: .balanced, maxDimension: nil, sizeLimit: nil,
                                                 background: .keep, model: .biRefNet, metadata: .keep)
        XCTAssertEqual(plain.resize, .original)
        XCTAssertFalse(plain.targetSizeEnabled)
    }

    func testConvertVideosPicksTheFormatsCodec() throws {
        let mp4 = ConvertVideosIntent.settings(format: .mp4, codec: nil, quality: .balanced, resolution: .p720,
                                               frameRate: .fps30, sizeLimit: 19, metadata: .removeAll)
        XCTAssertEqual(mp4.videoCodec, .hevc)
        XCTAssertEqual(mp4.resize, .p720)
        XCTAssertEqual(mp4.frameRate, .fps30)
        XCTAssertTrue(mp4.usesTargetSize)
        XCTAssertNoThrow(try ShortcutRunner.validate(mp4))

        let webm = ConvertVideosIntent.settings(format: .webm, codec: nil, quality: .balanced, resolution: .original,
                                                frameRate: .original, sizeLimit: nil, metadata: .keep)
        XCTAssertEqual(webm.videoCodec, .vp9)
    }

    func testRefusesSettingsTheFormatCantUse() {
        let proresInMP4 = ConvertVideosIntent.settings(format: .mp4, codec: .prores, quality: .balanced, resolution: .original,
                                                       frameRate: .original, sizeLimit: nil, metadata: .keep)
        XCTAssertThrowsError(try ShortcutRunner.validate(proresInMP4))

        let sizedProRes = ConvertVideosIntent.settings(format: .mov, codec: .prores, quality: .balanced, resolution: .original,
                                                       frameRate: .original, sizeLimit: 10, metadata: .keep)
        XCTAssertThrowsError(try ShortcutRunner.validate(sizedProRes))

        let sizedPNG = ConvertImagesIntent.settings(format: .png, quality: .balanced, maxDimension: nil, sizeLimit: 1,
                                                    background: .keep, model: .biRefNet, metadata: .keep)
        XCTAssertThrowsError(try ShortcutRunner.validate(sizedPNG))

        let sizedFLAC = ConvertAudioIntent.settings(format: .flac, quality: .balanced, sizeLimit: 5, metadata: .keep)
        XCTAssertThrowsError(try ShortcutRunner.validate(sizedFLAC))
    }

    func testRemoveBackground() throws {
        let s = RemoveBackgroundIntent.settings(background: .white, format: .jpeg, model: .vision)
        XCTAssertEqual(s.format, .jpeg)
        XCTAssertEqual(s.background, .white)
        XCTAssertEqual(s.subjectDetector, .vision)
        XCTAssertNoThrow(try ShortcutRunner.validate(s))
    }

    func testChoicesMapOntoOutputFormats() {
        XCTAssertEqual(Set(ImageFormat.allCases.map(\.outputFormat)), Set(OutputFormat.choices(for: .image)))
        XCTAssertEqual(Set(AudioFormat.allCases.map(\.outputFormat)), Set(OutputFormat.choices(for: .audio)))
        XCTAssertTrue(VideoFormat.allCases.allSatisfy { OutputFormat.choices(for: .video).contains($0.outputFormat) })
        XCTAssertTrue(VideoResolution.allCases.allSatisfy { ResizeOption.choices(for: .video).contains($0.resize) })
        XCTAssertEqual(Set(CutoutBackground.allCases.map(\.style)), [.white, .transparent])
    }
}
