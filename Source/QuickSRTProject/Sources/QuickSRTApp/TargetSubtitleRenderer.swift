import Foundation
import NaturalLanguage

enum SubtitleQAIssueSeverity: String, Codable, Equatable {
    case warning
    case error
}

enum SubtitleQAIssueCode: String, Codable, Equatable {
    case noSemanticUnits
    case translationCountMismatch
    case missingTranslation
    case emptyTranslation
    case orphanTranslation
    case duplicateUnitIdentifier
    case duplicateTranslation
    case sourceUnitsOutOfOrder
    case invalidSourceTiming
    case overlappingSourceUnits
    case timingWindowInsufficient
    case timingCapacityExceeded
    case forcedLexicalBreak
    case invalidCueNumbering
    case invalidCueTiming
    case overlappingCues
    case emptyCueText
    case tooManyLines
    case emptyLine
    case lineTooLong
    case cueTooShort
    case cueTooLong
    case readingSpeedExceeded
    case cuePastMediaEnd
}

struct SubtitleQAIssue: Equatable {
    let severity: SubtitleQAIssueSeverity
    let code: SubtitleQAIssueCode
    let cueIndex: Int?
    let unitID: String?
    let message: String
    let actualValue: Double?
    let limit: Double?

    init(
        severity: SubtitleQAIssueSeverity,
        code: SubtitleQAIssueCode,
        cueIndex: Int? = nil,
        unitID: String? = nil,
        message: String,
        actualValue: Double? = nil,
        limit: Double? = nil
    ) {
        self.severity = severity
        self.code = code
        self.cueIndex = cueIndex
        self.unitID = unitID
        self.message = message
        self.actualValue = actualValue
        self.limit = limit
    }
}

struct SubtitleQAReport: Equatable {
    let issues: [SubtitleQAIssue]

    /// A strict PASS has neither blocking errors nor review warnings.
    var passed: Bool { issues.isEmpty }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    /// Count reviewable output issues without double-counting the renderer's
    /// unit-level planning diagnostics and the final cue-level QA result that
    /// describes the same constrained timing.
    var reviewWarningCount: Int {
        let warnings = issues.filter { $0.severity == .warning }
        let planningCodes: Set<SubtitleQAIssueCode> = [
            .timingCapacityExceeded,
            .timingWindowInsufficient
        ]
        let finalTimingCodes: Set<SubtitleQAIssueCode> = [
            .cueTooShort,
            .cueTooLong,
            .readingSpeedExceeded
        ]
        let outputWarnings = warnings.filter { !planningCodes.contains($0.code) }
        let unitsWithFinalTimingWarnings = Set(outputWarnings.compactMap { issue in
            finalTimingCodes.contains(issue.code) ? issue.unitID : nil
        })
        var uncoveredPlanningUnits: Set<String> = []
        var unassociatedPlanningWarnings = 0
        for warning in warnings where planningCodes.contains(warning.code) {
            guard let unitID = warning.unitID else {
                unassociatedPlanningWarnings += 1
                continue
            }
            if !unitsWithFinalTimingWarnings.contains(unitID) {
                uncoveredPlanningUnits.insert(unitID)
            }
        }
        return outputWarnings.count
            + uncoveredPlanningUnits.count
            + unassociatedPlanningWarnings
    }
}

struct SubtitleRenderResult: Equatable {
    let document: SRTDocument
    let qualityReport: SubtitleQAReport
}

/// Converts translated semantic units into target-specific SRT cues without
/// knowing which translation engine produced their text.
enum TargetSubtitleRenderer {
    static func render(
        semanticUnits: [TranscriptSemanticUnit],
        translatedTexts: [String: String],
        profile: SubtitleProfile,
        mediaDuration: TimeInterval? = nil
    ) -> SubtitleRenderResult {
        let sourceIDs = Set(semanticUnits.map(\.id))
        let orphanIssues = translatedTexts.keys
            .filter { !sourceIDs.contains($0) }
            .sorted()
            .map { id in
                SubtitleQAIssue(
                    severity: .error,
                    code: .orphanTranslation,
                    unitID: id,
                    message: "Translation does not match a semantic unit."
                )
            }

        return render(
            semanticUnits: semanticUnits,
            profile: profile,
            mediaDuration: mediaDuration,
            initialIssues: orphanIssues,
            translation: { unit, _ in translatedTexts[unit.id] }
        )
    }

