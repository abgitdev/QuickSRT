import Foundation
@testable import QuickSRT
import XCTest

@MainActor
final class AppControllerTests: XCTestCase {
    func testModelDownloadPreflightRequiresSpaceForStagingAndInstall() {
        XCTAssertThrowsError(try ModelDownloadResourcePreflight.validate(
            SystemResourceSnapshot(
                availableDiskBytes: ModelDownloadResourcePreflight.requiredDiskBytes - 1,
                availableMemoryBytes: UInt64.max
            )
        )) { error in
            guard case QuickSRTError.insufficientWorkspaceSpace = error else {
                return XCTFail("Expected disk preflight failure, got \(error)")
            }
        }
    }

    func testChildProcessEnvironmentDropsInjectionVariables() {
        let environment = ChildProcessEnvironment.sanitized(parent: [
            "HOME": "/Users/example",
            "TMPDIR": "/tmp/example",
            "LANG": "ru_RU.UTF-8",
            "PYTHONPATH": "/tmp/injected",
            "PYTHONHOME": "/tmp/python",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            "DYLD_LIBRARY_PATH": "/tmp/lib",
            "LD_LIBRARY_PATH": "/tmp/lib",
            "SSH_AUTH_SOCK": "/tmp/agent",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["LANG"], "ru_RU.UTF-8")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertNil(environment["PYTHONHOME"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertNil(environment["LD_LIBRARY_PATH"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
    }

    func testLogBufferSanitizesBoundsAndClearsText() {
        let buffer = LogBuffer(maximumCharacters: 24)

        buffer.append("/Users/example/Desktop/private.mov\n")
        buffer.append(String(repeating: "x", count: 40) + "END")

        XCTAssertLessThanOrEqual(buffer.text.count, 24)
        XCTAssertTrue(buffer.text.hasSuffix("END"))
        XCTAssertFalse(buffer.text.contains("/Users/"))

        buffer.clear()
        XCTAssertEqual(buffer.text, "")
    }

    func testLocalizationControllerFormatsDynamicStateAfterLanguageChange() {
        let localization = LocalizationController(language: .english)
        let timing = JobStageTiming(elapsed: 65, eta: 30)

        XCTAssertEqual(localization.durationText(duration: 65, isInspecting: false), "Duration: 1:05")
        XCTAssertEqual(localization.etaText(for: timing), "~0:30 left")
        XCTAssertEqual(localization.stageTimingText(for: timing), "Elapsed 1:05 · ~0:30 left")

        localization.language = .russian

        XCTAssertEqual(localization.durationText(duration: 65, isInspecting: false), "Длительность: 1:05")
        XCTAssertEqual(localization.etaText(for: timing), "Осталось ~0:30")
        XCTAssertEqual(localization.stageTimingText(for: timing), "Прошло 1:05 · осталось ~0:30")
    }

    func testRuntimeDiagnosticsReportsPythonBeforeDownloader() {
        let diagnostics = RuntimeDiagnostics(
            isExecutable: { _ in false },
            fileExists: { _ in false }
        )
        let python = URL(fileURLWithPath: "/runtime/python")
        let downloader = URL(fileURLWithPath: "/scripts/downloader.py")

        XCTAssertEqual(
            diagnostics.modelDownloadIssue(python: python, downloader: downloader),
            .missingPython(python)
        )
    }

    func testRecognitionLanguageCatalogContainsTheCuratedLanguages() {
        XCTAssertEqual(
            RecognitionLanguage.allCases.map(\.rawValue),
            ["en", "ru", "de", "es", "it", "fr", "ja", "zh", "ko", "hi"]
        )
        XCTAssertEqual(RecognitionLanguage.hindi.pickerTitle(.english), "Hindi (HI) — Beta")
        XCTAssertEqual(RecognitionLanguage.japanese.pickerTitle(.russian), "Японский (JA)")
    }

    func testInterfaceLanguageCatalogUsesStableCodesAutonymsAndLocales() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["en", "ru", "de", "es", "it", "fr", "ja", "zh-Hans", "ko", "hi"]
        )
        XCTAssertEqual(
            AppLanguage.allCases.map(\.nativeName),
            ["English", "Русский", "Deutsch", "Español", "Italiano", "Français", "日本語", "简体中文", "한국어", "हिन्दी"]
        )
        XCTAssertEqual(AppLanguage.chinese.localeIdentifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-CN"]), .chinese)
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-Hans-SG"]), .chinese)
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-Hant-TW", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.preferred(from: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.preferred(from: ["unsupported"]), .english)
    }

    func testEveryTextKeyAndRecognitionLanguageHasEveryTranslation() {
        for appLanguage in AppLanguage.allCases {
            for key in TextKey.allCases {
                XCTAssertFalse(
                    key.text(appLanguage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Missing \(key) for \(appLanguage.rawValue)"
                )
            }
            for recognitionLanguage in RecognitionLanguage.allCases {
                let title = recognitionLanguage.pickerTitle(appLanguage)
                XCTAssertFalse(title.isEmpty)
                XCTAssertTrue(title.contains(recognitionLanguage.title))
            }
        }

        let hindiText = TextKey.allCases.map { $0.text(.hindi) }.joined()
        XCTAssertEqual(hindiText, hindiText.precomposedStringWithCanonicalMapping)
        XCTAssertTrue(RecognitionLanguage.hindi.pickerTitle(.chinese).contains("测试版"))
        XCTAssertTrue(RecognitionLanguage.hindi.pickerTitle(.korean).contains("베타"))
        XCTAssertTrue(RecognitionLanguage.hindi.pickerTitle(.hindi).contains("बीटा"))
    }

    func testLocalizedDynamicMessagesAndTypedFailuresResolveForEveryLanguage() {
        let localization = LocalizationController()
        let timing = JobStageTiming(elapsed: 65, eta: 30)
        let videoFailures: [VideoValidationFailure] = [
            .invalidProbeOutput, .invalidDescription, .noAudioTrack,
            .durationUnavailable, .runnerUnavailable
        ]
        let srtFailures: [SRTValidationFailure] = [
            .notRegularFile, .emptyFile, .unexpectedlyLarge, .invalidUTF8, .noCues,
            .cueMissingText(3), .invalidNumbering(3), .invalidTimestamps(3), .emptyCueText(3)
        ]

        for language in AppLanguage.allCases {
            localization.language = language
            let messages = [
                localization.durationText(duration: 65, isInspecting: false),
                localization.etaText(for: timing),
                localization.stageTimingText(for: timing),
                localization.modelLocationText(isManaged: true, path: "/model"),
                localization.modelLocationText(isManaged: false, path: "/model"),
                localization.outputLanguageText(source: .chinese, target: .hindi),
                TextKey.logTranslatingFormat.formatted(
                    language: language,
                    arguments: ["zh", "hi"]
                ),
                localization.qualityWarning(for: SubtitleQualityReport(
                    inputSegments: 4,
                    outputSegments: 3,
                    removedSegments: 1,
                    overlapsAdjusted: 0,
                    decoderLoopsTrimmed: 0,
                    requiresUserWarning: true
                )).message,
                localization.outputSummary(for: TranscriptionResult(
                    targetResults: [
                        SubtitleTargetResult(
                            language: .english,
                            destinationURL: URL(fileURLWithPath: "/tmp/output.en.srt"),
                            status: .saved
                        ),
                        SubtitleTargetResult(
                            language: .japanese,
                            destinationURL: URL(fileURLWithPath: "/tmp/output.ja.srt"),
                            status: .failed(.invalidTranslation)
                        )
                    ],
                    qualityReport: nil
                )).message,
                localization.errorMessage(for: QuickSRTError.commandFailed(
                    label: "ffmpeg",
                    exitCode: 2,
                    details: "details"
                )),
                localization.errorMessage(for: QuickSRTError.timeout(label: "ffmpeg", seconds: 65)),
                localization.errorMessage(for: QuickSRTError.translationPairUnsupported(
                    source: .chinese,
                    target: .hindi
                )),
                localization.errorMessage(for: QuickSRTError.translationNotReady),
                localization.errorMessage(for: QuickSRTError.translationOutputInvalid)
            ]
            + videoFailures.map { localization.errorMessage(for: QuickSRTError.invalidVideo($0)) }
            + srtFailures.map { localization.errorMessage(for: QuickSRTError.invalidSRT($0)) }

            for message in messages {
                XCTAssertFalse(message.isEmpty, "Empty dynamic message for \(language.rawValue)")
                XCTAssertFalse(message.contains("%1$"), "Unresolved format in: \(message)")
                XCTAssertFalse(message.contains("%2$"), "Unresolved format in: \(message)")
                XCTAssertFalse(message.contains("%3$"), "Unresolved format in: \(message)")
            }
        }
    }

    func testSemanticLogMessagesRerenderButRawToolOutputDoesNot() {
        let buffer = LogBuffer()
        buffer.append(.stage(.checkingVideo, completed: false))
        buffer.append(.error(AppDisplayError(QuickSRTError.commandFailed(
            label: AppProcessLabel.modelDownload,
            exitCode: 2,
            details: "technical details"
        ))))
        buffer.append(.raw("RAW_TOOL_OUTPUT\n"))

        let english = buffer.renderedText(in: .english)
        let japanese = buffer.renderedText(in: .japanese)

        XCTAssertNotEqual(english, japanese)
        XCTAssertTrue(english.contains("RAW_TOOL_OUTPUT"))
        XCTAssertTrue(japanese.contains("RAW_TOOL_OUTPUT"))
        XCTAssertTrue(english.contains(TextKey.checkingVideo.text(.english)))
        XCTAssertTrue(japanese.contains(TextKey.checkingVideo.text(.japanese)))
        XCTAssertTrue(english.contains(TextKey.processModelDownload.text(.english)))
        XCTAssertTrue(japanese.contains(TextKey.processModelDownload.text(.japanese)))
    }

    func testOutputFileManagerBuildsLanguageSpecificSubtitleNamesBesideVideo() {
        let video = URL(fileURLWithPath: "/tmp/My.Video.mov")

        for language in RecognitionLanguage.allCases {
            XCTAssertEqual(
                OutputFileManager.suggestedOutputURL(for: video, targetLanguage: language),
                URL(fileURLWithPath: "/tmp/My.Video.\(language.rawValue).srt")
            )
        }
    }

    func testMultilingualModelCapabilityUsesMLXWhisperVocabularyThreshold() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-model-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: model) }
        let config = model.appendingPathComponent("config.json")

        try Data(#"{"n_vocab":51864}"#.utf8).write(to: config)
        XCTAssertFalse(ProjectPaths.supportsMultilingualTranscription(at: model))

        try Data(#"{"n_vocab":51865}"#.utf8).write(to: config)
        XCTAssertTrue(ProjectPaths.supportsMultilingualTranscription(at: model))

        try Data(#"{"n_vocab":51866}"#.utf8).write(to: config)
        XCTAssertTrue(ProjectPaths.supportsMultilingualTranscription(at: model))

        try Data(#"{"n_vocab":"invalid"}"#.utf8).write(to: config)
        XCTAssertFalse(ProjectPaths.supportsMultilingualTranscription(at: model))
    }

    func testAppViewModelPersistsTheSelectedRecognitionLanguage() {
        let suiteName = "QuickSRTTests.recognition-language.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated preferences")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let environment = ModelManagerEnvironment(
            python: URL(fileURLWithPath: "/runtime/python"),
            downloader: URL(fileURLWithPath: "/scripts/downloader.py"),
            repositoryID: "example/model",
            modelsRoot: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            resolveModel: { nil },
            selectModel: { _ in nil },
            useManagedModel: { nil },
            isManagedModel: { _ in false },
            acquireOperationLock: {
                try InterprocessFileLock.acquire(
                    at: FileManager.default.temporaryDirectory
                        .appendingPathComponent("language-preference-test-\(UUID().uuidString).lock")
                )
            },
            cleanPartialDownloads: { CleanupReport() },
            cleanPartialDownloadsWhileLocked: { CleanupReport() },
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        let first = AppViewModel(
            modelEnvironment: environment,
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )
        XCTAssertEqual(first.recognitionLanguage, .english)
        XCTAssertEqual(first.subtitleLanguage, .russian)
        first.recognitionLanguage = .chinese
        first.subtitleLanguage = .japanese

        let reloaded = AppViewModel(
            modelEnvironment: environment,
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )
        XCTAssertEqual(reloaded.recognitionLanguage, .chinese)
        XCTAssertEqual(reloaded.subtitleLanguage, .japanese)
        XCTAssertNotEqual(reloaded.recognitionLanguage, reloaded.subtitleLanguage)

        reloaded.toggleSubtitleLanguage(.german)
        reloaded.toggleSubtitleLanguage(.french)
        let multiTargetReload = AppViewModel(
            modelEnvironment: environment,
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )
        XCTAssertEqual(
            multiTargetReload.subtitleLanguages,
            Set([.german, .french, .japanese])
        )
    }

    func testAppViewModelPersistsInterfaceLanguageSeparatelyFromSpeechLanguage() {
        let suiteName = "QuickSRTTests.interface-language.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated preferences")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let first = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences,
            preferredAppLanguages: ["ja-JP"]
        )
        XCTAssertEqual(first.appLanguage, .japanese)

        for language in AppLanguage.allCases {
            first.appLanguage = language
            let reloaded = AppViewModel(
                modelEnvironment: makeModelEnvironment(),
                pipeline: SuccessfulControllerPipeline(),
                preferences: preferences,
                preferredAppLanguages: ["en"]
            )
            XCTAssertEqual(reloaded.appLanguage, language)
        }

        first.recognitionLanguage = .korean
        first.appLanguage = .french
        let independentReload = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences,
            preferredAppLanguages: ["en"]
        )
        XCTAssertEqual(independentReload.appLanguage, .french)
        XCTAssertEqual(independentReload.recognitionLanguage, .korean)

        preferences.set("unsupported-language", forKey: "QuickSRT.appLanguage")
        let invalidReload = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences,
            preferredAppLanguages: ["ja-JP"]
        )
        XCTAssertEqual(invalidReload.appLanguage, .english)
    }

    func testModelManagerOwnsModelPresentationState() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let managedModel = home.appendingPathComponent("Models/managed", isDirectory: true)
        let selectedModel = LockedValue<URL?>(managedModel)
        let environment = ModelManagerEnvironment(
            python: URL(fileURLWithPath: "/runtime/python"),
            downloader: URL(fileURLWithPath: "/scripts/downloader.py"),
            repositoryID: "example/model",
            modelsRoot: home.appendingPathComponent("Models", isDirectory: true),
            resolveModel: { selectedModel.withLock { $0 } },
            selectModel: { selected in
                selectedModel.withLock { $0 = selected }
                return selected
            },
            useManagedModel: { managedModel },
            isManagedModel: { $0 == managedModel },
            acquireOperationLock: {
                try InterprocessFileLock.acquire(
                    at: FileManager.default.temporaryDirectory
                        .appendingPathComponent("model-manager-test-\(UUID().uuidString).lock")
                )
            },
            cleanPartialDownloads: { CleanupReport() },
            cleanPartialDownloadsWhileLocked: { CleanupReport() },
            homeDirectory: home
        )
        let manager = ModelManager(
            environment: environment,
            diagnostics: RuntimeDiagnostics(isExecutable: { _ in true }, fileExists: { _ in true }),
            logBuffer: LogBuffer()
        )

        XCTAssertTrue(manager.isInstalled)
        XCTAssertTrue(manager.isManaged)
        XCTAssertEqual(manager.pathText, "~/Models/managed")
        XCTAssertNil(manager.transcriptionIssue(for: .english))
        guard case .modelDoesNotSupportLanguage(.russian)? = manager.transcriptionIssue(for: .russian) else {
            XCTFail("Expected the English-only model to reject Russian transcription.")
            return
        }

        let external = URL(fileURLWithPath: "/tmp/external-model", isDirectory: true)
        XCTAssertTrue(manager.selectModel(at: external))
        XCTAssertFalse(manager.isManaged)
        XCTAssertEqual(manager.pathText, "/tmp/external-model")
    }

    func testLanguageDetectionConfidenceUsesProbabilityAndMargin() {
        XCTAssertTrue(LanguageDetectionResult(
            languageCode: "fr",
            confidence: 0.80,
            runnerUpConfidence: 0.50
        ).isHighConfidence)
        XCTAssertFalse(LanguageDetectionResult(
            languageCode: "fr",
            confidence: 0.79,
            runnerUpConfidence: 0.10
        ).isHighConfidence)
        XCTAssertFalse(LanguageDetectionResult(
            languageCode: "fr",
            confidence: 0.90,
            runnerUpConfidence: 0.75
        ).isHighConfidence)
    }

    func testQueueRequiresDecisionForConfidentLanguageMismatch() async throws {
        let pipeline = QueueControllerPipeline(detectedCodes: ["first.mov": "fr"])
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        let video = URL(fileURLWithPath: "/tmp/first.mov")

        controller.addVideos(
            [video],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.first?.state == .needsAttention }

        let job = try XCTUnwrap(controller.jobs.first)
        XCTAssertTrue(job.languageCheck.requiresDecision)
        XCTAssertFalse(controller.canBeginQueue)

        controller.useDetectedLanguage(for: job.id)
        XCTAssertEqual(controller.jobs.first?.sourceLanguage, .french)
        XCTAssertEqual(controller.jobs.first?.state, .ready)
        XCTAssertTrue(controller.canBeginQueue)
    }

    func testQueueProcessesVideosSequentiallyInReorderedOrder() async throws {
        let pipeline = QueueControllerPipeline(detectedCodes: [
            "one.mov": "en", "two.mov": "en", "three.mov": "en"
        ])
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        let videos = ["one.mov", "two.mov", "three.mov"].map {
            URL(fileURLWithPath: "/tmp/\($0)")
        }
        controller.addVideos(
            videos,
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }

        let thirdID = try XCTUnwrap(controller.jobs.last?.id)
        controller.moveJob(thirdID, offset: -1)
        controller.moveJob(thirdID, offset: -1)
        XCTAssertEqual(controller.jobs.map { $0.videoURL.lastPathComponent }, [
            "three.mov", "one.mov", "two.mov"
        ])

        let destinations: [UUID: [RecognitionLanguage: OutputDestination]] = Dictionary(
            uniqueKeysWithValues: controller.jobs.map { job in
                (
                    job.id,
                    [RecognitionLanguage.english: OutputDestination.assumingAbsent(URL(
                        fileURLWithPath: "/tmp/\(job.videoURL.lastPathComponent).en.srt"
                    ))]
                )
            }
        )
        XCTAssertTrue(controller.setDestinations(destinations))
        controller.beginQueue()

        while controller.isQueueActive {
            if controller.nextJobID != nil {
                controller.startNext(
                    translators: [:],
                    onError: { error in XCTFail("Unexpected run error: \(error)") }
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(pipeline.transcribedFiles, ["three.mov", "one.mov", "two.mov"])
        XCTAssertEqual(pipeline.maximumConcurrentTranscriptions, 1)
        XCTAssertTrue(controller.jobs.allSatisfy { $0.state == .completed })
    }

    func testQueueRejectsDuplicateDestinationReservationsAcrossJobs() async throws {
        let pipeline = QueueControllerPipeline(detectedCodes: ["one.mp4": "en", "one.mov": "en"])
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/one.mp4"), URL(fileURLWithPath: "/tmp/one.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }

        let shared = OutputDestination.assumingAbsent(URL(fileURLWithPath: "/tmp/one.en.srt"))
        let duplicateReservations = Dictionary(
            uniqueKeysWithValues: controller.jobs.map { job in
                (job.id, [RecognitionLanguage.english: shared])
            }
        )

        XCTAssertFalse(controller.setDestinations(duplicateReservations))
        XCTAssertTrue(controller.jobs.allSatisfy { $0.destinations.isEmpty })
    }

    func testQueueRecordsQualityWarningWithoutInteractionAndContinues() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["warning.mov": "en", "next.mov": "en"],
            qualityWarningTranscriptions: ["warning.mov"]
        )
        let logBuffer = LogBuffer()
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: logBuffer)
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/warning.mov"), URL(fileURLWithPath: "/tmp/next.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }
        controller.setDestinations(Dictionary(uniqueKeysWithValues: controller.jobs.map {
            ($0.id, [.english: OutputDestination.assumingAbsent(
                URL(fileURLWithPath: "/tmp/\($0.videoURL.lastPathComponent).srt")
            )])
        }))
        controller.beginQueue()

