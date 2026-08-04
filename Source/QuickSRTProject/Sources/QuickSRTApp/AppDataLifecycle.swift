import AppKit
import CryptoKit
import Darwin
import Foundation

struct OwnedOutputRecord: Codable, Equatable {
    let path: String
    let byteCount: Int
    let sha256: String
}

private struct OwnedOutputManifest: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    var outputs: [OwnedOutputRecord]
}

enum OutputOwnershipManifest {
    private static let lock = NSLock()
    private static let maximumManifestBytes = 4 * 1_024 * 1_024
    private static let pendingSuffix = ".pending"

    static func record(_ outputURL: URL, manifestURL: URL = ProjectPaths.outputManifest) throws {
        try SRTValidator.validate(outputURL)
        let record = try makeRecord(for: outputURL)
        try lock.withLifecycleLock {
            var manifest = try loadIfPresent(from: manifestURL)
                ?? OwnedOutputManifest(schemaVersion: OwnedOutputManifest.schemaVersion, outputs: [])
            manifest.outputs.removeAll { $0.path == record.path }
            manifest.outputs.append(record)
            try write(manifest, to: manifestURL)
        }
    }

    static func trackedOutputCount(manifestURL: URL = ProjectPaths.outputManifest) throws -> Int {
        try lock.withLifecycleLock {
            try loadIfPresent(from: manifestURL)?.outputs.count ?? 0
        }
    }

    static func deleteTrackedOutputs(
        manifestURL: URL = ProjectPaths.outputManifest,
        fileManager: FileManager = .default,
        afterQuarantine: ((URL) throws -> Void)? = nil
    ) -> CleanupReport {
        lock.withLifecycleLock {
            var report = CleanupReport()
            let manifest: OwnedOutputManifest
            do {
                guard let loaded = try loadIfPresent(from: manifestURL) else { return report }
                manifest = loaded
            } catch {
                report.failed(manifestURL, error)
                return report
            }

            for output in manifest.outputs {
                let url = URL(fileURLWithPath: output.path)
                do {
                    if try atomicallyDelete(
                        output,
                        at: url,
                        fileManager: fileManager,
                        afterQuarantine: afterQuarantine
                    ) {
                        report.removed(url)
                    }
                } catch CocoaError.fileReadNoSuchFile {
                    continue
                } catch {
                    report.failed(url, error)
                }
            }
            return report
        }
    }

