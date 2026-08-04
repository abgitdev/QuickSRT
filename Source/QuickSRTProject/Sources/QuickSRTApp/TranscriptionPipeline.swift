import Darwin
import Foundation

protocol TranscriptionPipelineRunning: AnyObject, Sendable {
    func probe(videoURL: URL) async throws -> VideoInfo
    func detectLanguage(videoURL: URL) async throws -> LanguageDetectionResult
    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        outputs: [SubtitleOutputRequest],
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult
    func stop()
}

extension TranscriptionPipeline: TranscriptionPipelineRunning {}

extension TranscriptionPipelineRunning {
    func detectLanguage(videoURL: URL) async throws -> LanguageDetectionResult {
        throw QuickSRTError.languageDetectionFailed
    }
}

public struct PipelineProgressUpdate: Sendable {
    public let stage: PipelineStage
    public let overallProgress: Double
    public let stageElapsed: TimeInterval
    public let stageETA: TimeInterval?
}

public struct LanguageDetectionResult: Equatable, Sendable {
    public let languageCode: String
    public let confidence: Double
    public let runnerUpConfidence: Double

    public init(languageCode: String, confidence: Double, runnerUpConfidence: Double) {
        self.languageCode = languageCode
        self.confidence = confidence
        self.runnerUpConfidence = runnerUpConfidence
    }

    public var recognizedLanguage: RecognitionLanguage? {
        RecognitionLanguage(rawValue: languageCode)
    }

    public var isHighConfidence: Bool {
        confidence >= 0.80 && confidence - runnerUpConfidence >= 0.20
    }
}

public struct SubtitleQualityReport: Equatable, Sendable {
    public let inputSegments: Int
    public let outputSegments: Int
    public let removedSegments: Int
    public let overlapsAdjusted: Int
    public let decoderLoopsTrimmed: Int
    public let retainedLowConfidenceSegments: Int
    public let syntheticWordTimingSegments: Int
    public let requiresUserWarning: Bool

    public init(
        inputSegments: Int,
        outputSegments: Int,
        removedSegments: Int,
        overlapsAdjusted: Int,
        decoderLoopsTrimmed: Int,
        retainedLowConfidenceSegments: Int = 0,
        syntheticWordTimingSegments: Int = 0,
        requiresUserWarning: Bool
    ) {
        self.inputSegments = inputSegments
        self.outputSegments = outputSegments
        self.removedSegments = removedSegments
        self.overlapsAdjusted = overlapsAdjusted
        self.decoderLoopsTrimmed = decoderLoopsTrimmed
        self.retainedLowConfidenceSegments = retainedLowConfidenceSegments
        self.syntheticWordTimingSegments = syntheticWordTimingSegments
        self.requiresUserWarning = requiresUserWarning
    }

    public init?(event: [String: Any]) {
        guard event["type"] as? String == "complete" else { return nil }
        self.init(
            inputSegments: event["input_segments"] as? Int ?? 0,
            outputSegments: event["output_segments"] as? Int
                ?? event["segments"] as? Int
                ?? 0,
            removedSegments: event["removed"] as? Int ?? 0,
            overlapsAdjusted: event["overlaps_adjusted"] as? Int ?? 0,
            decoderLoopsTrimmed: event["decoder_loops_trimmed"] as? Int ?? 0,
            retainedLowConfidenceSegments: event["retained_low_confidence_segments"] as? Int ?? 0,
            syntheticWordTimingSegments: event["synthetic_word_timing_segments"] as? Int ?? 0,
            requiresUserWarning: event["quality_warning"] as? Bool ?? false
        )
    }
}

public enum SubtitleTargetFailureReason: String, Equatable, Sendable {
    case invalidTranslation
    case invalidLayout
    case saveFailed
}

public enum SubtitleTargetStatus: Equatable, Sendable {
    case saved
    case savedWithWarnings
    case failed(SubtitleTargetFailureReason)
}

public struct SubtitleTargetResult: Equatable, Sendable {
    public let language: RecognitionLanguage
    public let destinationURL: URL
    public let status: SubtitleTargetStatus
    public let warningCount: Int

    public init(
        language: RecognitionLanguage,
        destinationURL: URL,
        status: SubtitleTargetStatus,
        warningCount: Int = 0
    ) {
        self.language = language
        self.destinationURL = destinationURL
        self.status = status
        self.warningCount = warningCount
    }

    public var wasSaved: Bool {
        switch status {
        case .saved, .savedWithWarnings: return true
        case .failed: return false
        }
    }
}

