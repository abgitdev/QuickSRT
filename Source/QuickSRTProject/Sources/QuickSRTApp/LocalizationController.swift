import Combine
import Foundation

enum AppProcessLabel {
    static let modelDownload = "QuickSRT.ModelDownload"

    static func localized(_ label: String, language: AppLanguage) -> String {
        label == modelDownload ? TextKey.processModelDownload.text(language) : label
    }
}

enum AppDisplayError: Sendable {
    case runtime(RuntimeDiagnosticIssue)
    case quickSRT(QuickSRTError)
    case external(String)

    init(_ error: Error) {
        if let runtimeIssue = error as? RuntimeDiagnosticIssue {
            self = .runtime(runtimeIssue)
        } else if let quickError = error as? QuickSRTError {
            self = .quickSRT(quickError)
        } else {
            self = .external(error.localizedDescription)
        }
    }

    var technicalDetails: String? {
        switch self {
        case let .external(message):
            return message
        case let .quickSRT(.translationFailed(details)),
             let .quickSRT(.invalidTimeline(details)):
            return details
        case let .quickSRT(.cleanupFailed(primaryFailure, failures)):
            let failureText = failures
                .map { "\($0.path): \($0.reason)" }
                .joined(separator: "\n")
            return [primaryFailure, failureText].compactMap { $0 }.joined(separator: "\n")
        default:
            return nil
        }
    }

    func rendered(in language: AppLanguage) -> String {
        switch self {
        case let .runtime(issue):
            switch issue {
            case .missingPython:
                return TextKey.runtimeMissingPython.text(language)
            case .missingModelDownloader:
                return TextKey.runtimeMissingModelDownloader.text(language)
            }
        case let .quickSRT(error):
            return render(error, language: language)
        case .external:
            return TextKey.operationFailed.text(language)
        }
    }

    private func render(_ error: QuickSRTError, language: AppLanguage) -> String {
        switch error {
        case let .missingExecutable(name, _):
            return format(.componentUnavailableFormat, language: language, name)
        case .missingVenvPython:
            return TextKey.runtimeMissingPython.text(language)
        case .missingModel:
            return TextKey.modelNotFound.text(language)
        case let .modelDoesNotSupportLanguage(recognitionLanguage):
            return format(
                .unsupportedLanguageFormat,
                language: language,
                recognitionLanguage.localizedName(language)
            )
        case let .invalidVideo(failure):
            return videoFailureText(failure, language: language)
        case let .invalidSRT(failure):
            return format(
                .invalidSRTFormat,
                language: language,
                srtFailureText(failure, language: language)
            )
        case .invalidTimeline:
            return TextKey.translationOutputInvalid.text(language)
        case .translationRequiresNewerMacOS:
            return TextKey.translationRequiresNewerMacOS.text(language)
        case let .translationPairUnsupported(source, target):
            return format(
                .translationPairUnsupportedFormat,
                language: language,
                source.localizedName(language),
                target.localizedName(language)
            )
        case .translationNotReady:
            return TextKey.translationNotReady.text(language)
        case .translationFailed:
            return TextKey.translationFailed.text(language)
        case .translationOutputInvalid:
            return TextKey.translationOutputInvalid.text(language)
        case .languageDetectionFailed:
            return TextKey.languageDetectionFailed.text(language)
        case .operationAlreadyRunning:
            return TextKey.operationAlreadyRunning.text(language)
        case .operationLockUnavailable:
            return TextKey.operationLockUnavailable.text(language)
        case let .processOutputLineTooLong(label, maximumBytes):
            return format(
                .processOutputLineTooLongFormat,
                language: language,
                AppProcessLabel.localized(label, language: language),
                Int64(maximumBytes)
            )
        case let .videoDurationLimitExceeded(maximum):
            return format(
                .videoDurationLimitFormat,
                language: language,
                DurationFormatter.string(from: maximum)
            )
        case let .insufficientWorkspaceSpace(requiredBytes, availableBytes):
            return format(
                .insufficientDiskSpaceFormat,
                language: language,
                ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .memory),
                ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .memory)
            )
        case let .insufficientAvailableMemory(requiredBytes, availableBytes):
            return format(
                .insufficientMemoryFormat,
                language: language,
                ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .memory),
                ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .memory)
            )
        case .outputDestinationChanged:
            return TextKey.targetFailureSaveFailed.text(language)
        case let .cleanupFailed(_, failures):
            return format(.cleanupFailedFormat, language: language, Int64(failures.count))
        case let .commandFailed(label, exitCode, details):
            return format(
                .commandFailedFormat,
                language: language,
                AppProcessLabel.localized(label, language: language),
                Int64(exitCode),
                details
            )
        case let .timeout(label, seconds):
            return format(
                .timeoutFormat,
                language: language,
                AppProcessLabel.localized(label, language: language),
                DurationFormatter.string(from: seconds)
            )
        case .outputMissing:
            return TextKey.outputMissing.text(language)
        }
    }

    private func videoFailureText(
        _ failure: VideoValidationFailure,
        language: AppLanguage
    ) -> String {
        switch failure {
        case .invalidProbeOutput: return TextKey.videoInvalidProbeOutput.text(language)
        case .invalidDescription: return TextKey.videoInvalidDescription.text(language)
        case .noAudioTrack: return TextKey.videoNoAudio.text(language)
        case .durationUnavailable: return TextKey.videoDurationUnavailable.text(language)
        case .runnerUnavailable: return TextKey.videoRunnerUnavailable.text(language)
        }
    }

    private func srtFailureText(
        _ failure: SRTValidationFailure,
        language: AppLanguage
    ) -> String {
        switch failure {
        case .notRegularFile: return TextKey.srtNotRegularFile.text(language)
        case .emptyFile: return TextKey.srtEmptyFile.text(language)
        case .unexpectedlyLarge: return TextKey.srtTooLarge.text(language)
        case .invalidUTF8: return TextKey.srtInvalidUTF8.text(language)
        case .noCues: return TextKey.srtNoCues.text(language)
        case let .cueMissingText(index):
            return format(.srtCueMissingTextFormat, language: language, Int64(index))
        case let .invalidNumbering(index):
            return format(.srtInvalidNumberingFormat, language: language, Int64(index))
        case let .invalidTimestamps(index):
            return format(.srtInvalidTimestampsFormat, language: language, Int64(index))
        case let .emptyCueText(index):
            return format(.srtEmptyCueTextFormat, language: language, Int64(index))
        }
    }

    private func format(
        _ key: TextKey,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        key.formatted(language: language, arguments: arguments)
    }
}

