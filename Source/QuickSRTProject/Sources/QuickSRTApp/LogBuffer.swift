import Combine
import Foundation

enum AppLogMessage: Sendable {
    case text(TextKey)
    case stage(PipelineStage, completed: Bool)
    case transcribing(languageCode: String)
    case translating(sourceCode: String, targetCode: String)
    case savingValidatedSRT(completed: Bool)
    case subtitleQuality(SubtitleQualityReport)
    case targetQualityWarnings(targetCode: String, count: Int)
    case targetOutputFailed(targetCode: String, reason: SubtitleTargetFailureReason)
    case outputSummary(saved: Int, total: Int)
    case cleanupFailed(count: Int)
    case outputManifestFailed
    case error(AppDisplayError)

    func rendered(in language: AppLanguage) -> String {
        switch self {
        case let .text(key):
            return key.text(language)
        case let .stage(stage, completed):
            let base = stage.key.text(language) + "…"
            return completed ? "\(base) \(TextKey.ok.text(language))" : base
        case let .transcribing(languageCode):
            return TextKey.logTranscribingFormat.formatted(
                language: language,
                arguments: [languageCode]
            )
        case let .translating(sourceCode, targetCode):
            return TextKey.logTranslatingFormat.formatted(
                language: language,
                arguments: [sourceCode, targetCode]
            )
        case let .savingValidatedSRT(completed):
            let base = TextKey.logSavingValidatedSRT.text(language)
            return completed ? "\(base) \(TextKey.ok.text(language))" : base
        case let .subtitleQuality(report):
            return TextKey.logQualityFormat.formatted(
                language: language,
                arguments: [
                    Int64(report.outputSegments),
                    Int64(report.inputSegments),
                    Int64(report.removedSegments),
                    Int64(report.decoderLoopsTrimmed),
                    Int64(report.overlapsAdjusted),
                    Int64(report.retainedLowConfidenceSegments),
                    Int64(report.syntheticWordTimingSegments)
                ]
            )
        case let .targetQualityWarnings(targetCode, count):
            return TextKey.logTargetQualityWarningsFormat.formatted(
                language: language,
                arguments: [targetCode, Int64(count)]
            )
        case let .targetOutputFailed(targetCode, reason):
            return TextKey.logTargetOutputFailedFormat.formatted(
                language: language,
                arguments: [targetCode, reason.textKey.text(language)]
            )
        case let .outputSummary(saved, total):
            return TextKey.logOutputSummaryFormat.formatted(
                language: language,
                arguments: [Int64(saved), Int64(total)]
            )
        case let .cleanupFailed(count):
            return TextKey.cleanupFailedFormat.formatted(
                language: language,
                arguments: [Int64(count)]
            )
        case .outputManifestFailed:
            return TextKey.outputManifestFailed.text(language)
        case let .error(error):
            return error.rendered(in: language)
        }
    }
}

extension SubtitleTargetFailureReason {
    var textKey: TextKey {
        switch self {
        case .invalidTranslation: return .targetFailureInvalidTranslation
        case .invalidLayout: return .targetFailureInvalidLayout
        case .saveFailed: return .targetFailureSaveFailed
        }
    }
}

enum AppLogEvent: Sendable {
    case localized(AppLogMessage)
    case raw(String)

    var estimatedLength: Int {
        switch self {
        case let .localized(message):
            return message.rendered(in: .english).count + 1
        case let .raw(text):
            return text.count
        }
    }

    func rendered(in language: AppLanguage) -> String {
        switch self {
        case let .localized(message):
            return message.rendered(in: language) + "\n"
        case let .raw(text):
            return text
        }
    }
}

@MainActor
final class LogBuffer: ObservableObject {
    @Published private var entries: [AppLogEvent] = []

    private let maximumCharacters: Int
    private var estimatedCharacters = 0

    init(maximumCharacters: Int = 8_000) {
        self.maximumCharacters = maximumCharacters
    }

    var text: String {
        renderedText(in: .english)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    func append(_ output: String) {
        let sanitized = ProcessOutputSanitizer.sanitize(output)
        guard !sanitized.isEmpty else { return }
        let bounded = sanitized.count > maximumCharacters
            ? String(sanitized.suffix(maximumCharacters))
            : sanitized
        appendEntry(.raw(bounded))
    }

    func append(_ message: AppLogMessage) {
        appendEntry(.localized(message))
    }

    func append(_ event: AppLogEvent) {
        switch event {
        case let .localized(message):
            append(message)
        case let .raw(text):
            append(text)
        }
    }

    func renderedText(in language: AppLanguage) -> String {
        let rendered = entries.map { $0.rendered(in: language) }.joined()
        return rendered.count > maximumCharacters
            ? String(rendered.suffix(maximumCharacters))
            : rendered
    }

    func clear() {
        entries = []
        estimatedCharacters = 0
    }

    private func appendEntry(_ entry: AppLogEvent) {
        entries.append(entry)
        estimatedCharacters += entry.estimatedLength

        while estimatedCharacters > maximumCharacters, entries.count > 1 {
            estimatedCharacters -= entries.removeFirst().estimatedLength
        }
    }
}
