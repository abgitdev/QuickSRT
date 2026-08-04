import Foundation

extension RecognitionLanguage {
    init?(subtitleIdentifier identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        switch normalized {
        case "en", "en-us", "en-gb": self = .english
        case "ru", "ru-ru": self = .russian
        case "de", "de-de": self = .german
        case "es", "es-es", "es-419": self = .spanish
        case "it", "it-it": self = .italian
        case "fr", "fr-fr", "fr-ca": self = .french
        case "ja", "ja-jp": self = .japanese
        case "zh", "zh-cn", "zh-hans", "zh-hans-cn": self = .chinese
        case "ko", "ko-kr": self = .korean
        case "hi", "hi-in": self = .hindi
        default: return nil
        }
    }

    var subtitleLocaleIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .russian: return "ru-RU"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        case .italian: return "it-IT"
        case .french: return "fr-FR"
        case .japanese: return "ja-JP"
        case .chinese: return "zh-Hans-CN"
        case .korean: return "ko-KR"
        case .hindi: return "hi-IN"
        }
    }

    var usesUnspacedLineBreaking: Bool {
        self == .japanese || self == .chinese
    }

    var subtitleProfile: SubtitleProfile {
        SubtitleProfile.standard(for: self)
    }
}

/// Adult-program subtitle limits. Values follow the per-language Netflix
/// interlingual timed-text guides, with a common two-line limit.
struct SubtitleProfile: Equatable {
    let language: RecognitionLanguage
    let maximumLines: Int
    let maximumCharactersPerLine: Double
    let maximumCharactersPerSecond: Double
    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval

    static func standard(for language: RecognitionLanguage) -> SubtitleProfile {
        let cpl: Double
        let cps: Double
        let minimumDuration: TimeInterval

        switch language {
        case .english:
            (cpl, cps, minimumDuration) = (42, 20, 0.833)
        case .russian, .german, .spanish, .italian, .french:
            (cpl, cps, minimumDuration) = (42, 17, 0.833)
        case .japanese:
            (cpl, cps, minimumDuration) = (13, 4, 0.5)
        case .chinese:
            (cpl, cps, minimumDuration) = (16, 9, 0.833)
        case .korean:
            (cpl, cps, minimumDuration) = (16, 12, 0.833)
        case .hindi:
            (cpl, cps, minimumDuration) = (42, 22, 0.833)
        }

        return SubtitleProfile(
            language: language,
            maximumLines: 2,
            maximumCharactersPerLine: cpl,
            maximumCharactersPerSecond: cps,
            minimumDuration: minimumDuration,
            maximumDuration: 7
        )
    }

    /// Counts extended grapheme clusters using target-guide width rules.
    /// Newline separators are layout, not readable characters.
    func characterUnits(in text: String) -> Double {
        text.reduce(into: 0) { result, character in
            guard character != "\n" && character != "\r" else { return }
            result += characterUnits(for: character)
        }
    }

    func characterUnits(for character: Character) -> Double {
        switch language {
        case .japanese:
            return character.isHalfwidthJapaneseCharacter ? 0.5 : 1
        case .korean:
            return character.isKoreanHalfUnitCharacter ? 0.5 : 1
        default:
            return 1
        }
    }
}

private extension Character {
    var isHalfwidthJapaneseCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.isASCII || (0xFF61...0xFF9F).contains(scalar.value)
        }
    }

    var isKoreanHalfUnitCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            if scalar.isASCII { return true }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation,
                 .dashPunctuation,
                 .openPunctuation,
                 .closePunctuation,
                 .initialPunctuation,
                 .finalPunctuation,
                 .otherPunctuation,
                 .mathSymbol,
                 .currencySymbol,
                 .modifierSymbol,
                 .otherSymbol:
                return true
            default:
                return false
            }
        }
    }
}
