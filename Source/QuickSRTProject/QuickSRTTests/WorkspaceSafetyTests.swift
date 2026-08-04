import Darwin
import Foundation
@testable import QuickSRT
import XCTest

final class WorkspaceSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-WorkspaceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: QuickSRTOperationLock.lockURL(in: root))
        }
        root = nil
    }

    func testSafeJobPathRequiresExactUUIDNameAndDirectParent() {
        let valid = root.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        let invalidName = root.appendingPathComponent("job-not-a-uuid", isDirectory: true)
        let nested = root.appendingPathComponent("nested/job-\(UUID().uuidString)", isDirectory: true)
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)

        XCTAssertTrue(TempWorkspace.isSafeJobDirectory(valid, inside: root))
        XCTAssertFalse(TempWorkspace.isSafeJobDirectory(invalidName, inside: root))
        XCTAssertFalse(TempWorkspace.isSafeJobDirectory(nested, inside: root))
        XCTAssertFalse(TempWorkspace.isSafeJobDirectory(sibling, inside: root))
    }

    func testCleanerNeverDeletesActiveJob() throws {
        let job = try TempWorkspace.createJobDirectory(in: root)
        let marker = job.url.appendingPathComponent("active.txt")
        try "active".write(to: marker, atomically: true, encoding: .utf8)

        TempWorkspace.cleanStaleJobs(in: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        job.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.url.path))
    }

    func testCleanerDeletesOnlyOrphanedExactJobDirectories() throws {
        let orphan = root.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        let invalid = root.appendingPathComponent("job-not-a-uuid", isDirectory: true)
        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("QuickSRT-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideMarker = outside.appendingPathComponent("keep.txt")
        try "keep".write(to: outsideMarker, atomically: true, encoding: .utf8)
        let symlink = root.appendingPathComponent("job-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        TempWorkspace.cleanStaleJobs(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
    }

    func testOperationLockRejectsSecondHolderAndCanBeReacquired() throws {
        let first = try QuickSRTOperationLock.acquire(in: root)
        XCTAssertThrowsError(try QuickSRTOperationLock.acquire(in: root)) { error in
            guard case InterprocessLockError.busy = error else {
                return XCTFail("Expected a busy lock, got \(error)")
            }
        }

        first.unlock()
        let second = try QuickSRTOperationLock.acquire(in: root)
        second.unlock()
    }

    func testOperationLockRemainsExclusiveWhenProtectedTempRootIsDeleted() throws {
        let first = try QuickSRTOperationLock.acquire(in: root)
        try FileManager.default.removeItem(at: root)

        XCTAssertThrowsError(try QuickSRTOperationLock.acquire(in: root)) { error in
            guard case InterprocessLockError.busy = error else {
                return XCTFail("Expected the stable sibling lock to remain busy, got \(error)")
            }
        }

        first.unlock()
        let second = try QuickSRTOperationLock.acquire(in: root)
        second.unlock()
    }

    func testTwoConcurrentInstancesOnlyOneAcquiresOperationLock() async throws {
        let lockURL = root.appendingPathComponent("cross-process.lock")
        let first = try InterprocessFileLock.acquire(at: lockURL)

        let busyResult = try await pythonLockProbe(lockURL)
        XCTAssertEqual(busyResult, "BUSY")

        first.unlock()
        let availableResult = try await pythonLockProbe(lockURL)
        XCTAssertEqual(availableResult, "ACQUIRED")
    }

    func testForceQuitReleasesJobLockAndRecoveryRemovesWorkspace() async throws {
        let job = root.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        let activeLock = job.appendingPathComponent(".active.lock")
        let ready = job.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let script = """
        import fcntl
        import os
        import sys
        import time
        handle = open(sys.argv[1], "a+")
        fcntl.lockf(handle, fcntl.LOCK_EX)
        with open(sys.argv[2], "w") as ready:
            ready.write(str(os.getpid()))
            ready.flush()
            os.fsync(ready.fileno())
        while True: time.sleep(1)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, activeLock.path, ready.path]
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        for _ in 0..<1_500 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            XCTFail("Timed out waiting for the lock-holder readiness marker")
            return
        }
        TempWorkspace.cleanStaleJobs(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.path))

        let pid = process.processIdentifier
        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        TempWorkspace.cleanStaleJobs(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
    }

    func testPowerLossRecoveryDeletesOnlyManifestedExternalTemporaryFile() throws {
        let outputRoot = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let tracked = outputRoot.appendingPathComponent(
            ".quicksrt-\(UUID().uuidString)-movie.en.srt.tmp"
        )
        let untracked = outputRoot.appendingPathComponent(
            ".quicksrt-\(UUID().uuidString)-other.en.srt.tmp"
        )
        let job = try TempWorkspace.createJobDirectory(in: root)
        try job.trackOutputStagingArtifact(tracked)
        try "tracked".write(to: tracked, atomically: false, encoding: .utf8)
        try "untracked".write(to: untracked, atomically: false, encoding: .utf8)
        let jobURL = job.url
        job.abandonForRecoveryTest()

        let report = TempWorkspace.cleanStaleJobs(in: root)

        XCTAssertTrue(report.isSuccessful, "\(report.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
    }

    func testRecoveryAfterSIGTERMDeletesManifestedExternalTemporaryFile() async throws {
        try await assertSignalRecovery(signal: SIGTERM, ignoresTERM: false)
    }

    func testRecoveryAfterSIGKILLDeletesManifestedExternalTemporaryFile() async throws {
        try await assertSignalRecovery(signal: SIGKILL, ignoresTERM: true)
    }

    func testRecoveryRejectsOutputParentReplacedBySymlink() throws {
        let outputRoot = root.appendingPathComponent("outputs", isDirectory: true)
        let movedRoot = root.appendingPathComponent("outputs-original", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("QuickSRT-symlink-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { _ = SafeFileRemoval.removeItem(at: outside, containedIn: outside.deletingLastPathComponent()) }

        let fileName = ".quicksrt-\(UUID().uuidString)-movie.en.srt.tmp"
        let tracked = outputRoot.appendingPathComponent(fileName)
        let job = try TempWorkspace.createJobDirectory(in: root)
        try job.trackOutputStagingArtifact(tracked)
        job.abandonForRecoveryTest()

        try FileManager.default.moveItem(at: outputRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: outputRoot, withDestinationURL: outside)
        let outsideFile = outside.appendingPathComponent(fileName)
        try "outside".write(to: outsideFile, atomically: false, encoding: .utf8)

        let report = TempWorkspace.cleanStaleJobs(in: root)

        XCTAssertFalse(report.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        XCTAssertTrue(report.failures.contains { $0.path == outsideFile.path || $0.path == tracked.path })

        try FileManager.default.removeItem(at: outputRoot)
        try FileManager.default.moveItem(at: movedRoot, to: outputRoot)
        let finalReport = TempWorkspace.cleanStaleJobs(in: root)
        XCTAssertTrue(finalReport.isSuccessful, "\(finalReport.failures)")
    }

    func testModelCleanupRemovesOnlyOldPartialAndLockArtifacts() throws {
        let oldIncomplete = root.appendingPathComponent("old.incomplete")
        let recentIncomplete = root.appendingPathComponent("recent.incomplete")
        let modelFile = root.appendingPathComponent("weights.safetensors")
        let lockDirectory = root.appendingPathComponent(".locks/repository", isDirectory: true)
        let oldLock = lockDirectory.appendingPathComponent("old.lock")
        let recentLock = lockDirectory.appendingPathComponent("recent.lock")

        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        for file in [oldIncomplete, recentIncomplete, modelFile, oldLock, recentLock] {
            try "data".write(to: file, atomically: true, encoding: .utf8)
        }

        let now = Date()
        let oldDate = now.addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldIncomplete.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldLock.path)

        ModelStorage.cleanStalePartialDownloads(
            in: root,
            olderThan: now.addingTimeInterval(-24 * 60 * 60)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldIncomplete.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentIncomplete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
    }

    private func pythonLockProbe(_ lockURL: URL) async throws -> String {
        let script = """
        import fcntl
        import sys
        handle = open(sys.argv[1], "a+")
        try:
            fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("ACQUIRED")
        except BlockingIOError:
            print("BUSY")
        """
        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, lockURL.path],
            label: "lock probe",
            timeout: 10,
            onOutput: { _ in }
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertSignalRecovery(signal: Int32, ignoresTERM: Bool) async throws {
        let outputRoot = root.appendingPathComponent("signal-output-\(signal)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let tracked = outputRoot.appendingPathComponent(
            ".quicksrt-\(UUID().uuidString)-movie.en.srt.tmp"
        )
        let job = try TempWorkspace.createJobDirectory(in: root)
        try job.trackOutputStagingArtifact(tracked)
        try "temporary".write(to: tracked, atomically: false, encoding: .utf8)
        let jobURL = job.url
        let activeLock = jobURL.appendingPathComponent(".active.lock")
        let ready = jobURL.appendingPathComponent("signal-ready")
        job.abandonForRecoveryTest()

        let script = """
        import fcntl
        import os
        import signal
        import sys
        import time
        if sys.argv[3] == "ignore": signal.signal(signal.SIGTERM, signal.SIG_IGN)
        handle = open(sys.argv[1], "a+")
        fcntl.lockf(handle, fcntl.LOCK_EX)
        open(sys.argv[2], "w").write(str(os.getpid()))
        while True: time.sleep(1)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, activeLock.path, ready.path, ignoresTERM ? "ignore" : "default"]
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertTrue(TempWorkspace.cleanStaleJobs(in: root).isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracked.path))

        XCTAssertEqual(Darwin.kill(process.processIdentifier, signal), 0)
        process.waitUntilExit()
        XCTAssertEqual(Darwin.kill(process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        let report = TempWorkspace.cleanStaleJobs(in: root)
        XCTAssertTrue(report.isSuccessful, "\(report.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobURL.path))
    }
}