public struct TranscriptionResult: Sendable {
    public let targetResults: [SubtitleTargetResult]
    public let qualityReport: SubtitleQualityReport?

    public var outputURLs: [URL] {
        targetResults.filter(\.wasSaved).map(\.destinationURL)
    }

    public var outputURL: URL {
        outputURLs[0]
    }

    public init(targetResults: [SubtitleTargetResult], qualityReport: SubtitleQualityReport?) {
        precondition(!targetResults.isEmpty)
        self.targetResults = targetResults
        self.qualityReport = qualityReport
    }

    public init(outputURLs: [URL], qualityReport: SubtitleQualityReport?) {
        precondition(!outputURLs.isEmpty)
        self.init(
            targetResults: outputURLs.map {
                SubtitleTargetResult(
                    language: .english,
                    destinationURL: $0,
                    status: .saved
                )
            },
            qualityReport: qualityReport
        )
    }

    public init(outputURL: URL, qualityReport: SubtitleQualityReport?) {
        self.init(outputURLs: [outputURL], qualityReport: qualityReport)
    }
}

struct SubtitleOutputRequest: Sendable {
    let language: RecognitionLanguage
    let translator: (any SubtitleTranslating)?
    let destination: OutputDestination

    var destinationURL: URL { destination.url }

    init(
        language: RecognitionLanguage,
        translator: (any SubtitleTranslating)?,
        destination: OutputDestination
    ) {
        self.language = language
        self.translator = translator
        self.destination = destination
    }

    init(
        language: RecognitionLanguage,
        translator: (any SubtitleTranslating)?,
        destinationURL: URL
    ) {
        self.language = language
        self.translator = translator
        destination = (try? OutputDestination.authorizingCurrentState(destinationURL))
            ?? OutputDestination.assumingAbsent(destinationURL)
    }
}

public struct PipelineTimeouts: Sendable {
    public let probe: TimeInterval
    public let extraction: @Sendable (TimeInterval) -> TimeInterval
    public let transcription: @Sendable (TimeInterval) -> TimeInterval

    public init(
        probe: TimeInterval,
        extraction: @escaping @Sendable (TimeInterval) -> TimeInterval,
        transcription: @escaping @Sendable (TimeInterval) -> TimeInterval
    ) {
        self.probe = probe
        self.extraction = extraction
        self.transcription = transcription
    }

    static let live = PipelineTimeouts(
        probe: 45,
        extraction: { max(20 * 60, $0 * 2) },
        transcription: { max(30 * 60, $0 * 4) }
    )
}

public struct SystemResourceSnapshot: Equatable, Sendable {
    public let availableDiskBytes: Int64
    public let availableMemoryBytes: UInt64

    public init(availableDiskBytes: Int64, availableMemoryBytes: UInt64) {
        self.availableDiskBytes = availableDiskBytes
        self.availableMemoryBytes = availableMemoryBytes
    }
}

enum SystemResourceMonitor {
    static func snapshot(for workspaceURL: URL) throws -> SystemResourceSnapshot {
        let values = try workspaceURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let availableDisk = values.volumeAvailableCapacityForImportantUsage else {
            throw POSIXError(.ENOSPC)
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            throw POSIXError(.ENOMEM)
        }
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw POSIXError(.ENOMEM)
        }
        let availablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        return SystemResourceSnapshot(
            availableDiskBytes: availableDisk,
            availableMemoryBytes: availablePages * UInt64(pageSize)
        )
    }
}

enum PipelineResourcePreflight {
    static let maximumVideoDuration: TimeInterval = 12 * 60 * 60
    static let minimumAvailableMemoryBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    static let workspaceReserveBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let audioBytesPerSecond: Double = 32_100

    static func requiredWorkspaceBytes(for duration: TimeInterval) -> Int64 {
        let audioBytes = Int64((max(0, duration) * audioBytesPerSecond).rounded(.up))
        return workspaceReserveBytes + audioBytes * 2
    }

    static func validate(duration: TimeInterval, snapshot: SystemResourceSnapshot) throws {
        guard duration <= maximumVideoDuration else {
            throw QuickSRTError.videoDurationLimitExceeded(maximum: maximumVideoDuration)
        }
        let requiredDisk = requiredWorkspaceBytes(for: duration)
        guard snapshot.availableDiskBytes >= requiredDisk else {
            throw QuickSRTError.insufficientWorkspaceSpace(
                requiredBytes: requiredDisk,
                availableBytes: snapshot.availableDiskBytes
            )
        }
        guard snapshot.availableMemoryBytes >= minimumAvailableMemoryBytes else {
            throw QuickSRTError.insufficientAvailableMemory(
                requiredBytes: minimumAvailableMemoryBytes,
                availableBytes: snapshot.availableMemoryBytes
            )
        }
    }
}

