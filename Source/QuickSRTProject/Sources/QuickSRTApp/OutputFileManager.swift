import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct OutputFileManager {
    enum ExistingDestinationDecision: Equatable {
        case replace
        case chooseAnother(URL?)
        case cancel
    }

    static func suggestedOutputURL(
        for videoURL: URL,
        targetLanguage: RecognitionLanguage = .english
    ) -> URL {
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        return videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(targetLanguage.rawValue).srt")
    }

    static func reservationKey(for url: URL) -> String {
        let parent = url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let name = url.lastPathComponent
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return parent + "/" + name
    }

    static func suggestedOutputURL(
        for videoURL: URL,
        targetLanguage: RecognitionLanguage,
        avoiding reservedKeys: Set<String>
    ) -> URL {
        let suggested = suggestedOutputURL(for: videoURL, targetLanguage: targetLanguage)
        guard reservedKeys.contains(reservationKey(for: suggested)) else { return suggested }

        let sourceExtension = videoURL.pathExtension.lowercased()
        if !sourceExtension.isEmpty {
            let extensionQualified = videoURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(videoURL.deletingPathExtension().lastPathComponent).\(sourceExtension).\(targetLanguage.rawValue).srt"
                )
            if !reservedKeys.contains(reservationKey(for: extensionQualified)) {
                return extensionQualified
            }
        }

        return nextAvailableURL(basedOn: suggested, avoiding: reservedKeys)
    }

    func resolveDestination(
        for videoURL: URL,
        targetLanguage: RecognitionLanguage,
        localization: LocalizationController,
        avoiding reservedKeys: Set<String> = []
    ) throws -> OutputDestination? {
        var candidate = Self.suggestedOutputURL(
            for: videoURL,
            targetLanguage: targetLanguage,
            avoiding: reservedKeys
        )

        while true {
            if reservedKeys.contains(Self.reservationKey(for: candidate)) {
                let alternative = Self.nextAvailableURL(basedOn: candidate, avoiding: reservedKeys)
                guard let selected = chooseAnotherURL(suggested: alternative, localization: localization) else {
                    return nil
                }
                candidate = selected
                continue
            }

            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return try OutputDestination.authorizingCurrentState(candidate)
            }

            let alert = NSAlert()
            alert.messageText = localization.text(.srtExistsTitle)
            alert.informativeText = candidate.path
            alert.addButton(withTitle: localization.text(.replace))
            alert.addButton(withTitle: localization.text(.chooseAnotherName))
            alert.addButton(withTitle: localization.text(.cancel))

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return try OutputDestination.authorizingCurrentState(candidate)
            case .alertSecondButtonReturn:
                guard let selected = chooseAnotherURL(suggested: candidate, localization: localization) else {
                    return nil
                }
                candidate = selected
            default:
                return nil
            }
        }
    }

    private func chooseAnotherURL(
        suggested: URL,
        localization: LocalizationController
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = localization.text(.saveSRT)
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.allowedContentTypes = [.srt]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func nextAvailableURL(basedOn suggested: URL, avoiding reservedKeys: Set<String>) -> URL {
        let parent = suggested.deletingLastPathComponent()
        let extensionName = suggested.pathExtension
        let stem = suggested.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let name = extensionName.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(extensionName)"
            let candidate = parent.appendingPathComponent(name)
            if !reservedKeys.contains(reservationKey(for: candidate)) { return candidate }
            suffix += 1
        }
    }

    static func resolveExistingDestination(
        _ suggested: URL,
        decision: ExistingDestinationDecision
    ) -> URL? {
        switch decision {
        case .replace:
            return suggested
        case let .chooseAnother(url):
            return url
        case .cancel:
            return nil
        }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

extension UTType {
    static var srt: UTType {
        UTType(filenameExtension: "srt") ?? .plainText
    }
}
