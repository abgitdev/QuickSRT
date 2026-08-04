import Foundation

public enum VideoValidationFailure: Equatable, Sendable {
    case invalidProbeOutput
    case invalidDescription
    case noAudioTrack
    case durationUnavailable
    case runnerUnavailable

    var englishDescription: String {
        switch self {
        case .invalidProbeOutput:
            return "ffprobe returned invalid output."
        case .invalidDescription:
            return "ffprobe did not return a valid file description."
        case .noAudioTrack:
            return "The video does not contain an audio track."
        case .durationUnavailable:
            return "The video duration could not be determined."
        case .runnerUnavailable:
            return "The MLX Whisper runner is unavailable."
        }
    }
}

public enum SRTValidationFailure: Equatable, Sendable {
    case notRegularFile
    case emptyFile
    case unexpectedlyLarge
    case invalidUTF8
    case noCues
    case cueMissingText(Int)
    case invalidNumbering(Int)
    case invalidTimestamps(Int)
    case emptyCueText(Int)

    var englishDescription: String {
        switch self {
        case .notRegularFile:
            return "The output is not a regular file."
        case .emptyFile:
            return "The output file is empty."
        case .unexpectedlyLarge:
            return "The output file is unexpectedly large."
        case .invalidUTF8:
            return "The output is not valid UTF-8 text."
        case .noCues:
            return "No subtitle cues were found."
        case let .cueMissingText(index):
            return "Cue \(index) has no subtitle text."
        case let .invalidNumbering(index):
            return "Cue numbering is invalid at item \(index)."
        case let .invalidTimestamps(index):
            return "Cue \(index) has invalid or non-monotonic timestamps."
        case let .emptyCueText(index):
            return "Cue \(index) has empty subtitle text."
        }
    }
}

public enum QuickSRTError: LocalizedError, Sendable {
    case missingExecutable(name: String, url: URL)
    case missingVenvPython(URL)
    case missingModel(URL)
    case modelDoesNotSupportLanguage(RecognitionLanguage)
    case invalidVideo(VideoValidationFailure)
    case invalidSRT(SRTValidationFailure)
    case invalidTimeline(String)
    case translationRequiresNewerMacOS
    case translationPairUnsupported(source: RecognitionLanguage, target: RecognitionLanguage)
    case translationNotReady
    case translationFailed(String)
    case translationOutputInvalid
    case languageDetectionFailed
    case operationAlreadyRunning
    case operationLockUnavailable
    case processOutputLineTooLong(label: String, maximumBytes: Int)
    case videoDurationLimitExceeded(maximum: TimeInterval)
    case insufficientWorkspaceSpace(requiredBytes: Int64, availableBytes: Int64)
    case insufficientAvailableMemory(requiredBytes: UInt64, availableBytes: UInt64)
    case outputDestinationChanged
    case cleanupFailed(primaryFailure: String?, failures: [CleanupFailure])
    case commandFailed(label: String, exitCode: Int32, details: String)
    case timeout(label: String, seconds: TimeInterval)
    case outputMissing(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingExecutable(name, _):
            return "The \(name) component is unavailable. Reinstall the local QuickSRT build."
        case .missingVenvPython:
            return "The local Python runtime is unavailable. Reinstall the local QuickSRT build."
        case .missingModel:
            return "MLX Whisper large-v3 was not found. Use Download in QuickSRT."
        case let .modelDoesNotSupportLanguage(language):
            return "The selected MLX Whisper model cannot transcribe \(language.localizedName(.english)). Choose a multilingual MLX Whisper model."
        case let .invalidVideo(failure):
            return failure.englishDescription
        case let .invalidSRT(failure):
            return "Invalid SRT output: \(failure.englishDescription)"
        case let .invalidTimeline(details):
            return "Invalid timed transcript: \(details)"
        case .translationRequiresNewerMacOS:
            return "Subtitle translation requires macOS 15 or newer."
        case let .translationPairUnsupported(source, target):
            return "Translation from \(source.localizedName(.english)) to \(target.localizedName(.english)) is not supported on this Mac."
        case .translationNotReady:
            return "The selected translation languages are not ready yet."
        case let .translationFailed(details):
            return "Subtitle translation failed.\n\(details)"
        case .translationOutputInvalid:
            return "Translated subtitles could not pass completeness, timing, or readability checks."
        case .languageDetectionFailed:
            return "QuickSRT could not determine the spoken language."
        case .operationAlreadyRunning:
            return "Another QuickSRT operation is already running. Wait for it to finish."
        case .operationLockUnavailable:
            return "QuickSRT could not enable single-operation protection. Restart the app and try again."
        case let .processOutputLineTooLong(label, maximumBytes):
            return "\(label) produced a line longer than the \(maximumBytes)-byte safety limit. The process was stopped."
        case let .videoDurationLimitExceeded(maximum):
            return "The selected video exceeds the \(DurationFormatter.string(from: maximum)) processing limit."
        case let .insufficientWorkspaceSpace(requiredBytes, availableBytes):
            return "Not enough free disk space for temporary audio and timeline data (required \(Self.bytes(requiredBytes)), available \(Self.bytes(availableBytes)))."
        case let .insufficientAvailableMemory(requiredBytes, availableBytes):
            return "Not enough memory is currently available for local transcription (required \(Self.bytes(requiredBytes)), available \(Self.bytes(availableBytes)))."
        case .outputDestinationChanged:
            return "The selected SRT destination changed after it was approved. No file was overwritten. Review the destination and start the queue again."
        case let .cleanupFailed(primaryFailure, failures):
            let prefix = primaryFailure.map { "\($0) " } ?? ""
            return "\(prefix)QuickSRT could not remove \(failures.count) owned temporary item(s). See the cleanup report."
        case let .commandFailed(label, exitCode, details):
            return "\(label) exited with code \(exitCode).\n\(details)"
        case let .timeout(label, seconds):
            return "\(label) ran longer than \(DurationFormatter.string(from: seconds)). The process was stopped; temporary-file cleanup is reported separately."
        case .outputMissing:
            return "MLX Whisper did not create a subtitle file."
        }
    }

    private static func bytes<T: BinaryInteger>(_ value: T) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
