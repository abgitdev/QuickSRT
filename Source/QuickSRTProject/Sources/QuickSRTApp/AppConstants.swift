import Foundation

enum AppLinks {
    static let github = URL(string: "https://github.com/abgitdev/QuickSRT")!
    static let koFi = URL(string: "https://ko-fi.com/abgitdev")!
}

public struct AppVersionInfo: Equatable, Sendable {
    let marketingVersion: String?
    let buildNumber: String?

    public init(marketingVersion: String?, buildNumber: String?) {
        self.marketingVersion = Self.nonEmpty(marketingVersion)
        self.buildNumber = Self.nonEmpty(buildNumber)
    }

    public init(bundle: Bundle = .main) {
        self.init(
            marketingVersion: Self.stringValue(
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            ),
            buildNumber: Self.stringValue(
                bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            )
        )
    }

    public var displayText: String {
        displayText(language: .english)
    }

    func displayText(language: AppLanguage) -> String {
        switch (marketingVersion, buildNumber) {
        case let (version?, build?):
            return TextKey.versionAndBuildFormat.formatted(
                language: language,
                arguments: [version, build]
            )
        case let (version?, nil):
            return TextKey.versionFormat.formatted(language: language, arguments: [version])
        case let (nil, build?):
            return TextKey.buildFormat.formatted(language: language, arguments: [build])
        case (nil, nil):
            return TextKey.versionUnavailable.text(language)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        return nonEmpty(String(describing: value))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public enum RecognitionLanguage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case english = "en"
    case russian = "ru"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case french = "fr"
    case japanese = "ja"
    case chinese = "zh"
    case korean = "ko"
    case hindi = "hi"

    public var id: String { rawValue }

    var title: String {
        rawValue.uppercased()
    }

    var isBeta: Bool {
        self == .hindi
    }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .french: return "Français"
        case .japanese: return "日本語"
        case .chinese: return "简体中文"
        case .korean: return "한국어"
        case .hindi: return "हिन्दी"
        }
    }

    var translationLocaleIdentifier: String {
        self == .chinese ? "zh-Hans" : rawValue
    }

    func localizedName(_ appLanguage: AppLanguage) -> String {
        languageNameKey.text(appLanguage)
    }

    private var languageNameKey: TextKey {
        switch self {
        case .english: return .languageEnglish
        case .russian: return .languageRussian
        case .german: return .languageGerman
        case .spanish: return .languageSpanish
        case .italian: return .languageItalian
        case .french: return .languageFrench
        case .japanese: return .languageJapanese
        case .chinese: return .languageChinese
        case .korean: return .languageKorean
        case .hindi: return .languageHindi
        }
    }

    func pickerTitle(_ appLanguage: AppLanguage) -> String {
        let base = "\(localizedName(appLanguage)) (\(title))"
        return isBeta ? "\(base) — \(TextKey.beta.text(appLanguage))" : base
    }

    func targetPickerTitle(_ appLanguage: AppLanguage) -> String {
        "\(localizedName(appLanguage)) (\(title))"
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case french = "fr"
    case japanese = "ja"
    case chinese = "zh-Hans"
    case korean = "ko"
    case hindi = "hi"

    var id: String { rawValue }

    var shortCode: String {
        switch self {
        case .english: return "EN"
        case .russian: return "RU"
        case .german: return "DE"
        case .spanish: return "ES"
        case .italian: return "IT"
        case .french: return "FR"
        case .japanese: return "JA"
        case .chinese: return "ZH"
        case .korean: return "KO"
        case .hindi: return "HI"
        }
    }

    var title: String { shortCode }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .french: return "Français"
        case .japanese: return "日本語"
        case .chinese: return "简体中文"
        case .korean: return "한국어"
        case .hindi: return "हिन्दी"
        }
    }

    var localeIdentifier: String {
        rawValue
    }

    var menuTitle: String {
        "\(nativeName) (\(shortCode))"
    }

    static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let normalized = identifier
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            guard let languageCode = normalized.split(separator: "-").first else {
                continue
            }
            if languageCode == "zh" {
                let subtags = normalized.split(separator: "-").dropFirst().map(String.init)
                if subtags.isEmpty
                    || subtags.contains("hans")
                    || !Set(subtags).isDisjoint(with: ["cn", "sg", "my"])
                {
                    return .chinese
                }
                continue
            }
            if let language = allCases.first(where: { $0.rawValue == String(languageCode) }) {
                return language
            }
        }
        return .english
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    var next: AppAppearanceMode {
        switch self {
        case .light: return .dark
        case .dark: return .light
        }
    }

    var textKey: TextKey {
        switch self {
        case .light: return .themeLight
        case .dark: return .themeDark
        }
    }
}

