import Combine
import Foundation

struct JobStageTiming: Equatable, Sendable {
    let elapsed: TimeInterval
    let eta: TimeInterval?
}

struct TranslationPair: Hashable, Identifiable, Sendable {
    let source: RecognitionLanguage
    let target: RecognitionLanguage

    var id: String { "\(source.rawValue)-\(target.rawValue)" }
}

enum QueueLanguageCheck: Equatable, Sendable {
    case pending
    case checking
    case matched(LanguageDetectionResult)
    case lowConfidence(LanguageDetectionResult)
    case mismatch(LanguageDetectionResult)
    case confirmed(LanguageDetectionResult, usedDetectedLanguage: Bool)
    case failed(String)
    case failureAccepted

    var result: LanguageDetectionResult? {
        switch self {
        case let .matched(result), let .lowConfidence(result), let .mismatch(result),
             let .confirmed(result, _):
            return result
        case .pending, .checking, .failed, .failureAccepted:
            return nil
        }
    }

    var requiresDecision: Bool {
        switch self {
        case .mismatch, .failed: return true
        default: return false
        }
    }
}

enum TranscriptionQueueJobState: Equatable, Sendable {
    case waitingForInspection
    case inspecting
    case needsAttention
    case ready
    case waitingForTranslation
    case running
    case paused
    case completed
    case completedWithWarnings
    case failed
    case cancelled

    var isEditable: Bool {
        switch self {
        case .waitingForInspection, .needsAttention, .ready, .paused: return true
        default: return false
        }
    }

    var isRunnable: Bool {
        self == .ready || self == .paused
    }
}

struct TranscriptionQueueJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let videoURL: URL
    var videoInfo: VideoInfo?
    var sourceLanguage: RecognitionLanguage
    var targetLanguages: Set<RecognitionLanguage>
    var languageCheck: QueueLanguageCheck
    var state: TranscriptionQueueJobState
    var progressValue: Double
    var currentStage: PipelineStage?
    var failedStage: PipelineStage?
    var stoppedStage: PipelineStage?
    var stageTimings: [PipelineStage: JobStageTiming]
    var targetResults: [SubtitleTargetResult]
    var qualityReport: SubtitleQualityReport?
    var destinations: [RecognitionLanguage: OutputDestination]
    var failureDescription: String?

    init(
        id: UUID = UUID(),
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        targetLanguages: Set<RecognitionLanguage>
    ) {
        self.id = id
        self.videoURL = videoURL
        self.videoInfo = nil
        self.sourceLanguage = sourceLanguage
        self.targetLanguages = targetLanguages
        self.languageCheck = .pending
        self.state = .waitingForInspection
        self.progressValue = 0
        self.currentStage = .checkingVideo
        self.failedStage = nil
        self.stoppedStage = nil
        self.stageTimings = [:]
        self.targetResults = []
        self.qualityReport = nil
        self.destinations = [:]
        self.failureDescription = nil
    }

    var selectedTargets: [RecognitionLanguage] {
        RecognitionLanguage.allCases.filter(targetLanguages.contains)
    }

    var outputURLs: [URL] {
        targetResults.filter(\.wasSaved).map(\.destinationURL)
    }

    var hasFailedTargets: Bool {
        targetResults.contains {
            if case .failed = $0.status { return true }
            return false
        }
    }
}

@MainActor
final class TranscriptionQueueController: ObservableObject {
    @Published private(set) var jobs: [TranscriptionQueueJob] = []
    @Published var selectedJobID: UUID?
    @Published private(set) var isQueueActive = false
    @Published private(set) var isRunning = false
    @Published private(set) var translatorResetRevision = 0

    private enum StopAction {
        case none
        case pause
        case cancelAndContinue
        case shutdown
    }

    private let pipeline: TranscriptionPipelineRunning
    private let logBuffer: LogBuffer
    private var inspectionTask: Task<Void, Never>?
    private var runningTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var stopAction: StopAction = .none

