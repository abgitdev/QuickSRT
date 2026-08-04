import Foundation

/// Engine-neutral, word-timed transcript loaded from `<output>.timeline.json`.
///
/// The custom decoders accept both snake_case and camelCase keys plus numeric or
/// textual identifiers. The three schema collections remain required: a missing
/// or malformed collection is a decoding error rather than a silent empty value.
struct TimedTranscript: Decodable, Equatable {
    let version: String
    let language: String
    let words: [TimedTranscriptWord]
    let segments: [TimedTranscriptSegment]
    let semanticUnits: [TranscriptSemanticUnit]

    var duration: TimeInterval {
        let wordEnd = words.map(\.end).max() ?? 0
        let segmentEnd = segments.map(\.end).max() ?? 0
        let unitEnd = semanticUnits.map(\.end).max() ?? 0
        return max(wordEnd, segmentEnd, unitEnd)
    }

    init(
        version: String = "1",
        language: String = "und",
        words: [TimedTranscriptWord] = [],
        segments: [TimedTranscriptSegment] = [],
        semanticUnits: [TranscriptSemanticUnit] = []
    ) {
        self.version = version
        self.language = language
        self.words = words
        self.segments = segments
        self.semanticUnits = semanticUnits
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case language
        case words
        case segments
        case semanticUnits
        case semanticUnitsSnake = "semantic_units"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.flexibleString(forKeys: [.version]) ?? "1"
        language = container.flexibleString(forKeys: [.language]) ?? "und"
        words = try container.requiredArray(TimedTranscriptWord.self, forKeys: [.words])
        segments = try container.requiredArray(TimedTranscriptSegment.self, forKeys: [.segments])
        semanticUnits = try container.requiredArray(
            TranscriptSemanticUnit.self,
            forKeys: [.semanticUnitsSnake, .semanticUnits]
        )
    }
}

struct TimedTranscriptWord: Decodable, Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let confidence: Double?

    init(
        id: String = "",
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case start
        case end
        case text
        case word
        case confidence
        case probability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKeys: [.id, .index]) ?? ""
        start = container.flexibleDouble(forKeys: [.start]) ?? 0
        end = container.flexibleDouble(forKeys: [.end]) ?? start
        text = container.flexibleString(forKeys: [.text, .word]) ?? ""
        confidence = container.flexibleDouble(forKeys: [.confidence, .probability])
    }
}

struct TimedTranscriptSegment: Decodable, Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let wordStart: Int?
    let wordEnd: Int?
    let speaker: String?

    init(
        id: String = "",
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        wordStart: Int? = nil,
        wordEnd: Int? = nil,
        speaker: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case start
        case end
        case text
        case wordStart
        case wordStartSnake = "word_start"
        case wordEnd
        case wordEndSnake = "word_end"
        case speaker
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKeys: [.id, .index]) ?? ""
        start = container.flexibleDouble(forKeys: [.start]) ?? 0
        end = container.flexibleDouble(forKeys: [.end]) ?? start
        text = container.flexibleString(forKeys: [.text]) ?? ""
        wordStart = container.flexibleInt(forKeys: [.wordStartSnake, .wordStart])
        wordEnd = container.flexibleInt(forKeys: [.wordEndSnake, .wordEnd])
        speaker = container.flexibleString(forKeys: [.speaker, .speakerID])
    }
}

struct TranscriptSemanticUnit: Decodable, Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let wordStart: Int?
    let wordEnd: Int?
    let speaker: String?

    init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        wordStart: Int? = nil,
        wordEnd: Int? = nil,
        speaker: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case start
        case end
        case text
        case wordStart
        case wordStartSnake = "word_start"
        case wordEnd
        case wordEndSnake = "word_end"
        case speaker
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKeys: [.id, .index]) ?? ""
        start = container.flexibleDouble(forKeys: [.start]) ?? 0
        end = container.flexibleDouble(forKeys: [.end]) ?? start
        text = container.flexibleString(forKeys: [.text]) ?? ""
        wordStart = container.flexibleInt(forKeys: [.wordStartSnake, .wordStart])
        wordEnd = container.flexibleInt(forKeys: [.wordEndSnake, .wordEnd])
        speaker = container.flexibleString(forKeys: [.speaker, .speakerID])
    }
}

/// Text returned by any translation engine for one semantic source unit.
struct TranslatedSemanticUnitText: Codable, Equatable {
    let unitID: String
    let text: String

    init(unitID: String, text: String) {
        self.unitID = unitID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case unitID
        case unitIDSnake = "unit_id"
        case id
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unitID = container.flexibleString(forKeys: [.unitIDSnake, .unitID, .id]) ?? ""
        text = container.flexibleString(forKeys: [.text]) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unitID, forKey: .unitIDSnake)
        try container.encode(text, forKey: .text)
    }
}

enum TimedTranscriptValidationError: LocalizedError, Equatable {
    case missingVersion
    case unsupportedVersion(String)
    case unsupportedLanguage(String)
    case missingWords
    case missingSegments
    case missingSemanticUnits
    case invalidWord(Int)
    case invalidSegment(Int)
    case invalidSemanticUnit(String)
    case duplicateSemanticUnitID(String)
    case invalidSemanticUnitWordRange(String)

