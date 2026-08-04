import Foundation
@testable import QuickSRT
import XCTest

@MainActor
final class ModelManagerTests: XCTestCase {
    func testCleanInstallRunsManagedDownloaderAndSelectsInstalledModel() async throws {
        let fixture = try ModelManagerFixture(initialModel: nil)
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .success)
        let manager = fixture.manager(downloader: downloader)
        var started = false
        var receivedError: Error?

        manager.download(
            onStarted: { started = true },
            onError: { receivedError = $0 }
        )
        try await waitUntil { !manager.isDownloading }

        XCTAssertTrue(started)
        XCTAssertNil(receivedError)
        XCTAssertTrue(manager.isInstalled)
        XCTAssertTrue(manager.isManaged)
        let invocation = try XCTUnwrap(downloader.invocations.first)
        XCTAssertEqual(invocation.executable, fixture.python)
        XCTAssertEqual(invocation.arguments, [
            fixture.downloaderScript.path,
            "--repo-id", fixture.repositoryID,
            "--models-dir", fixture.modelsRoot.path,
        ])
    }

    func testUpdateUsesSameVerifiedManagedDownloadPath() async throws {
        let fixture = try ModelManagerFixture(initialModel: .managed)
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .success)
        let manager = fixture.manager(downloader: downloader)

        manager.download(onStarted: {}, onError: { XCTFail("Unexpected error: \($0)") })
        try await waitUntil { !manager.isDownloading }

        XCTAssertEqual(downloader.invocations.count, 1)
        XCTAssertTrue(manager.isInstalled)
        XCTAssertTrue(manager.isManaged)
    }

    func testCancelDownloadStopsRunnerAndReturnsToIdle() async throws {
        let fixture = try ModelManagerFixture(initialModel: .managed)
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .waitForCancellation)
        let manager = fixture.manager(downloader: downloader)
        var receivedError: Error?

        manager.download(onStarted: {}, onError: { receivedError = $0 })
        try await waitUntil { downloader.hasStarted }
        manager.stopDownload()
        try await waitUntil { !manager.isDownloading }

        XCTAssertEqual(downloader.stopCount, 1)
        XCTAssertNil(receivedError)
    }

    func testShutdownKeepsOperationLockUntilDownloaderActuallyFinishes() async throws {
        let fixture = try ModelManagerFixture(initialModel: .managed)
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .waitForManualCompletion)
        let manager = fixture.manager(downloader: downloader)

        manager.download(onStarted: {}, onError: { error in
            if !(error is CancellationError) { XCTFail("Unexpected shutdown error: \(error)") }
        })
        try await waitUntil { downloader.hasStarted }
        manager.stopForShutdown()

        XCTAssertTrue(manager.isDownloading)
        XCTAssertThrowsError(try InterprocessFileLock.acquire(at: fixture.operationLockURL)) { error in
            guard case InterprocessLockError.busy = error else {
                return XCTFail("Expected the model operation lock to remain busy, got \(error)")
            }
        }

        downloader.allowCompletion()
        await manager.stopForShutdownAndWait()
        let reacquired = try InterprocessFileLock.acquire(at: fixture.operationLockURL)
        reacquired.unlock()
        XCTAssertFalse(manager.isDownloading)
    }

    func testNetworkFailureIsReportedAndPartialCleanupRuns() async throws {
        let fixture = try ModelManagerFixture(initialModel: .managed)
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .failure)
        let manager = fixture.manager(downloader: downloader)
        var receivedError: Error?

        manager.download(onStarted: {}, onError: { receivedError = $0 })
        try await waitUntil { !manager.isDownloading && receivedError != nil }

        guard case QuickSRTError.commandFailed? = receivedError else {
            return XCTFail("Expected a controlled downloader command failure.")
        }
        XCTAssertGreaterThanOrEqual(fixture.lockedCleanupCount, 2)
    }

    func testInsufficientDiskFailsBeforeDownloaderOrOperationLock() async throws {
        let fixture = try ModelManagerFixture(
            initialModel: nil,
            resourceSnapshot: SystemResourceSnapshot(
                availableDiskBytes: ModelDownloadResourcePreflight.requiredDiskBytes - 1,
                availableMemoryBytes: UInt64.max
            )
        )
        defer { fixture.remove() }
        let downloader = TestModelDownloader(behavior: .success)
        let manager = fixture.manager(downloader: downloader)
        var receivedError: Error?

        manager.download(onStarted: { XCTFail("Download must not start.") }, onError: { receivedError = $0 })

        guard case QuickSRTError.insufficientWorkspaceSpace? = receivedError else {
            return XCTFail("Expected a disk-space preflight failure.")
        }
        XCTAssertTrue(downloader.invocations.isEmpty)
        XCTAssertFalse(manager.isDownloading)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for ModelManager state.")
    }
}

