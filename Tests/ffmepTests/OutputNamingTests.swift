import XCTest
@testable import ffmep

final class OutputNamingTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffmep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testUniqueURLCountsUp() {
        let taken: Set<String> = ["/o/a.webp", "/o/a (1).webp"]
        let url = OutputNaming.uniqueURL(in: URL(fileURLWithPath: "/o"), baseName: "a", ext: "webp") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "a (2).webp")
    }

    func testDirectoryChoice() {
        let source = URL(fileURLWithPath: "/Users/me/Downloads/IMG_1.HEIC")
        let folder = URL(fileURLWithPath: "/Users/me/Converted")
        XCTAssertEqual(OutputNaming.directory(for: source, location: .nextToOriginal, folder: folder).path, "/Users/me/Downloads")
        XCTAssertEqual(OutputNaming.directory(for: source, location: .folder, folder: folder).path, "/Users/me/Converted")
        XCTAssertEqual(OutputNaming.directory(for: source, location: .folder, folder: nil).path, "/Users/me/Downloads")
    }

    func testNeverOverwritesSource() async throws {
        let source = try touch("photo.jpg")
        let url = await OutputReservations().reserve(source: source, directory: dir, ext: "jpg")
        XCTAssertEqual(url.lastPathComponent, "photo (1).jpg")
    }

    func testCaseInsensitiveCollision() async throws {
        let source = try touch("clip.MP4")
        let url = await OutputReservations().reserve(source: source, directory: dir, ext: "mp4")
        XCTAssertEqual(url.lastPathComponent, "clip (1).mp4")
    }

    func testConcurrentJobsWithSameBaseNameGetDistinctNames() async throws {
        _ = try touch("IMG_1.webp")
        let reservations = OutputReservations()
        let a = await reservations.reserve(source: dir.appendingPathComponent("IMG_1.HEIC"), directory: dir, ext: "webp")
        let b = await reservations.reserve(source: dir.appendingPathComponent("IMG_1.JPG"), directory: dir, ext: "webp")
        XCTAssertEqual(a.lastPathComponent, "IMG_1 (1).webp")
        XCTAssertEqual(b.lastPathComponent, "IMG_1 (2).webp")

        await reservations.release(a)
        let c = await reservations.reserve(source: dir.appendingPathComponent("IMG_1.png"), directory: dir, ext: "webp")
        XCTAssertEqual(c.lastPathComponent, "IMG_1 (1).webp")
    }

    func testPartialFileIsHiddenSibling() {
        let final = URL(fileURLWithPath: "/o/My Clip.mp4")
        let partial = OutputNaming.partialURL(for: final)
        XCTAssertEqual(partial.deletingLastPathComponent().path, "/o")
        XCTAssertTrue(partial.lastPathComponent.hasPrefix(".My Clip.ffmep-"))
        XCTAssertEqual(partial.pathExtension, "mp4")
    }

    func testCommitMovesIntoPlaceAndAvoidsLateCollision() async throws {
        let reservations = OutputReservations()
        let source = dir.appendingPathComponent("song.wav")
        let final = await reservations.reserve(source: source, directory: dir, ext: "mp3")
        XCTAssertEqual(final.lastPathComponent, "song.mp3")

        // Someone else creates song.mp3 while we're encoding.
        _ = try touch("song.mp3")
        let partial = try touch(".song.ffmep-abcd.mp3")
        let committed = try await reservations.commit(partial: partial, to: final, baseName: "song")
        XCTAssertEqual(committed.lastPathComponent, "song (1).mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("song.mp3"), encoding: .utf8), "x")
    }

    func testReplacedOutputTakesOriginalName() async throws {
        let reservations = OutputReservations()
        let source = try touch("IMG_1.jpg")
        let output = await reservations.reserve(source: source, directory: dir, ext: "jpg")
        XCTAssertEqual(output.lastPathComponent, "IMG_1 (1).jpg")
        _ = try touch(output.lastPathComponent)
        await reservations.release(output)

        // Still taken while the original is there.
        let kept = await reservations.takeOriginalName(of: source, output: output)
        XCTAssertEqual(kept.lastPathComponent, "IMG_1 (1).jpg")

        try FileManager.default.removeItem(at: source)
        let renamed = await reservations.takeOriginalName(of: source, output: output)
        XCTAssertEqual(renamed.lastPathComponent, "IMG_1.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testReplacedOutputDoesNotStealReservedName() async throws {
        let reservations = OutputReservations()
        let source = dir.appendingPathComponent("song.wav")
        let output = try touch("song (1).mp3")
        // Another job is about to write song.mp3.
        let other = await reservations.reserve(source: dir.appendingPathComponent("song.flac"), directory: dir, ext: "mp3")
        XCTAssertEqual(other.lastPathComponent, "song.mp3")
        let result = await reservations.takeOriginalName(of: source, output: output)
        XCTAssertEqual(result.lastPathComponent, "song (1).mp3")
    }

    func testNameTemplate() {
        let source = URL(fileURLWithPath: "/in/IMG_1234.HEIC")
        let date = ISO8601DateFormatter().date(from: "2026-03-04T12:00:00Z")!
        func name(_ template: String) -> String {
            OutputNaming.baseName(template: template, source: source, format: .webp, date: date)
        }
        XCTAssertEqual(name(OutputNaming.defaultTemplate), "IMG_1234")
        XCTAssertEqual(name("{name} ({format})"), "IMG_1234 (WebP)")
        XCTAssertEqual(name("{date} {name}"), "2026-03-04 IMG_1234")
        XCTAssertEqual(name("web/{name}:small"), "web-IMG_1234-small")
        XCTAssertEqual(name("  "), "IMG_1234", "empty falls back to the original name")
        XCTAssertEqual(name("..{name}"), "IMG_1234", "never a hidden file")
    }

    func testTemplateNameStillNeverOverwrites() async throws {
        _ = try touch("clip small.mp4")
        let url = await OutputReservations().reserve(baseName: "clip small", directory: dir, ext: "mp4")
        XCTAssertEqual(url.lastPathComponent, "clip small (1).mp4")
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let json = #"{"format":"webp","quality":40}"#
        let s = try JSONDecoder().decode(ConversionSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.format, .webp)
        XCTAssertEqual(s.quality, 40)
        XCTAssertTrue(s.noUpscale)
        XCTAssertEqual(s.resize, .original)
    }
}
