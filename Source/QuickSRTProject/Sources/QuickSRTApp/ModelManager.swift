import AppKit
import Combine
import Foundation

enum ModelDownloadResourcePreflight {
    static let requiredDiskBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    static func validate(_ snapshot: SystemResourceSnapshot) throws {
        guard snapshot.availableDiskBytes >= requiredDiskBytes else {
            throw QuickSRTError.insufficientWorkspaceSpace(
                requiredBytes: requiredDiskBytes,
                availableBytes: snapshot.availableDiskBytes
            )
        }
    }
}

struct ModelManagerEnvironment: Sendable {
    let python: URL
    let downloader: URL
    let repositoryID: String
    let modelsRoot: URL
    let resolveModel: @Sendable () -> URL?
    let selectModel: @Sendable (URL) -> URL?
    let useManagedModel: @Sendable () -> URL?
    let isManagedModel: @Sendable (URL) -> Bool
    let acquireOperationLock: @Sendable () throws -> InterprocessFileLock
    let cleanPartialDownloads: @Sendable () -> CleanupReport
    let cleanPartialDownloadsWhileLocked: @Sendable () -> CleanupReport
    let resourceSnapshot: @Sendable (URL) throws -> SystemResourceSnapshot
    let homeDirectory: URL

    init(
        python: URL,
        downloader: URL,
        repositoryID: String,
        modelsRoot: URL,
        resolveModel: @escaping @Sendable () -> URL?,
        selectModel: @escaping @Sendable (URL) -> URL?,
        useManagedModel: @escaping @Sendable () -> URL?,
        isManagedModel: @escaping @Sendable (URL) -> Bool,
        acquireOperationLock: @escaping @Sendable () throws -> InterprocessFileLock,
        cleanPartialDownloads: @escaping @Sendable () -> CleanupReport,
        cleanPartialDownloadsWhileLocked: @escaping @Sendable () -> CleanupReport,
        resourceSnapshot: @escaping @Sendable (URL) throws -> SystemResourceSnapshot = SystemResourceMonitor.snapshot,
        homeDirectory: URL
    ) {
        self.python = python
        self.downloader = downloader
        self.repositoryID = repositoryID
        self.modelsRoot = modelsRoot
        self.resolveModel = resolveModel
        self.selectModel = selectModel
        self.useManagedModel = useManagedModel
        self.isManagedModel = isManagedModel
        self.acquireOperationLock = acquireOperationLock
        self.cleanPartialDownloads = cleanPartialDownloads
        self.cleanPartialDownloadsWhileLocked = cleanPartialDownloadsWhileLocked
        self.resourceSnapshot = resourceSnapshot
        self.homeDirectory = homeDirectory
    }

    static let live = ModelManagerEnvironment(
        python: ProjectPaths.python,
        downloader: ProjectPaths.mlxWhisperDownloader,
        repositoryID: ProjectPaths.mlxWhisperRepositoryID,
        modelsRoot: ProjectPaths.mlxWhisperModelsRoot,
        resolveModel: ProjectPaths.resolvedMLXWhisperModel,
        selectModel: ProjectPaths.selectModel,
        useManagedModel: ProjectPaths.useManagedModel,
        isManagedModel: ProjectPaths.isManagedModel,
        acquireOperationLock: QuickSRTOperationLock.acquire,
        cleanPartialDownloads: ModelStorage.cleanPartialDownloads,
        cleanPartialDownloadsWhileLocked: ModelStorage.cleanPartialDownloadsWhileLocked,
        resourceSnapshot: SystemResourceMonitor.snapshot,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
}

protocol ModelDownloadRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        label: String,
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult

    func stopCurrent()
}

