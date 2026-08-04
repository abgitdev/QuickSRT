import Foundation
@testable import QuickSRT
import XCTest

final class AppDataLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-AppDataLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            let report = SafeFileRemoval.removeItem(
                at: root,
                containedIn: root.deletingLastPathComponent()
            )
            XCTAssertTrue(report.isSuccessful, "\(report.failures)")
        }
        root = nil
    }

    func testOutputManifestDeletesOnlyExactUnchangedTrackedSRT() throws {
        let appSupport = root.appendingPathComponent("Application Support/QuickSRT", isDirectory: true)
        let manifest = appSupport.appendingPathComponent("output-manifest.json")
        let outputs = root.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let tracked = outputs.appendingPathComponent("movie.en.srt")
        let untracked = outputs.appendingPathComponent("other.en.srt")
        try validSRT("Tracked").write(to: tracked, atomically: false, encoding: .utf8)
        try validSRT("Untracked").write(to: untracked, atomically: false, encoding: .utf8)
        try OutputOwnershipManifest.record(tracked, manifestURL: manifest)

        let report = OutputOwnershipManifest.deleteTrackedOutputs(manifestURL: manifest)

        XCTAssertTrue(report.isSuccessful, "\(report.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
    }

    func testOutputManifestPreservesModifiedAndSymlinkedOutputs() throws {
        let manifest = root.appendingPathComponent("support/output-manifest.json")
        let tracked = root.appendingPathComponent("movie.en.srt")
        try validSRT("Original").write(to: tracked, atomically: false, encoding: .utf8)
        try OutputOwnershipManifest.record(tracked, manifestURL: manifest)
        try validSRT("Edited by user").write(to: tracked, atomically: false, encoding: .utf8)

        let modifiedReport = OutputOwnershipManifest.deleteTrackedOutputs(manifestURL: manifest)
        XCTAssertFalse(modifiedReport.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracked.path))

        try FileManager.default.removeItem(at: tracked)
        let outside = root.appendingPathComponent("outside.srt")
        try validSRT("Outside").write(to: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tracked, withDestinationURL: outside)
        let symlinkReport = OutputOwnershipManifest.deleteTrackedOutputs(manifestURL: manifest)
        XCTAssertFalse(symlinkReport.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testOutputManifestCannotDeleteReplacementCreatedAfterAtomicQuarantine() throws {
        let manifest = root.appendingPathComponent("support/output-manifest.json")
        let tracked = root.appendingPathComponent("movie.en.srt")
        try validSRT("Original").write(to: tracked, atomically: false, encoding: .utf8)
        try OutputOwnershipManifest.record(tracked, manifestURL: manifest)

        let report = OutputOwnershipManifest.deleteTrackedOutputs(
            manifestURL: manifest,
            afterQuarantine: { destination in
                try FileManager.default.removeItem(at: destination)
                try self.validSRT("Replacement created by user").write(
                    to: destination,
                    atomically: false,
                    encoding: .utf8
                )
            }
        )

        XCTAssertTrue(report.isSuccessful, "\(report.failures)")
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), validSRT("Replacement created by user"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".quicksrt-") })
    }

    func testDeleteOwnedDataRemovesModelsPreferencesCachesJobsAndLocksButKeepsSRT() throws {
        let appSupport = root.appendingPathComponent("Library/Application Support/QuickSRT", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp/QuickSRT", isDirectory: true)
        let preferences = root.appendingPathComponent("Library/Preferences/local.quicksrt.app.plist")
        let savedState = root.appendingPathComponent("Library/Saved Application State/local.quicksrt.app.savedState")
        let cache = root.appendingPathComponent("Library/Caches/local.quicksrt.app")
        let output = root.appendingPathComponent("Videos/movie.en.srt")
        for directory in [
            appSupport.appendingPathComponent("Models/Runtime/Tools/Scripts", isDirectory: true),
            tempRoot,
            preferences.deletingLastPathComponent(),
            savedState,
            cache,
            output.deletingLastPathComponent()
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for file in [
            appSupport.appendingPathComponent("Models/model.bin"),
            tempRoot.appendingPathComponent("operation.lock"),
            tempRoot.appendingPathComponent("workspace.lock"),
            preferences,
            savedState.appendingPathComponent("windows.plist"),
            cache.appendingPathComponent("metal.cache")
        ] {
            try Data("owned".utf8).write(to: file)
        }
        try validSRT("Keep me").write(to: output, atomically: false, encoding: .utf8)
        let manifest = appSupport.appendingPathComponent("output-manifest.json")
        try OutputOwnershipManifest.record(output, manifestURL: manifest)
        var clearedDomain: String?
        let paths = AppDataPaths(
            applicationSupport: appSupport,
            outputManifest: manifest,
            tempRoot: tempRoot,
            removableRoots: [preferences, savedState, cache],
            preferenceDomain: "local.quicksrt.app"
        )

        let report = AppDataCleaner.deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { clearedDomain = $0 },
            preferenceDomainExists: { _ in false }
        )

        XCTAssertTrue(report.isSuccessful, "\(report.cleanup.failures)")
        XCTAssertEqual(clearedDomain, "local.quicksrt.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedState.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testExclusiveDataRemovalRefusesToDeleteAnotherInstancesActiveData() throws {
        let appSupport = root.appendingPathComponent("Library/Application Support/QuickSRT", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp/QuickSRT", isDirectory: true)
        let model = appSupport.appendingPathComponent("Models/model.bin")
        let activeJob = tempRoot.appendingPathComponent("job-active/working.wav")
        try FileManager.default.createDirectory(
            at: model.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: activeJob.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model".utf8).write(to: model)
        try Data("audio".utf8).write(to: activeJob)
        let paths = AppDataPaths(
            applicationSupport: appSupport,
            outputManifest: appSupport.appendingPathComponent("output-manifest.json"),
            tempRoot: tempRoot,
            removableRoots: [],
            preferenceDomain: "test.domain"
        )
        let otherInstanceLock = try QuickSRTOperationLock.acquire(in: tempRoot)
        defer { otherInstanceLock.unlock() }

        let blocked = AppDataCleaner.deleteOwnedDataExclusively(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in false }
        )

        XCTAssertFalse(blocked.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeJob.path))

        otherInstanceLock.unlock()
        let deleted = AppDataCleaner.deleteOwnedDataExclusively(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in false }
        )
        XCTAssertTrue(deleted.isSuccessful, "\(deleted.cleanup.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))
    }

    func testDeleteOwnedDataRemovesOnlyManifestedOutputsAfterSeparateRequest() throws {
        let appSupport = root.appendingPathComponent("support", isDirectory: true)
        let manifest = appSupport.appendingPathComponent("output-manifest.json")
        let tracked = root.appendingPathComponent("tracked.srt")
        let unrelated = root.appendingPathComponent("unrelated.srt")
        try validSRT("Tracked").write(to: tracked, atomically: false, encoding: .utf8)
        try validSRT("Unrelated").write(to: unrelated, atomically: false, encoding: .utf8)
        try OutputOwnershipManifest.record(tracked, manifestURL: manifest)
        let paths = AppDataPaths(
            applicationSupport: appSupport,
            outputManifest: manifest,
            tempRoot: root.appendingPathComponent("temp"),
            removableRoots: [],
            preferenceDomain: "test.domain"
        )

        let report = AppDataCleaner.deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: true,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in false }
        )

        XCTAssertTrue(report.isSuccessful, "\(report.cleanup.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(report.trackedOutputsRequested, 1)
        XCTAssertEqual(report.trackedOutputsPreserved, 0)
    }

    func testDeleteOwnedDataUnlinksSymlinkWithoutFollowingIt() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideMarker = outside.appendingPathComponent("keep.txt")
        let applicationSupport = root.appendingPathComponent("Application Support/QuickSRT")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideMarker)
        try FileManager.default.createDirectory(
            at: applicationSupport.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: applicationSupport, withDestinationURL: outside)
        let paths = AppDataPaths(
            applicationSupport: applicationSupport,
            outputManifest: applicationSupport.appendingPathComponent("output-manifest.json"),
            tempRoot: root.appendingPathComponent("temp"),
            removableRoots: [],
            preferenceDomain: "test.domain"
        )

        let report = AppDataCleaner.deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in false }
        )

        XCTAssertTrue(report.isSuccessful, "\(report.cleanup.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
    }

    func testCleanupFailureIsReturnedInsteadOfIgnored() {
        let appSupport = root.appendingPathComponent("support")
        let paths = AppDataPaths(
            applicationSupport: appSupport,
            outputManifest: appSupport.appendingPathComponent("output-manifest.json"),
            tempRoot: root.appendingPathComponent("temp"),
            removableRoots: [URL(fileURLWithPath: "/")],
            preferenceDomain: "test.domain"
        )

        let report = AppDataCleaner.deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in false }
        )

        XCTAssertFalse(report.isSuccessful)
        XCTAssertTrue(report.cleanup.failures.contains { $0.path == "/" })
    }

    func testPreferenceDomainVerificationFailureIsReported() {
        let appSupport = root.appendingPathComponent("support")
        let preference = root.appendingPathComponent("local.quicksrt.app.plist")
        let paths = AppDataPaths(
            applicationSupport: appSupport,
            outputManifest: appSupport.appendingPathComponent("output-manifest.json"),
            tempRoot: root.appendingPathComponent("temp"),
            removableRoots: [preference],
            preferenceDomain: "local.quicksrt.app"
        )

        let report = AppDataCleaner.deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: false,
            clearPreferenceDomain: { _ in },
            preferenceDomainExists: { _ in true }
        )

        XCTAssertFalse(report.isSuccessful)
        XCTAssertTrue(report.cleanup.failures.contains {
            $0.path == preference.path && $0.reason.contains("preference domain")
        })
    }

    func testUninstallHelperWaitsForExitAndMovesOnlyPassedAppToTrash() {
        let script = UninstallHelper.helperScript
        XCTAssertTrue(script.contains("kill -0 \"$pid\""))
        XCTAssertTrue(script.contains("ps -p \"$pid\" -o comm="))
        XCTAssertTrue(script.contains("= \"$expected_executable\""))
        XCTAssertTrue(script.contains("delete POSIX file (item 1 of argv)"))
        XCTAssertTrue(script.contains("rm -f -- \"$0\""))
        XCTAssertTrue(script.contains("logger -t QuickSRT"))
        XCTAssertFalse(script.contains("find "))
        XCTAssertFalse(script.contains("*.app"))
        XCTAssertFalse(script.contains("*.srt"))
        XCTAssertFalse(script.contains("rmdir -- \"$helper_root\" 2>/dev/null || true"))
    }

    private func validSRT(_ text: String) -> String {
        "1\n00:00:00,000 --> 00:00:01,000\n\(text)\n"
    }
}
