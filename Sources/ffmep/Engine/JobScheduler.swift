import Foundation

enum Lane: String, CaseIterable, Sendable {
    case image, audio, hardwareVideo, softwareVideo

    static func of(kind: MediaKind, settings: ConversionSettings) -> Lane {
        if kind == .image { return .image }
        if settings.format.isAudio { return .audio }
        return settings.usesSoftwareVideo ? .softwareVideo : .hardwareVideo
    }
}

struct ConcurrencyLimits: Codable, Equatable, Sendable {
    var image: Int
    var audio: Int
    var hardwareVideo: Int
    var softwareVideo: Int

    static let performanceCores: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(ProcessInfo.processInfo.activeProcessorCount / 2, 1)
    }()

    static let `default` = ConcurrencyLimits(image: performanceCores, audio: 4, hardwareVideo: 2, softwareVideo: 1)

    func limit(for lane: Lane) -> Int {
        switch lane {
        case .image: max(image, 1)
        case .audio: max(audio, 1)
        case .hardwareVideo: max(hardwareVideo, 1)
        case .softwareVideo: max(softwareVideo, 1)
        }
    }
}

/// Runs jobs with separate concurrency limits per lane. All bookkeeping happens on the main actor;
/// the actual encoding runs off-main inside `Converter`.
@MainActor
final class JobScheduler {
    private var queues: [Lane: [Job]] = [:]
    private var jobTasks: [UUID: Task<ConversionResult, Error>] = [:]
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }

    func start(
        jobs: [Job],
        limits: ConcurrencyLimits,
        converter: Converter,
        request: @escaping @MainActor (Job) -> ConversionRequest,
        lane: @escaping @MainActor (Job) -> Lane,
        completion: @escaping @MainActor () -> Void
    ) {
        guard runTask == nil else { return }
        queues = [:]
        for job in jobs {
            job.status = .waiting
            job.note = nil
            job.failureDetail = nil
            job.removedMetadata = []
            queues[lane(job), default: []].append(job)
        }

        runTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for lane in Lane.allCases where !(self?.queues[lane]?.isEmpty ?? true) {
                    for _ in 0..<limits.limit(for: lane) {
                        group.addTask { @MainActor in
                            await self?.worker(lane: lane, converter: converter, request: request)
                        }
                    }
                }
            }
            self?.runTask = nil
            completion()
        }
    }

    private func worker(lane: Lane, converter: Converter, request: @MainActor (Job) -> ConversionRequest) async {
        while !Task.isCancelled, let job = queues[lane]?.first {
            queues[lane]?.removeFirst()
            let req = request(job)
            job.status = .running(0)
            job.outputURL = nil

            let task = Task {
                try await converter.convert(req) { fraction in
                    Task { @MainActor in
                        if job.status.isRunning { job.status = .running(fraction) }
                    }
                }
            }
            jobTasks[job.id] = task
            do {
                let result = try await task.value
                job.outputURL = result.output
                job.note = result.note
                job.removedMetadata = result.removedMetadata
                job.status = .done(outputSize: result.bytes)
            } catch is CancellationError {
                job.status = .cancelled
            } catch {
                job.failureDetail = (error as? DetailedError)?.failureDetail
                job.status = task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            jobTasks[job.id] = nil
        }
    }

    /// Cancels one job, whether it is queued or running.
    func cancel(jobID: UUID) {
        for lane in Lane.allCases {
            if let index = queues[lane]?.firstIndex(where: { $0.id == jobID }) {
                queues[lane]?[index].status = .cancelled
                queues[lane]?.remove(at: index)
            }
        }
        jobTasks[jobID]?.cancel()
    }

    func cancelAll() {
        for lane in Lane.allCases {
            queues[lane]?.forEach { $0.status = .cancelled }
        }
        queues = [:]
        jobTasks.values.forEach { $0.cancel() }
        runTask?.cancel()
    }
}