        while controller.isQueueActive {
            if controller.nextJobID != nil {
                controller.startNext(
                    translators: [:],
                    onError: { error in XCTFail("Unexpected run error: \(error)") }
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(pipeline.transcribedFiles, ["warning.mov", "next.mov"])
        XCTAssertEqual(controller.jobs.map(\.state), [.completed, .completed])
        XCTAssertEqual(controller.jobs.first?.qualityReport?.syntheticWordTimingSegments, 2)
        XCTAssertEqual(controller.jobs.first?.targetResults.first?.status, .savedWithWarnings)
        XCTAssertTrue(logBuffer.text.contains("warning.mov"))
        XCTAssertTrue(logBuffer.text.contains("next.mov"))
    }

    func testQueueUsesWarningCompletionOnlyForPartialExport() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["partial.mov": "en"],
            partialTargetFailureTranscriptions: ["partial.mov"]
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/partial.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english, .russian],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }
        let jobID = try XCTUnwrap(controller.jobs.first?.id)
        controller.setDestinations([
            jobID: [
                .english: OutputDestination.assumingAbsent(URL(fileURLWithPath: "/tmp/partial.en.srt")),
                .russian: OutputDestination.assumingAbsent(URL(fileURLWithPath: "/tmp/partial.ru.srt"))
            ]
        ])
        let translators: [TranslationPair: SubtitleTranslating] = [
            TranslationPair(source: .english, target: .russian): NoOpTestTranslator()
        ]
        controller.beginQueue()