    var errorDescription: String? {
        switch self {
        case .missingVersion:
            return "Timeline sidecar has no schema version."
        case let .unsupportedVersion(version):
            return "Timeline sidecar uses unsupported schema version '\(version)'."
        case let .unsupportedLanguage(language):
            return "Timeline sidecar uses unsupported language '\(language)'."
        case .missingWords:
            return "Timeline sidecar has no word timestamps."
        case .missingSegments:
            return "Timeline sidecar has no source segments."
        case .missingSemanticUnits:
            return "Timeline sidecar has no semantic units."
        case let .invalidWord(index):
            return "Timeline word \(index) has empty text or invalid timing."
        case let .invalidSegment(index):
            return "Timeline segment \(index) has empty text or invalid timing."
        case let .invalidSemanticUnit(id):
            return "Semantic unit '\(id)' has empty text, ID, or invalid timing."
        case let .duplicateSemanticUnitID(id):
            return "Semantic unit ID '\(id)' is duplicated."
        case let .invalidSemanticUnitWordRange(id):
            return "Semantic unit '\(id)' has an invalid word range."
        }
    }
}

enum TimedTranscriptValidator {
    static let maximumFileSizeBytes: Int64 = 64 * 1_024 * 1_024

    static func load(from url: URL) throws -> TimedTranscript {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw QuickSRTError.invalidTimeline("Timeline sidecar is not a regular file.")
            }
            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize > 0 else {
                throw QuickSRTError.invalidTimeline("Timeline sidecar is empty.")
            }
            guard fileSize <= maximumFileSizeBytes else {
                throw QuickSRTError.invalidTimeline(
                    "Timeline sidecar exceeds the \(maximumFileSizeBytes)-byte safety limit."
                )
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let transcript = try JSONDecoder().decode(TimedTranscript.self, from: data)
            try validate(transcript)
            return transcript
        } catch let error as QuickSRTError {
            throw error
        } catch {
            throw QuickSRTError.invalidTimeline(error.localizedDescription)
        }
    }

    static func validate(_ transcript: TimedTranscript) throws {
        guard !transcript.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimedTranscriptValidationError.missingVersion
        }
        guard transcript.version == "1" else {
            throw TimedTranscriptValidationError.unsupportedVersion(transcript.version)
        }
        guard RecognitionLanguage(subtitleIdentifier: transcript.language) != nil else {
            throw TimedTranscriptValidationError.unsupportedLanguage(transcript.language)
        }
        guard !transcript.words.isEmpty else {
            throw TimedTranscriptValidationError.missingWords
        }
        guard !transcript.segments.isEmpty else {
            throw TimedTranscriptValidationError.missingSegments
        }
        guard !transcript.semanticUnits.isEmpty else {
            throw TimedTranscriptValidationError.missingSemanticUnits
        }

        var wordIDs: Set<String> = []
        var previousWordEnd: TimeInterval = 0
        for (index, word) in transcript.words.enumerated() {
            guard
                validTiming(start: word.start, end: word.end),
                word.start >= previousWordEnd,
                !word.id.isEmpty,
                wordIDs.insert(word.id).inserted,
                !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw TimedTranscriptValidationError.invalidWord(index)
            }
            if let confidence = word.confidence,
               (!confidence.isFinite || confidence < 0 || confidence > 1) {
                throw TimedTranscriptValidationError.invalidWord(index)
            }
            previousWordEnd = word.end
        }

        var segmentIDs: Set<String> = []
        var previousSegmentEnd: TimeInterval = 0
        for (index, segment) in transcript.segments.enumerated() {
            guard
                validTiming(start: segment.start, end: segment.end),
                segment.start >= previousSegmentEnd,
                !segment.id.isEmpty,
                segmentIDs.insert(segment.id).inserted,
                !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let wordStart = segment.wordStart,
                let wordEnd = segment.wordEnd,
                wordStart >= 0,
                wordEnd > wordStart,
                wordEnd <= transcript.words.count
            else {
                throw TimedTranscriptValidationError.invalidSegment(index)
            }
            previousSegmentEnd = segment.end
        }

        var identifiers: Set<String> = []
        var previousUnitEnd: TimeInterval = 0
        for unit in transcript.semanticUnits {
            guard
                validTiming(start: unit.start, end: unit.end),
                unit.start >= previousUnitEnd,
                !unit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw TimedTranscriptValidationError.invalidSemanticUnit(unit.id)
            }
            guard identifiers.insert(unit.id).inserted else {
                throw TimedTranscriptValidationError.duplicateSemanticUnitID(unit.id)
            }
            guard
                let wordStart = unit.wordStart,
                let wordEnd = unit.wordEnd,
                wordStart >= 0,
                wordEnd > wordStart,
                wordEnd <= transcript.words.count
            else {
                throw TimedTranscriptValidationError.invalidSemanticUnitWordRange(unit.id)
            }
            previousUnitEnd = unit.end
        }
    }

    private static func validTiming(start: TimeInterval, end: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decode(String.self, forKey: key) {
                return value
            }
            if let value = try? decode(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? decode(Double.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func flexibleDouble(forKeys keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? decode(Int.self, forKey: key) {
                return Double(value)
            }
            if
                let value = try? decode(String.self, forKey: key),
                let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return parsed
            }
        }
        return nil
    }

    func flexibleInt(forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? decode(Double.self, forKey: key) {
                return Int(value)
            }
            if
                let value = try? decode(String.self, forKey: key),
                let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return parsed
            }
        }
        return nil
    }

    func requiredArray<Element: Decodable>(
        _ type: Element.Type,
        forKeys keys: [Key]
    ) throws -> [Element] {
        for key in keys {
            guard contains(key) else { continue }
            return try decode([Element].self, forKey: key)
        }
        let key = keys[0]
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Required timeline collection '\(key.stringValue)' is missing."
            )
        )
    }
}
