import XCTest
@testable import ffmep

final class CommandBuilderTests: XCTestCase {
    let allEncoders: Set<String> = [
        "h264_videotoolbox", "hevc_videotoolbox", "prores_videotoolbox", "libx264", "libx265", "prores_ks",
        "libsvtav1", "libvpx-vp9", "libopus", "libmp3lame", "aac_at", "aac", "libwebp", "mjpeg", "png", "flac", "alac",
    ]
    let input = URL(fileURLWithPath: "/in/clip.mov")
    let output = URL(fileURLWithPath: "/out/.clip.ffmep-1234.mp4")

    func video4K(fps: Double = 30, audio: Bool = true) -> ProbeResult {
        ProbeResult(duration: 20, width: 3840, height: 2160, fps: fps, hasVideo: true, hasAudio: audio,
                    videoCodec: "hevc", pixelFormat: "yuv420p")
    }

    func plan(_ settings: ConversionSettings, probe: ProbeResult? = nil, encoders: Set<String>? = nil,
              forceSoftware: Bool = false, prepared: Bool = false) throws -> EncodePlan {
        try CommandBuilder.plan(CommandInput(
            input: input, output: output, settings: settings, probe: probe ?? video4K(),
            encoders: encoders ?? allEncoders, forceSoftware: forceSoftware,
            passLogPrefix: URL(fileURLWithPath: "/tmp/pass"), inputIsPrepared: prepared))
    }

    func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Video

    func testMP4HEVCHardwareDefaults() throws {
        var s = ConversionSettings(format: .mp4)
        s.resize = .p1080
        let p = try plan(s)
        XCTAssertEqual(p.passes.count, 1)
        XCTAssertTrue(p.usesHardware)
        let args = p.passes[0]
        XCTAssertEqual(Array(args.prefix(CommandBuilder.baseArgs.count)), CommandBuilder.baseArgs)
        XCTAssertEqual(value(after: "-c:v", in: args), "hevc_videotoolbox")
        XCTAssertEqual(value(after: "-q:v", in: args), "63")
        XCTAssertEqual(value(after: "-tag:v", in: args), "hvc1")
        XCTAssertEqual(value(after: "-movflags", in: args), "+faststart")
        XCTAssertEqual(value(after: "-vf", in: args), "scale=1920:1080")
        XCTAssertEqual(value(after: "-c:a", in: args), "aac_at")
        XCTAssertEqual(value(after: "-f", in: args), "mp4")
        XCTAssertEqual(args.last, output.path)
        XCTAssertEqual(value(after: "-map", in: args), "0:v:0")
        XCTAssertTrue(args.contains("0:a:0?"))
    }

    func testPortraitPresetCapsShortSide() throws {
        var s = ConversionSettings(format: .mp4)
        s.resize = .p1080
        var probe = video4K()
        probe.width = 2160
        probe.height = 3840
        XCTAssertEqual(value(after: "-vf", in: try plan(s, probe: probe).passes[0]), "scale=1080:1920")
    }

    func testNoUpscaleSkipsScale() throws {
        var s = ConversionSettings(format: .mp4)
        s.resize = .p1080
        var probe = video4K()
        probe.width = 1280
        probe.height = 720
        XCTAssertNil(value(after: "-vf", in: try plan(s, probe: probe).passes[0]))
        s.noUpscale = false
        XCTAssertEqual(value(after: "-vf", in: try plan(s, probe: probe).passes[0]), "scale=1920:1080")
    }

    func testOddDimensionsBecomeEven() throws {
        var probe = video4K()
        probe.width = 1279
        probe.height = 719
        XCTAssertEqual(value(after: "-vf", in: try plan(ConversionSettings(format: .mp4), probe: probe).passes[0]), "scale=1278:718")
    }

    func testMaxCompressionUsesX265CRF() throws {
        var s = ConversionSettings(format: .mp4)
        s.maxCompression = true
        let p = try plan(s)
        XCTAssertFalse(p.usesHardware)
        let args = p.passes[0]
        XCTAssertEqual(value(after: "-c:v", in: args), "libx265")
        XCTAssertEqual(value(after: "-crf", in: args), "24")
        XCTAssertEqual(value(after: "-preset", in: args), "medium")
        XCTAssertEqual(value(after: "-tag:v", in: args), "hvc1")
    }