        while controller.isQueueActive {
            if controller.nextJobID != nil {
                controller.startNext(
                    translators: translators,
                    onError: { error in XCTFail("Unexpected run error: \(error)") }
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(controller.jobs.first?.state, .completedWithWarnings)
        XCTAssertEqual(controller.jobs.first?.outputURLs.count, 1)
        XCTAssertFalse(controller.finishedSuccessfully)
        XCTAssertTrue(controller.finishedWithPartialExport)
    }

    func testQueueKeepsPerVideoSettingsAndRequiredTranslationPairsIndependent() async throws {
        let pipeline = QueueControllerPipeline(detectedCodes: ["one.mov": "en", "two.mov": "en"])
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/one.mov"), URL(fileURLWithPath: "/tmp/two.mov")],
            sourceLanguage: .english,
            targetLanguages: [.russian],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }

        let secondID = controller.jobs[1].id
        controller.updateSourceLanguage(.french, for: secondID)
        controller.updateTargetLanguages([.german, .japanese], for: secondID)

        XCTAssertEqual(controller.jobs[0].sourceLanguage, .english)
        XCTAssertEqual(controller.jobs[0].targetLanguages, [.russian])
        XCTAssertEqual(controller.jobs[1].sourceLanguage, .french)
        XCTAssertEqual(controller.jobs[1].targetLanguages, [.german, .japanese])
        XCTAssertEqual(controller.jobs[1].state, .needsAttention)

        controller.keepSelectedLanguage(for: secondID)
        XCTAssertEqual(
            Set(controller.allRequiredTranslationPairs),
            Set([
                TranslationPair(source: .english, target: .russian),
                TranslationPair(source: .french, target: .german),
                TranslationPair(source: .french, target: .japanese)
            ])
        )
    }

    func testQueueHandlesLowConfidenceUnsupportedAndDetectionFailureChoices() async throws {
        let low = URL(fileURLWithPath: "/tmp/low.mov")
        let unsupported = URL(fileURLWithPath: "/tmp/unsupported.mov")
        let retry = URL(fileURLWithPath: "/tmp/retry.mov")
        let accept = URL(fileURLWithPath: "/tmp/accept.mov")
        let pipeline = QueueControllerPipeline(
            detectedCodes: [:],
            detections: [
                "low.mov": LanguageDetectionResult(
                    languageCode: "fr", confidence: 0.79, runnerUpConfidence: 0.10
                ),
                "unsupported.mov": LanguageDetectionResult(
                    languageCode: "pt", confidence: 0.94, runnerUpConfidence: 0.02
                ),
                "retry.mov": LanguageDetectionResult(
                    languageCode: "en", confidence: 0.96, runnerUpConfidence: 0.01
                ),
                "accept.mov": LanguageDetectionResult(
                    languageCode: "en", confidence: 0.96, runnerUpConfidence: 0.01
                )
            ],
            detectionFailuresRemaining: ["retry.mov": 1, "accept.mov": 1]
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [low, unsupported, retry, accept],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil {
            !controller.jobs.contains { $0.state == .inspecting || $0.state == .waitingForInspection }
        }

        XCTAssertEqual(controller.jobs[0].state, .ready)
        guard case .lowConfidence = controller.jobs[0].languageCheck else {
            return XCTFail("Expected informational low-confidence result")
        }
        XCTAssertEqual(controller.jobs[1].state, .needsAttention)
        controller.useDetectedLanguage(for: controller.jobs[1].id)
        XCTAssertEqual(controller.jobs[1].state, .needsAttention)
        controller.keepSelectedLanguage(for: controller.jobs[1].id)
        XCTAssertEqual(controller.jobs[1].state, .ready)

        let retryID = controller.jobs[2].id
        guard case .failed = controller.jobs[2].languageCheck else {
            return XCTFail("Expected failed language detection")
        }
        controller.retryLanguageDetection(for: retryID) { error in
            XCTFail("Unexpected retry error: \(error)")
        }
        try await waitUntil { controller.jobs[2].state == .ready }

        let acceptID = controller.jobs[3].id
        controller.keepSelectedLanguage(for: acceptID)
        XCTAssertEqual(controller.jobs[3].state, .ready)
        controller.updateSourceLanguage(.french, for: acceptID)
        XCTAssertEqual(controller.jobs[3].state, .needsAttention)
        guard case .failed = controller.jobs[3].languageCheck else {
            return XCTFail("Changing the source must reset failure confirmation")
        }
    }

    func testQueueContinuesAfterOneVideoFails() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["bad.mov": "en", "good.mov": "en"],
            failingTranscriptions: ["bad.mov"]
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/bad.mov"), URL(fileURLWithPath: "/tmp/good.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }
        controller.setDestinations(Dictionary(uniqueKeysWithValues: controller.jobs.map {
            ($0.id, [.english: OutputDestination.assumingAbsent(
                URL(fileURLWithPath: "/tmp/\($0.videoURL.lastPathComponent).srt")
            )])
        }))
        controller.beginQueue()
        var runErrors = 0
        while controller.isQueueActive {
            if controller.nextJobID != nil {
                controller.startNext(
                    translators: [:],
                    onError: { _ in runErrors += 1 }
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(runErrors, 1)
        XCTAssertEqual(controller.jobs.map(\.state), [.failed, .completed])
        XCTAssertEqual(pipeline.transcribedFiles, ["bad.mov", "good.mov"])
    }

    func testQueueCancelsOnlyActiveVideoAndContinues() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["cancel.mov": "en", "next.mov": "en"],
            transcriptionDelay: 200_000_000
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/cancel.mov"), URL(fileURLWithPath: "/tmp/next.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.allSatisfy { $0.state == .ready } }
        controller.setDestinations(Dictionary(uniqueKeysWithValues: controller.jobs.map {
            ($0.id, [.english: OutputDestination.assumingAbsent(
                URL(fileURLWithPath: "/tmp/\($0.videoURL.lastPathComponent).srt")
            )])
        }))
        controller.beginQueue()
        controller.startNext(
            translators: [:], onError: { _ in }
        )
        try await waitUntil { controller.isRunning }
        controller.cancelActiveAndContinue()
        try await waitUntil { controller.nextJobID == controller.jobs[1].id }
        controller.startNext(
            translators: [:], onError: { _ in }
        )
        try await waitUntil(timeoutIterations: 100) { !controller.isQueueActive }

        XCTAssertEqual(controller.jobs.map(\.state), [.cancelled, .completed])
    }

    func testVideoAddedDuringRunIsInspectedAfterPipelineBecomesFree() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["first.mov": "en", "added.mov": "en"],
            transcriptionDelay: 150_000_000
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/first.mov")],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.first?.state == .ready }
        let firstID = try XCTUnwrap(controller.jobs.first?.id)
        controller.setDestinations([
            firstID: [.english: OutputDestination.assumingAbsent(
                URL(fileURLWithPath: "/tmp/first.en.srt")
            )]
        ])
        controller.beginQueue()
        controller.startNext(
            translators: [:], onError: { _ in }
        )
        try await waitUntil { controller.isRunning }
        controller.addVideos(
            [URL(fileURLWithPath: "/tmp/added.mov")],
            sourceLanguage: .french,
            targetLanguages: [.german],
            onError: { error in XCTFail("Unexpected deferred inspection error: \(error)") }
        )
        XCTAssertEqual(controller.jobs[1].state, .waitingForInspection)
        try await waitUntil(timeoutIterations: 100) { controller.jobs[1].state == .needsAttention }

        XCTAssertEqual(controller.jobs[0].state, .completed)
        XCTAssertEqual(controller.jobs[1].sourceLanguage, .french)
        XCTAssertEqual(controller.jobs[1].targetLanguages, [.german])
        XCTAssertFalse(controller.isQueueActive)
    }

