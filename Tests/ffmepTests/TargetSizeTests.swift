import XCTest
@testable import ffmep

final class TargetSizeTests: XCTestCase {
    func testVideoBitrateWithAudio() {
        let r = TargetSize.videoBitrates(targetBytes: TargetSize.bytes(megabytes: 10), duration: 20, hasAudio: true)
        // 10 MB · 8 · 0.98 / 20 s = 3920 kbps total, minus 128 kbps audio
        XCTAssertEqual(r.videoKbps, 3792)
        XCTAssertEqual(r.audioKbps, 128)
    }

    func testVideoBitrateWithoutAudio() {
        let r = TargetSize.videoBitrates(targetBytes: TargetSize.bytes(megabytes: 10), duration: 20, hasAudio: false)
        XCTAssertEqual(r.videoKbps, 3920)
        XCTAssertEqual(r.audioKbps, 0)
    }

    func testTinyBudgetClampsVideoAndLowersAudio() {
        let r = TargetSize.videoBitrates(targetBytes: TargetSize.bytes(megabytes: 1), duration: 60, hasAudio: true)
        XCTAssertEqual(r.audioKbps, 64)
        XCTAssertEqual(r.videoKbps, TargetSize.minVideoKbps)
    }

    func testMidBudgetAudio() {
        // 8 MB over 60 s ≈ 1045 kbps → 96 kbps audio
        let r = TargetSize.videoBitrates(targetBytes: TargetSize.bytes(megabytes: 8), duration: 60, hasAudio: true)
        XCTAssertEqual(r.audioKbps, 96)
        XCTAssertEqual(r.videoKbps, 949)
    }

    func testAudioBitrateSnapsDown() {
        // 5 MB over 300 s ≈ 130.7 kbps → 128
        XCTAssertEqual(TargetSize.audioBitrate(targetBytes: TargetSize.bytes(megabytes: 5), duration: 300, family: .mp3), 128)
        XCTAssertEqual(TargetSize.audioBitrate(targetBytes: TargetSize.bytes(megabytes: 5), duration: 300, family: .opus), 128)
        // Huge budget caps at the encoder maximum; tiny budget uses the minimum.
        XCTAssertEqual(TargetSize.audioBitrate(targetBytes: TargetSize.bytes(megabytes: 500), duration: 60, family: .mp3), 320)
        XCTAssertEqual(TargetSize.audioBitrate(targetBytes: 1000, duration: 600, family: .aac), 32)
    }

    func testSearchFindsHighestFittingQuality() async {
        var tries = 0
        let result = await TargetSize.searchQuality(limit: 50_500) { q in
            tries += 1
            return Int64(q * 1000)
        }
        XCTAssertLessThanOrEqual(tries, 6)
        XCTAssertEqual(result?.fits, true)
        XCTAssertLessThanOrEqual(result!.bytes, 50_500)
        XCTAssertGreaterThanOrEqual(result!.quality, 47)
    }

    func testSearchEasyTargetTakesOneTry() async {
        var tries = 0
        let result = await TargetSize.searchQuality(limit: 10_000_000) { q in
            tries += 1
            return Int64(q * 1000)
        }
        XCTAssertEqual(tries, 1)
        XCTAssertEqual(result, TargetSize.SearchResult(quality: 95, bytes: 95_000, fits: true))
    }

    func testSearchUnreachableReturnsSmallestAttempt() async {
        let result = await TargetSize.searchQuality(limit: 1) { q in Int64(q * 1000) }
        XCTAssertEqual(result?.fits, false)
        XCTAssertLessThanOrEqual(result!.quality, 10)
    }

    func testSearchNonMonotonicSizesKeepBestUnderLimit() async {
        // Real encoders aren't strictly monotonic: q=49 produces a spike above the limit.
        // Path: 95 ✗, 49 ✗(spike), 26 ✓, 37 ✓, 43 ✓, 46 ✓
        let result = await TargetSize.searchQuality(limit: 500) { q in q == 49 ? 700 : Int64(q * 10) }
        XCTAssertEqual(result, TargetSize.SearchResult(quality: 46, bytes: 460, fits: true))
    }
}