private final class TestModelDownloader: ModelDownloadRunning, @unchecked Sendable {
    enum Behavior: Sendable {
        case success
        case failure
        case waitForCancellation
        case waitForManualCompletion
    }

    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private struct State {
        var invocations: [Invocation] = []
        var stopCount = 0
        var hasStarted = false
        var mayComplete = false
    }

    private let behavior: Behavior
    private let state = LockedValue(State())

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var invocations: [Invocation] { state.withLock { $0.invocations } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var hasStarted: Bool { state.withLock { $0.hasStarted } }

    func allowCompletion() {
        state.withLock { $0.mayComplete = true }
    }

    func run(
        executable: URL,
        arguments: [String],
        label: String,
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        state.withLock {
            $0.invocations.append(Invocation(executable: executable, arguments: arguments))
            $0.hasStarted = true
        }
        switch behavior {
        case .success:
            onOutput("download complete\n")
            return CommandResult(stdout: "", stderr: "")
        case .failure:
            throw QuickSRTError.commandFailed(
                label: label,
                exitCode: 1,
                details: "simulated network failure"
            )
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return CommandResult(stdout: "", stderr: "")
        case .waitForManualCompletion:
            while !state.withLock({ $0.mayComplete }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
    }

    func stopCurrent() {
        state.withLock { $0.stopCount += 1 }
    }
}

private final class ModelManagerFixture: @unchecked Sendable {
    enum InitialModel {
        case managed
    }

    let root: URL
    let python: URL
    let downloaderScript: URL
    let modelsRoot: URL
    let managedModel: URL
    let repositoryID = "example/whisper-model"
    var operationLockURL: URL { root.appendingPathComponent("operation.lock") }

    private let selectedModel: LockedValue<URL?>
    private let cleanupCounts = LockedValue((regular: 0, locked: 0))
    private let resourceSnapshot: SystemResourceSnapshot

    init(
        initialModel: InitialModel?,
        resourceSnapshot: SystemResourceSnapshot = SystemResourceSnapshot(
            availableDiskBytes: Int64.max,
            availableMemoryBytes: UInt64.max
        )
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-ModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        python = root.appendingPathComponent("python")
        downloaderScript = root.appendingPathComponent("download.py")
        modelsRoot = root.appendingPathComponent("Models", isDirectory: true)
        managedModel = modelsRoot.appendingPathComponent("managed", isDirectory: true)
        switch initialModel {
        case .managed:
            selectedModel = LockedValue(managedModel)
        case nil:
            selectedModel = LockedValue(nil)
        }
        self.resourceSnapshot = resourceSnapshot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var lockedCleanupCount: Int { cleanupCounts.withLock { $0.locked } }

    @MainActor
    func manager(downloader: TestModelDownloader) -> ModelManager {
        ModelManager(
            environment: ModelManagerEnvironment(
                python: python,
                downloader: downloaderScript,
                repositoryID: repositoryID,
                modelsRoot: modelsRoot,
                resolveModel: { [selectedModel] in selectedModel.withLock { $0 } },
                selectModel: { [selectedModel] url in
                    selectedModel.withLock { $0 = url }
                    return url
                },
                useManagedModel: { [selectedModel, managedModel] in
                    selectedModel.withLock { $0 = managedModel }
                    return managedModel
                },
                isManagedModel: { [managedModel] in $0 == managedModel },
                acquireOperationLock: { [root] in
                    try InterprocessFileLock.acquire(at: root.appendingPathComponent("operation.lock"))
                },
                cleanPartialDownloads: { [cleanupCounts] in
                    cleanupCounts.withLock { $0.regular += 1 }
                    return CleanupReport()
                },
                cleanPartialDownloadsWhileLocked: { [cleanupCounts] in
                    cleanupCounts.withLock { $0.locked += 1 }
                    return CleanupReport()
                },
                resourceSnapshot: { [resourceSnapshot] _ in resourceSnapshot },
                homeDirectory: root
            ),
            diagnostics: RuntimeDiagnostics(isExecutable: { _ in true }, fileExists: { _ in true }),
            logBuffer: LogBuffer(),
            downloader: downloader
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