    func testQueueDeduplicatesVideosAndRejectsEmptyTargetUpdates() async throws {
        let pipeline = QueueControllerPipeline(detectedCodes: ["same.mov": "en"])
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        let video = URL(fileURLWithPath: "/tmp/same.mov")
        controller.addVideos(
            [video, video],
            sourceLanguage: .english,
            targetLanguages: [.russian],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.first?.state == .ready }
        XCTAssertEqual(controller.jobs.count, 1)
        let id = try XCTUnwrap(controller.jobs.first?.id)
        controller.updateTargetLanguages([], for: id)
        XCTAssertEqual(controller.jobs.first?.targetLanguages, [.russian])
    }

    func testQueuePauseRestartsCurrentVideoFromBeginning() async throws {
        let pipeline = QueueControllerPipeline(
            detectedCodes: ["pause.mov": "en"],
            transcriptionDelay: 200_000_000
        )
        let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
        let video = URL(fileURLWithPath: "/tmp/pause.mov")
        controller.addVideos(
            [video],
            sourceLanguage: .english,
            targetLanguages: [.english],
            onError: { error in XCTFail("Unexpected inspection error: \(error)") }
        )
        try await waitUntil { controller.jobs.first?.state == .ready }
        let jobID = try XCTUnwrap(controller.jobs.first?.id)
        controller.setDestinations([
            jobID: [.english: OutputDestination.assumingAbsent(
                URL(fileURLWithPath: "/tmp/pause.en.srt")
            )]
        ])
        controller.beginQueue()
        controller.startNext(
            translators: [:],
            onError: { error in XCTFail("Unexpected run error: \(error)") }
        )
        try await waitUntil { controller.isRunning }
        controller.pauseQueue()
        try await waitUntil { controller.jobs.first?.state == .paused }

        controller.beginQueue()
        controller.startNext(
            translators: [:],
            onError: { error in XCTFail("Unexpected resumed error: \(error)") }
        )
        try await waitUntil(timeoutIterations: 100) { controller.jobs.first?.state == .completed }

        XCTAssertEqual(pipeline.transcribedFiles, ["pause.mov", "pause.mov"])
    }

