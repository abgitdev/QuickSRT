import Foundation

struct SubtitleTranslationUnit: Equatable, Sendable {
    let id: Int
    let sourceText: String
    let precedingContext: String?
    let followingContext: String?

    init(
        id: Int,
        sourceText: String,
        precedingContext: String? = nil,
        followingContext: String? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.precedingContext = precedingContext
        self.followingContext = followingContext
    }
}

struct SubtitleTranslationResponse: Equatable, Sendable {
    let id: Int
    let targetText: String
}

enum TranslationTextValidationFailure: String, Equatable, Sendable {
    case empty
    case replacementCharacter
    case invalidUnicodeScalar
    case disallowedControlCharacter
}

enum TranslationTextValidator {
    static func failure(in text: String) -> TranslationTextValidationFailure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        for scalar in trimmed.unicodeScalars {
            if scalar.value == 0xFFFD {
                return .replacementCharacter
            }
            if isUnicodeNoncharacter(scalar.value) {
                return .invalidUnicodeScalar
            }
            switch scalar.properties.generalCategory {
            case .control, .format:
                if !allowedFormattingScalars.contains(scalar.value) {
                    return .disallowedControlCharacter
                }
            default:
                break
            }
        }
        return nil
    }

    private static func isUnicodeNoncharacter(_ value: UInt32) -> Bool {
        (0xFDD0...0xFDEF).contains(value) || value & 0xFFFE == 0xFFFE
    }

    // Preserve language shaping and emoji selectors while rejecting invisible
    // transport/control characters that cannot belong in an SRT payload.
    private static let allowedFormattingScalars: Set<UInt32> = [
        0x0009, 0x000A, 0x000D,
        0x061C, 0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
        0xFE0E, 0xFE0F
    ]
}

protocol SubtitleTranslating: AnyObject, Sendable {
    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String]

    func translate(
        units: [SubtitleTranslationUnit],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SubtitleTranslationResponse]

    func cancel()
}

extension SubtitleTranslating {
    func translate(
        units: [SubtitleTranslationUnit],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SubtitleTranslationResponse] {
        let translations = try await translate(
            texts: units.map(\.sourceText),
            progress: progress
        )
        guard translations.count == units.count else {
            throw QuickSRTError.translationOutputInvalid
        }
        return zip(units, translations).map { unit, translation in
            SubtitleTranslationResponse(id: unit.id, targetText: translation)
        }
    }
}