    static func render(
        semanticUnits: [TranscriptSemanticUnit],
        translatedTexts: [TranslatedSemanticUnitText],
        profile: SubtitleProfile,
        mediaDuration: TimeInterval? = nil
    ) -> SubtitleRenderResult {
        var translations: [String: String] = [:]
        var issues: [SubtitleQAIssue] = []
        for translation in translatedTexts {
            if translations.updateValue(translation.text, forKey: translation.unitID) != nil {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .duplicateTranslation,
                        unitID: translation.unitID,
                        message: "More than one translation was supplied for this semantic unit."
                    )
                )
            }
        }

        let sourceIDs = Set(semanticUnits.map(\.id))
        for id in translations.keys where !sourceIDs.contains(id) {
            issues.append(
                SubtitleQAIssue(
                    severity: .error,
                    code: .orphanTranslation,
                    unitID: id,
                    message: "Translation does not match a semantic unit."
                )
            )
        }

        return render(
            semanticUnits: semanticUnits,
            profile: profile,
            mediaDuration: mediaDuration,
            initialIssues: issues,
            translation: { unit, _ in translations[unit.id] }
        )
    }

    /// Convenience overload for engines that preserve semantic-unit order.
    static func render(
        semanticUnits: [TranscriptSemanticUnit],
        translatedTexts: [String],
        profile: SubtitleProfile,
        mediaDuration: TimeInterval? = nil
    ) -> SubtitleRenderResult {
        var issues: [SubtitleQAIssue] = []
        if semanticUnits.count != translatedTexts.count {
            issues.append(
                SubtitleQAIssue(
                    severity: .error,
                    code: .translationCountMismatch,
                    message: "Expected \(semanticUnits.count) translations, received \(translatedTexts.count).",
                    actualValue: Double(translatedTexts.count),
                    limit: Double(semanticUnits.count)
                )
            )
        }

        return render(
            semanticUnits: semanticUnits,
            profile: profile,
            mediaDuration: mediaDuration,
            initialIssues: issues,
            translation: { _, index in
                translatedTexts.indices.contains(index) ? translatedTexts[index] : nil
            }
        )
    }

    private static func render(
        semanticUnits: [TranscriptSemanticUnit],
        profile: SubtitleProfile,
        mediaDuration: TimeInterval?,
        initialIssues: [SubtitleQAIssue],
        translation: (TranscriptSemanticUnit, Int) -> String?
    ) -> SubtitleRenderResult {
        var issues = initialIssues
        guard !semanticUnits.isEmpty else {
            issues.append(
                SubtitleQAIssue(
                    severity: .error,
                    code: .noSemanticUnits,
                    message: "The transcript has no semantic units to render."
                )
            )
            return result(
                cues: [],
                issues: issues,
                profile: profile,
                mediaDuration: mediaDuration
            )
        }

        let maximumEndTime = normalizedMediaEnd(mediaDuration)

        var seenIDs: Set<String> = []
        for unit in semanticUnits where unit.id.isEmpty || !seenIDs.insert(unit.id).inserted {
            issues.append(
                SubtitleQAIssue(
                    severity: .error,
                    code: .duplicateUnitIdentifier,
                    unitID: unit.id,
                    message: unit.id.isEmpty
                        ? "Semantic unit has an empty identifier."
                        : "Semantic unit identifier is not unique."
                )
            )
        }

        let indexedUnits = semanticUnits.enumerated().map { offset, unit in
            IndexedSemanticUnit(originalIndex: offset, unit: unit)
        }
        let orderedUnits = indexedUnits.sorted { lhs, rhs in
            if lhs.unit.start == rhs.unit.start {
                return lhs.originalIndex < rhs.originalIndex
            }
            return lhs.unit.start < rhs.unit.start
        }
        if orderedUnits.map(\.originalIndex) != Array(semanticUnits.indices) {
            issues.append(
                SubtitleQAIssue(
                    severity: .warning,
                    code: .sourceUnitsOutOfOrder,
                    message: "Semantic units were reordered by start time."
                )
            )
        }

        var cues: [SRTCue] = []
        var unitIdentifiersByCueIndex: [Int: String] = [:]
        var previousRenderedEnd: TimeInterval = 0

        for (orderedIndex, indexedUnit) in orderedUnits.enumerated() {
            let unit = indexedUnit.unit
            guard let rawTranslation = translation(unit, indexedUnit.originalIndex) else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .missingTranslation,
                        unitID: unit.id,
                        message: "No translated text was supplied for this semantic unit."
                    )
                )
                continue
            }

            let translatedText = normalize(rawTranslation, language: profile.language)
            guard !translatedText.isEmpty else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .emptyTranslation,
                        unitID: unit.id,
                        message: "Translated text is empty after whitespace normalization."
                    )
                )
                continue
            }

            guard
                unit.start.isFinite,
                unit.end.isFinite,
                unit.start >= 0,
                unit.end > unit.start
            else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidSourceTiming,
                        unitID: unit.id,
                        message: "Semantic unit must have finite, increasing, non-negative timing."
                    )
                )
                continue
            }

            let nextSourceStart = nextValidStart(after: orderedIndex, in: orderedUnits)
            let followingStart: TimeInterval?
            if let nextSourceStart, let maximumEndTime {
                followingStart = min(nextSourceStart, maximumEndTime)
            } else {
                followingStart = nextSourceStart ?? maximumEndTime
            }
            var displayStart = unit.start
            var sourceEnd = min(unit.end, maximumEndTime ?? unit.end)

            if let maximumEndTime, displayStart >= maximumEndTime - 0.000_5 {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidSourceTiming,
                        unitID: unit.id,
                        message: "Semantic unit begins at or beyond the media boundary."
                    )
                )
                continue
            }

            if displayStart < previousRenderedEnd - 0.000_5 {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .overlappingSourceUnits,
                        unitID: unit.id,
                        message: "Semantic unit overlaps the preceding rendered unit."
                    )
                )
                displayStart = previousRenderedEnd
            }
            if let followingStart, sourceEnd > followingStart {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .overlappingSourceUnits,
                        unitID: unit.id,
                        message: "Semantic unit overlaps the following unit."
                    )
                )
                sourceEnd = followingStart
            }
            guard sourceEnd > displayStart else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidSourceTiming,
                        unitID: unit.id,
                        message: "No non-overlapping timing window remains for this semantic unit."
                    )
                )
                continue
            }

            let sourceDuration = sourceEnd - displayStart
            let totalUnits = profile.characterUnits(in: translatedText)
            let cueCapacity = Double(profile.maximumLines) * profile.maximumCharactersPerLine
            let minimumByCapacity = max(1, Int(ceil((totalUnits - 0.000_001) / cueCapacity)))
            let minimumByDuration = max(
                1,
                Int(ceil((sourceDuration - 0.000_001) / profile.maximumDuration))
            )
            var desiredCueCount = max(minimumByCapacity, minimumByDuration)
            let visibleCharacterCount = translatedText.reduce(into: 0) { count, character in
                if !isWhitespace(character) { count += 1 }
            }
            let forbiddenLexicalBreaks = forbiddenLexicalBreakOffsets(
                in: translatedText,
                language: profile.language
            )
            let maximumLexicalCueCount = maximumSafeChunkCount(
                translatedText,
                language: profile.language,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            )

            if desiredCueCount > visibleCharacterCount {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .timingCapacityExceeded,
                        unitID: unit.id,
                        message: "Text has too few grapheme clusters to cover the source interval within the maximum cue duration.",
                        actualValue: sourceDuration,
                        limit: Double(visibleCharacterCount) * profile.maximumDuration
                    )
                )
                desiredCueCount = max(minimumByCapacity, visibleCharacterCount)
            }
            if desiredCueCount > maximumLexicalCueCount {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .timingCapacityExceeded,
                        unitID: unit.id,
                        message: "Subtitle limits would require splitting a lexical token; the token is kept whole.",
                        actualValue: Double(desiredCueCount),
                        limit: Double(maximumLexicalCueCount)
                    )
                )
                desiredCueCount = maximumLexicalCueCount
            }

            var partition = partitionText(
                translatedText,
                count: desiredCueCount,
                capacity: cueCapacity,
                profile: profile,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            )
            // Retrying the same greedy partition with every legal boundary can
            // turn Japanese into dozens of one-character cues. A failed greedy
            // layout should go directly to the deterministic capacity fallback.
            if partitionNeedsMoreCues(
                partition,
                requestedCount: desiredCueCount,
                capacity: cueCapacity,
                profile: profile,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            ) {
                partition = capacitySafePartition(
                    translatedText,
                    capacity: cueCapacity,
                    profile: profile,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks
                )
            }
            if partitionHasBlockingLayout(
                partition,
                capacity: cueCapacity,
                profile: profile,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            ) {
                partition = capacitySafePartition(
                    translatedText,
                    capacity: cueCapacity,
                    profile: profile,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks
                )
            }
            if partition.forcedBreakCount > 0 {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .forcedLexicalBreak,
                        unitID: unit.id,
                        message: "Renderer attempted a forbidden lexical break."
                    )
                )
            }

            var laidOutTexts: [String] = []
            for chunk in partition.chunks {
                let layout = layOutLines(
                    chunk.text,
                    profile: profile,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                    baseOffset: chunk.startOffset
                )
                laidOutTexts.append(layout.text)
                if layout.forcedBreak {
                    issues.append(
                        SubtitleQAIssue(
                            severity: .error,
                            code: .forcedLexicalBreak,
                            unitID: unit.id,
                            message: "Renderer attempted to split a lexical token."
                        )
                    )
                }
            }
            guard !laidOutTexts.isEmpty else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .emptyTranslation,
                        unitID: unit.id,
                        message: "Translated text could not be divided into non-empty cues."
                    )
                )
                continue
            }

            let cueWeights = laidOutTexts.map { max(profile.characterUnits(in: $0), 0.5) }
            let cueCount = laidOutTexts.count
            let minimumReadableCueDuration = cueWeights.reduce(0.0) { total, weight in
                total + max(
                    weight / profile.maximumCharactersPerSecond,
                    profile.minimumDuration
                )
            }
            let maximumCueDuration = Double(cueCount) * profile.maximumDuration
            let desiredDisplayDuration = max(
                sourceDuration,
                minimumReadableCueDuration
            )
            let capacityLimitedDuration = min(desiredDisplayDuration, maximumCueDuration)
            if desiredDisplayDuration > maximumCueDuration + 0.000_5 {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .timingCapacityExceeded,
                        unitID: unit.id,
                        message: "Text cannot meet reading-speed and duration limits within this timing window.",
                        actualValue: desiredDisplayDuration,
                        limit: maximumCueDuration
                    )
                )
            }

            // A translation can be only a few hundred milliseconds too long for
            // the post-speech gap even though there is unused silence immediately
            // before the source unit. Borrow a small lead-in from that silence so
            // strict reading-speed checks do not reject an otherwise readable cue.
            if let followingStart {
                let currentWindow = max(0, followingStart - displayStart)
                let requiredLeadIn = max(0, capacityLimitedDuration - currentWindow)
                let availableLeadIn = max(0, displayStart - previousRenderedEnd)
                let leadIn = min(requiredLeadIn, availableLeadIn, maximumLeadIn)
                displayStart -= leadIn
            }

            let availableEnd = followingStart ?? (displayStart + capacityLimitedDuration)
            let availableDuration = max(0, availableEnd - displayStart)
            let displayDuration = min(capacityLimitedDuration, availableDuration)
            if displayDuration + 0.000_5 < capacityLimitedDuration {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .timingWindowInsufficient,
                        unitID: unit.id,
                        message: "The gap before the next unit is too short for readable subtitle timing.",
                        actualValue: displayDuration,
                        limit: capacityLimitedDuration
                    )
                )
            }
            guard displayDuration >= Double(cueCount) * 0.001 else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidSourceTiming,
                        unitID: unit.id,
                        message: "Timing window is shorter than one SRT millisecond per cue."
                    )
                )
                continue
            }

            let durations = allocateDurations(
                total: displayDuration,
                weights: cueWeights,
                minimum: profile.minimumDuration,
                maximum: profile.maximumDuration
            )
            var cursor = displayStart
            for index in laidOutTexts.indices {
                let cueEnd = index == laidOutTexts.index(before: laidOutTexts.endIndex)
                    ? displayStart + displayDuration
                    : cursor + durations[index]
                let startMilliseconds = milliseconds(cursor)
                let endMilliseconds = max(startMilliseconds + 1, milliseconds(cueEnd))
                let cueIndex = cues.count + 1
                cues.append(
                    SRTCue(
                        index: cueIndex,
                        timingLine: "\(timestamp(startMilliseconds)) --> \(timestamp(endMilliseconds))",
                        text: laidOutTexts[index]
                    )
                )
                unitIdentifiersByCueIndex[cueIndex] = unit.id
                cursor = cueEnd
            }
            previousRenderedEnd = displayStart + displayDuration
        }

        return result(
            cues: cues,
            issues: issues,
            profile: profile,
            mediaDuration: maximumEndTime,
            unitIdentifiersByCueIndex: unitIdentifiersByCueIndex
        )
    }

    private static func result(
        cues: [SRTCue],
        issues: [SubtitleQAIssue],
        profile: SubtitleProfile,
        mediaDuration: TimeInterval?,
        unitIdentifiersByCueIndex: [Int: String] = [:]
    ) -> SubtitleRenderResult {
        let document = SRTDocument(cues: cues)
        let automaticIssues = SubtitleQualityAssessor.assess(
            document: document,
            profile: profile,
            mediaDuration: mediaDuration,
            unitIdentifiersByCueIndex: unitIdentifiersByCueIndex
        ).issues
        return SubtitleRenderResult(
            document: document,
            qualityReport: SubtitleQAReport(issues: issues + automaticIssues)
        )
    }

    private static func nextValidStart(
        after index: Int,
        in units: [IndexedSemanticUnit]
    ) -> TimeInterval? {
        guard index + 1 < units.count else { return nil }
        for candidate in units[(index + 1)...] {
            if candidate.unit.start.isFinite, candidate.unit.start >= 0 {
                return candidate.unit.start
            }
        }
        return nil
    }

    private static func normalize(
        _ text: String,
        language: RecognitionLanguage
    ) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        var result = String()
        var pendingSpace = false
        for character in normalized {
            if isWhitespace(character) {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                result.append(character)
                pendingSpace = false
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Whisper and machine translation occasionally put spaces around an
        // apostrophe inside an elision (for example, `c 'est` or `d ' avoir`).
        // Keep quote spacing intact while repairing only letter-apostrophe-letter
        // sequences.
        result = result.replacingOccurrences(
            of: #"(?<=\p{L})\s+(['’])\s*(?=\p{L})"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<=\p{L})(['’])\s+(?=\p{L})"#,
            with: "$1",
            options: .regularExpression
        )

        if language == .chinese {
            result = result.applyingTransform(
                StringTransform("Traditional-Simplified"),
                reverse: false
            ) ?? result
        }
        return result
    }

    private static func partitionText(
        _ text: String,
        count requestedCount: Int,
        capacity: Double,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>
    ) -> TextPartition {
        let characters = Array(text)
        guard !characters.isEmpty else { return TextPartition(chunks: [], forcedBreakCount: 0) }
        let count = max(1, requestedCount)
        var start = skipWhitespace(in: characters, from: 0)
        var chunks: [TextChunk] = []
        let forcedBreakCount = 0

        while chunks.count < count - 1, start < characters.count {
            let remainingChunkCount = count - chunks.count
            let remainingWidth = width(
                of: characters,
                from: start,
                to: characters.count,
                profile: profile
            )
            let targetWidth = remainingWidth / Double(remainingChunkCount)
            var candidates: [BreakCandidate] = []

            if start + 1 < characters.count {
                for end in (start + 1)..<characters.count {
                    let bounds = trimmedBounds(in: characters, from: start, to: end)
                    guard bounds.start < bounds.end else { continue }
                    let chunkWidth = width(
                        of: characters,
                        from: bounds.start,
                        to: bounds.end,
                        profile: profile
                    )
                    let nextStart = skipWhitespace(in: characters, from: end)
                    let chunksAfter = remainingChunkCount - 1
                    let remainingVisible = visibleCount(
                        in: characters,
                        from: nextStart,
                        to: characters.count
                    )
                    guard remainingVisible >= chunksAfter else { continue }

                    // A visible-character count is not enough to prove that the
                    // suffix can be divided without breaking a word or a protected
                    // Japanese run. Preserve enough legal boundaries for every
                    // remaining chunk so the greedy choice cannot strand one long,
                    // otherwise breakable tail in the final cue.
                    guard maximumSafeChunkCount(
                        in: characters,
                        from: nextStart,
                        to: characters.count,
                        language: profile.language,
                        forbiddenLexicalBreaks: forbiddenLexicalBreaks
                    ) >= chunksAfter else { continue }

                    let boundary = boundaryRating(
                        in: characters,
                        at: end,
                        language: profile.language,
                        forbiddenLexicalBreaks: forbiddenLexicalBreaks
                    )
                    guard boundary.isSafe else { continue }
                    let chunkText = String(characters[bounds.start..<bounds.end])
                    guard
                        chunkWidth <= capacity + 0.000_001
                            || isUnbreakableDisplayLine(
                                chunkText,
                                language: profile.language,
                                forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                                baseOffset: bounds.start
                            )
                    else { continue }
                    candidates.append(
                        BreakCandidate(
                            end: end,
                            width: chunkWidth,
                            rating: boundary.rating,
                            isSafe: boundary.isSafe,
                            distanceFromTarget: abs(chunkWidth - targetWidth)
                        )
                    )
                }
            }

            guard let selected = selectCandidate(candidates) else { break }
            let bounds = trimmedBounds(in: characters, from: start, to: selected.end)
            chunks.append(
                TextChunk(
                    text: String(characters[bounds.start..<bounds.end]),
                    startOffset: bounds.start
                )
            )
            start = skipWhitespace(in: characters, from: selected.end)
        }

        if start < characters.count {
            let bounds = trimmedBounds(in: characters, from: start, to: characters.count)
            if bounds.start < bounds.end {
                chunks.append(
                    TextChunk(
                        text: String(characters[bounds.start..<bounds.end]),
                        startOffset: bounds.start
                    )
                )
            }
        }
        return TextPartition(chunks: chunks, forcedBreakCount: forcedBreakCount)
    }

    /// Final deterministic fallback for a greedy partition that used all legal
    /// boundaries but still stranded a long, breakable suffix. It consumes the
    /// longest prefix that can be laid out as at most two legal lines, preserving
    /// words and protected Japanese runs. An actually indivisible oversized token
    /// remains whole and is reported later as a warning rather than discarded.
    private static func capacitySafePartition(
        _ text: String,
        capacity: Double,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>
    ) -> TextPartition {
        let characters = Array(text)
        guard !characters.isEmpty else { return TextPartition(chunks: [], forcedBreakCount: 0) }
        var chunks: [TextChunk] = []
        var start = skipWhitespace(in: characters, from: 0)

        while start < characters.count {
            var firstSafeEnd: Int?
            var furthestLegalEnd: Int?
            for end in (start + 1)...characters.count {
                let boundaryIsSafe = end == characters.count
                    || boundaryRating(
                        in: characters,
                        at: end,
                        language: profile.language,
                        forbiddenLexicalBreaks: forbiddenLexicalBreaks
                    ).isSafe
                guard boundaryIsSafe else { continue }
                if firstSafeEnd == nil { firstSafeEnd = end }

                let bounds = trimmedBounds(in: characters, from: start, to: end)
                guard bounds.start < bounds.end else { continue }
                let chunk = String(characters[bounds.start..<bounds.end])
                let chunkWidth = profile.characterUnits(in: chunk)
                guard
                    chunkWidth <= capacity + 0.000_001
                        || isUnbreakableDisplayLine(
                            chunk,
                            language: profile.language,
                            forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                            baseOffset: bounds.start
                        )
                else { continue }
                guard chunkHasLegalLineLayout(
                    chunk,
                    baseOffset: bounds.start,
                    profile: profile,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks
                ) else { continue }
                furthestLegalEnd = end
            }

            let end = furthestLegalEnd ?? firstSafeEnd ?? characters.count
            let bounds = trimmedBounds(in: characters, from: start, to: end)
            guard bounds.start < bounds.end else { break }
            chunks.append(
                TextChunk(
                    text: String(characters[bounds.start..<bounds.end]),
                    startOffset: bounds.start
                )
            )
            start = skipWhitespace(in: characters, from: end)
        }
        return TextPartition(chunks: chunks, forcedBreakCount: 0)
    }

    private static func partitionHasBlockingLayout(
        _ partition: TextPartition,
        capacity: Double,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>
    ) -> Bool {
        partition.chunks.contains { chunk in
            let width = profile.characterUnits(in: chunk.text)
            if width > capacity + 0.000_001,
               !isUnbreakableDisplayLine(
                    chunk.text,
                    language: profile.language,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                    baseOffset: chunk.startOffset
               ) {
                return true
            }
            return !chunkHasLegalLineLayout(
                chunk.text,
                baseOffset: chunk.startOffset,
                profile: profile,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            )
        }
    }

    private static func chunkHasLegalLineLayout(
        _ chunk: String,
        baseOffset: Int,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>
    ) -> Bool {
        let layout = layOutLines(
            chunk,
            profile: profile,
            forbiddenLexicalBreaks: forbiddenLexicalBreaks,
            baseOffset: baseOffset
        )
        let lines = layout.text.components(separatedBy: "\n")
        guard lines.count <= profile.maximumLines else { return false }
        return zip(lines, layout.lineStartOffsets).allSatisfy { line, lineStartOffset in
            profile.characterUnits(in: line) <= profile.maximumCharactersPerLine + 0.000_001
                || isUnbreakableDisplayLine(
                    line,
                    language: profile.language,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                    baseOffset: lineStartOffset
                )
        }
    }

    /// A cue can fit the combined two-line capacity and still be impossible to
    /// lay out as two legal lines. This happens when grapheme widths step over
    /// the exact midpoint (for example 15.5/16.5 Korean units) or when Japanese
    /// kinsoku/lexical boundaries leave no valid 13/13 split. Add another cue
    /// instead of emitting a line that the final QA must reject.
    private static func partitionNeedsMoreCues(
        _ partition: TextPartition,
        requestedCount: Int,
        capacity: Double,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>
    ) -> Bool {
        guard partition.chunks.count >= requestedCount else { return true }
        for chunk in partition.chunks {
            if profile.characterUnits(in: chunk.text) > capacity + 0.000_001 {
                if isUnbreakableDisplayLine(
                    chunk.text,
                    language: profile.language,
                    forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                    baseOffset: chunk.startOffset
                ) {
                    continue
                }
                return true
            }
            let layout = layOutLines(
                chunk.text,
                profile: profile,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                baseOffset: chunk.startOffset
            )
            let lines = layout.text.components(separatedBy: "\n")
            if lines.contains(where: {
                profile.characterUnits(in: $0)
                    > profile.maximumCharactersPerLine + 0.000_001
            }) {
                if zip(lines, layout.lineStartOffsets).allSatisfy({ line, lineStartOffset in
                    profile.characterUnits(in: line) <= profile.maximumCharactersPerLine + 0.000_001
                        || isUnbreakableDisplayLine(
                            line,
                            language: profile.language,
                            forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                            baseOffset: lineStartOffset
                        )
                }) {
                    continue
                }
                return true
            }
        }
        return false
    }

    private static func layOutLines(
        _ text: String,
        profile: SubtitleProfile,
        forbiddenLexicalBreaks: Set<Int>,
        baseOffset: Int
    ) -> LineLayout {
        guard profile.characterUnits(in: text) > profile.maximumCharactersPerLine else {
            return LineLayout(
                text: text,
                forcedBreak: false,
                lineStartOffsets: [baseOffset]
            )
        }

        let characters = Array(text)
        var candidates: [BreakCandidate] = []
        guard characters.count > 1 else {
            return LineLayout(
                text: text,
                forcedBreak: false,
                lineStartOffsets: [baseOffset]
            )
        }

        for end in 1..<characters.count {
            let leftBounds = trimmedBounds(in: characters, from: 0, to: end)
            let rightBounds = trimmedBounds(in: characters, from: end, to: characters.count)
            guard leftBounds.start < leftBounds.end, rightBounds.start < rightBounds.end else { continue }
            let leftWidth = width(
                of: characters,
                from: leftBounds.start,
                to: leftBounds.end,
                profile: profile
            )
            let rightWidth = width(
                of: characters,
                from: rightBounds.start,
                to: rightBounds.end,
                profile: profile
            )
            let boundary = boundaryRating(
                in: characters,
                at: end,
                language: profile.language,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                baseOffset: baseOffset
            )
            guard boundary.isSafe else { continue }
            let leftText = String(characters[leftBounds.start..<leftBounds.end])
            let rightText = String(characters[rightBounds.start..<rightBounds.end])
            guard
                leftWidth <= profile.maximumCharactersPerLine + 0.000_001
                    || isUnbreakableDisplayLine(
                        leftText,
                        language: profile.language,
                        forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                        baseOffset: baseOffset + leftBounds.start
                    ),
                rightWidth <= profile.maximumCharactersPerLine + 0.000_001
                    || isUnbreakableDisplayLine(
                        rightText,
                        language: profile.language,
                        forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                        baseOffset: baseOffset + rightBounds.start
                    )
            else { continue }
            candidates.append(
                BreakCandidate(
                    end: end,
                    width: leftWidth,
                    rating: boundary.rating,
                    isSafe: boundary.isSafe,
                    distanceFromTarget: abs(leftWidth - rightWidth)
                )
            )
        }

        guard let selected = selectCandidate(candidates) else {
            return LineLayout(
                text: text,
                forcedBreak: false,
                lineStartOffsets: [baseOffset]
            )
        }
        let leftBounds = trimmedBounds(in: characters, from: 0, to: selected.end)
        let rightBounds = trimmedBounds(in: characters, from: selected.end, to: characters.count)
        let firstLine = String(characters[leftBounds.start..<leftBounds.end])
        let secondLine = String(characters[rightBounds.start..<rightBounds.end])
        return LineLayout(
            text: "\(firstLine)\n\(secondLine)",
            forcedBreak: false,
            lineStartOffsets: [baseOffset + leftBounds.start, baseOffset + rightBounds.start]
        )
    }

    private static func selectCandidate(_ candidates: [BreakCandidate]) -> BreakCandidate? {
        let preferred = candidates.filter { $0.isSafe && $0.rating > 0 }
        let safe = candidates.filter(\.isSafe)
        let pool = !preferred.isEmpty ? preferred : safe
        return pool.min { lhs, rhs in
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            if abs(lhs.distanceFromTarget - rhs.distanceFromTarget) > 0.000_001 {
                return lhs.distanceFromTarget < rhs.distanceFromTarget
            }
            return lhs.end > rhs.end
        }
    }

    private static func boundaryRating(
        in characters: [Character],
        at index: Int,
        language: RecognitionLanguage,
        forbiddenLexicalBreaks: Set<Int> = [],
        baseOffset: Int = 0
    ) -> (rating: Int, isSafe: Bool) {
        guard index > 0, index < characters.count else { return (4, true) }
        let left = characters[index - 1]
        let right = characters[index]
        let isSafe = !openingPunctuation.contains(left)
            && !closingPunctuation.contains(right)
            && !(language == .japanese && japaneseProhibitedLineStarts.contains(right))
            && !forbiddenLexicalBreaks.contains(baseOffset + index)
            && isLexicallySafeBoundary(left: left, right: right, language: language)

        if isWhitespace(left) || isWhitespace(right) { return (4, isSafe) }
        if sentenceEndPunctuation.contains(left) { return (3, isSafe) }
        if left.isPunctuation { return (2, isSafe) }
        if language.usesUnspacedLineBreaking { return (1, isSafe) }
        return (0, isSafe)
    }

    private static func isLexicallySafeBoundary(
        left: Character,
        right: Character,
        language: RecognitionLanguage
    ) -> Bool {
        if isWhitespace(left) || isWhitespace(right) { return true }
        if left.isApostrophe || right.isApostrophe { return false }
        if left.isDecimalDigit, right.isDecimalDigit { return false }
        if left.isASCIIWordCharacter, right.isASCIIWordCharacter { return false }

        if language == .japanese {
            if left.isHiragana, right.isHiragana { return false }
            if left.isKatakana, right.isKatakana { return false }
            return true
        }
        if language == .chinese { return true }

        // Languages with spaces must never be divided inside a lexical token.
        // Punctuation remains a legal emergency boundary for unusually long
        // clauses that contain no spaces.
        return left.isPunctuation || right.isPunctuation
    }

    /// Japanese may switch scripts inside one lexical token (for example
    /// `触れる` or `割り当てる`), so pairwise character heuristics alone cannot
    /// identify every forbidden break. Tokenize once per input string and keep
    /// every interior Character offset protected throughout the hot candidate
    /// loops. Existing punctuation, kinsoku, ASCII, and digit guards remain
    /// conjunctive in `boundaryRating`.
    private static func forbiddenLexicalBreakOffsets(
        in text: String,
        language: RecognitionLanguage
    ) -> Set<Int> {
        guard language == .japanese, text.count > 1 else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        var forbidden: Set<Int> = []
        var tokenCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokenCount += 1
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            if end - start > 1 {
                forbidden.formUnion((start + 1)..<end)
            }
            return true
        }

        // A tokenizer failure must not silently re-enable arbitrary Japanese
        // word splitting. Preserve every non-whitespace, non-punctuation run;
        // an oversized indivisible run is retained and reported by existing QA.
        if tokenCount == 0 {
            let characters = Array(text)
            for index in 1..<characters.count {
                let left = characters[index - 1]
                let right = characters[index]
                if !isWhitespace(left), !isWhitespace(right),
                   !left.isPunctuation, !right.isPunctuation {
                    forbidden.insert(index)
                }
            }
        }
        return forbidden
    }

    fileprivate static func isUnbreakableDisplayLine(
        _ text: String,
        language: RecognitionLanguage
    ) -> Bool {
        let forbiddenLexicalBreaks = forbiddenLexicalBreakOffsets(
            in: text,
            language: language
        )
        return isUnbreakableDisplayLine(
            text,
            language: language,
            forbiddenLexicalBreaks: forbiddenLexicalBreaks,
            baseOffset: 0
        )
    }

    private static func isUnbreakableDisplayLine(
        _ text: String,
        language: RecognitionLanguage,
        forbiddenLexicalBreaks: Set<Int>,
        baseOffset: Int
    ) -> Bool {
        let characters = Array(text)
        guard characters.count > 1 else { return true }
        for index in 1..<characters.count {
            let boundary = boundaryRating(
                in: characters,
                at: index,
                language: language,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks,
                baseOffset: baseOffset
            )
            if boundary.isSafe, boundary.rating > 0 {
                return false
            }
        }
        return true
    }

    private static func maximumSafeChunkCount(
        _ text: String,
        language: RecognitionLanguage,
        forbiddenLexicalBreaks: Set<Int>
    ) -> Int {
        let characters = Array(text)
        return maximumSafeChunkCount(
            in: characters,
            from: 0,
            to: characters.count,
            language: language,
            forbiddenLexicalBreaks: forbiddenLexicalBreaks
        )
    }

    private static func maximumSafeChunkCount(
        in characters: [Character],
        from start: Int,
        to end: Int,
        language: RecognitionLanguage,
        forbiddenLexicalBreaks: Set<Int>
    ) -> Int {
        guard end - start > 1 else { return 1 }
        var count = 1
        for index in (start + 1)..<end {
            let boundary = boundaryRating(
                in: characters,
                at: index,
                language: language,
                forbiddenLexicalBreaks: forbiddenLexicalBreaks
            )
            if boundary.isSafe, boundary.rating > 0 {
                count += 1
            }
        }
        return count
    }

    private static func allocateDurations(
        total: TimeInterval,
        weights: [Double],
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> [TimeInterval] {
        guard !weights.isEmpty else { return [] }
        let count = weights.count
        let canRespectBounds = total >= Double(count) * minimum - 0.000_001
            && total <= Double(count) * maximum + 0.000_001
        guard canRespectBounds else {
            let weightSum = weights.reduce(0, +)
            return weights.map { total * ($0 / weightSum) }
        }

        var result = Array(repeating: 0.0, count: count)
        var active = Set(weights.indices)
        var remaining = total

        while !active.isEmpty {
            let activeWeight = active.reduce(0.0) { $0 + weights[$1] }
            var clampedIndex: Int?
            var clampedValue: Double = 0

            for index in active.sorted() {
                let share = remaining * weights[index] / activeWeight
                if share < minimum {
                    clampedIndex = index
                    clampedValue = minimum
                    break
                }
                if share > maximum {
                    clampedIndex = index
                    clampedValue = maximum
                    break
                }
            }

            if let clampedIndex {
                result[clampedIndex] = clampedValue
                remaining -= clampedValue
                active.remove(clampedIndex)
            } else {
                for index in active {
                    result[index] = remaining * weights[index] / activeWeight
                }
                break
            }
        }
        return result
    }

    private static func width(
        of characters: [Character],
        from start: Int,
        to end: Int,
        profile: SubtitleProfile
    ) -> Double {
        guard start < end else { return 0 }
        return characters[start..<end].reduce(0) { partial, character in
            partial + profile.characterUnits(for: character)
        }
    }

    private static func visibleCount(
        in characters: [Character],
        from start: Int,
        to end: Int
    ) -> Int {
        guard start < end else { return 0 }
        return characters[start..<end].reduce(into: 0) { count, character in
            if !isWhitespace(character) { count += 1 }
        }
    }

    private static func trimmedBounds(
        in characters: [Character],
        from start: Int,
        to end: Int
    ) -> (start: Int, end: Int) {
        var lower = start
        var upper = end
        while lower < upper, isWhitespace(characters[lower]) { lower += 1 }
        while upper > lower, isWhitespace(characters[upper - 1]) { upper -= 1 }
        return (lower, upper)
    }

    private static func skipWhitespace(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, isWhitespace(characters[index]) { index += 1 }
        return index
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    private static func milliseconds(_ time: TimeInterval) -> Int {
        max(0, Int((time * 1_000).rounded()))
    }

    private static func normalizedMediaEnd(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return floor(duration * 1_000) / 1_000
    }

    private static func timestamp(_ totalMilliseconds: Int) -> String {
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    private static let openingPunctuation = Set(Array("([{（［｛〈《「『【〔〖〘〚‘“"))
    private static let closingPunctuation = Set(Array(")]},.!?;:%）］｝〉》」』】〕〗〙〛’”、。，．！？：；％‰℃…"))
    private static let sentenceEndPunctuation = Set(Array(".!?。！？…"))
    private static let japaneseProhibitedLineStarts = Set(Array("ぁぃぅぇぉっゃゅょァィゥェォッャュョー々〻"))
    private static let maximumLeadIn: TimeInterval = 0.5
}

enum SubtitleQualityAssessor {
    static func assess(
        document: SRTDocument,
        profile: SubtitleProfile,
        mediaDuration: TimeInterval? = nil,
        unitIdentifiersByCueIndex: [Int: String] = [:]
    ) -> SubtitleQAReport {
        var issues: [SubtitleQAIssue] = []
        var previousEndMilliseconds = 0
        let mediaEndMilliseconds = mediaDuration.flatMap { duration -> Int? in
            guard duration.isFinite, duration > 0 else { return nil }
            return Int(floor(duration * 1_000))
        }

        for (offset, cue) in document.cues.enumerated() {
            let expectedIndex = offset + 1
            let unitID = unitIdentifiersByCueIndex[cue.index]
            if cue.index != expectedIndex {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidCueNumbering,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue index must be \(expectedIndex)."
                    )
                )
            }

            guard let timing = parseTimingLine(cue.timingLine), timing.end > timing.start else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .invalidCueTiming,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue has an invalid SRT timing line."
                    )
                )
                continue
            }
            if timing.start < previousEndMilliseconds {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .overlappingCues,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue overlaps the preceding cue."
                    )
                )
            }
            if let mediaEndMilliseconds, timing.end > mediaEndMilliseconds {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .cuePastMediaEnd,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue ends after the media duration.",
                        actualValue: Double(timing.end) / 1_000,
                        limit: Double(mediaEndMilliseconds) / 1_000
                    )
                )
            }
            previousEndMilliseconds = timing.end

            let trimmedText = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .emptyCueText,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue text is empty."
                    )
                )
                continue
            }

            let lines = cue.text.components(separatedBy: "\n")
            if lines.count > profile.maximumLines {
                issues.append(
                    SubtitleQAIssue(
                        severity: .error,
                        code: .tooManyLines,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue has \(lines.count) lines; maximum is \(profile.maximumLines).",
                        actualValue: Double(lines.count),
                        limit: Double(profile.maximumLines)
                    )
                )
            }
            for line in lines {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        SubtitleQAIssue(
                            severity: .error,
                            code: .emptyLine,
                            cueIndex: cue.index,
                            unitID: unitID,
                            message: "Cue contains an empty display line."
                        )
                    )
                    continue
                }
                let lineUnits = profile.characterUnits(in: line)
                if lineUnits > profile.maximumCharactersPerLine + 0.000_001 {
                    let unbreakable = TargetSubtitleRenderer.isUnbreakableDisplayLine(
                        line,
                        language: profile.language
                    )
                    issues.append(
                        SubtitleQAIssue(
                            severity: unbreakable ? .warning : .error,
                            code: .lineTooLong,
                            cueIndex: cue.index,
                            unitID: unitID,
                            message: unbreakable
                                ? "An indivisible lexical token exceeds the target-language character limit; it was kept whole."
                                : "Line exceeds the target-language character limit.",
                            actualValue: lineUnits,
                            limit: profile.maximumCharactersPerLine
                        )
                    )
                }
            }

            let duration = Double(timing.end - timing.start) / 1_000
            if duration + 0.000_5 < profile.minimumDuration {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .cueTooShort,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue duration is below the target-language minimum.",
                        actualValue: duration,
                        limit: profile.minimumDuration
                    )
                )
            }
            if duration > profile.maximumDuration + 0.000_5 {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .cueTooLong,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue duration exceeds the maximum.",
                        actualValue: duration,
                        limit: profile.maximumDuration
                    )
                )
            }

            let cueUnits = profile.characterUnits(in: cue.text)
            let readingSpeed = cueUnits / duration
            let minimumReadingDuration = cueUnits / profile.maximumCharactersPerSecond
            // SRT rounds both endpoints to milliseconds, so the serialized
            // duration can be up to one millisecond shorter than the renderer's
            // exact allocation without representing a real readability breach.
            if duration + 0.001_001 < minimumReadingDuration {
                issues.append(
                    SubtitleQAIssue(
                        severity: .warning,
                        code: .readingSpeedExceeded,
                        cueIndex: cue.index,
                        unitID: unitID,
                        message: "Cue exceeds the target-language reading-speed limit.",
                        actualValue: readingSpeed,
                        limit: profile.maximumCharactersPerSecond
                    )
                )
            }
        }
        return SubtitleQAReport(issues: issues)
    }

    private static func parseTimingLine(_ line: String) -> (start: Int, end: Int)? {
        let parts = line.components(separatedBy: " --> ")
        guard
            parts.count == 2,
            let start = parseTimestamp(parts[0]),
            let end = parseTimestamp(parts[1])
        else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ value: String) -> Int? {
        let timeParts = value
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard
            timeParts.count == 3,
            let hours = Int(timeParts[0]),
            let minutes = Int(timeParts[1]),
            minutes >= 0,
            minutes < 60
        else { return nil }

        let secondsParts = timeParts[2].split(separator: ",", omittingEmptySubsequences: false)
        guard
            secondsParts.count == 2,
            secondsParts[1].count == 3,
            let seconds = Int(secondsParts[0]),
            let milliseconds = Int(secondsParts[1]),
            seconds >= 0,
            seconds < 60,
            milliseconds >= 0,
            milliseconds < 1_000
        else { return nil }
        return (((hours * 60) + minutes) * 60 + seconds) * 1_000 + milliseconds
    }
}

private struct IndexedSemanticUnit {
    let originalIndex: Int
    let unit: TranscriptSemanticUnit
}

private struct TextPartition {
    let chunks: [TextChunk]
    let forcedBreakCount: Int
}

private struct TextChunk {
    let text: String
    let startOffset: Int
}

private struct LineLayout {
    let text: String
    let forcedBreak: Bool
    let lineStartOffsets: [Int]
}

private struct BreakCandidate {
    let end: Int
    let width: Double
    let rating: Int
    let isSafe: Bool
    let distanceFromTarget: Double
}

private extension Character {
    var isPunctuation: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation,
                 .dashPunctuation,
                 .openPunctuation,
                 .closePunctuation,
                 .initialPunctuation,
                 .finalPunctuation,
                 .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }

    var isApostrophe: Bool {
        self == "'" || self == "’"
    }

    var isDecimalDigit: Bool {
        unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber }
    }

    var isASCIIWordCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_"
            )
        }
    }

    var isHiragana: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(scalar.value)
        }
    }

    var isKatakana: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x30A0...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0xFF65...0xFF9F).contains(scalar.value)
        }
    }
}