    func testPauseDuringEveryInterruptiblePipelineStage() async throws {
        try await assertQueueInterruptionAcrossEveryStage(
            action: { $0.pauseQueue() },
            expectedState: .paused
        )
    }

    func testSkipDuringEveryInterruptiblePipelineStage() async throws {
        try await assertQueueInterruptionAcrossEveryStage(
            action: { $0.cancelActiveAndContinue() },
            expectedState: .cancelled
        )
    }

    func testShutdownDuringEveryInterruptiblePipelineStage() async throws {
        try await assertQueueInterruptionAcrossEveryStage(
            action: { $0.stopForShutdown() },
            expectedState: .paused
        )
    }

    private func assertQueueInterruptionAcrossEveryStage(
        action: (TranscriptionQueueController) -> Void,
        expectedState: TranscriptionQueueJobState
    ) async throws {
        for stage in PipelineStage.allCases where stage != .done {
            let pipeline = StageBlockingControllerPipeline(stage: stage)
            let controller = TranscriptionQueueController(pipeline: pipeline, logBuffer: LogBuffer())
            let video = URL(fileURLWithPath: "/tmp/\(stage.id)-\(UUID().uuidString).mov")
            controller.addVideos(
                [video],
                sourceLanguage: .english,
                targetLanguages: [.english],
                onError: { error in XCTFail("Unexpected inspection error at \(stage): \(error)") }
            )
            try await waitUntil { controller.jobs.first?.state == .ready }
            let jobID = try XCTUnwrap(controller.jobs.first?.id)
            controller.setDestinations([
                jobID: [.english: OutputDestination.assumingAbsent(
                    URL(fileURLWithPath: "/tmp/\(UUID().uuidString).en.srt")
                )]
            ])
            controller.beginQueue()
            controller.startNext(
                translators: [:],
                onError: { error in XCTFail("Unexpected run error at \(stage): \(error)") }
            )
            try await waitUntil { controller.currentStage == stage && controller.isRunning }

            action(controller)
            try await waitUntil { controller.jobs.first?.state == expectedState }

            XCTAssertEqual(controller.jobs.first?.stoppedStage, stage)
            XCTAssertEqual(pipeline.stopCount, 1)
        }
    }

