import Darwin
import Foundation
@testable import QuickSRT
import XCTest

final class TranscriptionPipelineIntegrationTests: XCTestCase {
    private var fixture: PipelineFixture!

    override func setUpWithError() throws {
        fixture = try PipelineFixture()
    }

    override func tearDownWithError() throws {
        fixture.remove()
        fixture = nil
    }

    func testCompleteLifecycleReplacesExistingSRTAndCleansWorkspace() async throws {
        try fixture.writeExistingSRT("Previous subtitle")
        let recorder = PipelineRecorder()

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            language: .english,
            destinationURL: fixture.destination,
            status: recorder.record,
            log: recorder.append
        )

        XCTAssertEqual(result.outputURL, fixture.destination)
        XCTAssertEqual(result.qualityReport?.inputSegments, 1)
        XCTAssertEqual(result.qualityReport?.outputSegments, 1)
        XCTAssertEqual(result.qualityReport?.removedSegments, 0)
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Fresh subtitle"))
        XCTAssertEqual(
            recorder.stageNames,
            [
                "checkingVideo", "checkingVideo",
                "extractingAudio", "extractingAudio", "extractingAudio",
                "transcribingSpeech", "transcribingSpeech", "transcribingSpeech",
                "translatingSubtitles", "translatingSubtitles", "translatingSubtitles",
                "savingSRT", "savingSRT", "done"
            ]
        )
        XCTAssertTrue(recorder.log.contains("Subtitle quality — kept: 1/1"))
        fixture.assertNoJobDirectories()
    }

    func testLanguageDetectionUsesThirtySecondSampleAndCleansWorkspace() async throws {
        try fixture.installLanguageDetectionRunner()

        let result = try await fixture.pipeline().detectLanguage(videoURL: fixture.video)

        XCTAssertEqual(result.languageCode, "fr")
        XCTAssertEqual(result.confidence, 0.93, accuracy: 0.0001)
        XCTAssertEqual(result.runnerUpConfidence, 0.04, accuracy: 0.0001)
        XCTAssertTrue(result.isHighConfidence)
        let ffmpegArguments = try String(contentsOf: fixture.ffmpegMarker, encoding: .utf8)
        XCTAssertTrue(ffmpegArguments.contains("-t\n30\n"))
        XCTAssertTrue(ffmpegArguments.contains("-map\n0:a:0\n"))
        XCTAssertTrue(ffmpegArguments.contains("-ac\n1\n"))
        XCTAssertTrue(ffmpegArguments.contains("-ar\n16000\n"))
        fixture.assertNoJobDirectories()
    }

    func testAnySourceCanProduceOneSelectedTranslatedSRTWithoutExtraFiles() async throws {
        let translator = RecordingSubtitleTranslator { texts in
            texts.map { "한국어: \($0)" }
        }
        let destination = fixture.root.appendingPathComponent("video.ko.srt")

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .chinese,
            targetLanguage: .korean,
            translator: translator,
            destinationURL: destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(result.outputURL, destination)
        XCTAssertEqual(translator.receivedTexts, ["Fresh subtitle"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), fixture.validSRT("한국어: Fresh subtitle"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("video.zh.srt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("video.en.srt").path))
        XCTAssertEqual(
            try String(contentsOf: fixture.whisperMarker, encoding: .utf8),
            RecognitionLanguage.chinese.rawValue
        )
        fixture.assertNoJobDirectories()
    }

    func testOneWhisperRunProducesEverySelectedSubtitleLanguageAndCleansAudioWorkspace() async throws {
        let russian = RecordingSubtitleTranslator { $0.map { "RU: \($0)" } }
        let german = RecordingSubtitleTranslator { $0.map { "DE: \($0)" } }
        let englishURL = fixture.root.appendingPathComponent("video.en.srt")
        let russianURL = fixture.root.appendingPathComponent("video.ru.srt")
        let germanURL = fixture.root.appendingPathComponent("video.de.srt")

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            outputs: [
                SubtitleOutputRequest(language: .english, translator: nil, destinationURL: englishURL),
                SubtitleOutputRequest(language: .russian, translator: russian, destinationURL: russianURL),
                SubtitleOutputRequest(language: .german, translator: german, destinationURL: germanURL)
            ],
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(result.outputURLs, [englishURL, russianURL, germanURL])
        XCTAssertEqual(russian.receivedTexts, ["Fresh subtitle"])
        XCTAssertEqual(german.receivedTexts, ["Fresh subtitle"])
        XCTAssertEqual(try String(contentsOf: englishURL, encoding: .utf8), fixture.validSRT("Fresh subtitle"))
        XCTAssertEqual(try String(contentsOf: russianURL, encoding: .utf8), fixture.validSRT("RU: Fresh subtitle"))
        XCTAssertEqual(try String(contentsOf: germanURL, encoding: .utf8), fixture.validSRT("DE: Fresh subtitle"))
        XCTAssertEqual(
            try String(contentsOf: fixture.whisperMarker, encoding: .utf8),
            RecognitionLanguage.english.rawValue
        )
        fixture.assertNoJobDirectories()
    }

    func testDamagedTargetIsRetriedThenSkippedWhileValidTargetsAreSaved() async throws {
        let damaged = AttemptingSubtitleTranslator { text, _ in "破損� \(text)" }
        let valid = RecordingSubtitleTranslator { $0.map { "DE: \($0)" } }
        let englishURL = fixture.root.appendingPathComponent("video.en.srt")
        let japaneseURL = fixture.root.appendingPathComponent("video.ja.srt")
        let germanURL = fixture.root.appendingPathComponent("video.de.srt")
        let recorder = PipelineRecorder()

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            outputs: [
                SubtitleOutputRequest(language: .english, translator: nil, destinationURL: englishURL),
                SubtitleOutputRequest(language: .japanese, translator: damaged, destinationURL: japaneseURL),
                SubtitleOutputRequest(language: .german, translator: valid, destinationURL: germanURL)
            ],
            status: { _ in },
            log: recorder.append
        )

        XCTAssertEqual(result.outputURLs, [englishURL, germanURL])
        XCTAssertEqual(damaged.receivedBatches.count, 2, "Only the damaged unit should be retried once.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: japaneseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: englishURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: germanURL.path))
        XCTAssertEqual(result.targetResults.count, 3)
        XCTAssertEqual(result.targetResults[1].status, .failed(.invalidTranslation))
        XCTAssertTrue(recorder.log.contains("ja: not saved"))
        XCTAssertTrue(recorder.log.contains("saved 2/3"))
        fixture.assertNoJobDirectories()
    }

    func testDamagedTranslationThatRecoversOnSingleUnitRetryIsSaved() async throws {
        let translator = AttemptingSubtitleTranslator { text, attempt in
            attempt == 1 ? "�" : "JA: \(text)"
        }
        let destination = fixture.root.appendingPathComponent("video.ja.srt")

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            targetLanguage: .japanese,
            translator: translator,
            destinationURL: destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(translator.receivedBatches.count, 2)
        XCTAssertEqual(result.targetResults.first?.status, .savedWithWarnings)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("JA: Fresh subtitle"))
    }

    func testMissingTranslationResponseIsRetriedAsOneUnit() async throws {
        let translator = MissingThenValidSubtitleTranslator()
        let destination = fixture.root.appendingPathComponent("video.fr.srt")

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            targetLanguage: .french,
            translator: translator,
            destinationURL: destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(translator.unitCallCount, 2)
        XCTAssertEqual(result.outputURL, destination)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("FR: Fresh subtitle"))
    }

    func testReadabilityWarningsAreLoggedWithoutDiscardingValidTranslatedSRT() async throws {
        try installReadabilityWarningFixture()
        let translator = RecordingSubtitleTranslator { _ in
            ["これは読みやすさの制限を意図的に超える長い日本語字幕です。", "次です。"]
        }
        let recorder = PipelineRecorder()

        let result = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .french,
            targetLanguage: .japanese,
            translator: translator,
            destinationURL: fixture.destination,
            status: recorder.record,
            log: recorder.append
        )

        XCTAssertEqual(result.outputURL, fixture.destination)
        XCTAssertNoThrow(try SRTValidator.validate(fixture.destination))
        XCTAssertTrue(recorder.log.contains("Readability review — ja:"))
        fixture.assertNoJobDirectories()
    }

    func testReadabilityReviewIsLoggedOnlyAfterTheSRTIsSaved() async throws {
        try installReadabilityWarningFixture()
        try fixture.writeExistingSRT("Previous subtitle")
        let translator = RecordingSubtitleTranslator { _ in
            ["これは読みやすさの制限を意図的に超える長い日本語字幕です。", "次です。"]
        }
        let recorder = PipelineRecorder()
        let environment = fixture.environment(saveSRT: { _, _ in
            throw PipelineIntegrationTestError.simulatedSaveFailure
        })

        do {
            _ = try await fixture.pipeline(environment: environment).transcribe(
                videoURL: fixture.video,
                sourceLanguage: .french,
                targetLanguage: .japanese,
                translator: translator,
                destinationURL: fixture.destination,
                status: { _ in },
                log: recorder.append
            )
            XCTFail("The pipeline unexpectedly succeeded.")
        } catch {
            XCTAssertTrue(error is PipelineIntegrationTestError)
        }

        XCTAssertFalse(recorder.log.contains("Readability review — ja:"))
        XCTAssertTrue(recorder.log.contains("ja: not saved"))
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Previous subtitle"))
        fixture.assertNoJobDirectories()
    }

    func testPipelineClampsVerboseFinalTranslationToVideoDuration() async throws {
        let translator = RecordingSubtitleTranslator { _ in
            ["もしお気に召し、役に立ったのであれば、ぜひチャンネル登録と「いいね」、そしてポッドキャストプラットフォームへの5つ星をご投稿ください。新しいエピソードでまたお会いしましょう！"]
        }

        _ = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            targetLanguage: .japanese,
            translator: translator,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        let document = try SRTDocument(validatedURL: fixture.destination)
        let finalTiming = try XCTUnwrap(document.cues.last?.timingLine)
        XCTAssertLessThanOrEqual(try endMilliseconds(of: finalTiming), 2_000)
        fixture.assertNoJobDirectories()
    }

    func testPipelineNormalizesChineseTargetToSimplifiedScript() async throws {
        let translator = RecordingSubtitleTranslator { _ in
            ["假期有付費嗎？在法國，這是最後一個。阿尔薩斯。"]
        }

        _ = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            translator: translator,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        let output = try fixture.destinationText()
        XCTAssertTrue(output.contains("假期有付费吗"))
        XCTAssertTrue(output.contains("在法国"))
        XCTAssertTrue(output.contains("这是最后一个"))
        XCTAssertTrue(output.contains("阿尔萨斯"))
        XCTAssertFalse(output.contains("付費"))
        XCTAssertFalse(output.contains("法國"))
        fixture.assertNoJobDirectories()
    }

    @MainActor
    func testEveryCuratedSourceTargetPairHasAnUnambiguousSingleOutputName() {
        for source in RecognitionLanguage.allCases {
            for target in RecognitionLanguage.allCases {
                let video = URL(fileURLWithPath: "/tmp/\(source.rawValue)-speech.mov")
                XCTAssertEqual(
                    OutputFileManager.suggestedOutputURL(for: video, targetLanguage: target),
                    URL(fileURLWithPath: "/tmp/\(source.rawValue)-speech.\(target.rawValue).srt")
                )
            }
        }
    }

    func testSelectedRecognitionLanguageIsForwardedToWhisper() async throws {
        _ = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            language: .korean,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(
            try String(contentsOf: fixture.whisperMarker, encoding: .utf8),
            RecognitionLanguage.korean.rawValue
        )
        fixture.assertNoJobDirectories()
    }

    func testVideoWithoutAudioFailsBeforeExtractionAndCleansWorkspace() async throws {
        try fixture.installProbe(output: """
        {"streams":[{"codec_type":"video"}],"format":{"duration":"2.0"}}
        """)

        await assertPipelineFailure { error in
            guard case let QuickSRTError.invalidVideo(failure) = error else { return false }
            return failure == .noAudioTrack
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ffmpegMarker.path))
    }

    func testCorruptedVideoFailsAtProbeAndCleansWorkspace() async throws {
        try fixture.installFailingExecutable(
            at: fixture.ffprobe,
            marker: fixture.probeMarker,
            exitCode: 9,
            message: "damaged container"
        )

        await assertPipelineFailure { error in
            guard case let QuickSRTError.commandFailed(label, exitCode, details) = error else {
                return false
            }
            return label == "ffprobe" && exitCode == 9 && details.contains("damaged container")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ffmpegMarker.path))
    }

    func testMissingFFmpegFailsPreflightWithoutCreatingJob() async throws {
        let missing = fixture.root.appendingPathComponent("missing-ffmpeg")
        await assertPipelineFailure(environment: fixture.environment(ffmpeg: missing)) { error in
            guard case let QuickSRTError.missingExecutable(name, url) = error else { return false }
            return name == "ffmpeg" && url == missing
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.probeMarker.path))
    }

    func testMissingFFprobeFailsPreflightWithoutCreatingJob() async throws {
        let missing = fixture.root.appendingPathComponent("missing-ffprobe")
        await assertPipelineFailure(environment: fixture.environment(ffprobe: missing)) { error in
            guard case let QuickSRTError.missingExecutable(name, url) = error else { return false }
            return name == "ffprobe" && url == missing
        }
    }

    func testMissingPythonFailsPreflightWithoutCreatingJob() async throws {
        let missing = fixture.root.appendingPathComponent("missing-python")
        await assertPipelineFailure(environment: fixture.environment(python: missing)) { error in
            guard case let QuickSRTError.missingVenvPython(url) = error else { return false }
            return url == missing
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.probeMarker.path))
    }

    func testMissingModelFailsPreflightWithoutCreatingJob() async throws {
        await assertPipelineFailure(environment: fixture.environment(resolveModel: { nil })) { error in
            if case QuickSRTError.missingModel = error { return true }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.probeMarker.path))
    }

    func testEnglishOnlyModelRemainsAvailableForEnglish() async throws {
        try fixture.writeModelConfig(nVocab: 51_864)

        _ = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            language: .english,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Fresh subtitle"))
        fixture.assertNoJobDirectories()
    }

    func testEnglishOnlyModelRejectsNonEnglishBeforeCreatingJob() async throws {
        try fixture.writeModelConfig(nVocab: 51_864)

        await assertPipelineFailure(language: .russian) { error in
            guard case let QuickSRTError.modelDoesNotSupportLanguage(language) = error else {
                return false
            }
            return language == .russian
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.probeMarker.path))
    }

    func testIncompleteModelIsRejectedByRealModelResolver() async throws {
        let incomplete = fixture.root.appendingPathComponent("incomplete-model", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try "{}".write(
            to: incomplete.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        await assertPipelineFailure(
            environment: fixture.environment(resolveModel: { ProjectPaths.findModel(in: incomplete) })
        ) { error in
            if case QuickSRTError.missingModel = error { return true }
            return false
        }
    }

    func testMissingWhisperRunnerFailsAfterAudioExtractionAndCleansWorkspace() async throws {
        let missing = fixture.root.appendingPathComponent("missing-runner.py")
        await assertPipelineFailure(environment: fixture.environment(mlxWhisperRunner: missing)) { error in
            guard case let QuickSRTError.invalidVideo(failure) = error else { return false }
            return failure == .runnerUnavailable
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ffmpegMarker.path))
    }

    func testStopDuringVideoCheckTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.ffprobe, marker: fixture.probeMarker)
        try await assertStop(marker: fixture.probeMarker)
    }

    func testStopDuringAudioExtractionTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.ffmpeg, marker: fixture.ffmpegMarker)
        try await assertStop(marker: fixture.ffmpegMarker)
    }

    func testStopDuringWhisperTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.python, marker: fixture.whisperMarker)
        try await assertStop(marker: fixture.whisperMarker)
    }

    func testStopDuringAtomicSaveAllowsSafeCommitToFinish() async throws {
        let gate = SaveGate()
        let environment = fixture.environment(saveSRT: { source, destination in
            gate.enterAndWait()
            try SRTOutputWriter.save(validatedSource: source, to: destination)
        })
        let pipeline = fixture.pipeline(environment: environment)
        let video = fixture.video
        let destination = fixture.destination
        let task = Task {
            try await pipeline.transcribe(
                videoURL: video,
                language: .english,
                destinationURL: destination,
                status: { _ in },
                log: { _ in }
            )
        }

        try await waitUntil { gate.hasEntered }
        task.cancel()
        pipeline.stop()
        gate.release()

        let result = try await task.value
        XCTAssertEqual(result.outputURL, fixture.destination)
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Fresh subtitle"))
        fixture.assertNoJobDirectories()
    }

    func testProbeTimeoutTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.ffprobe, marker: fixture.probeMarker)
        let timeouts = PipelineTimeouts(
            probe: 0.05,
            extraction: { _ in 10 },
            transcription: { _ in 10 }
        )
        await assertTimeout(environment: fixture.environment(timeouts: timeouts), label: "ffprobe")
    }

    func testFFmpegTimeoutTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.ffmpeg, marker: fixture.ffmpegMarker)
        let timeouts = PipelineTimeouts(
            probe: 10,
            extraction: { _ in 0.05 },
            transcription: { _ in 10 }
        )
        await assertTimeout(environment: fixture.environment(timeouts: timeouts), label: "ffmpeg")
    }

    func testWhisperTimeoutTerminatesProcessAndCleansWorkspace() async throws {
        try fixture.installSleepingExecutable(at: fixture.python, marker: fixture.whisperMarker)
        let timeouts = PipelineTimeouts(
            probe: 10,
            extraction: { _ in 10 },
            transcription: { _ in 0.05 }
        )
        await assertTimeout(environment: fixture.environment(timeouts: timeouts), label: "MLX Whisper")
    }

    func testOversizedSubprocessLineStopsPipelineWithControlledError() async throws {
        try fixture.installOversizedOutputRunner()

        await assertPipelineFailure { error in
            guard case let QuickSRTError.processOutputLineTooLong(label, maximumBytes) = error else {
                return false
            }
            return label == "MLX Whisper"
                && maximumBytes == LineStreamParser.defaultMaximumLineBytes
        }
    }

    func testResourcePreflightRejectsExcessiveDurationLowDiskAndLowMemory() {
        XCTAssertThrowsError(try PipelineResourcePreflight.validate(
            duration: PipelineResourcePreflight.maximumVideoDuration + 1,
            snapshot: SystemResourceSnapshot(
                availableDiskBytes: Int64.max,
                availableMemoryBytes: UInt64.max
            )
        )) { error in
            guard case QuickSRTError.videoDurationLimitExceeded = error else {
                return XCTFail("Expected duration limit, got \(error)")
            }
        }

        let duration: TimeInterval = 60 * 60
        let requiredDisk = PipelineResourcePreflight.requiredWorkspaceBytes(for: duration)
        XCTAssertThrowsError(try PipelineResourcePreflight.validate(
            duration: duration,
            snapshot: SystemResourceSnapshot(
                availableDiskBytes: requiredDisk - 1,
                availableMemoryBytes: UInt64.max
            )
        )) { error in
            guard case QuickSRTError.insufficientWorkspaceSpace = error else {
                return XCTFail("Expected disk preflight failure, got \(error)")
            }
        }

        XCTAssertThrowsError(try PipelineResourcePreflight.validate(
            duration: duration,
            snapshot: SystemResourceSnapshot(
                availableDiskBytes: Int64.max,
                availableMemoryBytes: PipelineResourcePreflight.minimumAvailableMemoryBytes - 1
            )
        )) { error in
            guard case QuickSRTError.insufficientAvailableMemory = error else {
                return XCTFail("Expected memory preflight failure, got \(error)")
            }
        }
    }

    func testCancellationDuringHighMemoryWhisperReleasesProcessAndWorkspace() async throws {
        let pidMarker = fixture.root.appendingPathComponent("memory-pressure.pid")
        try fixture.installMemoryPressureRunner(pidMarker: pidMarker, byteCount: 128 * 1_024 * 1_024)
        let pipeline = fixture.pipeline()
        let video = fixture.video
        let destination = fixture.destination
        let task = Task {
            try await pipeline.transcribe(
                videoURL: video,
                language: .english,
                destinationURL: destination,
                status: { _ in },
                log: { _ in }
            )
        }

        try await waitUntil(
            { FileManager.default.fileExists(atPath: pidMarker.path) },
            timeout: 8
        )
        let pidText = try String(contentsOf: pidMarker, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntil(
            { self.residentBytes(of: pid) >= 96 * 1_024 * 1_024 },
            timeout: 8
        )

        task.cancel()
        pipeline.stop()
        do {
            _ = try await task.value
            XCTFail("The cancelled high-memory pipeline unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected.
        }

        try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
        fixture.assertNoJobDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testThirtySequentialJobsHaveBoundedResidentMemoryGrowth() async throws {
        let pipeline = fixture.pipeline()
        _ = try await pipeline.transcribe(
            videoURL: fixture.video,
            language: .english,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )
        let baseline = residentBytes(of: getpid())
        var peak = baseline

        for _ in 0..<30 {
            _ = try await pipeline.transcribe(
                videoURL: fixture.video,
                language: .english,
                destinationURL: fixture.destination,
                status: { _ in },
                log: { _ in }
            )
            peak = max(peak, residentBytes(of: getpid()))
        }

        let final = residentBytes(of: getpid())
        XCTAssertLessThanOrEqual(peak - baseline, 128 * 1_024 * 1_024)
        let finalGrowth = final > baseline ? final - baseline : 0
        XCTAssertLessThanOrEqual(finalGrowth, 96 * 1_024 * 1_024)
        let metrics = "QuickSRT 30-job memory: baseline=\(baseline) peak=\(peak) final=\(final)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.name = "30-job-memory-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        fixture.assertNoJobDirectories()
    }

    func testSaveFailurePreservesExistingSRTAndCleansWorkspace() async throws {
        try fixture.writeExistingSRT("Previous subtitle")
        let environment = fixture.environment(saveSRT: { _, _ in
            throw PipelineIntegrationTestError.simulatedSaveFailure
        })

        await assertPipelineFailure(environment: environment) { error in
            error is PipelineIntegrationTestError
        }
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Previous subtitle"))
    }

    func testInvalidWhisperTimestampsPreserveExistingSRTAndCleanWorkspace() async throws {
        try fixture.writeExistingSRT("Previous subtitle")
        try fixture.installWhisper(output: """
        1
        00:00:01,000 --> 00:00:04,000
        First

        2
        00:00:03,000 --> 00:00:05,000
        Overlapping

        """)

        await assertPipelineFailure { error in
            if case QuickSRTError.invalidSRT = error { return true }
            return false
        }
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Previous subtitle"))
    }

    func testMissingTimelinePreservesExistingSRTAndCleansWorkspace() async throws {
        try fixture.writeExistingSRT("Previous subtitle")
        try fixture.installWhisper(
            output: fixture.validSRT("Fresh subtitle"),
            timelineJSON: nil
        )

        await assertPipelineFailure { error in
            if case QuickSRTError.outputMissing = error { return true }
            return false
        }
        XCTAssertEqual(try fixture.destinationText(), fixture.validSRT("Previous subtitle"))
    }

    func testTranslatorReceivesSemanticGroupsInsteadOfRawWhisperCues() async throws {
        let rawSRT = """
        1
        00:00:00,000 --> 00:00:00,700
        Lena macht

        2
        00:00:00,700 --> 00:00:01,400
        Kaffee.

        """
        let timeline = #"{"version":1,"language":"de","words":[{"id":0,"start":0.0,"end":0.7,"text":"Lena macht"},{"id":1,"start":0.7,"end":1.4,"text":"Kaffee."}],"segments":[{"id":0,"start":0.0,"end":0.7,"text":"Lena macht","word_start":0,"word_end":1},{"id":1,"start":0.7,"end":1.4,"text":"Kaffee.","word_start":1,"word_end":2}],"semantic_units":[{"id":0,"start":0.0,"end":0.7,"text":"Lena macht","word_start":0,"word_end":1},{"id":1,"start":0.7,"end":1.4,"text":"Kaffee.","word_start":1,"word_end":2}]}"#
        try fixture.installWhisper(output: rawSRT, timelineJSON: timeline)
        let translator = RecordingSubtitleTranslator { texts in
            texts.map { "EN: \($0)" }
        }

        _ = try await fixture.pipeline().transcribe(
            videoURL: fixture.video,
            sourceLanguage: .german,
            targetLanguage: .english,
            translator: translator,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        XCTAssertEqual(translator.receivedTexts, ["Lena macht Kaffee."])
        fixture.assertNoJobDirectories()
    }

    func testRealPythonSanitizerFlowsThroughCompleteSwiftPipeline() async throws {
        let sanitizerRunner = try fixture.installSanitizerIntegrationRunner()
        let sourceRunner = fixture.repositoryRoot
            .appendingPathComponent("Scripts/mlx_transcribe_srt.py")
        let environment = fixture.environment(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            mlxWhisperRunner: sanitizerRunner,
            resolveModel: { sourceRunner }
        )

        let result = try await fixture.pipeline(environment: environment).transcribe(
            videoURL: fixture.video,
            language: .english,
            destinationURL: fixture.destination,
            status: { _ in },
            log: { _ in }
        )

        let output = try fixture.destinationText()
        XCTAssertTrue(output.contains("no no no"), "Short intentional repetition must survive.")
        XCTAssertTrue(output.contains("Real speech"))
        XCTAssertTrue(output.contains("Done"))
        XCTAssertFalse(output.contains("in in in"), "The decoder loop must be removed.")
        XCTAssertEqual(result.qualityReport?.inputSegments, 5)
        XCTAssertEqual(result.qualityReport?.outputSegments, 3)
        XCTAssertEqual(result.qualityReport?.removedSegments, 2)
        XCTAssertEqual(result.qualityReport?.overlapsAdjusted, 1)
        XCTAssertEqual(result.qualityReport?.decoderLoopsTrimmed, 1)
        XCTAssertNoThrow(try SRTValidator.validate(fixture.destination))
        fixture.assertNoJobDirectories()
    }

    func testNextLaunchCleanupRemovesWorkspaceLeftByForcedTermination() throws {
        let orphan = fixture.tempRoot
            .appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "partial audio".write(
            to: orphan.appendingPathComponent("audio.wav"),
            atomically: true,
            encoding: .utf8
        )
        try "lock anchor".write(
            to: orphan.appendingPathComponent(".active.lock"),
            atomically: true,
            encoding: .utf8
        )

        TempWorkspace.cleanStaleJobs(in: fixture.tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        fixture.assertNoJobDirectories()
    }

    private func assertPipelineFailure(
        environment: TranscriptionPipelineEnvironment? = nil,
        language: RecognitionLanguage = .english,
        matches: (Error) -> Bool
    ) async {
        let pipeline = fixture.pipeline(environment: environment ?? fixture.environment())
        do {
            _ = try await pipeline.transcribe(
                videoURL: fixture.video,
                language: language,
                destinationURL: fixture.destination,
                status: { _ in },
                log: { _ in }
            )
            XCTFail("The pipeline unexpectedly succeeded.")
        } catch {
            XCTAssertTrue(matches(error), "Unexpected pipeline error: \(error)")
        }
        fixture.assertNoJobDirectories()
    }

    private func installReadabilityWarningFixture() throws {
        try fixture.installProbe(output: """
        {"streams":[{"codec_type":"video"},{"codec_type":"audio"}],"format":{"duration":"5.5"}}
        """)
        let rawSRT = """
        1
        00:00:00,000 --> 00:00:02,000
        First

        2
        00:00:04,000 --> 00:00:05,000
        Second

        """
        let timeline = #"{"version":1,"language":"fr","words":[{"id":0,"start":0.0,"end":2.0,"text":"First"},{"id":1,"start":4.0,"end":5.0,"text":"Second"}],"segments":[{"id":0,"start":0.0,"end":2.0,"text":"First","word_start":0,"word_end":1},{"id":1,"start":4.0,"end":5.0,"text":"Second","word_start":1,"word_end":2}],"semantic_units":[{"id":0,"start":0.0,"end":2.0,"text":"First","word_start":0,"word_end":1},{"id":1,"start":4.0,"end":5.0,"text":"Second","word_start":1,"word_end":2}]}"#
        try fixture.installWhisper(output: rawSRT, timelineJSON: timeline)
    }

    private func assertStop(marker: URL) async throws {
        let pipeline = fixture.pipeline()
        let video = fixture.video
        let destination = fixture.destination
        let task = Task {
            try await pipeline.transcribe(
                videoURL: video,
                language: .english,
                destinationURL: destination,
                status: { _ in },
                log: { _ in }
            )
        }

        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        task.cancel()
        pipeline.stop()
        pipeline.stop()

        do {
            _ = try await task.value
            XCTFail("The stopped pipeline unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected: cancellation owns the single final outcome.
        } catch {
            XCTFail("The stopped pipeline returned the wrong final outcome: \(error)")
        }

        fixture.assertNoJobDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    private func assertTimeout(
        environment: TranscriptionPipelineEnvironment,
        label: String
    ) async {
        await assertPipelineFailure(environment: environment) { error in
            guard case let QuickSRTError.timeout(actualLabel, seconds) = error else { return false }
            return actualLabel == label && seconds == 0.05
        }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PipelineIntegrationTestError.waitTimedOut
    }

    private func residentBytes(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }

    private func endMilliseconds(of timingLine: String) throws -> Int {
        let timestamp = try XCTUnwrap(timingLine.components(separatedBy: " --> ").last)
        let parts = timestamp.replacingOccurrences(of: ",", with: ":")
            .split(separator: ":")
            .map(String.init)
        XCTAssertEqual(parts.count, 4)
        return try XCTUnwrap(Int(parts[0])) * 3_600_000
            + (try XCTUnwrap(Int(parts[1])) * 60_000)
            + (try XCTUnwrap(Int(parts[2])) * 1_000)
            + (try XCTUnwrap(Int(parts[3])))
    }
}

private final class PipelineFixture: @unchecked Sendable {
    let root: URL
    let tools: URL
    let tempRoot: URL
    let model: URL
    let video: URL
    let destination: URL
    let ffprobe: URL
    let ffmpeg: URL
    let python: URL
    let whisperRunner: URL
    let probeMarker: URL
    let ffmpegMarker: URL
    let whisperMarker: URL
    let repositoryRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-PipelineTests-\(UUID().uuidString)", isDirectory: true)
        tools = root.appendingPathComponent("tools", isDirectory: true)
        tempRoot = root.appendingPathComponent("workspace", isDirectory: true)
        model = root.appendingPathComponent("model", isDirectory: true)
        video = root.appendingPathComponent("input.mp4")
        destination = root.appendingPathComponent("output.en.srt")
        ffprobe = tools.appendingPathComponent("ffprobe")
        ffmpeg = tools.appendingPathComponent("ffmpeg")
        python = tools.appendingPathComponent("python")
        whisperRunner = tools.appendingPathComponent("mlx_transcribe_srt.py")
        probeMarker = root.appendingPathComponent("probe.started")
        ffmpegMarker = root.appendingPathComponent("ffmpeg.started")
        whisperMarker = root.appendingPathComponent("whisper.started")

        let testFile = URL(fileURLWithPath: #filePath)
        repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try writeModelConfig(nVocab: 51_866)
        try Data("video fixture".utf8).write(to: video)
        try Data("runner fixture".utf8).write(to: whisperRunner)
        try installProbe()
        try installFFmpeg()
        try installWhisper(output: validSRT("Fresh subtitle"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func pipeline(environment: TranscriptionPipelineEnvironment? = nil) -> TranscriptionPipeline {
        TranscriptionPipeline(environment: environment ?? self.environment())
    }

    func environment(
        ffmpeg: URL? = nil,
        ffprobe: URL? = nil,
        python: URL? = nil,
        mlxWhisperRunner: URL? = nil,
        resolveModel: (@Sendable () -> URL?)? = nil,
        saveSRT: (@Sendable (URL, URL) throws -> Void)? = nil,
        resourceSnapshot: (@Sendable (URL) throws -> SystemResourceSnapshot)? = nil,
        timeouts: PipelineTimeouts? = nil
    ) -> TranscriptionPipelineEnvironment {
        TranscriptionPipelineEnvironment(
            ffmpeg: ffmpeg ?? self.ffmpeg,
            ffprobe: ffprobe ?? self.ffprobe,
            python: python ?? self.python,
            mlxWhisperRunner: mlxWhisperRunner ?? self.whisperRunner,
            tempRoot: tempRoot,
            resolveModel: resolveModel ?? { [model] in model },
            saveSRT: { source, destination, workspace in
                if let saveSRT {
                    try saveSRT(source, destination.url)
                    return CleanupReport()
                }
                return try SRTOutputWriter.save(
                    validatedSource: source,
                    to: destination,
                    workspace: workspace
                )
            },
            resourceSnapshot: resourceSnapshot ?? { _ in
                SystemResourceSnapshot(
                    availableDiskBytes: 100 * 1_024 * 1_024 * 1_024,
                    availableMemoryBytes: 16 * 1_024 * 1_024 * 1_024
                )
            },
            timeouts: timeouts ?? PipelineTimeouts(
                probe: 10,
                extraction: { _ in 10 },
                transcription: { _ in 10 }
            )
        )
    }

    func installProbe(output: String = """
    {"streams":[{"codec_type":"video"},{"codec_type":"audio"}],"format":{"duration":"2.0"}}
    """) throws {
        try writeExecutable(
            ffprobe,
            """
            #!/bin/sh
            : > "\(probeMarker.path)"
            printf '%s\\n' '\(output.replacingOccurrences(of: "'", with: "'\\''"))'
            """
        )
    }

    func installFFmpeg() throws {
        try writeExecutable(
            ffmpeg,
            """
            #!/bin/sh
            printf '%s\n' "$@" > "\(ffmpegMarker.path)"
            output=''
            for argument in "$@"; do output="$argument"; done
            printf 'audio fixture' > "$output"
            printf 'out_time_us=2000000\\n'
            """
        )
    }

    func installWhisper(output: String) throws {
        try installWhisper(output: output, timelineJSON: Self.defaultTimelineJSON)
    }

    func installWhisper(output: String, timelineJSON: String?) throws {
        let escapedOutput = output.replacingOccurrences(of: "'", with: "'\\''")
        let timelineCommand: String
        if let timelineJSON {
            let escapedTimeline = timelineJSON.replacingOccurrences(of: "'", with: "'\\''")
            timelineCommand = "printf '%s\\n' '\(escapedTimeline)' > \"$output_dir/$output_name.timeline.json\""
        } else {
            timelineCommand = ""
        }
        try writeExecutable(
            python,
            """
            #!/bin/sh
            output_dir=''
            output_name='quicksrt'
            language=''
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --output-dir) output_dir="$2"; shift 2 ;;
                    --output-name) output_name="$2"; shift 2 ;;
                    --language) language="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            printf '%s' "$language" > "\(whisperMarker.path)"
            mkdir -p "$output_dir"
            printf '%s' '\(escapedOutput)' > "$output_dir/$output_name.srt"
            \(timelineCommand)
            printf 'QSR_EVENT\\t{"type":"progress","fraction":1.0,"elapsed":0.1,"eta":0.0}\\n'
            printf 'QSR_EVENT\\t{"type":"complete","segments":1,"input_segments":1,"output_segments":1,"removed":0,"overlaps_adjusted":0,"decoder_loops_trimmed":0,"quality_warning":false}\\n'
            """
        )
    }

    func installLanguageDetectionRunner() throws {
        try writeExecutable(
            python,
            """
            #!/bin/sh
            detect='false'
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --detect-language-only) detect='true'; shift ;;
                    *) shift ;;
                esac
            done
            if [ "$detect" = 'true' ]; then
                printf 'QSR_EVENT\t{"type":"language_detection","language":"fr","confidence":0.93,"runner_up_confidence":0.04}\n'
                exit 0
            fi
            exit 2
            """
        )
    }

    func writeModelConfig(nVocab: Int) throws {
        let config = #"{"n_vocab":\#(nVocab)}"#
        try Data(config.utf8).write(to: model.appendingPathComponent("config.json"))
    }

    func installFailingExecutable(
        at url: URL,
        marker: URL,
        exitCode: Int,
        message: String
    ) throws {
        try writeExecutable(
            url,
            """
            #!/bin/sh
            : > "\(marker.path)"
            printf '%s\\n' '\(message)' >&2
            exit \(exitCode)
            """
        )
    }

    func installSleepingExecutable(at url: URL, marker: URL) throws {
        try writeExecutable(
            url,
            """
            #!/bin/sh
            : > "\(marker.path)"
            sleep 30
            """
        )
    }

    func installOversizedOutputRunner() throws {
        try writeExecutable(
            python,
            """
            #!/bin/sh
            exec /usr/bin/python3 -c 'import sys; sys.stdout.write("x" * 70000); sys.stdout.flush()'
            """
        )
    }

    func installMemoryPressureRunner(pidMarker: URL, byteCount: Int) throws {
        try writeExecutable(
            python,
            """
            #!/bin/sh
            exec /usr/bin/python3 -c 'import os,time; payload=bytearray(\(byteCount)); open("\(pidMarker.path)", "w").write(str(os.getpid())); time.sleep(30)'
            """
        )
    }

    func installSanitizerIntegrationRunner() throws -> URL {
        let runner = tools.appendingPathComponent("sanitizer_integration.py")
        let source = """
        #!/usr/bin/python3
        import argparse
        import importlib.util
        import pathlib

        parser = argparse.ArgumentParser()
        parser.add_argument("audio")
        parser.add_argument("--model", required=True)
        parser.add_argument("--language")
        parser.add_argument("--output-dir", required=True)
        parser.add_argument("--output-name", required=True)
        args = parser.parse_args()

        spec = importlib.util.spec_from_file_location("quicksrt_sanitizer", args.model)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        segments = [
            {"start": 0.0, "end": 1.0, "text": "no no no", "compression_ratio": 1.0, "avg_logprob": -0.1, "no_speech_prob": 0.0},
            {"start": 0.8, "end": 2.0, "text": "Real speech", "compression_ratio": 1.0, "avg_logprob": -0.1, "no_speech_prob": 0.0},
            {"start": 2.0, "end": 3.0, "text": "in " * 30, "compression_ratio": 1.0, "avg_logprob": -1.2, "no_speech_prob": 0.0},
            {"start": 3.0, "end": 3.0, "text": "Invalid timestamp"},
            {"start": 3.0, "end": 4.0, "text": "Done", "compression_ratio": 1.0, "avg_logprob": -0.1, "no_speech_prob": 0.0},
        ]
        cleaned, report = module.sanitize_segments(segments)
        output = pathlib.Path(args.output_dir) / f"{args.output_name}.srt"
        module.write_srt(output, cleaned)
        cleaned_with_trace, _, trace = module._sanitize_segments_with_trace(segments)
        timeline = module.build_timeline(
            {"segments": segments, "language": args.language},
            cleaned_with_trace,
            report,
            trace,
            language=args.language,
        )
        module.write_timeline(
            pathlib.Path(args.output_dir) / f"{args.output_name}.timeline.json",
            timeline,
        )
        module.emit_event("complete", segments=len(cleaned), **report)
        """
        try Data(source.utf8).write(to: runner)
        return runner
    }

    func writeExistingSRT(_ text: String) throws {
        try validSRT(text).write(to: destination, atomically: true, encoding: .utf8)
    }

    func destinationText() throws -> String {
        try String(contentsOf: destination, encoding: .utf8)
    }

    func validSRT(_ text: String) -> String {
        """
        1
        00:00:00,000 --> 00:00:01,500
        \(text)

        """
    }

    func assertNoJobDirectories(file: StaticString = #filePath, line: UInt = #line) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            items.filter { $0.lastPathComponent.hasPrefix("job-") }.isEmpty,
            "Temporary job directories remain: \(items)",
            file: file,
            line: line
        )
    }

    private func writeExecutable(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static let defaultTimelineJSON = #"{"version":1,"language":"en","words":[{"id":0,"start":0.0,"end":1.5,"text":"Fresh subtitle","probability":0.99}],"segments":[{"id":0,"start":0.0,"end":1.5,"text":"Fresh subtitle","word_start":0,"word_end":1}],"semantic_units":[{"id":0,"start":0.0,"end":1.5,"text":"Fresh subtitle","word_start":0,"word_end":1}]}"#
}

private final class PipelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [String] = []
    private var output = ""

    var stageNames: [String] {
        lock.withLock { stages }
    }

    var log: String {
        lock.withLock { output }
    }

    func record(_ update: PipelineProgressUpdate) {
        lock.withLock { stages.append(update.stage.id) }
    }

    func append(_ event: AppLogEvent) {
        lock.withLock { output += event.rendered(in: .english) }
    }
}

private final class SaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class RecordingSubtitleTranslator: SubtitleTranslating, @unchecked Sendable {
    private let transform: @Sendable ([String]) -> [String]
    private(set) var receivedTexts: [String] = []

    init(transform: @escaping @Sendable ([String]) -> [String]) {
        self.transform = transform
    }

    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        receivedTexts = texts
        progress(1)
        return transform(texts)
    }

    func cancel() {}
}

private final class AttemptingSubtitleTranslator: SubtitleTranslating, @unchecked Sendable {
    private let transform: @Sendable (String, Int) -> String
    private var attempts: [String: Int] = [:]
    private(set) var receivedBatches: [[String]] = []

    init(transform: @escaping @Sendable (String, Int) -> String) {
        self.transform = transform
    }

    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        receivedBatches.append(texts)
        let result = texts.map { text in
            let attempt = (attempts[text] ?? 0) + 1
            attempts[text] = attempt
            return transform(text, attempt)
        }
        progress(1)
        return result
    }

    func cancel() {}
}

private final class MissingThenValidSubtitleTranslator: SubtitleTranslating, @unchecked Sendable {
    private(set) var unitCallCount = 0

    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        texts.map { "FR: \($0)" }
    }

    func translate(
        units: [SubtitleTranslationUnit],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SubtitleTranslationResponse] {
        unitCallCount += 1
        progress(1)
        guard unitCallCount > 1 else { return [] }
        return units.map { SubtitleTranslationResponse(id: $0.id, targetText: "FR: \($0.sourceText)") }
    }

    func cancel() {}
}

private enum PipelineIntegrationTestError: Error {
    case simulatedSaveFailure
    case waitTimedOut
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
