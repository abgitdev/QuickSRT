import Foundation

enum RuntimeDiagnosticIssue: Error, Equatable {
    case missingPython(URL)
    case missingModelDownloader(URL)
}

struct RuntimeDiagnostics {
    private let isExecutable: (String) -> Bool
    private let fileExists: (String) -> Bool

    init(
        isExecutable: @escaping (String) -> Bool = FileManager.default.isExecutableFile,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists
    ) {
        self.isExecutable = isExecutable
        self.fileExists = fileExists
    }

    func modelDownloadIssue(python: URL, downloader: URL) -> RuntimeDiagnosticIssue? {
        guard isExecutable(python.path) else {
            return .missingPython(python)
        }
        guard fileExists(downloader.path) else {
            return .missingModelDownloader(downloader)
        }
        return nil
    }
}