enum TextKey: CaseIterable, Sendable {
    case tagline
    case subtitle
    case chooseVideo
    case interfaceLanguage
    case speechLanguage
    case sourceLanguage
    case subtitleLanguage
    case selectInterfaceLanguage
    case selectSourceLanguage
    case selectSubtitleLanguage
    case close
    case noVideo
    case durationDash
    case durationChecking
    case start
    case stop
    case openSRT
    case lastOutput
    case emptyLog
    case ready
    case checkingVideo
    case extractingAudio
    case transcribingSpeech
    case translatingSubtitles
    case savingSRT
    case done
    case stopped
    case error
    case chooseVideoPanelTitle
    case choose
    case srtExistsTitle
    case replace
    case chooseAnotherName
    case cancel
    case saveSRT
    case progress
    case completed
    case ok
    case pending
    case localProcessing
    case noBackgroundServices
    case stopsOnQuit
    case createsMultilingualSRT
    case createsAnyToAnyTranslations
    case modelTitle
    case modelInstalled
    case modelMissing
    case modelDownloading
    case modelDownload
    case modelOpenFolder
    case modelStopDownload
    case modelUpdate
    case modelChooseExisting
    case modelInvalidFolder
    case modelRepo
    case modelInstalledDetail
    case modelMissingDetail
    case clear
    case finishedPrefix
    case outputLanguageNote
    case aboutQuickSRT
    case deleteQuickSRTData
    case uninstallQuickSRT
    case deleteDataMessage
    case deleteDataAndOutputs
    case deleteTrackedOutputsConfirmFormat
    case cleanupSuccessFormat
    case cleanupFailureReportFormat
    case quitAndMoveToTrash
    case dataRemovalLimits
    case adminApprovalMayBeRequired
    case supportDevelopment
    case beta
    case languageEnglish
    case languageRussian
    case languageGerman
    case languageSpanish
    case languageItalian
    case languageFrench
    case languageJapanese
    case languageChinese
    case languageKorean
    case languageHindi
    case versionAndBuildFormat
    case versionFormat
    case buildFormat
    case versionUnavailable
    case applicationAccessibilityFormat
    case durationFormat
    case estimating
    case etaRemainingFormat
    case elapsedFormat
    case elapsedRemainingFormat
    case managedFolderFormat
    case externalModelFormat
    case outputLanguageFormat
    case outputTranslationFormat
    case translationPreparing
    case translationReady
    case translationNotRequired
    case qualityWarningTitle
    case qualityWarningFormat
    case outputSummaryTitle
    case outputSummaryFormat
    case targetFailureInvalidTranslation
    case targetFailureInvalidLayout
    case targetFailureSaveFailed
    case runtimeMissingPython
    case runtimeMissingModelDownloader
    case componentUnavailableFormat
    case modelNotFound
    case unsupportedLanguageFormat
    case translationRequiresNewerMacOS
    case translationPairUnsupportedFormat
    case translationNotReady
    case translationFailed
    case translationOutputInvalid
    case languageDetectionFailed
    case themeLight
    case themeDark
    case themeHelpFormat
    case queueTitle
    case queueEmpty
    case queueStart
    case queuePause
    case queueAdd
    case queueMoveUp
    case queueMoveDown
    case queueRemove
    case queueCancelCurrent
    case queueReady
    case queueInspecting
    case queueNeedsAttention
    case queueWaiting
    case queueRunning
    case queuePaused
    case queueCompleted
    case queueCompletedWarnings
    case queueFailed
    case queueCancelled
    case languageDetectedFormat
    case languageLowConfidenceFormat
    case languageMismatchFormat
    case useDetectedLanguage
    case keepSelectedLanguage
    case retryDetection
    case continueSelected
    case videosCountFormat
    case invalidSRTFormat
    case operationAlreadyRunning
    case operationLockUnavailable
    case operationFailed
    case processOutputLineTooLongFormat
    case videoDurationLimitFormat
    case insufficientDiskSpaceFormat
    case insufficientMemoryFormat
    case cleanupFailedFormat
    case outputManifestFailed
    case commandFailedFormat
    case timeoutFormat
    case outputMissing
    case videoInvalidProbeOutput
    case videoInvalidDescription
    case videoNoAudio
    case videoDurationUnavailable
    case videoRunnerUnavailable
    case srtNotRegularFile
    case srtEmptyFile
    case srtTooLarge
    case srtInvalidUTF8
    case srtNoCues
    case srtCueMissingTextFormat
    case srtInvalidNumberingFormat
    case srtInvalidTimestampsFormat
    case srtEmptyCueTextFormat
    case logModelCheckingUpdate
    case logModelDownloading
    case logModelCurrent
    case logModelStopped
    case logModelSelectedExisting
    case processModelDownload
    case logTranscribingFormat
    case logTranslatingFormat
    case logTranslationNotRequired
    case logSavingValidatedSRT
    case logDoneCleanup
    case logQualityFormat
    case logTargetQualityWarningsFormat
    case logTargetOutputFailedFormat
    case logOutputSummaryFormat
    case approximateModelSize

    func text(_ language: AppLanguage) -> String {
        LocalizationCatalog.text(self, language: language)
    }

    func formatted(language: AppLanguage, arguments: [CVarArg]) -> String {
        String(
            format: text(language),
            locale: Locale(identifier: language.localeIdentifier),
            arguments: arguments
        )
    }
}

public enum PipelineStage: CaseIterable, Identifiable, Sendable {
    case checkingVideo
    case extractingAudio
    case transcribingSpeech
    case translatingSubtitles
    case savingSRT
    case done

    public var id: String {
        String(describing: self)
    }

    var key: TextKey {
        switch self {
        case .checkingVideo: return .checkingVideo
        case .extractingAudio: return .extractingAudio
        case .transcribingSpeech: return .transcribingSpeech
        case .translatingSubtitles: return .translatingSubtitles
        case .savingSRT: return .savingSRT
        case .done: return .done
        }
    }
}