    func testAppearanceModeCyclesAndPersists() {
        let suiteName = "QuickSRTTests.appearance.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated preferences")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("light", forKey: "QuickSRT.appearance")
        let first = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )
        XCTAssertEqual(first.appearanceMode, .light)
        first.cycleAppearance()
        XCTAssertEqual(first.appearanceMode, .dark)

        let reloaded = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )
        XCTAssertEqual(reloaded.appearanceMode, .dark)
        reloaded.cycleAppearance()
        XCTAssertEqual(reloaded.appearanceMode, .light)
    }

    func testLegacySystemAppearanceMigratesToOneOfTwoVisibleThemes() {
        let suiteName = "QuickSRTTests.appearance-migration.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated preferences")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("system", forKey: "QuickSRT.appearance")

        let model = AppViewModel(
            modelEnvironment: makeModelEnvironment(),
            pipeline: SuccessfulControllerPipeline(),
            preferences: preferences
        )

        XCTAssertTrue([AppAppearanceMode.light, .dark].contains(model.appearanceMode))
        XCTAssertEqual(
            preferences.string(forKey: "QuickSRT.appearance"),
            model.appearanceMode.rawValue
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for controller state")
    }

    private func makeModelEnvironment() -> ModelManagerEnvironment {
        ModelManagerEnvironment(
            python: URL(fileURLWithPath: "/runtime/python"),
            downloader: URL(fileURLWithPath: "/scripts/downloader.py"),
            repositoryID: "example/model",
            modelsRoot: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            resolveModel: { nil },
            selectModel: { _ in nil },
            useManagedModel: { nil },
            isManagedModel: { _ in false },
            acquireOperationLock: {
                try InterprocessFileLock.acquire(
                    at: FileManager.default.temporaryDirectory
                        .appendingPathComponent("interface-language-test-\(UUID().uuidString).lock")
                )
            },
            cleanPartialDownloads: { CleanupReport() },
            cleanPartialDownloadsWhileLocked: { CleanupReport() },
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
    }
}

