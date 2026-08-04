import Darwin
import AppKit
import Foundation
@testable import QuickSRT
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testSupportFileInsideInstalledRootRequiresManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-ManifestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("tool")
        try Data("tool".utf8).write(to: tool)

        XCTAssertThrowsError(try SupportBundleIntegrity.validate(file: tool, root: root)) { error in
            XCTAssertEqual((error as NSError).domain, "QuickSRT.SupportIntegrity")
            XCTAssertEqual((error as NSError).code, 3)
        }
    }

    func testExternalUserInputDoesNotRequireSupportManifest() throws {
        let root = URL(fileURLWithPath: "/Applications/QuickSRT.app/Contents/Resources/QuickSRTSupport")
        let input = URL(fileURLWithPath: "/Volumes/Media/video.mov")

        XCTAssertNoThrow(try SupportBundleIntegrity.validate(file: input, root: root))
    }

    func testRepeatedStopStartsTerminationOnlyOnce() {
        let recorder = SignalRecorder()
        let controller = ProcessTerminationController(
            pid: 42,
            gracePeriod: 0.05,
            isSameProcess: { true },
            sendSignal: { recorder.record($0) }
        )

        controller.terminateTree()
        controller.terminateTree()
        controller.terminateTree()
        controller.markExited()

        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testNormalExitCancelsPendingForcedTermination() async throws {
        let recorder = SignalRecorder()
        let controller = ProcessTerminationController(
            pid: 42,
            gracePeriod: 0.03,
            isSameProcess: { true },
            sendSignal: { recorder.record($0) }
        )

        controller.terminateTree()
        controller.markExited()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testPIDReuseProtectionPreventsForcedTerminationAfterIdentityChanges() async throws {
        let recorder = SignalRecorder()
        let controller = ProcessTerminationController(
            pid: 42,
            gracePeriod: 0.03,
            isSameProcess: { false },
            sendSignal: { recorder.record($0) }
        )

        controller.terminateTree()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.signals, [SIGTERM])
    }

    func testStillRunningProcessReceivesSingleForcedTermination() async throws {
        let recorder = SignalRecorder()
        let controller = ProcessTerminationController(
            pid: 42,
            gracePeriod: 0.03,
            isSameProcess: { true },
            sendSignal: { recorder.record($0) }
        )

        controller.terminateTree()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.terminateTree()

        XCTAssertEqual(recorder.signals, [SIGTERM, SIGKILL])
    }

    func testStopAfterExitSendsNoSignal() {
        let recorder = SignalRecorder()
        let controller = ProcessTerminationController(
            pid: 42,
            gracePeriod: 0.03,
            isSameProcess: { true },
            sendSignal: { recorder.record($0) }
        )

        controller.markExited()
        controller.terminateTree()

        XCTAssertTrue(recorder.signals.isEmpty)
    }

    func testStopDuringFFmpegStage() async throws {
        try await assertProcessStopsExactlyOnce(stage: "ffmpeg")
    }

    func testStopDuringWhisperStage() async throws {
        try await assertProcessStopsExactlyOnce(stage: "MLX Whisper")
    }

    func testStopDuringModelDownloadStage() async throws {
        try await assertProcessStopsExactlyOnce(stage: "model download")
    }

    func testRealSIGKILLFallbackStopsTERMRejectingProcess() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let runner = ProcessRunner(terminationGracePeriod: 0.15)
        let task = fixture.start(
            runner: runner,
            script: """
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], "w").write(str(os.getpid()))
            while True: time.sleep(1)
            """
        )
        let pids = try await fixture.waitForPIDs(count: 1)

        let started = Date()
        task.cancel()
        runner.stopCurrent()
        await assertCancelled(task)

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.10)
        try await assertNoOrphanOrZombie(pids)
        XCTAssertFalse(runner.hasActiveProcess)
    }

    func testRealProcessTreeTerminationStopsChild() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let runner = ProcessRunner(terminationGracePeriod: 0.15)
        let task = fixture.start(
            runner: runner,
            script: """
            import os, signal, sys, time
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True: time.sleep(1)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], "w").write(f"{os.getpid()} {child}")
            while True: time.sleep(1)
            """
        )
        let pids = try await fixture.waitForPIDs(count: 2)

        task.cancel()
        runner.stopCurrent()
        await assertCancelled(task)

        try await assertNoOrphanOrZombie(pids)
        XCTAssertFalse(runner.hasActiveProcess)
    }

    func testDescendantHoldingPipeCannotBlockSIGKILLFallback() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let runner = ProcessRunner(terminationGracePeriod: 0.15)
        let task = fixture.start(
            runner: runner,
            script: """
            import os, signal, sys, time
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True: time.sleep(1)
            open(sys.argv[1], "w").write(f"{os.getpid()} {child}")
            while True: time.sleep(1)
            """
        )
        let pids = try await fixture.waitForPIDs(count: 2)

        let started = Date()
        task.cancel()
        runner.stopCurrent()
        await assertCancelled(task)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await assertNoOrphanOrZombie(pids)
        XCTAssertFalse(runner.hasActiveProcess)
    }

    func testQuitStopsConcurrentTranscriptionAndModelDownloadProcesses() async throws {
        let transcriptionFixture = try ProcessFixture()
        let downloadFixture = try ProcessFixture()
        defer {
            transcriptionFixture.cleanUp()
            downloadFixture.cleanUp()
        }
        let transcriptionRunner = ProcessRunner(terminationGracePeriod: 0.15)
        let downloadRunner = ProcessRunner(terminationGracePeriod: 0.15)
        let script = """
        import os, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(sys.argv[1], "w").write(str(os.getpid()))
        while True: time.sleep(1)
        """
        let transcription = transcriptionFixture.start(
            runner: transcriptionRunner,
            label: "MLX Whisper",
            script: script
        )
        let download = downloadFixture.start(
            runner: downloadRunner,
            label: "model download",
            script: script
        )
        let transcriptionPIDs = try await transcriptionFixture.waitForPIDs(count: 1)
        let downloadPIDs = try await downloadFixture.waitForPIDs(count: 1)

        ProcessRegistry.shared.terminateAll()
        await assertTerminated(transcription)
        await assertTerminated(download)

        try await assertNoOrphanOrZombie(transcriptionPIDs + downloadPIDs)
        XCTAssertFalse(transcriptionRunner.hasActiveProcess)
        XCTAssertFalse(downloadRunner.hasActiveProcess)
    }

    @MainActor
    func testApplicationTerminationReplyWaitsForTERMRejectingProcess() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let runner = ProcessRunner(terminationGracePeriod: 0.15)
        let task = fixture.start(
            runner: runner,
            script: """
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], "w").write(str(os.getpid()))
            while True: time.sleep(1)
            """
        )
        let pids = try await fixture.waitForPIDs(count: 1)
        let delegate = AppDelegate()

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        do {
            _ = try await task.value
            XCTFail("The process unexpectedly succeeded.")
        } catch is CancellationError {
            XCTFail("Application termination must not require task cancellation.")
        } catch {
            // A signal-derived command failure is the expected outcome.
        }
        XCTAssertTrue(pids.allSatisfy { pid in
            errno = 0
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        })
        XCTAssertFalse(runner.hasActiveProcess)
    }

    private func assertProcessStopsExactlyOnce(stage: String) async throws {
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                label: stage,
                timeout: 60,
                onOutput: { _ in }
            )
        }

        try await waitUntilProcessIsActive(runner)
        let stopStartedAt = Date()
        task.cancel()
        runner.stopCurrent()
        runner.stopCurrent()

        do {
            _ = try await task.value
            XCTFail("The \(stage) process unexpectedly completed successfully.")
        } catch is CancellationError {
            // Expected: task cancellation owns the single final outcome.
        } catch {
            XCTFail("The \(stage) process returned the wrong final outcome: \(error)")
        }

        XCTAssertFalse(runner.hasActiveProcess)
        XCTAssertLessThan(
            Date().timeIntervalSince(stopStartedAt),
            1,
            "The \(stage) process did not respond promptly to SIGTERM."
        )
    }

    private func waitUntilProcessIsActive(_ runner: ProcessRunner) async throws {
        for _ in 0..<100 {
            if runner.hasActiveProcess {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The child process did not start in time.")
        throw TestFailure.processDidNotStart
    }

    private func assertCancelled(
        _ task: Task<CommandResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("The process unexpectedly succeeded.", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error).", file: file, line: line)
        }
    }

    private func assertTerminated(
        _ task: Task<CommandResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("The process unexpectedly succeeded.", file: file, line: line)
        } catch is CancellationError {
            XCTFail("Registry termination must not require task cancellation.", file: file, line: line)
        } catch {
            // A signal-derived command failure is the expected non-cancelled result.
        }
    }

    private func assertNoOrphanOrZombie(
        _ pids: [pid_t],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if pids.allSatisfy({ pid in
                errno = 0
                return Darwin.kill(pid, 0) == -1 && errno == ESRCH
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let survivors = pids.filter { Darwin.kill($0, 0) == 0 || errno != ESRCH }
        XCTFail("Orphan or zombie processes remain: \(survivors)", file: file, line: line)
        for pid in survivors {
            _ = Darwin.kill(pid, SIGKILL)
        }
        throw TestFailure.processDidNotExit
    }
}

private final class ProcessFixture: @unchecked Sendable {
    private let root: URL
    private let pidFile: URL
    private let lock = NSLock()
    private var observedPIDs: [pid_t] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-ProcessTests-\(UUID().uuidString)", isDirectory: true)
        pidFile = root.appendingPathComponent("pids.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start(
        runner: ProcessRunner,
        label: String = "process fixture",
        script: String
    ) -> Task<CommandResult, Error> {
        Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, pidFile.path],
                label: label,
                timeout: 10,
                onOutput: { _ in }
            )
        }
    }

    func waitForPIDs(count: Int) async throws -> [pid_t] {
        for _ in 0..<300 {
            if
                let text = try? String(contentsOf: pidFile, encoding: .utf8),
                text.split(whereSeparator: \.isWhitespace).count == count
            {
                let values = text.split(whereSeparator: \.isWhitespace).compactMap {
                    pid_t(String($0))
                }
                if values.count == count {
                    lock.withLock {
                        observedPIDs = values
                    }
                    return values
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestFailure.processDidNotStart
    }

    func cleanUp() {
        let pids = lock.withLock { observedPIDs }
        for pid in pids where Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var signals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ signal: Int32) {
        lock.lock()
        storage.append(signal)
        lock.unlock()
    }
}

private enum TestFailure: Error {
    case processDidNotStart
    case processDidNotExit
}