    func testHardwareTargetSizeUsesBitrateCaps() throws {
        var s = ConversionSettings(format: .mp4)
        s.targetSizeEnabled = true
        s.targetSizeMB = 10
        let args = try plan(s).passes[0]
        XCTAssertEqual(value(after: "-b:v", in: args), "3792k")
        XCTAssertEqual(value(after: "-maxrate", in: args), "5688k")
        XCTAssertEqual(value(after: "-bufsize", in: args), "7584k")
        XCTAssertEqual(value(after: "-b:a", in: args), "128k")
        XCTAssertNil(value(after: "-q:v", in: args))
    }

    func testSoftwareTargetSizeIsTwoPassX265() throws {
        var s = ConversionSettings(format: .mp4)
        s.targetSizeEnabled = true
        s.targetSizeMB = 10
        s.maxCompression = true
        let p = try plan(s)
        XCTAssertEqual(p.passes.count, 2)
        XCTAssertEqual(p.passWeights.reduce(0, +), 1, accuracy: 0.0001)
        let (first, second) = (p.passes[0], p.passes[1])
        XCTAssertEqual(value(after: "-x265-params", in: first), "pass=1:stats=/tmp/pass.x265:log-level=error")
        XCTAssertEqual(Array(first.suffix(3)), ["-f", "null", "/dev/null"])
        XCTAssertTrue(first.contains("-an"))
        XCTAssertEqual(value(after: "-x265-params", in: second), "pass=2:stats=/tmp/pass.x265:log-level=error")
        XCTAssertEqual(value(after: "-b:v", in: second), "3792k")
        XCTAssertEqual(second.last, output.path)
    }

    func testForceSoftwareFallsBackToX264() throws {
        var s = ConversionSettings(format: .mp4)
        s.videoCodec = .h264
        let p = try plan(s, forceSoftware: true)
        XCTAssertFalse(p.usesHardware)
        XCTAssertEqual(value(after: "-c:v", in: p.passes[0]), "libx264")
        XCTAssertEqual(value(after: "-pix_fmt", in: p.passes[0]), "yuv420p")
    }

    func testTenBitHEVCKeepsP010OnHardware() throws {
        var probe = video4K()
        probe.pixelFormat = "yuv420p10le"
        XCTAssertEqual(value(after: "-pix_fmt", in: try plan(ConversionSettings(format: .mov), probe: probe).passes[0]), "p010le")
    }

    func testWebMUsesVP9AndOpus() throws {
        let args = try plan(ConversionSettings(format: .webm)).passes[0]
        XCTAssertEqual(value(after: "-c:v", in: args), "libvpx-vp9")
        XCTAssertEqual(value(after: "-crf", in: args), "34")
        XCTAssertEqual(value(after: "-b:v", in: args), "0")
        XCTAssertEqual(value(after: "-c:a", in: args), "libopus")
        XCTAssertEqual(value(after: "-f", in: args), "webm")
    }

    func testWebMAV1() throws {
        var s = ConversionSettings(format: .webm)
        s.videoCodec = .av1
        let args = try plan(s).passes[0]
        XCTAssertEqual(value(after: "-c:v", in: args), "libsvtav1")
        XCTAssertEqual(value(after: "-crf", in: args), "33")
        XCTAssertTrue(s.usesSoftwareVideo)
    }

    func testProResMOV() throws {
        var s = ConversionSettings(format: .mov)
        s.videoCodec = .prores
        let args = try plan(s).passes[0]
        XCTAssertEqual(value(after: "-c:v", in: args), "prores_videotoolbox")
        XCTAssertEqual(value(after: "-profile:v", in: args), "2")
        XCTAssertEqual(value(after: "-c:a", in: args), "pcm_s16le")
        XCTAssertFalse(s.supportsTargetSize)
    }