    init(
        pipeline: TranscriptionPipelineRunning = TranscriptionPipeline(),
        logBuffer: LogBuffer
    ) {
        self.pipeline = pipeline
        self.logBuffer = logBuffer
    }

    var selectedJob: TranscriptionQueueJob? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    var activeJob: TranscriptionQueueJob? {
        jobs.first { $0.state == .running }
    }

    var displayJob: TranscriptionQueueJob? {
        activeJob ?? selectedJob ?? jobs.last
    }

    var nextJobID: UUID? {
        jobs.first { $0.state == .waitingForTranslation }?.id
    }

    var requiredTranslationPairs: [TranslationPair] {
        guard let job = jobs.first(where: { $0.state == .waitingForTranslation }) else { return [] }
        return job.selectedTargets.compactMap { target in
            target == job.sourceLanguage ? nil : TranslationPair(source: job.sourceLanguage, target: target)
        }
    }

    var allRequiredTranslationPairs: [TranslationPair] {
        let pairs = jobs
            .filter {
                $0.state.isRunnable
                    || $0.state == .waitingForTranslation
                    || $0.state == .running
            }
            .flatMap { job in
                job.selectedTargets.compactMap { target in
                    target == job.sourceLanguage
                        ? nil
                        : TranslationPair(source: job.sourceLanguage, target: target)
                }
            }
        return Array(Set(pairs)).sorted { $0.id < $1.id }
    }

    var isInspecting: Bool {
        jobs.contains { $0.state == .inspecting || $0.state == .waitingForInspection }
    }

    var hasUnresolvedLanguageChecks: Bool {
        jobs.contains { $0.languageCheck.requiresDecision }
    }

    var canBeginQueue: Bool {
        !isRunning
            && !isQueueActive
            && !isInspecting
            && !hasUnresolvedLanguageChecks
            && jobs.contains(where: { $0.state.isRunnable })
    }

    var selectedVideoURL: URL? { displayJob?.videoURL }
    var videoInfo: VideoInfo? { displayJob?.videoInfo }
    var outputURLs: [URL] { displayJob?.outputURLs ?? [] }
    var targetResults: [SubtitleTargetResult] { displayJob?.targetResults ?? [] }
    var progressValue: Double { displayJob?.progressValue ?? 0 }
    var currentStage: PipelineStage? { displayJob?.currentStage }
    var failedStage: PipelineStage? { displayJob?.failedStage }
    var stoppedStage: PipelineStage? { displayJob?.stoppedStage }
    var stageTimings: [PipelineStage: JobStageTiming] { displayJob?.stageTimings ?? [:] }
    var currentTiming: JobStageTiming? {
        guard let stage = currentStage else { return nil }
        return stageTimings[stage]
    }
    var finishedSuccessfully: Bool {
        displayJob?.state == .completed
    }

    var finishedWithPartialExport: Bool {
        displayJob?.state == .completedWithWarnings
    }

    func addVideos(
        _ urls: [URL],
        sourceLanguage: RecognitionLanguage,
        targetLanguages: Set<RecognitionLanguage>,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        var seen = Set(jobs.map { $0.videoURL.standardizedFileURL })
        let newURLs = urls.filter { url in
            seen.insert(url.standardizedFileURL).inserted
        }
        guard !newURLs.isEmpty else { return }
        jobs.append(contentsOf: newURLs.map {
            TranscriptionQueueJob(
                videoURL: $0,
                sourceLanguage: sourceLanguage,
                targetLanguages: targetLanguages
            )
        })
        selectedJobID = newURLs.first.flatMap { url in
            jobs.first(where: { $0.videoURL.standardizedFileURL == url.standardizedFileURL })?.id
        }
        startInspectionIfPossible(onError: onError)
    }