public struct TranscriptionPipelineEnvironment: Sendable {
    let ffmpeg: URL
    let ffprobe: URL
    let python: URL
    let mlxWhisperRunner: URL
    let tempRoot: URL
    let resolveModel: @Sendable () -> URL?
    let saveSRT: @Sendable (URL, OutputDestination, TempJobWorkspace) throws -> CleanupReport
    let recordOutput: @Sendable (URL) throws -> Void
    let resourceSnapshot: @Sendable (URL) throws -> SystemResourceSnapshot
    let timeouts: PipelineTimeouts

    public init(
        ffmpeg: URL,
        ffprobe: URL,
        python: URL,
        mlxWhisperRunner: URL,
        tempRoot: URL,
        resolveModel: @escaping @Sendable () -> URL?,
        saveSRT: @escaping @Sendable (URL, OutputDestination, TempJobWorkspace) throws -> CleanupReport,
        recordOutput: @escaping @Sendable (URL) throws -> Void = { _ in },
        resourceSnapshot: (@Sendable (URL) throws -> SystemResourceSnapshot)? = nil,
        timeouts: PipelineTimeouts
    ) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.python = python
        self.mlxWhisperRunner = mlxWhisperRunner
        self.tempRoot = tempRoot
        self.resolveModel = resolveModel
        self.saveSRT = saveSRT
        self.recordOutput = recordOutput
        self.resourceSnapshot = resourceSnapshot ?? SystemResourceMonitor.snapshot
        self.timeouts = timeouts
    }

    static let live = TranscriptionPipelineEnvironment(
        ffmpeg: ProjectPaths.ffmpeg,
        ffprobe: ProjectPaths.ffprobe,
        python: ProjectPaths.python,
        mlxWhisperRunner: ProjectPaths.mlxWhisperRunner,
        tempRoot: ProjectPaths.tempRoot,
        resolveModel: ProjectPaths.resolvedMLXWhisperModel,
        saveSRT: { source, destination, workspace in
            try SRTOutputWriter.save(
                validatedSource: source,
                to: destination,
                workspace: workspace
            )
        },
        recordOutput: { try OutputOwnershipManifest.record($0) },
        resourceSnapshot: SystemResourceMonitor.snapshot,
        timeouts: .live
    )
}

public final class TranscriptionPipeline: @unchecked Sendable {
    private let runner = ProcessRunner()
    private let environment: TranscriptionPipelineEnvironment
    private let translatorLock = NSLock()
    private var activeTranslators: [any SubtitleTranslating] = []

    public convenience init() {
        self.init(environment: .live)
    }

    public init(environment: TranscriptionPipelineEnvironment) {
        self.environment = environment
    }

    public func stop() {
        runner.stopCurrent()
        translatorLock.withLock {
            activeTranslators.forEach { $0.cancel() }
        }
    }

    private func validatedTranslations(
        translator: any SubtitleTranslating,
        units: [SubtitleTranslationUnit],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SubtitleTranslationResponse] {
        let responses = try await translator.translate(units: units, progress: progress)
        let knownIDs = Set(units.map(\.id))
        var responseByID: [Int: SubtitleTranslationResponse] = [:]
        for response in responses {
            guard
                knownIDs.contains(response.id),
                responseByID.updateValue(response, forKey: response.id) == nil
            else {
                throw QuickSRTError.translationOutputInvalid
            }
        }

        var validated: [SubtitleTranslationResponse] = []
        validated.reserveCapacity(units.count)
        for unit in units {
            if
                let response = responseByID[unit.id],
                TranslationTextValidator.failure(in: response.targetText) == nil
            {
                validated.append(response)
                continue
            }

            try Task.checkCancellation()
            let retry = try await translator.translate(units: [unit], progress: { _ in })
            guard
                retry.count == 1,
                let response = retry.first,
                response.id == unit.id,
                TranslationTextValidator.failure(in: response.targetText) == nil
            else {
                throw QuickSRTError.translationOutputInvalid
            }
            validated.append(response)
        }
        return validated
    }