private final class SuccessfulControllerPipeline: TranscriptionPipelineRunning, @unchecked Sendable {
    func probe(videoURL: URL) async throws -> VideoInfo {
        VideoInfo(duration: 12, hasAudio: true)
    }

    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        outputs: [SubtitleOutputRequest],
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        status(PipelineProgressUpdate(
            stage: .transcribingSpeech,
            overallProgress: 0.5,
            stageElapsed: 2,
            stageETA: 3
        ))
        status(PipelineProgressUpdate(
            stage: .done,
            overallProgress: 1,
            stageElapsed: 5,
            stageETA: 0
        ))
        log(.raw("controller pipeline completed\n"))
        return TranscriptionResult(
            outputURLs: outputs.map(\.destinationURL),
            qualityReport: nil
        )
    }

    func stop() {}
}

private final class QueueControllerPipeline: TranscriptionPipelineRunning, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "QuickSRTTests.QueueControllerPipeline")
    private let detectedCodes: [String: String]
    private let detections: [String: LanguageDetectionResult]
    private let transcriptionDelay: UInt64
    private let failingTranscriptions: Set<String>
    private let qualityWarningTranscriptions: Set<String>
    private let partialTargetFailureTranscriptions: Set<String>
    private var detectionFailuresRemaining: [String: Int]
    private(set) var transcribedFiles: [String] = []
    private(set) var maximumConcurrentTranscriptions = 0
    private var concurrentTranscriptions = 0

    init(
        detectedCodes: [String: String],
        detections: [String: LanguageDetectionResult] = [:],
        detectionFailuresRemaining: [String: Int] = [:],
        failingTranscriptions: Set<String> = [],
        qualityWarningTranscriptions: Set<String> = [],
        partialTargetFailureTranscriptions: Set<String> = [],
        transcriptionDelay: UInt64 = 15_000_000
    ) {
        self.detectedCodes = detectedCodes
        self.detections = detections
        self.detectionFailuresRemaining = detectionFailuresRemaining
        self.failingTranscriptions = failingTranscriptions
        self.qualityWarningTranscriptions = qualityWarningTranscriptions
        self.partialTargetFailureTranscriptions = partialTargetFailureTranscriptions
        self.transcriptionDelay = transcriptionDelay
    }

    func probe(videoURL: URL) async throws -> VideoInfo {
        VideoInfo(duration: 20, hasAudio: true)
    }

    func detectLanguage(videoURL: URL) async throws -> LanguageDetectionResult {
        let name = videoURL.lastPathComponent
        let shouldFail = stateQueue.sync { () -> Bool in
            let remaining = detectionFailuresRemaining[name] ?? 0
            guard remaining > 0 else { return false }
            detectionFailuresRemaining[name] = remaining - 1
            return true
        }
        if shouldFail { throw QuickSRTError.languageDetectionFailed }
        if let result = detections[name] { return result }
        return LanguageDetectionResult(
            languageCode: detectedCodes[name] ?? "en",
            confidence: 0.95,
            runnerUpConfidence: 0.02
        )
    }

    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        outputs: [SubtitleOutputRequest],
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        stateQueue.sync {
            concurrentTranscriptions += 1
            maximumConcurrentTranscriptions = max(maximumConcurrentTranscriptions, concurrentTranscriptions)
            transcribedFiles.append(videoURL.lastPathComponent)
        }
        defer {
            stateQueue.sync { concurrentTranscriptions -= 1 }
        }
        status(PipelineProgressUpdate(
            stage: .transcribingSpeech,
            overallProgress: 0.5,
            stageElapsed: 1,
            stageETA: 1
        ))
        log(.raw("queue job: \(videoURL.lastPathComponent)\n"))
        try await Task.sleep(nanoseconds: transcriptionDelay)
        if failingTranscriptions.contains(videoURL.lastPathComponent) {
            throw QuickSRTError.commandFailed(label: "Whisper", exitCode: 2, details: "test failure")
        }
        let report = qualityWarningTranscriptions.contains(videoURL.lastPathComponent)
            ? SubtitleQualityReport(
                inputSegments: 24,
                outputSegments: 24,
                removedSegments: 0,
                overlapsAdjusted: 0,
                decoderLoopsTrimmed: 0,
                syntheticWordTimingSegments: 2,
                requiresUserWarning: true
            )
            : nil
        let targetResults = outputs.enumerated().map { index, output in
            let status: SubtitleTargetStatus
            if partialTargetFailureTranscriptions.contains(videoURL.lastPathComponent), index == 0 {
                status = .failed(.invalidLayout)
            } else if qualityWarningTranscriptions.contains(videoURL.lastPathComponent) {
                status = .savedWithWarnings
            } else {
                status = .saved
            }
            return SubtitleTargetResult(
                language: output.language,
                destinationURL: output.destinationURL,
                status: status,
                warningCount: status == .savedWithWarnings ? 2 : 0
            )
        }
        return TranscriptionResult(targetResults: targetResults, qualityReport: report)
    }

    func stop() {}
}

