import Foundation

enum AudioEncoderFamily: Sendable {
    case mp3, aac, opus

    /// Coarse steps the quality slider maps onto.
    var qualitySteps: [Int] {
        switch self {
        case .mp3: [64, 96, 128, 160, 192, 224, 256, 320]
        case .aac: [64, 96, 128, 160, 192, 256, 320]
        case .opus: [48, 64, 96, 128, 160, 192, 256]
        }
    }

    /// All bitrates target-size mode may snap to.
    var allowedBitrates: [Int] {
        switch self {
        case .mp3: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        case .aac: [32, 48, 64, 96, 128, 160, 192, 256, 320]
        case .opus: [16, 24, 32, 48, 64, 96, 128, 160, 192, 256]
        }
    }

    func kbps(quality: Double) -> Int {
        let steps = qualitySteps
        let index = Int((min(max(quality, 0), 100) / 100) * Double(steps.count - 1))
        return steps[index]
    }
}

enum TargetSize {
    /// Share of the byte budget given to streams. MP4/MKV overhead is <1%, and encoders tend to
    /// undershoot (measured: 0.96 landed x265 two-pass at −5.5%), so 2% keeps results just under target.
    static let containerFactor = 0.98
    static let minVideoKbps = 100

    static func bytes(megabytes: Double) -> Int64 {
        Int64(megabytes * 1_000_000)
    }

    /// `videoKbps = (bytes·8·containerFactor / duration) − audioKbps`, clamped to a minimum.
    static func videoBitrates(targetBytes: Int64, duration: Double, hasAudio: Bool) -> (videoKbps: Int, audioKbps: Int) {
        guard duration > 0 else { return (minVideoKbps, hasAudio ? 96 : 0) }
        let totalKbps = Double(targetBytes) * 8 * containerFactor / duration / 1000
        let audio: Int
        if !hasAudio {
            audio = 0
        } else if totalKbps >= 2000 {
            audio = 128
        } else if totalKbps >= 600 {
            audio = 96
        } else {
            audio = 64
        }
        let video = max(minVideoKbps, Int((totalKbps - Double(audio)).rounded(.down)))
        return (video, audio)
    }

    /// Highest allowed bitrate whose output fits the budget (or the lowest allowed one).
    static func audioBitrate(targetBytes: Int64, duration: Double, family: AudioEncoderFamily) -> Int {
        let allowed = family.allowedBitrates
        guard duration > 0 else { return allowed[0] }
        let kbps = Double(targetBytes) * 8 * 0.98 / duration / 1000
        return allowed.last { Double($0) <= kbps } ?? allowed[0]
    }

    struct SearchResult: Equatable, Sendable {
        var quality: Int
        var bytes: Int64
        var fits: Bool
    }

    /// Binary search for the highest quality whose encode is ≤ `limit`.
    /// Tries the top of the range first, so an easy target costs a single encode.
    /// If nothing fits, returns the smallest attempt with `fits == false`.
    static func searchQuality(
        limit: Int64,
        range: ClosedRange<Int> = 5...95,
        maxTries: Int = 6,
        encode: (Int) async throws -> Int64
    ) async rethrows -> SearchResult? {
        var lo = range.lowerBound
        var hi = range.upperBound
        var best: SearchResult?
        var smallest: SearchResult?
        var tries = 0

        while tries < maxTries, lo <= hi {
            let q = tries == 0 ? hi : (lo + hi) / 2
            let size = try await encode(q)
            tries += 1
            if size <= limit {
                if best == nil || q > best!.quality { best = SearchResult(quality: q, bytes: size, fits: true) }
                lo = q + 1
            } else {
                if smallest == nil || size < smallest!.bytes { smallest = SearchResult(quality: q, bytes: size, fits: false) }
                hi = q - 1
            }
        }
        return best ?? smallest
    }
}
