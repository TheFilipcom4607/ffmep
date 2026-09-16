import Foundation

enum FFmpegError: LocalizedError {
    case failed(status: Int32, message: String)
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .failed(let status, let message):
            message.isEmpty ? "ffmpeg exited with status \(status)" : message
        case .launch(let message):
            message
        }
    }
}

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Thread-safe byte buffer used by pipe readability handlers.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int?

    init(limit: Int? = nil) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if let limit, data.count > limit { data.removeFirst(data.count - limit) }
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Parses ffmpeg `-progress pipe:1` key=value lines.
final class ProgressParser: @unchecked Sendable {
    private var pending = ""
    private let duration: Double?
    private let onProgress: @Sendable (Double) -> Void

    init(duration: Double?, onProgress: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.onProgress = onProgress
    }

    func feed(_ chunk: Data) {
        pending += String(decoding: chunk, as: UTF8.self)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("out_time_us="), let duration, duration > 0,
           let us = Double(line.dropFirst("out_time_us=".count)) {
            onProgress(min(max(us / 1_000_000 / duration, 0), 1))
        } else if line == "progress=end" {
            onProgress(1)
        }
    }
}

enum ProcessRunner {
    /// Runs a short-lived process and collects its output. Terminates it if the task is cancelled.
    static func capture(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outBuf = LockedBuffer(), errBuf = LockedBuffer(limit: 64_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                out.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
                err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: ProcessOutput(status: p.terminationStatus, stdout: outBuf.value, stderr: errBuf.value))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: FFmpegError.launch("Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

enum FFmpegRunner {
    /// Runs one ffmpeg invocation, reporting progress (0…1) against `duration`.
    /// Throws `CancellationError` when the surrounding task is cancelled (ffmpeg gets SIGTERM).
    static func run(
        ffmpeg: URL,
        arguments: [String],
        duration: Double?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let parser = ProgressParser(duration: duration, onProgress: onProgress)
        let errTail = LockedBuffer(limit: 8_000)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                out.fileHandleForReading.readabilityHandler = { h in parser.feed(h.availableData) }
                err.fileHandleForReading.readabilityHandler = { h in errTail.append(h.availableData) }
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    errTail.append(err.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: FFmpegError.launch("Could not launch ffmpeg: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw FFmpegError.failed(status: status, message: summarize(stderr: String(decoding: errTail.value, as: UTF8.self)))
        }
    }

    /// Last few meaningful stderr lines, which is where ffmpeg puts the real reason.
    static func summarize(stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Conversion failed") }
        return lines.suffix(3).joined(separator: "\n")
    }
}
