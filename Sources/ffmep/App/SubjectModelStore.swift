import CoreML
import CryptoKit
import Foundation
import Observation

/// Downloads, installs and removes the optional BiRefNet background model.
@MainActor
@Observable
final class SubjectModelStore {
    enum Phase: Equatable {
        case notInstalled
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    private(set) var phase: Phase
    /// Whether the "download the better model?" question has been asked, so it's asked only once.
    var hasOffered: Bool { didSet { UserDefaults.standard.set(hasOffered, forKey: Self.offeredKey) } }

    @ObservationIgnored private var task: Task<Void, Never>?
    private static let offeredKey = "subjectModelOffered"

    init() {
        phase = SubjectModel.isInstalled ? .installed : .notInstalled
        hasOffered = UserDefaults.standard.bool(forKey: Self.offeredKey)
    }

    var isInstalled: Bool { phase == .installed }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: true
        default: false
        }
    }

    static var sizeText: String { ByteCountFormatter.string(fromByteCount: SubjectModel.downloadBytes, countStyle: .file) }

    func download() {
        guard !isBusy, !isInstalled else { return }
        phase = .downloading(0)
        task = Task { [weak self] in
            do {
                let zip = try await Self.fetch { fraction in
                    Task { @MainActor in
                        if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                    }
                }
                self?.phase = .installing
                try await Task.detached(priority: .userInitiated) { try await Self.install(zip: zip) }.value
                self?.phase = .installed
            } catch is CancellationError {
                self?.phase = .notInstalled
            } catch let error as URLError where error.code == .cancelled {
                self?.phase = .notInstalled
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        guard !isBusy else { return }
        SubjectMatte.shared.unload()
        try? FileManager.default.removeItem(at: SubjectModel.compiledURL)
        phase = .notInstalled
    }

    // MARK: Steps

    private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var observation: NSKeyValueObservation?
        let report: @Sendable (Double) -> Void
        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
                report(progress.fractionCompleted)
            }
        }
    }

    /// Downloads the zip into a private temporary file and checks it against the published checksum.
    private nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let watcher = ProgressWatcher(report: progress)
        let (temporary, response) = try await URLSession.shared.download(from: SubjectModel.downloadURL, delegate: watcher)
        watcher.observation = nil
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("ffmep-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: zip)

        do {
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.download }
            try Task.checkCancellation()
            guard try sha256(of: zip) == SubjectModel.sha256 else { throw StoreError.checksum }
            return zip
        } catch {
            try? FileManager.default.removeItem(at: zip)
            throw error
        }
    }

    /// Unzips, compiles for this Mac and moves the result into place.
    private nonisolated static func install(zip: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ffmep-model-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: work)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        let package = work.appendingPathComponent("BiRefNet.mlpackage")
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: package.path) else { throw StoreError.unpack }

        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        try fm.createDirectory(at: SubjectModel.directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: SubjectModel.compiledURL.path) {
            _ = try fm.replaceItemAt(SubjectModel.compiledURL, withItemAt: compiled)
        } else {
            try fm.moveItem(at: compiled, to: SubjectModel.compiledURL)
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum StoreError: LocalizedError {
        case download, checksum, unpack

        var errorDescription: String? {
            switch self {
            case .download: "The download failed. Check your connection and try again."
            case .checksum: "The downloaded file was damaged. Try again."
            case .unpack: "The downloaded file couldn't be unpacked. Try again."
            }
        }
    }
}