extension ProcessRunner: ModelDownloadRunning {}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    @Published private(set) var pathText = ""
    @Published private(set) var isManaged = false

    private let environment: ModelManagerEnvironment
    private let diagnostics: RuntimeDiagnostics
    private let logBuffer: LogBuffer
    private let downloader: any ModelDownloadRunning
    private var downloadTask: Task<Void, Never>?
    private var operationLock: InterprocessFileLock?
    private var activeDownloadID: UUID?

    init(
        environment: ModelManagerEnvironment = .live,
        diagnostics: RuntimeDiagnostics,
        logBuffer: LogBuffer,
        downloader: any ModelDownloadRunning = ProcessRunner()
    ) {
        self.environment = environment
        self.diagnostics = diagnostics
        self.logBuffer = logBuffer
        self.downloader = downloader
        refreshStatus()
    }

    func download(
        onStarted: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !isDownloading else { return }

        if let issue = diagnostics.modelDownloadIssue(
            python: environment.python,
            downloader: environment.downloader
        ) {
            onError(issue)
            return
        }

        if !isInstalled {
            do {
                try FileManager.default.createDirectory(
                    at: environment.modelsRoot,
                    withIntermediateDirectories: true
                )
                try ModelDownloadResourcePreflight.validate(
                    try environment.resourceSnapshot(environment.modelsRoot)
                )
            } catch {
                onError(error)
                return
            }
        }

        do {
            operationLock = try environment.acquireOperationLock()
        } catch InterprocessLockError.busy {
            onError(QuickSRTError.operationAlreadyRunning)
            return
        } catch {
            onError(QuickSRTError.operationLockUnavailable)
            return
        }

        reportCleanup(environment.cleanPartialDownloadsWhileLocked())
        onStarted()
        isDownloading = true
        let downloadID = UUID()
        activeDownloadID = downloadID
        logBuffer.append(.text(isInstalled ? .logModelCheckingUpdate : .logModelDownloading))

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await downloader.run(
                    executable: environment.python,
                    arguments: [
                        environment.downloader.path,
                        "--repo-id", environment.repositoryID,
                        "--models-dir", environment.modelsRoot.path
                    ],
                    label: AppProcessLabel.modelDownload,
                    timeout: 6 * 60 * 60,
                    onOutput: { [weak self] text in
                        Task { @MainActor in
                            guard self?.activeDownloadID == downloadID else { return }
                            self?.logBuffer.append(text)
                        }
                    }
                )

                await MainActor.run {
                    guard self.activeDownloadID == downloadID else { return }
                    self.markDownloadFinished()
                    self.reportCleanup(self.environment.cleanPartialDownloadsWhileLocked())
                    _ = self.environment.useManagedModel()
                    self.refreshStatus()
                    self.logBuffer.append(.text(.logModelCurrent))
                    self.releaseOperationLock()
                }
            } catch {
                await MainActor.run {
                    guard self.activeDownloadID == downloadID else { return }
                    self.markDownloadFinished()
                    self.reportCleanup(self.environment.cleanPartialDownloadsWhileLocked())
                    self.refreshStatus()
                    if error is CancellationError {
                        self.logBuffer.append(.text(.logModelStopped))
                    } else {
                        onError(error)
                    }
                    self.releaseOperationLock()
                }
            }
        }
    }

    func stopDownload() {
        guard isDownloading else { return }
        downloadTask?.cancel()
        downloader.stopCurrent()
    }

    func selectModel(at url: URL) -> Bool {
        guard environment.selectModel(url) != nil else { return false }
        refreshStatus()
        logBuffer.append(.text(.logModelSelectedExisting))
        return true
    }

    func refreshStatus() {
        if !isDownloading {
            reportCleanup(environment.cleanPartialDownloads())
        }

        if let model = environment.resolveModel() {
            isInstalled = true
            isManaged = environment.isManagedModel(model)
            pathText = abbreviatedPath(model)
        } else {
            isInstalled = false
            isManaged = false
            pathText = abbreviatedPath(environment.modelsRoot)
        }
    }

    func markDataDeleted() {
        isInstalled = false
        isManaged = false
        pathText = abbreviatedPath(environment.modelsRoot)
    }

    func transcriptionIssue(for language: RecognitionLanguage) -> QuickSRTError? {
        guard let model = environment.resolveModel() else {
            return .missingModel(environment.modelsRoot)
        }
        guard language == .english || ProjectPaths.supportsMultilingualTranscription(at: model) else {
            return .modelDoesNotSupportLanguage(language)
        }
        return nil
    }

    func openModelFolder() {
        let folder = environment.resolveModel()?.deletingLastPathComponent() ?? environment.modelsRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func stopForShutdown() {
        downloadTask?.cancel()
        downloader.stopCurrent()
    }

    func stopForShutdownAndWait() async {
        let task = downloadTask
        stopForShutdown()
        await task?.value
    }

    private func markDownloadFinished() {
        activeDownloadID = nil
        isDownloading = false
        downloadTask = nil
    }

    private func releaseOperationLock() {
        operationLock?.unlock()
        operationLock = nil
    }

    private func reportCleanup(_ report: CleanupReport) {
        guard !report.isSuccessful else { return }
        logBuffer.append(.cleanupFailed(count: report.failures.count))
    }

    private func abbreviatedPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: environment.homeDirectory.path, with: "~")
    }
}
