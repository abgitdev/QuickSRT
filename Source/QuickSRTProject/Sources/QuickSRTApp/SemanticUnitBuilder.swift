import Foundation

struct SemanticSourceGroup: Equatable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let sourceText: String
    let wordStart: Int?
    let wordEnd: Int?
    let speaker: String?

    var renderUnit: TranscriptSemanticUnit {
        TranscriptSemanticUnit(
            id: String(id),
            start: start,
            end: end,
            text: sourceText,
            wordStart: wordStart,
            wordEnd: wordEnd,
            speaker: speaker
        )
    }
}

enum SemanticUnitBuilder {
    static let preferredMaximumUnitsPerGroup = 3
    static let preferredMaximumGroupDuration: TimeInterval = 12
    static let maximumUnitsPerGroup = 6
    static let maximumGroupDuration: TimeInterval = 20
    static let maximumGap: TimeInterval = 1
    static let maximumSourceCharacters = 600

    static func build(
        from transcript: TimedTranscript,
        language: RecognitionLanguage
    ) throws -> [SemanticSourceGroup] {
        try TimedTranscriptValidator.validate(transcript)

        var groups: [SemanticSourceGroup] = []
        var pending: [TranscriptSemanticUnit] = []

        func flush() {
            guard !pending.isEmpty else { return }
            groups.append(
                SemanticSourceGroup(
                    id: groups.count,
                    start: pending.first?.start ?? 0,
                    end: pending.last?.end ?? 0,
                    sourceText: joinedText(of: pending, language: language),
                    wordStart: pending.first?.wordStart,
                    wordEnd: pending.last?.wordEnd,
                    speaker: pending.compactMap(\.speaker).first
                )
            )
            pending = []
        }

        for unit in transcript.semanticUnits {
            guard let first = pending.first, let last = pending.last else {
                pending = [unit]
                continue
            }

            let candidateDuration = unit.end - first.start
            let gap = unit.start - last.end
            let candidateUnits = pending + [unit]
            let candidateText = joinedText(of: candidateUnits, language: language)
            let knownSpeakerChanged = last.speaker != nil
                && unit.speaker != nil
                && last.speaker != unit.speaker
            let preferredLimitReached = pending.count >= preferredMaximumUnitsPerGroup
                || (last.end - first.start) >= preferredMaximumGroupDuration
            let shouldCloseCompletedSentence = preferredLimitReached
                && endsSentence(last.text)
            let canAppend = pending.count < maximumUnitsPerGroup
                && gap >= 0
                && gap <= maximumGap
                && candidateDuration <= maximumGroupDuration
                && candidateText.count <= maximumSourceCharacters
                && !knownSpeakerChanged
                && !shouldCloseCompletedSentence

            if canAppend {
                pending.append(unit)
            } else {
                flush()
                pending = [unit]
            }
        }
        flush()
        return groups
    }

    static func translationUnits(from groups: [SemanticSourceGroup]) -> [SubtitleTranslationUnit] {
        groups.enumerated().map { index, group in
            SubtitleTranslationUnit(
                id: group.id,
                sourceText: group.sourceText,
                precedingContext: index > 0 ? groups[index - 1].sourceText : nil,
                followingContext: index + 1 < groups.count ? groups[index + 1].sourceText : nil
            )
        }
    }

    private static func joinedText(
        of units: [TranscriptSemanticUnit],
        language: RecognitionLanguage
    ) -> String {
        let separator = language.usesUnspacedLineBreaking ? "" : " "
        return units
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
            .precomposedStringWithCanonicalMapping
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .last
        else { return false }
        return sentenceTerminators.contains(last)
    }

    private static let sentenceTerminators = Set(Array(".!?。！？…"))
}