    private static func makeRecord(for url: URL) throws -> OwnedOutputRecord {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_size <= SRTValidator.maximumFileSize
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard FileIdentity(before) == FileIdentity(after), Int64(data.count) == after.st_size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return OwnedOutputRecord(
            path: url.standardizedFileURL.path,
            byteCount: data.count,
            sha256: digest
        )
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
            mode = UInt32(information.st_mode)
            size = Int64(information.st_size)
            modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        }
    }

    private static func atomicallyDelete(
        _ expected: OwnedOutputRecord,
        at url: URL,
        fileManager: FileManager,
        afterQuarantine: ((URL) throws -> Void)?
    ) throws -> Bool {
        let parent = url.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent(
            ".quicksrt-delete-\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        let descriptor = quarantine.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var markerInformation = stat()
        let markerStatus = Darwin.fstat(descriptor, &markerInformation)
        let markerError = errno
        Darwin.close(descriptor)
        guard markerStatus == 0 else {
            try? fileManager.removeItem(at: quarantine)
            throw POSIXError(POSIXErrorCode(rawValue: markerError) ?? .EIO)
        }
        let markerIdentity = FileIdentity(markerInformation)

        let swapResult = rename(quarantine, url, flags: UInt32(RENAME_SWAP))
        guard swapResult == 0 else {
            let swapError = errno
            try? fileManager.removeItem(at: quarantine)
            if swapError == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: swapError) ?? .EIO)
        }

        do {
            try afterQuarantine?(url)
            let quarantined = try makeRecord(for: quarantine)
            guard quarantined.byteCount == expected.byteCount,
                  quarantined.sha256 == expected.sha256
            else {
                try restoreQuarantinedOutput(
                    quarantine,
                    to: url,
                    markerIdentity: markerIdentity,
                    fileManager: fileManager
                )
                throw CocoaError(.fileReadCorruptFile)
            }

            try fileManager.removeItem(at: quarantine)
            try removeMarkerWithoutDeletingReplacement(
                at: url,
                markerIdentity: markerIdentity,
                fileManager: fileManager
            )
            return true
        } catch {
            if fileManager.fileExists(atPath: quarantine.path) {
                try? restoreQuarantinedOutput(
                    quarantine,
                    to: url,
                    markerIdentity: markerIdentity,
                    fileManager: fileManager
                )
            }
            throw error
        }
    }

    private static func restoreQuarantinedOutput(
        _ quarantine: URL,
        to destination: URL,
        markerIdentity: FileIdentity,
        fileManager: FileManager
    ) throws {
        guard try identity(at: destination) == markerIdentity else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard rename(quarantine, destination, flags: UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fileManager.removeItem(at: quarantine)
    }

    private static func removeMarkerWithoutDeletingReplacement(
        at destination: URL,
        markerIdentity: FileIdentity,
        fileManager: FileManager
    ) throws {
        guard let currentIdentity = try identityIfPresent(at: destination) else { return }
        guard currentIdentity == markerIdentity else { return }

        let cleanup = destination.deletingLastPathComponent().appendingPathComponent(
            ".quicksrt-marker-\(UUID().uuidString)-\(destination.lastPathComponent)"
        )
        guard rename(destination, cleanup, flags: UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try identity(at: cleanup) == markerIdentity else {
            guard rename(cleanup, destination, flags: UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        try fileManager.removeItem(at: cleanup)
    }

    private static func identity(at url: URL) throws -> FileIdentity {
        guard let identity = try identityIfPresent(at: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return identity
    }

    private static func identityIfPresent(at url: URL) throws -> FileIdentity? {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(information)
    }

    private static func rename(_ source: URL, _ destination: URL, flags: UInt32) -> Int32 {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, flags)
            }
        }
    }

    private static func loadIfPresent(from url: URL) throws -> OwnedOutputManifest? {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0,
              information.st_size <= maximumManifestBytes
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(
            OwnedOutputManifest.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        guard manifest.schemaVersion == OwnedOutputManifest.schemaVersion,
              manifest.outputs.count <= 10_000
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private static func write(_ manifest: OwnedOutputManifest, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try rejectSymlinkIfPresent(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= maximumManifestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let pending = URL(fileURLWithPath: url.path + pendingSuffix)
        try data.write(to: pending, options: [])
        let result = pending.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func rejectSymlinkIfPresent(_ url: URL) throws {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status == 0, information.st_mode & S_IFMT == S_IFLNK {
            throw CocoaError(.fileWriteNoPermission)
        }
        if status != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct AppDataPaths: Sendable {
    let applicationSupport: URL
    let outputManifest: URL
    let tempRoot: URL
    let removableRoots: [URL]
    let preferenceDomain: String

    static var live: AppDataPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let applicationSupport = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("QuickSRT", isDirectory: true)
        return AppDataPaths(
            applicationSupport: applicationSupport,
            outputManifest: applicationSupport.appendingPathComponent("output-manifest.json"),
            tempRoot: ProjectPaths.tempRoot,
            removableRoots: [
                library.appendingPathComponent("Preferences/local.quicksrt.app.plist"),
                library.appendingPathComponent("Saved Application State/local.quicksrt.app.savedState", isDirectory: true),
                library.appendingPathComponent("Caches/local.quicksrt.app", isDirectory: true),
                library.appendingPathComponent("Caches/QuickSRT", isDirectory: true),
                library.appendingPathComponent("Caches/com.apple.metal/local.quicksrt.app", isDirectory: true),
                library.appendingPathComponent("Caches/huggingface/quicksrt", isDirectory: true),
                library.appendingPathComponent("Caches/xet/quicksrt", isDirectory: true),
                library.appendingPathComponent("HTTPStorages/local.quicksrt.app", isDirectory: true),
                library.appendingPathComponent("WebKit/local.quicksrt.app", isDirectory: true),
                library.appendingPathComponent("Logs/QuickSRT", isDirectory: true),
                library.appendingPathComponent("Logs/QuickSRT-Xet", isDirectory: true),
                library.appendingPathComponent("Application Scripts/local.quicksrt.app", isDirectory: true),
                library.appendingPathComponent("Containers/local.quicksrt.app", isDirectory: true)
            ],
            preferenceDomain: "local.quicksrt.app"
        )
    }
}

struct AppDataDeletionReport: Sendable {
    let cleanup: CleanupReport
    let trackedOutputsRequested: Int
    let trackedOutputsPreserved: Int

    var isSuccessful: Bool { cleanup.isSuccessful }
}

enum AppDataCleaner {
    static func deleteOwnedDataExclusively(
        paths: AppDataPaths = .live,
        deleteTrackedOutputs: Bool,
        fileManager: FileManager = .default,
        clearPreferenceDomain: (String) -> Void = clearPreferenceDomain,
        preferenceDomainExists: (String) -> Bool = preferenceDomainExists
    ) -> AppDataDeletionReport {
        let operationLock: InterprocessFileLock
        do {
            operationLock = try QuickSRTOperationLock.acquire(in: paths.tempRoot)
        } catch InterprocessLockError.busy {
            return lockFailureReport(
                at: QuickSRTOperationLock.lockURL(in: paths.tempRoot),
                reason: QuickSRTError.operationAlreadyRunning.localizedDescription
            )
        } catch {
            return lockFailureReport(
                at: QuickSRTOperationLock.lockURL(in: paths.tempRoot),
                reason: QuickSRTError.operationLockUnavailable.localizedDescription
            )
        }
        defer { operationLock.unlock() }

        return deleteOwnedData(
            paths: paths,
            deleteTrackedOutputs: deleteTrackedOutputs,
            fileManager: fileManager,
            clearPreferenceDomain: clearPreferenceDomain,
            preferenceDomainExists: preferenceDomainExists
        )
    }

    static func deleteOwnedData(
        paths: AppDataPaths = .live,
        deleteTrackedOutputs: Bool,
        fileManager: FileManager = .default,
        clearPreferenceDomain: (String) -> Void = clearPreferenceDomain,
        preferenceDomainExists: (String) -> Bool = preferenceDomainExists
    ) -> AppDataDeletionReport {
        var report = CleanupReport()
        let trackedCount: Int
        do {
            trackedCount = try OutputOwnershipManifest.trackedOutputCount(
                manifestURL: paths.outputManifest
            )
        } catch {
            trackedCount = 0
            report.failed(paths.outputManifest, error)
        }

        if deleteTrackedOutputs {
            report.merge(OutputOwnershipManifest.deleteTrackedOutputs(
                manifestURL: paths.outputManifest,
                fileManager: fileManager
            ))
        }

        clearPreferenceDomain(paths.preferenceDomain)

        let targets = [paths.applicationSupport, paths.tempRoot] + paths.removableRoots
        for target in targets {
            report.merge(SafeFileRemoval.removeItem(
                at: target,
                containedIn: target.deletingLastPathComponent(),
                fileManager: fileManager
            ))
        }

        if preferenceDomainExists(paths.preferenceDomain) {
            let preferenceURL = paths.removableRoots.first {
                $0.lastPathComponent == "\(paths.preferenceDomain).plist"
            } ?? paths.applicationSupport.deletingLastPathComponent()
                .appendingPathComponent("\(paths.preferenceDomain).plist")
            report.failed(
                preferenceURL,
                reason: "The QuickSRT preference domain remained after deletion."
            )
        }

        let deletedOutputCount = deleteTrackedOutputs
            ? report.removedPaths.filter { $0.lowercased().hasSuffix(".srt") }.count
            : 0
        return AppDataDeletionReport(
            cleanup: report,
            trackedOutputsRequested: deleteTrackedOutputs ? trackedCount : 0,
            trackedOutputsPreserved: max(0, trackedCount - deletedOutputCount)
        )
    }

    private static func clearPreferenceDomain(_ domain: String) {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }

    private static func preferenceDomainExists(_ domain: String) -> Bool {
        UserDefaults.standard.persistentDomain(forName: domain) != nil
    }

    private static func lockFailureReport(at lockURL: URL, reason: String) -> AppDataDeletionReport {
        var cleanup = CleanupReport()
        cleanup.failed(lockURL, reason: reason)
        return AppDataDeletionReport(
            cleanup: cleanup,
            trackedOutputsRequested: 0,
            trackedOutputsPreserved: 0
        )
    }
}

struct UninstallHelperLaunch: Sendable {
    let helperURL: URL
    let requiresAdministratorApproval: Bool
}

enum UninstallHelper {
    static func launch(
        appURL: URL = Bundle.main.bundleURL,
        processID: pid_t = getpid(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> UninstallHelperLaunch {
        let app = appURL.standardizedFileURL
        guard app.pathExtension == "app",
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "local.quicksrt.app",
              let executable = bundle.executableURL?.standardizedFileURL,
              executable.path.hasPrefix(app.path + "/Contents/MacOS/")
        else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var information = stat()
        let status = app.path.withCString { Darwin.lstat($0, &information) }
        guard status == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let helperRoot = temporaryDirectory.appendingPathComponent(
            "QuickSRT-Uninstall-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: helperRoot, withIntermediateDirectories: false)
        let helperURL = helperRoot.appendingPathComponent("uninstall.sh")
        try helperScript.write(to: helperURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperURL.path,
            String(processID),
            app.path,
            helperRoot.path,
            executable.path
        ]
        try helper.run()

        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let requiresAdministratorApproval = app.deletingLastPathComponent() == applications
            && !fileManager.isWritableFile(atPath: applications.path)
        return UninstallHelperLaunch(
            helperURL: helperURL,
            requiresAdministratorApproval: requiresAdministratorApproval
        )
    }

    static let helperScript = #"""
#!/bin/sh
set -u
pid="$1"
app_path="$2"
helper_root="$3"
expected_executable="$4"

cleanup_helper() {
    cleanup_failed=0
    /bin/rm -f -- "$0" || cleanup_failed=1
    /bin/rmdir -- "$helper_root" || cleanup_failed=1
    if [ "$cleanup_failed" -ne 0 ]; then
        /usr/bin/logger -t QuickSRT "Uninstall helper could not remove all of its temporary files."
        /usr/bin/osascript -e 'display dialog "QuickSRT was moved to Trash, but the uninstall helper could not remove all of its temporary files." buttons {"OK"} default button "OK" with icon caution' || :
    fi
}
trap cleanup_helper EXIT

while /bin/kill -0 "$pid" 2>/dev/null; do
    current_executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null)"
    [ "$current_executable" = "$expected_executable" ] || break
    /bin/sleep 0.2
done

if ! /usr/bin/osascript - "$app_path" <<'APPLESCRIPT'
on run argv
    tell application "Finder"
        delete POSIX file (item 1 of argv)
    end tell
end run
APPLESCRIPT
then
    /usr/bin/logger -t QuickSRT "Uninstall helper could not move the application to Trash."
    /usr/bin/osascript -e 'display dialog "QuickSRT could not be moved to Trash. If it is installed in /Applications, administrator approval may be required." buttons {"OK"} default button "OK" with icon caution' || :
    exit 1
fi
"""#
}

enum AppLifecycleState {
    private static let destructiveExit = LockedValue(false)

    static var isDestructiveExit: Bool {
        destructiveExit.withLock { $0 }
    }

    static func beginDestructiveExit() {
        destructiveExit.withLock { $0 = true }
    }
}

private extension NSLock {
    func withLifecycleLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