    func selectJob(_ id: UUID) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        selectedJobID = id
    }

    func updateSourceLanguage(_ language: RecognitionLanguage, for id: UUID) {
        guard let index = index(of: id), jobs[index].state.isEditable else { return }
        jobs[index].sourceLanguage = language
        jobs[index].destinations = [:]
        reconcileLanguageDecision(at: index)
    }

    func updateTargetLanguages(_ languages: Set<RecognitionLanguage>, for id: UUID) {
        guard
            !languages.isEmpty,
            let index = index(of: id),
            jobs[index].state.isEditable
        else { return }
        jobs[index].targetLanguages = languages
        jobs[index].destinations = [:]
    }

    func useDetectedLanguage(for id: UUID) {
        guard
            let index = index(of: id),
            case let .mismatch(result) = jobs[index].languageCheck,
            let detected = result.recognizedLanguage
        else { return }
        jobs[index].sourceLanguage = detected
        jobs[index].languageCheck = .confirmed(result, usedDetectedLanguage: true)
        jobs[index].state = .ready
        jobs[index].destinations = [:]
    }

    func keepSelectedLanguage(for id: UUID) {
        guard let index = index(of: id) else { return }
        switch jobs[index].languageCheck {
        case let .mismatch(result):
            jobs[index].languageCheck = .confirmed(result, usedDetectedLanguage: false)
            jobs[index].state = .ready
        case .failed:
            jobs[index].languageCheck = .failureAccepted
            jobs[index].state = .ready
        default:
            break
        }
    }

    func retryLanguageDetection(for id: UUID, onError: @escaping @MainActor (Error) -> Void) {
        guard let index = index(of: id), jobs[index].state == .needsAttention else { return }
        jobs[index].languageCheck = .pending
        jobs[index].state = .waitingForInspection
        jobs[index].failureDescription = nil
        startInspectionIfPossible(onError: onError)
    }

    func moveJob(_ id: UUID, offset: Int) {
        guard !isQueueActive, !isRunning, offset != 0, let source = index(of: id) else { return }
        let destination = source + offset
        guard jobs.indices.contains(destination), jobs[source].state.isEditable, jobs[destination].state.isEditable else {
            return
        }
        jobs.swapAt(source, destination)
    }

    func removeJob(_ id: UUID) {
        guard let index = index(of: id), jobs[index].state != .running else { return }
        jobs.remove(at: index)
        if selectedJobID == id { selectedJobID = jobs.first?.id }
    }

    @discardableResult
    func setDestinations(_ destinations: [UUID: [RecognitionLanguage: OutputDestination]]) -> Bool {
        var updatedJobs = jobs
        for (id, values) in destinations {
            guard let index = updatedJobs.firstIndex(where: { $0.id == id }) else { continue }
            updatedJobs[index].destinations = values
        }

        var reservedKeys = Set<String>()
        for job in updatedJobs {
            for destination in job.destinations.values {
                guard reservedKeys.insert(OutputFileManager.reservationKey(for: destination.url)).inserted else {
                    return false
                }
            }
        }
        jobs = updatedJobs
        return true
    }

    func beginQueue() {
        guard canBeginQueue else { return }
        isQueueActive = true
        prepareNextJob()
    }

    func startNext(
        translators: [TranslationPair: any SubtitleTranslating],
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard
            isQueueActive,
            !isRunning,
            let jobID = nextJobID,
            let index = index(of: jobID)
        else { return }
        let job = jobs[index]
        let outputs = job.selectedTargets.compactMap { target -> SubtitleOutputRequest? in
            guard let destination = job.destinations[target] else { return nil }
            let translator = target == job.sourceLanguage
                ? nil
                : translators[TranslationPair(source: job.sourceLanguage, target: target)]
            if target != job.sourceLanguage && translator == nil { return nil }
            return SubtitleOutputRequest(
                language: target,
                translator: translator,
                destination: destination
            )
        }
        guard outputs.count == job.selectedTargets.count else { return }

        stopAction = .none
        activeRunID = UUID()
        let runID = activeRunID
        isRunning = true
        selectedJobID = jobID
        jobs[index].state = .running
        jobs[index].progressValue = 0.01
        jobs[index].failedStage = nil
        jobs[index].stoppedStage = nil
        jobs[index].targetResults = []
        jobs[index].qualityReport = nil
        jobs[index].failureDescription = nil
        jobs[index].stageTimings = [:]

        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pipeline.transcribe(
                    videoURL: job.videoURL,
                    sourceLanguage: job.sourceLanguage,
                    outputs: outputs,
                    status: { [weak self] update in
                        Task { @MainActor in self?.apply(update, to: jobID, runID: runID) }
                    },
                    log: { [weak self] event in
                        Task { @MainActor in
                            guard self?.activeRunID == runID else { return }
                            self?.logBuffer.append(event)
                        }
                    }
                )
                await finish(jobID: jobID, runID: runID, result: result)
            } catch {
                await failOrStop(jobID: jobID, runID: runID, error: error, onError: onError)
            }
        }
    }

    func pauseQueue() {
        guard isQueueActive else { return }
        isQueueActive = false
        guard isRunning else { return }
        stopAction = .pause
        translatorResetRevision += 1
        runningTask?.cancel()
        pipeline.stop()
    }

    func cancelActiveAndContinue() {
        guard isQueueActive, isRunning else { return }
        stopAction = .cancelAndContinue
        translatorResetRevision += 1
        runningTask?.cancel()
        pipeline.stop()
    }

    func stopForShutdown() {
        isQueueActive = false
        stopAction = .shutdown
        inspectionTask?.cancel()
        runningTask?.cancel()
        pipeline.stop()
    }

    func stopForShutdownAndWait() async {
        let inspection = inspectionTask
        let running = runningTask
        stopForShutdown()
        await inspection?.value
        await running?.value
    }

    func refreshInspections(onError: @escaping @MainActor (Error) -> Void) {
        startInspectionIfPossible(onError: onError)
    }

    private func startInspectionIfPossible(onError: @escaping @MainActor (Error) -> Void) {
        guard inspectionTask == nil, !isRunning, !isQueueActive else { return }
        inspectionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  !self.isRunning,
                  !self.isQueueActive,
                  let jobID = self.jobs.first(where: { $0.state == .waitingForInspection })?.id
            {
                await self.inspect(jobID: jobID, onError: onError)
            }
            self.inspectionTask = nil
        }
    }

    private func inspect(jobID: UUID, onError: @escaping @MainActor (Error) -> Void) async {
        guard let index = index(of: jobID) else { return }
        jobs[index].state = .inspecting
        jobs[index].languageCheck = .checking
        jobs[index].currentStage = .checkingVideo
        do {
            let info = try await pipeline.probe(videoURL: jobs[index].videoURL)
            guard let refreshed = self.index(of: jobID) else { return }
            jobs[refreshed].videoInfo = info
            do {
                let result = try await pipeline.detectLanguage(videoURL: jobs[refreshed].videoURL)
                guard let detectedIndex = self.index(of: jobID) else { return }
                jobs[detectedIndex].languageCheck = languageCheck(
                    result,
                    selected: jobs[detectedIndex].sourceLanguage
                )
                jobs[detectedIndex].state = jobs[detectedIndex].languageCheck.requiresDecision
                    ? .needsAttention
                    : .ready
                jobs[detectedIndex].progressValue = 0
                jobs[detectedIndex].currentStage = nil
            } catch is CancellationError {
                guard let cancelledIndex = self.index(of: jobID) else { return }
                jobs[cancelledIndex].languageCheck = .pending
                jobs[cancelledIndex].state = .waitingForInspection
            } catch {
                guard let failedIndex = self.index(of: jobID) else { return }
                jobs[failedIndex].languageCheck = .failed(error.localizedDescription)
                jobs[failedIndex].state = .needsAttention
                jobs[failedIndex].failureDescription = error.localizedDescription
                jobs[failedIndex].progressValue = 0
                jobs[failedIndex].currentStage = nil
            }
        } catch is CancellationError {
            guard let cancelledIndex = self.index(of: jobID) else { return }
            jobs[cancelledIndex].state = .waitingForInspection
            jobs[cancelledIndex].languageCheck = .pending
        } catch {
            guard let failedIndex = self.index(of: jobID) else { return }
            jobs[failedIndex].state = .failed
            jobs[failedIndex].failedStage = .checkingVideo
            jobs[failedIndex].failureDescription = error.localizedDescription
            onError(error)
        }
    }

    private func languageCheck(
        _ result: LanguageDetectionResult,
        selected: RecognitionLanguage
    ) -> QueueLanguageCheck {
        guard result.isHighConfidence else { return .lowConfidence(result) }
        return result.languageCode == selected.rawValue ? .matched(result) : .mismatch(result)
    }

    private func reconcileLanguageDecision(at index: Int) {
        guard let result = jobs[index].languageCheck.result else {
            if case .failureAccepted = jobs[index].languageCheck {
                jobs[index].languageCheck = .failed(jobs[index].failureDescription ?? "")
                jobs[index].state = .needsAttention
            }
            return
        }
        jobs[index].languageCheck = languageCheck(result, selected: jobs[index].sourceLanguage)
        jobs[index].state = jobs[index].languageCheck.requiresDecision ? .needsAttention : .ready
    }

    private func prepareNextJob() {
        guard isQueueActive, !isRunning else { return }
        guard let index = jobs.firstIndex(where: { $0.state.isRunnable }) else {
            isQueueActive = false
            startInspectionIfPossible(onError: { _ in })
            return
        }
        jobs[index].state = .waitingForTranslation
        jobs[index].progressValue = 0
        jobs[index].currentStage = nil
        selectedJobID = jobs[index].id
    }

    private func finish(jobID: UUID, runID: UUID?, result: TranscriptionResult) async {
        guard activeRunID == runID, let index = index(of: jobID) else { return }
        activeRunID = nil
        runningTask = nil
        isRunning = false
        jobs[index].targetResults = result.targetResults
        jobs[index].qualityReport = result.qualityReport
        jobs[index].progressValue = 1
        jobs[index].currentStage = .done
        jobs[index].failedStage = nil
        jobs[index].stoppedStage = nil
        // Review notes on successfully saved SRT files remain available in the
        // activity log, but they are not an export failure. Reserve the orange
        // completion state for a genuinely partial export.
        jobs[index].state = jobs[index].hasFailedTargets ? .completedWithWarnings : .completed
        prepareNextJob()
    }

    private func failOrStop(
        jobID: UUID,
        runID: UUID?,
        error: Error,
        onError: @escaping @MainActor (Error) -> Void
    ) async {
        guard activeRunID == runID, let index = index(of: jobID) else { return }
        activeRunID = nil
        runningTask = nil
        isRunning = false
        let action = stopAction
        stopAction = .none
        switch action {
        case .pause:
            jobs[index].state = .paused
            jobs[index].stoppedStage = jobs[index].currentStage
            jobs[index].progressValue = 0
            startInspectionIfPossible(onError: onError)
        case .cancelAndContinue:
            jobs[index].state = .cancelled
            jobs[index].stoppedStage = jobs[index].currentStage
            jobs[index].progressValue = 0
            prepareNextJob()
        case .shutdown:
            jobs[index].state = .paused
            jobs[index].stoppedStage = jobs[index].currentStage
        case .none:
            jobs[index].state = .failed
            jobs[index].failedStage = jobs[index].currentStage
            jobs[index].failureDescription = error.localizedDescription
            onError(error)
            prepareNextJob()
        }
    }

    private func apply(_ update: PipelineProgressUpdate, to jobID: UUID, runID: UUID?) {
        guard activeRunID == runID, let index = index(of: jobID) else { return }
        jobs[index].currentStage = update.stage
        jobs[index].progressValue = update.overallProgress
        jobs[index].stageTimings[update.stage] = JobStageTiming(
            elapsed: update.stageElapsed,
            eta: update.stageETA
        )
    }

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }
}