private final class StageBlockingControllerPipeline: TranscriptionPipelineRunning, @unchecked Sendable {
    private let stage: PipelineStage
    private let lock = NSLock()
    private var storedStopCount = 0

    init(stage: PipelineStage) {
        self.stage = stage
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func probe(videoURL: URL) async throws -> VideoInfo {
        VideoInfo(duration: 20, hasAudio: true)
    }

    func detectLanguage(videoURL: URL) async throws -> LanguageDetectionResult {
        LanguageDetectionResult(languageCode: "en", confidence: 0.99, runnerUpConfidence: 0.01)
    }

    func transcribe(
        videoURL: URL,
        sourceLanguage: RecognitionLanguage,
        outputs: [SubtitleOutputRequest],
        status: @escaping @Sendable (PipelineProgressUpdate) -> Void,
        log: @escaping @Sendable (AppLogEvent) -> Void
    ) async throws -> TranscriptionResult {
        status(PipelineProgressUpdate(
            stage: stage,
            overallProgress: 0.5,
            stageElapsed: 1,
            stageETA: 10
        ))
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return TranscriptionResult(outputURLs: outputs.map(\.destinationURL), qualityReport: nil)
    }

    func stop() {
        lock.withLock {
            storedStopCount += 1
        }
    }
}

private final class NoOpTestTranslator: SubtitleTranslating, @unchecked Sendable {
    func translate(texts: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        progress(1)
        return texts
    }

    func cancel() {}
}