@MainActor
final class LocalizationController: ObservableObject {
    @Published var language: AppLanguage

    init(language: AppLanguage = .english) {
        self.language = language
    }

    func text(_ key: TextKey) -> String {
        key.text(language)
    }

    func durationText(duration: TimeInterval?, isInspecting: Bool) -> String {
        if let duration {
            return format(.durationFormat, DurationFormatter.string(from: duration))
        }
        return text(isInspecting ? .durationChecking : .durationDash)
    }

    func etaText(for timing: JobStageTiming?) -> String {
        guard let timing, timing.eta != 0 else { return "" }
        guard let eta = timing.eta, eta.isFinite, eta >= 0 else {
            return text(.estimating)
        }
        return format(.etaRemainingFormat, DurationFormatter.string(from: eta))
    }

    func stageTimingText(for timing: JobStageTiming) -> String {
        let elapsed = DurationFormatter.string(from: timing.elapsed)
        if timing.eta == 0 {
            return "\(text(.ok)) · \(elapsed)"
        }
        guard let eta = timing.eta, eta.isFinite, eta >= 0 else {
            return format(.elapsedFormat, elapsed)
        }
        let remaining = DurationFormatter.string(from: eta)
        return format(.elapsedRemainingFormat, elapsed, remaining)
    }

    func modelLocationText(isManaged: Bool, path: String) -> String {
        format(isManaged ? .managedFolderFormat : .externalModelFormat, path)
    }

    func outputLanguageText(
        source: RecognitionLanguage,
        target: RecognitionLanguage
    ) -> String {
        format(
            .outputTranslationFormat,
            source.targetPickerTitle(language),
            target.targetPickerTitle(language),
            target.rawValue
        )
    }

    func qualityWarning(for report: SubtitleQualityReport) -> (title: String, message: String) {
        (
            text(.qualityWarningTitle),
            format(
                .qualityWarningFormat,
                Int64(report.removedSegments),
                Int64(report.inputSegments),
                Int64(report.retainedLowConfidenceSegments),
                Int64(report.syntheticWordTimingSegments)
            )
        )
    }

    func outputSummary(for result: TranscriptionResult) -> (title: String, message: String) {
        let saved = result.targetResults.filter(\.wasSaved).count
        let failedLines = result.targetResults.compactMap { target -> String? in
            guard case let .failed(reason) = target.status else { return nil }
            return "\(target.language.title): \(text(reason.textKey))"
        }
        var lines = [
            format(.outputSummaryFormat, Int64(saved), Int64(result.targetResults.count))
        ]
        lines.append(contentsOf: failedLines)
        return (text(.outputSummaryTitle), lines.joined(separator: "\n"))
    }

    func errorMessage(for error: Error) -> String {
        AppDisplayError(error).rendered(in: language)
    }

    private func format(_ key: TextKey, _ arguments: CVarArg...) -> String {
        key.formatted(language: language, arguments: arguments)
    }
}
