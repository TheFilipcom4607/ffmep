import Foundation
import Observation

enum JobStatus: Equatable, Sendable {
    case waiting
    case running(Double)
    case done(outputSize: Int64)
    case failed(String)
    case cancelled

    /// Jobs that "Convert" should (re)run.
    var isPending: Bool {
        switch self {
        case .waiting, .failed, .cancelled: true
        case .running, .done: false
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

@Observable
final class Job: Identifiable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
    let fileSize: Int64
    var override: ConversionSettings?
    var status: JobStatus = .waiting
    var outputURL: URL?
    /// The paired video of a Live Photo, when this still has one.
    var livePhotoVideo: URL?
    /// Non-fatal information, e.g. "Target size not reachable".
    var note: String?
    /// What ffmpeg printed when this job failed, kept for the row's tooltip and bug reports.
    var failureDetail: String?
    /// What the converted file no longer carries, e.g. location and camera.
    var removedMetadata: [MetadataCategory] = []

    init(url: URL, kind: MediaKind, fileSize: Int64) {
        self.url = url
        self.kind = kind
        self.fileSize = fileSize
    }

    var name: String { url.lastPathComponent }
}