    func probe(videoURL: URL) async throws -> VideoInfo {
        try requireExecutable(name: "ffprobe", url: environment.ffprobe)
        let result = try await runner.run(
            executable: environment.ffprobe,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                videoURL.path
            ],
            label: "ffprobe",
            timeout: environment.timeouts.probe,
            onOutput: { _ in }
        )

        guard let data = result.stdout.data(using: .utf8) else {
            throw QuickSRTError.invalidVideo(.invalidProbeOutput)
        }

        return try VideoProbe.parse(data)
    }

    func detectLanguage(videoURL: URL) async throws -> LanguageDetectionResult {
        try Task.checkCancellation()
        try requireExecutable(name: "ffmpeg", url: environment.ffmpeg)
        try requireExecutable(name: "Python", url: environment.python)
        let modelURL = try preflight(language: .english)

        let operationLock: InterprocessFileLock
        do {
            operationLock = try QuickSRTOperationLock.acquire(in: environment.tempRoot)
        } catch InterprocessLockError.busy {
            throw QuickSRTError.operationAlreadyRunning
        } catch {
            throw QuickSRTError.operationLockUnavailable
        }
        defer { operationLock.unlock() }

        let job = try TempWorkspace.createJobDirectory(in: environment.tempRoot)
        defer { _ = job.finish() }
        let sampleURL = job.url.appendingPathComponent("language-sample.wav")
        try job.trackWorkspaceArtifact(sampleURL)
        try PipelineResourcePreflight.validate(
            duration: 30,
            snapshot: try environment.resourceSnapshot(job.url)
        )
        _ = try await runner.run(
            executable: environment.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-i", videoURL.path,
                "-t", "30",
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
                "-f", "wav", sampleURL.path
            ],
            label: "ffmpeg",
            timeout: environment.timeouts.extraction(30),
            onOutput: { _ in }
        )

        try Task.checkCancellation()
        let detection = LockedLanguageDetectionResult()
        let parser = LineStreamParser(onLimitExceeded: { [weak self] in
            self?.runner.stopCurrent()
        }) { line in
            guard line.hasPrefix("QSR_EVENT\t") else { return }
            let json = String(line.dropFirst("QSR_EVENT\t".count))
            guard
                let data = json.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                event["type"] as? String == "language_detection",
                let language = event["language"] as? String,
                let confidence = event["confidence"] as? NSNumber,
                let runnerUp = event["runner_up_confidence"] as? NSNumber
            else { return }
            detection.store(LanguageDetectionResult(
                languageCode: language,
                confidence: confidence.doubleValue,
                runnerUpConfidence: runnerUp.doubleValue
            ))
        }
        _ = try await runParsingOutput(
            executable: environment.python,
            arguments: [
                environment.mlxWhisperRunner.path,
                sampleURL.path,
                "--model", modelURL.path,
                "--detect-language-only"
            ],
            label: "MLX Whisper language detection",
            timeout: environment.timeouts.transcription(30),
            parser: parser
        )
        if let result = detection.value { return result }
        throw QuickSRTError.languageDetectionFailed
    }

    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        outputs: [SubtitleOutputRequest],
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard !outputs.isEmpty else {
            throw QuickSRTError.translationNotReady
        }
        let operationLock: InterprocessFileLock
        do {
            operationLock = try QuickSRTOperationLock.acquire(in: environment.tempRoot)
        } catch InterprocessLockError.busy {
            throw QuickSRTError.operationAlreadyRunning
        } catch {
            throw QuickSRTError.operationLockUnavailable
        }
        defer { operationLock.unlock() }

        let modelURL = try preflight(language: sourceLanguage)
        for output in outputs where output.language != sourceLanguage {
            guard output.translator != nil else {
                throw QuickSRTError.translationNotReady
            }
        }
        translatorLock.withLock {
            activeTranslators = outputs.compactMap(\.translator)
        }
        defer {
            translatorLock.withLock {
                activeTranslators = []
            }
        }
        let job = try TempWorkspace.createJobDirectory(in: environment.tempRoot)
        var cleanupCompleted = false
        defer {
            if !cleanupCompleted {
                let cleanup = job.finish()
                if !cleanup.isSuccessful {
                    log(.localized(.cleanupFailed(count: cleanup.failures.count)))
                }
            }
        }
        let jobDirectory = job.url

        let checkStarted = Date()
        status(update(.checkingVideo, overall: 0.01, started: checkStarted))
        log(.localized(.stage(.checkingVideo, completed: false)))
        let videoInfo = try await probe(videoURL: videoURL)
        try PipelineResourcePreflight.validate(
            duration: videoInfo.duration,
            snapshot: try environment.resourceSnapshot(jobDirectory)
        )
        status(update(.checkingVideo, overall: 0.05, started: checkStarted, eta: 0))
        log(.localized(.stage(.checkingVideo, completed: true)))

        try Task.checkCancellation()
        let extractionStarted = Date()
        status(update(.extractingAudio, overall: 0.05, started: extractionStarted))
        log(.localized(.stage(.extractingAudio, completed: false)))
        let audioURL = jobDirectory.appendingPathComponent("audio.wav")
        try job.trackWorkspaceArtifact(audioURL)
        try await extractAudio(
            from: videoURL,
            to: audioURL,
            duration: videoInfo.duration,
            status: status,
            started: extractionStarted
        )
        status(update(.extractingAudio, overall: 0.15, started: extractionStarted, eta: 0))
        log(.localized(.stage(.extractingAudio, completed: true)))

        try Task.checkCancellation()
        let transcriptionStarted = Date()
        status(update(.transcribingSpeech, overall: 0.15, started: transcriptionStarted))
        log(.localized(.transcribing(languageCode: sourceLanguage.rawValue)))
        let whisperOutputName = "quicksrt"
        let whisperOutputDir = jobDirectory.appendingPathComponent("whisper", isDirectory: true)
        try job.trackWorkspaceArtifact(whisperOutputDir)
        try FileManager.default.createDirectory(at: whisperOutputDir, withIntermediateDirectories: true)

        let tempSRT = whisperOutputDir.appendingPathComponent("\(whisperOutputName).srt")
        let timelineURL = whisperOutputDir.appendingPathComponent(
            "\(whisperOutputName).timeline.json"
        )
        try job.trackWorkspaceArtifact(tempSRT)
        try job.trackWorkspaceArtifact(timelineURL)

        let qualityReport = try await runWhisper(
            audioURL: audioURL,
            outputName: whisperOutputName,
            outputDirectory: whisperOutputDir,
            modelURL: modelURL,
            language: sourceLanguage,
            duration: videoInfo.duration,
            status: status,
            log: log,
            started: transcriptionStarted
        )
        status(update(.transcribingSpeech, overall: 0.78, started: transcriptionStarted, eta: 0))
        log(.localized(.stage(.transcribingSpeech, completed: true)))

        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: tempSRT.path) else {
            throw QuickSRTError.outputMissing(tempSRT)
        }
        try SRTValidator.validate(tempSRT)
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            throw QuickSRTError.outputMissing(timelineURL)
        }
        let semanticGroups = try autoreleasepool {
            let timedTranscript = try TimedTranscriptValidator.load(from: timelineURL)
            return try SemanticUnitBuilder.build(
                from: timedTranscript,
                language: sourceLanguage
            )
        }
        try Task.checkCancellation()
        guard !semanticGroups.isEmpty else {
            throw QuickSRTError.invalidTimeline("Timeline contains no translatable speech.")
        }
        let translationUnits = SemanticUnitBuilder.translationUnits(from: semanticGroups)
        let renderUnits = semanticGroups.map(\.renderUnit)

        var preparedOutputs: [RecognitionLanguage: PreparedSubtitleOutput] = [:]
        var targetResults: [RecognitionLanguage: SubtitleTargetResult] = [:]
        var firstSaveError: Error?
        let translationStarted = Date()
        status(update(.translatingSubtitles, overall: 0.78, started: translationStarted))
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            let translations: [TranslatedSemanticUnitText]
            if sourceLanguage == output.language {
                log(.localized(.text(.logTranslationNotRequired)))
                translations = semanticGroups.map {
                    TranslatedSemanticUnitText(unitID: String($0.id), text: $0.sourceText)
                }
            } else {
                guard let translator = output.translator else {
                    throw QuickSRTError.translationNotReady
                }
                log(.localized(.translating(
                    sourceCode: sourceLanguage.rawValue,
                    targetCode: output.language.rawValue
                )))
                do {
                    let responses = try await validatedTranslations(
                        translator: translator,
                        units: translationUnits,
                        progress: { fraction in
                            let clamped = min(1, max(0, fraction)) * 0.9
                            self.reportTranslationProgress(
                                completedOutputCount: index,
                                localFraction: clamped,
                                outputCount: outputs.count,
                                started: translationStarted,
                                status: status
                            )
                        }
                    )
                    translations = responses.map {
                        TranslatedSemanticUnitText(
                            unitID: String($0.id),
                            text: $0.targetText
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    targetResults[output.language] = SubtitleTargetResult(
                        language: output.language,
                        destinationURL: output.destinationURL,
                        status: .failed(.invalidTranslation)
                    )
                    log(.localized(.targetOutputFailed(
                        targetCode: output.language.rawValue,
                        reason: .invalidTranslation
                    )))
                    reportTranslationProgress(
                        completedOutputCount: index,
                        localFraction: 1,
                        outputCount: outputs.count,
                        started: translationStarted,
                        status: status
                    )
                    continue
                }
            }

            try Task.checkCancellation()
            guard translations.allSatisfy({
                TranslationTextValidator.failure(in: $0.text) == nil
            }) else {
                targetResults[output.language] = SubtitleTargetResult(
                    language: output.language,
                    destinationURL: output.destinationURL,
                    status: .failed(.invalidTranslation)
                )
                log(.localized(.targetOutputFailed(
                    targetCode: output.language.rawValue,
                    reason: .invalidTranslation
                )))
                reportTranslationProgress(
                    completedOutputCount: index,
                    localFraction: 1,
                    outputCount: outputs.count,
                    started: translationStarted,
                    status: status
                )
                continue
            }
            let rendered = TargetSubtitleRenderer.render(
                semanticUnits: renderUnits,
                translatedTexts: translations,
                profile: output.language.subtitleProfile,
                mediaDuration: videoInfo.duration
            )
            guard !rendered.qualityReport.hasErrors else {
                targetResults[output.language] = SubtitleTargetResult(
                    language: output.language,
                    destinationURL: output.destinationURL,
                    status: .failed(.invalidLayout)
                )
                log(.localized(.targetOutputFailed(
                    targetCode: output.language.rawValue,
                    reason: .invalidLayout
                )))
                reportTranslationProgress(
                    completedOutputCount: index,
                    localFraction: 1,
                    outputCount: outputs.count,
                    started: translationStarted,
                    status: status
                )
                continue
            }
            let reviewWarningCount = rendered.qualityReport.reviewWarningCount
            try Task.checkCancellation()
            let renderedSRT = jobDirectory.appendingPathComponent(
                "rendered-\(output.language.rawValue).srt"
            )
            do {
                try job.trackWorkspaceArtifact(renderedSRT)
                try rendered.document.write(to: renderedSRT)
            } catch {
                if firstSaveError == nil { firstSaveError = error }
                targetResults[output.language] = SubtitleTargetResult(
                    language: output.language,
                    destinationURL: output.destinationURL,
                    status: .failed(.saveFailed)
                )
                log(.localized(.targetOutputFailed(
                    targetCode: output.language.rawValue,
                    reason: .saveFailed
                )))
                reportTranslationProgress(
                    completedOutputCount: index,
                    localFraction: 1,
                    outputCount: outputs.count,
                    started: translationStarted,
                    status: status
                )
                continue
            }
            preparedOutputs[output.language] = PreparedSubtitleOutput(
                language: output.language,
                temporaryURL: renderedSRT,
                destination: output.destination,
                warningCount: reviewWarningCount
            )
            reportTranslationProgress(
                completedOutputCount: index,
                localFraction: 1,
                outputCount: outputs.count,
                started: translationStarted,
                status: status
            )
        }
        status(update(.translatingSubtitles, overall: 0.95, started: translationStarted, eta: 0))
        log(.localized(.stage(.translatingSubtitles, completed: true)))

        guard !preparedOutputs.isEmpty else {
            throw firstSaveError ?? QuickSRTError.translationOutputInvalid
        }

        try Task.checkCancellation()
        let savingStarted = Date()
        status(update(.savingSRT, overall: 0.95, started: savingStarted))
        log(.localized(.savingValidatedSRT(completed: false)))

        // Once the atomic commit starts it intentionally finishes even if Stop is pressed:
        // interrupting the final rename would create a misleading or damaged result.
        for request in outputs {
            guard let output = preparedOutputs[request.language] else { continue }
            do {
                let saveCleanup = try environment.saveSRT(
                    output.temporaryURL,
                    output.destination,
                    job
                )
                if !saveCleanup.isSuccessful {
                    log(.localized(.cleanupFailed(count: saveCleanup.failures.count)))
                }
                do {
                    try environment.recordOutput(output.destinationURL)
                } catch {
                    log(.localized(.outputManifestFailed))
                }
                targetResults[output.language] = SubtitleTargetResult(
                    language: output.language,
                    destinationURL: output.destinationURL,
                    status: output.warningCount > 0 ? .savedWithWarnings : .saved,
                    warningCount: output.warningCount
                )
                if output.warningCount > 0 {
                    log(.localized(.targetQualityWarnings(
                        targetCode: output.language.rawValue,
                        count: output.warningCount
                    )))
                }
            } catch {
                if firstSaveError == nil { firstSaveError = error }
                targetResults[output.language] = SubtitleTargetResult(
                    language: output.language,
                    destinationURL: output.destinationURL,
                    status: .failed(.saveFailed)
                )
                log(.localized(.targetOutputFailed(
                    targetCode: output.language.rawValue,
                    reason: .saveFailed
                )))
            }
        }

        let orderedResults = outputs.compactMap { targetResults[$0.language] }
        let savedCount = orderedResults.filter(\.wasSaved).count
        guard savedCount > 0 else {
            throw firstSaveError ?? QuickSRTError.translationOutputInvalid
        }
        status(update(.savingSRT, overall: 0.99, started: savingStarted, eta: 0))
        log(.localized(.savingValidatedSRT(completed: true)))
        log(.localized(.outputSummary(saved: savedCount, total: orderedResults.count)))

        status(PipelineProgressUpdate(stage: .done, overallProgress: 1, stageElapsed: 0, stageETA: 0))
        let cleanup = job.finish()
        cleanupCompleted = true
        if cleanup.isSuccessful {
            log(.localized(.text(.logDoneCleanup)))
        } else {
            log(.localized(.cleanupFailed(count: cleanup.failures.count)))
        }
        return TranscriptionResult(
            targetResults: orderedResults,
            qualityReport: qualityReport
        )
    }

    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        targetLanguage: RecognitionLanguage,
        translator: (any SubtitleTranslating)?,
        destinationURL: URL,
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        try await transcribe(
            videoURL: videoURL,
            sourceLanguage: sourceLanguage,
            outputs: [SubtitleOutputRequest(
                language: targetLanguage,
                translator: translator,
                destinationURL: destinationURL
            )],
            status: status,
            log: log
        )
    }

    // Same-language convenience used by callers that only need transcription.
    func transcribe(
        videoURL: URL,
        language: RecognitionLanguage,
        destinationURL: URL,
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        try await transcribe(
            videoURL: videoURL,
            sourceLanguage: language,
            targetLanguage: language,
            translator: nil,
            destinationURL: destinationURL,
            status: status,
            log: log
        )
    }

    private func extractAudio(
        from videoURL: URL,
        to audioURL: URL,
        duration: TimeInterval,
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        started: Date
    ) async throws {
        let parser = LineStreamParser(onLimitExceeded: { [weak self] in
            self?.runner.stopCurrent()
        }) { line in
            guard line.hasPrefix("out_time_") else { return }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let microseconds = Double(parts[1]) else { return }
            let processed = microseconds / 1_000_000
            let fraction = min(1, max(0, processed / max(duration, 0.001)))
            let elapsed = Date().timeIntervalSince(started)
            let eta = fraction > 0 ? elapsed * (1 - fraction) / fraction : nil
            status(PipelineProgressUpdate(
                stage: .extractingAudio,
                overallProgress: 0.05 + fraction * 0.10,
                stageElapsed: elapsed,
                stageETA: eta
            ))
        }
        let timeout = environment.timeouts.extraction(duration)
        _ = try await runParsingOutput(
            executable: environment.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostats", "-nostdin", "-y",
                "-i", videoURL.path,
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
                "-progress", "pipe:1", "-f", "wav", audioURL.path
            ],
            label: "ffmpeg",
            timeout: timeout,
            parser: parser
        )
    }

    private func runWhisper(
        audioURL: URL,
        outputName: String,
        outputDirectory: URL,
        modelURL: URL,
        language: RecognitionLanguage,
        duration: TimeInterval,
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void,
        started: Date
    ) async throws -> SubtitleQualityReport? {
        let timeout = environment.timeouts.transcription(duration)
        guard FileManager.default.fileExists(atPath: environment.mlxWhisperRunner.path) else {
            throw QuickSRTError.invalidVideo(.runnerUnavailable)
        }

        let qualityReport = LockedQualityReport()
        let parser = LineStreamParser(onLimitExceeded: { [weak self] in
            self?.runner.stopCurrent()
        }) { line in
            guard line.hasPrefix("QSR_EVENT\t") else {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log(.raw(line + "\n"))
                }
                return
            }
            let json = String(line.dropFirst("QSR_EVENT\t".count))
            guard
                let data = json.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else { return }

            if type == "progress", let fraction = event["fraction"] as? Double {
                let elapsed = (event["elapsed"] as? Double) ?? Date().timeIntervalSince(started)
                let eta = event["eta"] as? Double
                status(PipelineProgressUpdate(
                    stage: .transcribingSpeech,
                    overallProgress: 0.15 + min(1, max(0, fraction)) * 0.63,
                    stageElapsed: elapsed,
                    stageETA: eta
                ))
            } else if type == "complete" {
                guard let report = SubtitleQualityReport(event: event) else { return }
                qualityReport.store(report)
                log(.localized(.subtitleQuality(report)))
            }
        }

        _ = try await runParsingOutput(
            executable: environment.python,
            arguments: [
                environment.mlxWhisperRunner.path,
                audioURL.path,
                "--model", modelURL.path,
                "--language", language.rawValue,
                "--output-dir", outputDirectory.path,
                "--output-name", outputName
            ],
            label: "MLX Whisper",
            timeout: timeout,
            parser: parser
        )
        return qualityReport.value
    }

    private func preflight(language: RecognitionLanguage) throws -> URL {
        try requireExecutable(name: "ffmpeg", url: environment.ffmpeg)
        try requireExecutable(name: "ffprobe", url: environment.ffprobe)
        guard FileManager.default.isExecutableFile(atPath: environment.python.path) else {
            throw QuickSRTError.missingVenvPython(environment.python)
        }
        guard let model = environment.resolveModel() else {
            throw QuickSRTError.missingModel(ProjectPaths.mlxWhisperModelsRoot)
        }
        if language != .english, !ProjectPaths.supportsMultilingualTranscription(at: model) {
            throw QuickSRTError.modelDoesNotSupportLanguage(language)
        }
        return model
    }

    private func runParsingOutput(
        executable: URL,
        arguments: [String],
        label: String,
        timeout: TimeInterval,
        parser: LineStreamParser
    ) async throws -> CommandResult {
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: arguments,
                label: label,
                timeout: timeout,
                onOutput: parser.consume
            )
            try parser.finish()
            return result
        } catch {
            if case let .lineTooLong(maximumBytes)? = parser.failure {
                throw QuickSRTError.processOutputLineTooLong(
                    label: label,
                    maximumBytes: maximumBytes
                )
            }
            throw error
        }
    }

    private func reportTranslationProgress(
        completedOutputCount: Int,
        localFraction: Double,
        outputCount: Int,
        started: Date,
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void
    ) {
        let clampedLocal = min(1, max(0, localFraction))
        let completedFraction = (
            Double(completedOutputCount) + clampedLocal
        ) / Double(max(1, outputCount))
        let elapsed = Date().timeIntervalSince(started)
        let eta = completedFraction > 0
            ? elapsed * (1 - completedFraction) / completedFraction
            : nil
        status(PipelineProgressUpdate(
            stage: .translatingSubtitles,
            overallProgress: 0.78 + completedFraction * 0.17,
            stageElapsed: elapsed,
            stageETA: eta
        ))
    }

    private func update(
        _ stage: PipelineStage,
        overall: Double,
        started: Date,
        eta: TimeInterval? = nil
    ) -> PipelineProgressUpdate {
        PipelineProgressUpdate(
            stage: stage,
            overallProgress: overall,
            stageElapsed: Date().timeIntervalSince(started),
            stageETA: eta
        )
    }

    private func requireExecutable(name: String, url: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw QuickSRTError.missingExecutable(name: name, url: url)
        }
    }
}

private struct PreparedSubtitleOutput {
    let language: RecognitionLanguage
    let temporaryURL: URL
    let destination: OutputDestination
    var destinationURL: URL { destination.url }
    let warningCount: Int
}

private final class LockedQualityReport: @unchecked Sendable {
    private let lock = NSLock()
    private var report: SubtitleQualityReport?

    var value: SubtitleQualityReport? {
        lock.withLock { report }
    }

    func store(_ report: SubtitleQualityReport) {
        lock.withLock {
            self.report = report
        }
    }
}

private final class LockedLanguageDetectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: LanguageDetectionResult?

    var value: LanguageDetectionResult? {
        lock.withLock { result }
    }

    func store(_ result: LanguageDetectionResult) {
        lock.withLock {
            self.result = result
        }
    }
}