    func testCodecFallsBackWhenFormatDoesNotSupportIt() {
        var s = ConversionSettings(format: .webm)
        s.videoCodec = .hevc
        XCTAssertEqual(s.effectiveCodec, .vp9)
    }

    func testExtrasOrderAndMetadata() throws {
        var s = ConversionSettings(format: .mp4)
        s.resize = .p720
        s.rotation = .cw90
        s.flipHorizontal = true
        s.frameRate = .fps30
        s.metadata = .removeAll
        let args = try plan(s, probe: video4K(fps: 59.94)).passes[0]
        XCTAssertEqual(value(after: "-vf", in: args), "fps=30,scale=1280:720,transpose=1,hflip")
        XCTAssertEqual(value(after: "-map_metadata", in: args), "-1")
        XCTAssertEqual(value(after: "-map_chapters", in: args), "-1")
    }

    func testFrameRateNeverIncreases() throws {
        var s = ConversionSettings(format: .mp4)
        s.frameRate = .fps30
        XCTAssertNil(value(after: "-vf", in: try plan(s, probe: video4K(fps: 24)).passes[0]))
    }

    func testRotate180() {
        var s = ConversionSettings(format: .mp4)
        s.rotation = .r180
        XCTAssertEqual(CommandBuilder.orientationFilters(s), ["hflip", "vflip"])
    }

    func testVideoWithoutAudioHasNoAudioArgs() throws {
        let args = try plan(ConversionSettings(format: .mp4), probe: video4K(audio: false)).passes[0]
        XCTAssertNil(value(after: "-c:a", in: args))
        XCTAssertFalse(args.contains("0:a:0?"))
    }

    // MARK: GIF

    func testGIFPaletteGraphWithCaps() throws {
        let args = try plan(ConversionSettings(format: .gif)).passes[0]
        let graph = try XCTUnwrap(value(after: "-filter_complex", in: args))
        XCTAssertEqual(graph, "[0:v]fps=15,scale=640:360:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle")
        XCTAssertEqual(value(after: "-loop", in: args), "0")
        XCTAssertEqual(value(after: "-f", in: args), "gif")
        XCTAssertFalse(ConversionSettings(format: .gif).supportsTargetSize)
    }

    // MARK: Audio

    func testExtractAudioToMP3() throws {
        let args = try plan(ConversionSettings(format: .mp3)).passes[0]
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertEqual(value(after: "-map", in: args), "0:a:0")
        XCTAssertEqual(value(after: "-c:a", in: args), "libmp3lame")
        XCTAssertEqual(value(after: "-b:a", in: args), "192k")
        XCTAssertEqual(value(after: "-f", in: args), "mp3")
    }

    func testAudioTargetSizeSnapsBitrate() throws {
        var s = ConversionSettings(format: .mp3)
        s.targetSizeEnabled = true
        s.targetSizeMB = 5
        var probe = ProbeResult(duration: 300, hasAudio: true)
        probe.audioBitDepth = 16
        XCTAssertEqual(value(after: "-b:a", in: try plan(s, probe: probe).passes[0]), "128k")
    }

    func testLosslessAudioFormats() throws {
        let hiRes = ProbeResult(duration: 10, hasAudio: true, audioBitDepth: 24)
        XCTAssertEqual(value(after: "-c:a", in: try plan(ConversionSettings(format: .wav), probe: hiRes).passes[0]), "pcm_s24le")
        let alac = try plan(ConversionSettings(format: .alac), probe: hiRes).passes[0]
        XCTAssertEqual(value(after: "-c:a", in: alac), "alac")
        XCTAssertEqual(value(after: "-f", in: alac), "ipod")
        XCTAssertEqual(value(after: "-f", in: try plan(ConversionSettings(format: .opus), probe: hiRes).passes[0]), "opus")
    }

    func testNoAudioTrackThrows() {
        XCTAssertThrowsError(try plan(ConversionSettings(format: .mp3), probe: video4K(audio: false))) { error in
            XCTAssertEqual(error as? CommandBuilderError, .noAudioTrack)
        }
    }

