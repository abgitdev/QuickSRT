import AppKit
@preconcurrency import Combine
import Foundation

@MainActor
final class AppViewModel: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private static let appLanguagePreferenceKey = "QuickSRT.appLanguage"
    private static let recognitionLanguagePreferenceKey = "QuickSRT.recognitionLanguage"
    private static let subtitleLanguagePreferenceKey = "QuickSRT.subtitleLanguage"
    private static let subtitleLanguagesPreferenceKey = "QuickSRT.subtitleLanguages"
    private static let appearancePreferenceKey = "QuickSRT.appearance"

    private let localization: LocalizationController
    private let logBuffer: LogBuffer
    private let outputFileManager: OutputFileManager
    private let modelManager: ModelManager
    private let queueController: TranscriptionQueueController
    private let preferences: UserDefaults
    private var storedRecognitionLanguage: RecognitionLanguage
    private var storedSubtitleLanguages: Set<RecognitionLanguage>
    private var storedAppearanceMode: AppAppearanceMode
    private var cancellables: Set<AnyCancellable> = []

    init(
        localization: LocalizationController? = nil,
        logBuffer: LogBuffer? = nil,
        outputFileManager: OutputFileManager? = nil,
        runtimeDiagnostics: RuntimeDiagnostics = RuntimeDiagnostics(),
        modelEnvironment: ModelManagerEnvironment = .live,
        pipeline: TranscriptionPipelineRunning = TranscriptionPipeline(),
        preferences: UserDefaults = .standard,
        preferredAppLanguages: [String] = Locale.preferredLanguages
    ) {
        let resolvedLocalization: LocalizationController
        if let providedLocalization = localization {
            resolvedLocalization = providedLocalization
        } else if let storedLanguage = preferences.string(forKey: Self.appLanguagePreferenceKey) {
            resolvedLocalization = LocalizationController(
                language: AppLanguage(rawValue: storedLanguage) ?? .english
            )
        } else {
            resolvedLocalization = LocalizationController(
                language: AppLanguage.preferred(from: preferredAppLanguages)
            )
        }
        let logBuffer = logBuffer ?? LogBuffer()
        self.preferences = preferences
        self.storedRecognitionLanguage = RecognitionLanguage(
            rawValue: preferences.string(forKey: Self.recognitionLanguagePreferenceKey) ?? ""
        ) ?? .english
        let restoredTargets = Set(
            (preferences.stringArray(forKey: Self.subtitleLanguagesPreferenceKey) ?? [])
                .compactMap(RecognitionLanguage.init(rawValue:))
        )
        let legacyTarget = RecognitionLanguage(
            rawValue: preferences.string(forKey: Self.subtitleLanguagePreferenceKey) ?? ""
        ) ?? .russian
        self.storedSubtitleLanguages = restoredTargets.isEmpty ? [legacyTarget] : restoredTargets
        let appearanceMode = AppAppearanceMode(
            rawValue: preferences.string(forKey: Self.appearancePreferenceKey) ?? ""
        ) ?? Self.currentSystemAppearanceMode
        self.storedAppearanceMode = appearanceMode
        preferences.set(appearanceMode.rawValue, forKey: Self.appearancePreferenceKey)
        self.localization = resolvedLocalization
        self.logBuffer = logBuffer
        self.outputFileManager = outputFileManager ?? OutputFileManager()
        self.modelManager = ModelManager(
            environment: modelEnvironment,
            diagnostics: runtimeDiagnostics,
            logBuffer: logBuffer
        )
        self.queueController = TranscriptionQueueController(
            pipeline: pipeline,
            logBuffer: logBuffer
        )
        observeChildChanges()
        applyAppearance()
    }

    var selectedVideoURL: URL? { queueController.selectedVideoURL }
    var selectedFileName: String {
        selectedVideoURL?.lastPathComponent ?? text(.noVideo)
    }
    var durationText: String {
        localization.durationText(
            duration: queueController.videoInfo?.duration,
            isInspecting: queueController.isInspecting
        )
    }
    var appLanguage: AppLanguage {
        get { localization.language }
        set {
            guard newValue != localization.language else { return }
            localization.language = newValue
            preferences.set(newValue.rawValue, forKey: Self.appLanguagePreferenceKey)
        }
    }
    var appearanceMode: AppAppearanceMode { storedAppearanceMode }
    var appearanceHelpText: String {
        TextKey.themeHelpFormat.formatted(
            language: appLanguage,
            arguments: [text(storedAppearanceMode.textKey)]
        )
    }
    func cycleAppearance() {
        objectWillChange.send()
        storedAppearanceMode = storedAppearanceMode.next
        preferences.set(storedAppearanceMode.rawValue, forKey: Self.appearancePreferenceKey)
        applyAppearance()
    }
    var recognitionLanguage: RecognitionLanguage {
        get { queueController.selectedJob?.sourceLanguage ?? storedRecognitionLanguage }
        set {
            objectWillChange.send()
            storedRecognitionLanguage = newValue
            preferences.set(newValue.rawValue, forKey: Self.recognitionLanguagePreferenceKey)
            if let id = queueController.selectedJobID {
                queueController.updateSourceLanguage(newValue, for: id)
            }
        }
    }
    var subtitleLanguage: RecognitionLanguage {
        get { selectedSubtitleLanguages.first ?? .russian }
        set {
            objectWillChange.send()
            storedSubtitleLanguages = [newValue]
            persistSubtitleLanguages()
            if let id = queueController.selectedJobID {
                queueController.updateTargetLanguages([newValue], for: id)
            }
        }
    }
    var subtitleLanguages: Set<RecognitionLanguage> {
        queueController.selectedJob?.targetLanguages ?? storedSubtitleLanguages
    }
    var selectedSubtitleLanguages: [RecognitionLanguage] {
        RecognitionLanguage.allCases.filter(subtitleLanguages.contains)
    }
    var subtitleLanguageSummary: String {
        let selected = selectedSubtitleLanguages
        if selected.count == 1, let language = selected.first {
            return language.targetPickerTitle(appLanguage)
        }
        let visible = selected.prefix(4).map(\.title)
        let remainder = selected.count - visible.count
        return (visible + (remainder > 0 ? ["+\(remainder)"] : [])).joined(separator: " · ")
    }
    var outputLanguageNote: String {
        let selected = selectedSubtitleLanguages
        guard selected.count == 1, let target = selected.first else {
            let suffixes = selected.map { ".\($0.rawValue).srt" }.joined(separator: " · ")
            return "\(recognitionLanguage.title) → \(suffixes)"
        }
        return localization.outputLanguageText(
            source: recognitionLanguage,
            target: target
        )
    }
    var statusText: String { text(queueStatusKey(queueController.displayJob?.state)) }
    var logText: String { logBuffer.renderedText(in: appLanguage) }
    var isRunning: Bool { queueController.isRunning }
    var isInspecting: Bool { queueController.isInspecting }
    var isQueueActive: Bool { queueController.isQueueActive }
    var outputURL: URL? { queueController.outputURLs.first }
    var outputURLs: [URL] { queueController.outputURLs }
    var progressValue: Double { queueController.progressValue }
    var currentStage: PipelineStage? { queueController.currentStage }
    var failedStage: PipelineStage? { queueController.failedStage }
    var stoppedStage: PipelineStage? { queueController.stoppedStage }
    var finishedSuccessfully: Bool { queueController.finishedSuccessfully }
    var finishedWithPartialExport: Bool { queueController.finishedWithPartialExport }
    var queueJobs: [TranscriptionQueueJob] { queueController.jobs }
    var selectedQueueJobID: UUID? { queueController.selectedJobID }
    var nextQueueJobID: UUID? { queueController.nextJobID }
    var requiredTranslationPairs: [TranslationPair] { queueController.allRequiredTranslationPairs }
    var translatorResetRevision: Int { queueController.translatorResetRevision }
    var canEditSelectedJob: Bool { queueController.selectedJob?.state.isEditable ?? true }
    var isModelInstalled: Bool { modelManager.isInstalled }
    var isDownloadingModel: Bool { modelManager.isDownloading }
    var modelPathText: String { modelManager.pathText }
    var modelIsManaged: Bool { modelManager.isManaged }
    var currentETAText: String {
        localization.etaText(for: queueController.currentTiming)
    }
    var stageTimingText: [PipelineStage: String] {
        queueController.stageTimings.reduce(into: [:]) { result, item in
            result[item.key] = localization.stageTimingText(for: item.value)
        }
    }
    var modelLocationText: String {
        localization.modelLocationText(
            isManaged: modelManager.isManaged,
            path: modelManager.pathText
        )
    }

    var canStart: Bool {
        queueController.canBeginQueue
            && isModelInstalled
            && !isDownloadingModel
    }

    var isBusy: Bool {
        isDownloadingModel
    }

    func selectVideo() {
        let panel = NSOpenPanel()
        panel.title = text(.chooseVideoPanelTitle)
        panel.prompt = text(.choose)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        queueController.addVideos(
            panel.urls,
            sourceLanguage: storedRecognitionLanguage,
            targetLanguages: storedSubtitleLanguages,
            onError: presentAndLogError
        )
    }

    func toggleSubtitleLanguage(_ language: RecognitionLanguage) {
        objectWillChange.send()
        var updated = subtitleLanguages
        if updated.contains(language) {
            guard updated.count > 1 else { return }
            updated.remove(language)
        } else {
            updated.insert(language)
        }
        storedSubtitleLanguages = updated
        persistSubtitleLanguages()
        if let id = queueController.selectedJobID {
            queueController.updateTargetLanguages(updated, for: id)
        }
    }

    func start(translators: [TranslationPair: SubtitleTranslating]) {
        var reservedDestinationKeys = Set<String>()
        for job in queueJobs where job.state.isRunnable {
            if let issue = modelManager.transcriptionIssue(for: job.sourceLanguage) {
                presentAndLogError(issue)
                return
            }
            var destinations = job.destinations.filter { job.targetLanguages.contains($0.key) }
            for target in job.selectedTargets {
                guard let destination = destinations[target] else { continue }
                let key = OutputFileManager.reservationKey(for: destination.url)
                if !reservedDestinationKeys.insert(key).inserted {
                    destinations[target] = nil
                }
            }
            for target in job.selectedTargets where destinations[target] == nil {
                let destination: OutputDestination
                do {
                    guard let resolved = try outputFileManager.resolveDestination(
                        for: job.videoURL,
                        targetLanguage: target,
                        localization: localization,
                        avoiding: reservedDestinationKeys
                    ) else { return }
                    destination = resolved
                } catch {
                    presentAndLogError(error)
                    return
                }
                guard reservedDestinationKeys.insert(
                    OutputFileManager.reservationKey(for: destination.url)
                ).inserted else {
                    presentAndLogError(QuickSRTError.outputDestinationChanged)
                    return
                }
                destinations[target] = destination
            }
            guard queueController.setDestinations([job.id: destinations]) else {
                presentAndLogError(QuickSRTError.outputDestinationChanged)
                return
            }
        }
        queueController.beginQueue()
        continueQueue(translators: translators)
    }

    func continueQueue(translators: [TranslationPair: SubtitleTranslating]) {
        queueController.startNext(
            translators: translators,
            onError: recordQueueError
        )
    }

    func stop() {
        queueController.pauseQueue()
    }

    func cancelActiveAndContinue() {
        queueController.cancelActiveAndContinue()
    }

    func selectQueueJob(_ id: UUID) {
        queueController.selectJob(id)
    }

    func moveQueueJob(_ id: UUID, offset: Int) {
        queueController.moveJob(id, offset: offset)
    }

    func removeQueueJob(_ id: UUID) {
        queueController.removeJob(id)
    }

    func useDetectedLanguage(for id: UUID) {
        queueController.useDetectedLanguage(for: id)
    }

    func keepSelectedLanguage(for id: UUID) {
        queueController.keepSelectedLanguage(for: id)
    }

    func retryLanguageDetection(for id: UUID) {
        queueController.retryLanguageDetection(for: id, onError: presentAndLogError)
    }

    func downloadModel() {
        guard !isDownloadingModel, !isRunning else { return }
        modelManager.download(
            onStarted: { [weak self] in
                self?.logBuffer.clear()
            },
            onError: presentAndLogError
        )
    }

    func stopModelDownload() {
        modelManager.stopDownload()
    }

    func openModelFolder() {
        modelManager.openModelFolder()
    }

    func chooseExistingModel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = text(.modelChooseExisting)
        panel.prompt = text(.choose)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectPaths.mlxWhisperModelsRoot

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard modelManager.selectModel(at: selected) else {
            showError(text(.modelInvalidFolder))
            return
        }
    }

    func refreshModelStatus() {
        modelManager.refreshStatus()
        queueController.refreshInspections(onError: presentAndLogError)
    }

    func stopForShutdown() {
        queueController.stopForShutdown()
        modelManager.stopForShutdown()
        ProcessRegistry.shared.terminateAll()
    }

    func presentCleanupReportIfNeeded(_ report: CleanupReport) {
        guard !report.isSuccessful else { return }
        logBuffer.append(.cleanupFailed(count: report.failures.count))
        showLifecycleReport(report, removedCount: report.removedPaths.count)
    }

    func requestDeleteQuickSRTData() {
        guard let deleteOutputs = confirmDataRemoval(uninstall: false) else { return }
        Task { await performDataRemoval(deleteOutputs: deleteOutputs, uninstall: false) }
    }

    func requestUninstallQuickSRT() {
        guard let deleteOutputs = confirmDataRemoval(uninstall: true) else { return }
        Task { await performDataRemoval(deleteOutputs: deleteOutputs, uninstall: true) }
    }

    func openOutputInFinder() {
        guard !outputURLs.isEmpty else { return }
        outputFileManager.reveal(outputURLs)
    }

    func clearLog() {
        logBuffer.clear()
    }

    func text(_ key: TextKey) -> String {
        localization.text(key)
    }

    func presentTranslationError(_ error: Error) {
        presentAndLogError(error)
    }

    func queueStateText(_ state: TranscriptionQueueJobState) -> String {
        text(queueStatusKey(state))
    }

    func languageCheckText(for job: TranscriptionQueueJob) -> String? {
        switch job.languageCheck {
        case let .matched(result), let .confirmed(result, _):
            return TextKey.languageDetectedFormat.formatted(
                language: appLanguage,
                arguments: [languageName(for: result.languageCode), Int64((result.confidence * 100).rounded())]
            )
        case let .lowConfidence(result):
            return TextKey.languageLowConfidenceFormat.formatted(
                language: appLanguage,
                arguments: [languageName(for: result.languageCode), Int64((result.confidence * 100).rounded())]
            )
        case let .mismatch(result):
            return TextKey.languageMismatchFormat.formatted(
                language: appLanguage,
                arguments: [
                    job.sourceLanguage.localizedName(appLanguage),
                    languageName(for: result.languageCode),
                    Int64((result.confidence * 100).rounded())
                ]
            )
        case .failed:
            return text(.languageDetectionFailed)
        case .failureAccepted, .pending, .checking:
            return nil
        }
    }

    func queueDurationText(for job: TranscriptionQueueJob) -> String {
        localization.durationText(duration: job.videoInfo?.duration, isInspecting: job.state == .inspecting)
    }

    private func observeChildChanges() {
        localization.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        logBuffer.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.queueController.refreshInspections(onError: self.presentAndLogError)
                }
            }
            .store(in: &cancellables)
        queueController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func persistSubtitleLanguages() {
        let selected = RecognitionLanguage.allCases.filter(storedSubtitleLanguages.contains)
        preferences.set(selected.map(\.rawValue), forKey: Self.subtitleLanguagesPreferenceKey)
        if let first = selected.first {
            preferences.set(first.rawValue, forKey: Self.subtitleLanguagePreferenceKey)
        } else {
            preferences.removeObject(forKey: Self.subtitleLanguagePreferenceKey)
        }
    }

    private func applyAppearance() {
        switch storedAppearanceMode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private static var currentSystemAppearanceMode: AppAppearanceMode {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light
    }

    private func queueStatusKey(_ state: TranscriptionQueueJobState?) -> TextKey {
        switch state {
        case .waitingForInspection: return .queueWaiting
        case .inspecting: return .queueInspecting
        case .needsAttention: return .queueNeedsAttention
        case .ready: return .queueReady
        case .waitingForTranslation: return .queueWaiting
        case .running: return .queueRunning
        case .paused: return .queuePaused
        case .completed: return .queueCompleted
        case .completedWithWarnings: return .queueCompletedWarnings
        case .failed: return .queueFailed
        case .cancelled: return .queueCancelled
        case nil: return .ready
        }
    }

    private func languageName(for code: String) -> String {
        if let language = RecognitionLanguage(rawValue: code) {
            return language.localizedName(appLanguage)
        }
        let locale = Locale(identifier: appLanguage.localeIdentifier)
        return locale.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private func presentAndLogError(_ error: Error) {
        let displayError = AppDisplayError(error)
        let message = displayError.rendered(in: appLanguage)
        logBuffer.append(.error(displayError))
        if let technicalDetails = displayError.technicalDetails {
            logBuffer.append(technicalDetails + "\n")
        }
        showError(message)
    }

    private func recordQueueError(_ error: Error) {
        let displayError = AppDisplayError(error)
        logBuffer.append(.error(displayError))
        if let technicalDetails = displayError.technicalDetails {
            logBuffer.append(technicalDetails + "\n")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "QuickSRT"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: text(.ok))
        alert.runModal()
    }

    private func confirmDataRemoval(uninstall: Bool) -> Bool? {
        let trackedCount = (try? OutputOwnershipManifest.trackedOutputCount()) ?? 0
        let alert = NSAlert()
        alert.messageText = text(uninstall ? .uninstallQuickSRT : .deleteQuickSRTData)
        alert.informativeText = text(.deleteDataMessage) + "\n\n" + text(.dataRemovalLimits)
        alert.alertStyle = .critical
        alert.addButton(withTitle: text(uninstall ? .uninstallQuickSRT : .deleteQuickSRTData))
        alert.addButton(withTitle: text(.cancel))
        if trackedCount > 0 {
            alert.addButton(withTitle: text(.deleteDataAndOutputs))
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return nil }
        guard response == .alertThirdButtonReturn else { return false }

        let outputAlert = NSAlert()
        outputAlert.messageText = text(.deleteDataAndOutputs)
        outputAlert.informativeText = TextKey.deleteTrackedOutputsConfirmFormat.formatted(
            language: appLanguage,
            arguments: [Int64(trackedCount)]
        )
        outputAlert.alertStyle = .critical
        outputAlert.addButton(withTitle: text(.deleteDataAndOutputs))
        outputAlert.addButton(withTitle: text(.cancel))
        return outputAlert.runModal() == .alertFirstButtonReturn ? true : nil
    }

    private func performDataRemoval(deleteOutputs: Bool, uninstall: Bool) async {
        await queueController.stopForShutdownAndWait()
        await modelManager.stopForShutdownAndWait()
        let remainingPIDs = await Task.detached(priority: .userInitiated) {
            ProcessRegistry.shared.terminateAllAndWait()
        }.value
        guard remainingPIDs.isEmpty else {
            var cleanup = CleanupReport()
            cleanup.failed(
                ProjectPaths.tempRoot,
                reason: "Child processes did not exit: \(remainingPIDs.map(String.init).joined(separator: ", "))."
            )
            showLifecycleReport(cleanup, removedCount: 0)
            return
        }

        let report = await Task.detached(priority: .userInitiated) {
            AppDataCleaner.deleteOwnedDataExclusively(deleteTrackedOutputs: deleteOutputs)
        }.value
        showLifecycleReport(report.cleanup, removedCount: report.cleanup.removedPaths.count)
        if !uninstall {
            if report.isSuccessful { modelManager.markDataDeleted() }
            return
        }
        guard report.isSuccessful else { return }

        let ready = NSAlert()
        ready.messageText = text(.uninstallQuickSRT)
        let appParent = Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent()
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let adminNote = appParent == applications
            ? "\n\n" + text(.adminApprovalMayBeRequired)
            : ""
        ready.informativeText = text(.dataRemovalLimits) + adminNote
        ready.alertStyle = .warning
        ready.addButton(withTitle: text(.quitAndMoveToTrash))
        ready.addButton(withTitle: text(.cancel))
        guard ready.runModal() == .alertFirstButtonReturn else { return }

        do {
            _ = try UninstallHelper.launch()
            AppLifecycleState.beginDestructiveExit()
            NSApp.terminate(nil)
        } catch {
            presentAndLogError(error)
        }
    }

    private func showLifecycleReport(_ report: CleanupReport, removedCount: Int) {
        let alert = NSAlert()
        alert.messageText = "QuickSRT"
        if report.isSuccessful {
            alert.informativeText = TextKey.cleanupSuccessFormat.formatted(
                language: appLanguage,
                arguments: [Int64(removedCount)]
            ) + "\n\n" + text(.dataRemovalLimits)
            alert.alertStyle = .informational
        } else {
            let details = report.failures.prefix(12)
                .map { "• \($0.path): \($0.reason)" }
                .joined(separator: "\n")
            alert.informativeText = TextKey.cleanupFailureReportFormat.formatted(
                language: appLanguage,
                arguments: [Int64(report.failures.count)]
            ) + "\n\n" + details
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: text(.ok))
        alert.runModal()
    }

}