    // MARK: Images

    func testPreparedImageToWebP() throws {
        let probe = ProbeResult(width: 4032, height: 3024, hasVideo: true, isStillImage: true)
        var s = ConversionSettings(format: .webp)
        s.resize = .percent
        let args = try plan(s, probe: probe, prepared: true).passes[0]
        XCTAssertEqual(value(after: "-c:v", in: args), "libwebp")
        XCTAssertEqual(value(after: "-quality", in: args), "72")
        XCTAssertNil(value(after: "-vf", in: args), "prepared input is already resized")
        XCTAssertEqual(value(after: "-f", in: args), "webp")
    }

    func testMissingWebPEncoderThrows() {
        let probe = ProbeResult(width: 100, height: 100, hasVideo: true, isStillImage: true)
        var encoders = allEncoders
        encoders.remove("libwebp")
        XCTAssertThrowsError(try plan(ConversionSettings(format: .webp), probe: probe, encoders: encoders, prepared: true)) { error in
            XCTAssertEqual(error as? CommandBuilderError, .missingEncoder("libwebp"))
        }
    }

    func testImageResizeMath() {
        var s = ConversionSettings(format: .webp)
        s.resize = .percent
        XCTAssertTrue(ResizeMath.target(width: 4032, height: 3024, settings: s, even: false)! == (2016, 1512))
        s.resize = .custom
        s.customWidth = 800
        s.customHeight = 0
        XCTAssertTrue(ResizeMath.target(width: 4032, height: 3024, settings: s, even: false)! == (800, 600))
        s.customWidth = 5000
        XCTAssertNil(ResizeMath.target(width: 4032, height: 3024, settings: s, even: false))
    }

    func testQualityMapping() {
        XCTAssertEqual(QualityMap.videoToolboxQ(QualityPreset.small.value), 48)
        XCTAssertEqual(QualityMap.x265CRF(QualityPreset.high.value), 20)
        XCTAssertEqual(QualityMap.svtAV1CRF(QualityPreset.balanced.value), 33)
        XCTAssertEqual(QualityMap.webpQuality(QualityPreset.high.value), 87)
        XCTAssertEqual(QualityMap.proresProfile(95), 3)
        XCTAssertEqual(AudioEncoderFamily.opus.kbps(quality: QualityPreset.balanced.value), 128)
        XCTAssertEqual(AudioEncoderFamily.mp3.kbps(quality: 100), 320)
        XCTAssertEqual(AudioEncoderFamily.aac.kbps(quality: 0), 64)
    }

    // MARK: Probe & locator parsing

    func testProbeParsesRotationAndAttachedPictures() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","codec_name":"mjpeg","width":600,"height":600,"disposition":{"attached_pic":1}},
          {"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"pix_fmt":"yuv420p10le",
           "avg_frame_rate":"30000/1001","side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]},
          {"codec_type":"audio","codec_name":"aac","bits_per_sample":0}
        ],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.5"}}
        """
        let probe = try Probe.parse(json: Data(json.utf8))
        XCTAssertEqual(probe.width, 2160)
        XCTAssertEqual(probe.height, 3840)
        XCTAssertEqual(probe.videoCodec, "hevc")
        XCTAssertEqual(probe.fps ?? 0, 29.97, accuracy: 0.01)
        XCTAssertEqual(probe.duration, 12.5)
        XCTAssertTrue(probe.hasAudio)
        XCTAssertTrue(probe.isHighBitDepth)
        XCTAssertFalse(probe.isStillImage)
    }

    func testLocatorParsing() {
        XCTAssertEqual(FFmpegLocator.parseVersion("ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers\nbuilt with"), "9.0.1")
        let encoders = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
         V....D hevc_videotoolbox    VideoToolbox H.265 Encoder (codec hevc)
         A....D aac_at               aac (AudioToolbox) (codec aac)
        """
        XCTAssertEqual(FFmpegLocator.parseEncoders(encoders), ["libx264", "hevc_videotoolbox", "aac_at"])
    }
}
