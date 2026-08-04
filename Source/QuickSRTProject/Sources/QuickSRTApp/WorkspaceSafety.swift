import Darwin
import Foundation

/// Small synchronization primitive for state that is shared by Sendable owners.
/// The value never escapes the lock, so the unchecked conformance is confined
/// to one auditable implementation instead of being repeated at every call site.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

public struct CleanupFailure: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanupReport: Equatable, Sendable {
    public private(set) var removedPaths: [String] = []
    public private(set) var failures: [CleanupFailure] = []

    public init() {}

    public var isSuccessful: Bool { failures.isEmpty }

    public mutating func merge(_ other: CleanupReport) {
        for path in other.removedPaths where !removedPaths.contains(path) {
            removedPaths.append(path)
        }
        failures.append(contentsOf: other.failures)
    }

    mutating func removed(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !removedPaths.contains(path) {
            removedPaths.append(path)
        }
    }

    mutating func failed(_ url: URL, _ error: Error) {
        failures.append(CleanupFailure(path: url.path, reason: error.localizedDescription))
    }

    mutating func failed(_ url: URL, reason: String) {
        failures.append(CleanupFailure(path: url.path, reason: reason))
    }
}

enum SafeFileRemoval {
    static func removeItem(
        at url: URL,
        containedIn root: URL,
        allowRoot: Bool = false,
        fileManager: FileManager = .default
    ) -> CleanupReport {
        var report = CleanupReport()
        removeItem(
            at: url.standardizedFileURL,
            containedIn: root.standardizedFileURL,
            allowRoot: allowRoot,
            fileManager: fileManager,
            report: &report
        )
        return report
    }

    static func isContained(_ url: URL, in root: URL, allowRoot: Bool = false) -> Bool {
        var rootInformation = stat()
        let rootStatus = root.path.withCString { Darwin.lstat($0, &rootInformation) }
        if rootStatus == 0, rootInformation.st_mode & S_IFMT == S_IFLNK {
            return false
        }
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedURL = url.standardizedFileURL
        if allowRoot, normalizedURL.resolvingSymlinksInPath() == normalizedRoot {
            return true
        }

        let parent = normalizedURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let rootComponents = normalizedRoot.pathComponents
        let parentComponents = parent.pathComponents
        return parentComponents.count >= rootComponents.count
            && Array(parentComponents.prefix(rootComponents.count)) == rootComponents
            && normalizedURL != normalizedRoot
    }

    private static func removeItem(
        at url: URL,
        containedIn root: URL,
        allowRoot: Bool,
        fileManager: FileManager,
        report: inout CleanupReport
    ) {
        guard isContained(url, in: root, allowRoot: allowRoot) else {
            report.failed(url, reason: "Refused cleanup outside its declared safe root.")
            return
        }

        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno != ENOENT {
                report.failed(url, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            return
        }

        let type = information.st_mode & S_IFMT
        if type == S_IFDIR {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                report.failed(url, error)
                return
            }

            for child in children {
                removeItem(
                    at: child,
                    containedIn: root,
                    allowRoot: false,
                    fileManager: fileManager,
                    report: &report
                )
            }
            guard report.failures.isEmpty else { return }
        }

        do {
            try fileManager.removeItem(at: url)
            report.removed(url)
        } catch {
            report.failed(url, error)
        }
    }
}

public enum InterprocessLockError: Error {
    case busy
    case system(Int32)
}

public final class InterprocessFileLock: @unchecked Sendable {
    private static let heldPaths = LockedValue(Set<String>())

    private let stateLock = NSLock()
    private let pathKey: String
    private var descriptor: Int32

    private init(descriptor: Int32, pathKey: String) {
        self.descriptor = descriptor
        self.pathKey = pathKey
    }

    deinit {
        unlock()
    }

    public static func acquire(at url: URL, nonBlocking: Bool = true) throws -> InterprocessFileLock {
        let pathKey = url.standardizedFileURL.path
        let reserved = heldPaths.withLock { heldPaths -> Bool in
            guard !heldPaths.contains(pathKey) else { return false }
            heldPaths.insert(pathKey)
            return true
        }
        guard reserved else { throw InterprocessLockError.busy }

        var shouldReleaseReservation = true
        defer {
            if shouldReleaseReservation {
                _ = heldPaths.withLock { $0.remove(pathKey) }
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw InterprocessLockError.system(errno)
        }

        var advisoryLock = flock()
        advisoryLock.l_type = Int16(F_WRLCK)
        advisoryLock.l_whence = Int16(SEEK_SET)
        advisoryLock.l_start = 0
        advisoryLock.l_len = 0
        let operation = nonBlocking ? F_SETLK : F_SETLKW
        guard Darwin.fcntl(descriptor, operation, &advisoryLock) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw InterprocessLockError.busy
            }
            throw InterprocessLockError.system(error)
        }

        shouldReleaseReservation = false
        return InterprocessFileLock(descriptor: descriptor, pathKey: pathKey)
    }

    public func unlock() {
        let descriptorToClose: Int32 = stateLock.withLock {
            guard descriptor >= 0 else { return -1 }
            let current = descriptor
            descriptor = -1
            return current
        }
        guard descriptorToClose >= 0 else { return }
        var advisoryLock = flock()
        advisoryLock.l_type = Int16(F_UNLCK)
        advisoryLock.l_whence = Int16(SEEK_SET)
        advisoryLock.l_start = 0
        advisoryLock.l_len = 0
        _ = Darwin.fcntl(descriptorToClose, F_SETLK, &advisoryLock)
        Darwin.close(descriptorToClose)
        _ = Self.heldPaths.withLock { $0.remove(pathKey) }
        // The empty lock inode deliberately remains. Unlinking a POSIX lock file
        // can create two independently locked inodes during an acquire/unlock race.
    }
}

public enum QuickSRTOperationLock {
    public static func lockURL(in root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(
            ".\(root.lastPathComponent).operation.lock"
        )
    }

    public static func acquire(in root: URL) throws -> InterprocessFileLock {
        try InterprocessFileLock.acquire(
            at: lockURL(in: root),
            nonBlocking: true
        )
    }

    static func acquire() throws -> InterprocessFileLock {
        try acquire(in: ProjectPaths.tempRoot)
    }
}

private enum TempArtifactKind: String, Codable {
    case workspace
    case outputStaging
}

private struct TempArtifactRecord: Codable, Equatable {
    let path: String
    let safeRootPath: String
    let kind: TempArtifactKind
}

private struct TempArtifactManifest: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let jobID: UUID
    var artifacts: [TempArtifactRecord]
}

public final class TempJobWorkspace {
    public let url: URL

    fileprivate let root: URL
    fileprivate let fileManager: FileManager
    fileprivate let stateLock = NSLock()
    fileprivate var activeLock: InterprocessFileLock?
    fileprivate var manifest: TempArtifactManifest

    fileprivate init(
        url: URL,
        root: URL,
        fileManager: FileManager,
        activeLock: InterprocessFileLock,
        manifest: TempArtifactManifest
    ) {
        self.url = url
        self.root = root
        self.fileManager = fileManager
        self.activeLock = activeLock
        self.manifest = manifest
    }

    deinit {
        _ = finish()
    }

    public func trackWorkspaceArtifact(_ artifactURL: URL) throws {
        try track(artifactURL, safeRoot: url, kind: .workspace)
    }

    public func trackOutputStagingArtifact(_ artifactURL: URL) throws {
        guard TempWorkspace.isSafeOutputStagingName(artifactURL.lastPathComponent) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try track(
            artifactURL,
            safeRoot: artifactURL.deletingLastPathComponent(),
            kind: .outputStaging
        )
    }

    public func removeTrackedArtifact(_ artifactURL: URL) -> CleanupReport {
        let record = stateLock.withLock {
            manifest.artifacts.first { $0.path == artifactURL.standardizedFileURL.path }
        }
        guard let record else {
            var report = CleanupReport()
            report.failed(artifactURL, reason: "Temporary file is missing from the active job manifest.")
            return report
        }

        var report = TempWorkspace.remove(record: record, fileManager: fileManager)
        guard report.isSuccessful else { return report }
        do {
            try stateLock.withLock {
                manifest.artifacts.removeAll { $0.path == record.path }
                try TempWorkspace.write(manifest: manifest, in: url)
            }
        } catch {
            report.failed(TempWorkspace.manifestURL(in: url), error)
        }
        return report
    }

    @discardableResult
    public func finish() -> CleanupReport {
        TempWorkspace.finish(self)
    }

    // Test-only crash simulation: a real SIGKILL/power loss closes the lock
    // descriptor without executing deinit. Keeping this internal allows XCTest
    // to reproduce that state without adding a production UI escape hatch.
    func abandonForRecoveryTest() {
        let lock: InterprocessFileLock? = stateLock.withLock {
            let current = activeLock
            activeLock = nil
            return current
        }
        lock?.unlock()
    }

    private func track(_ artifactURL: URL, safeRoot: URL, kind: TempArtifactKind) throws {
        let artifact = artifactURL.standardizedFileURL
        let safeRoot = safeRoot.standardizedFileURL
        guard SafeFileRemoval.isContained(artifact, in: safeRoot) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let record = TempArtifactRecord(
            path: artifact.path,
            safeRootPath: safeRoot.path,
            kind: kind
        )
        try stateLock.withLock {
            if !manifest.artifacts.contains(record) {
                manifest.artifacts.append(record)
                try TempWorkspace.write(manifest: manifest, in: url)
            }
        }
    }
}

public enum TempWorkspace {
    private static let coordinatorName = "workspace.lock"
    private static let activeLockName = ".active.lock"
    private static let manifestName = ".quicksrt-temp-manifest.json"
    private static let pendingManifestName = ".quicksrt-temp-manifest.pending"
    private static let maximumManifestBytes = 1 * 1_024 * 1_024

    static func createJobDirectory() throws -> TempJobWorkspace {
        try createJobDirectory(in: ProjectPaths.tempRoot)
    }

    public static func createJobDirectory(
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> TempJobWorkspace {
        let root = root.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = try InterprocessFileLock.acquire(
            at: root.appendingPathComponent(coordinatorName),
            nonBlocking: false
        )
        defer { coordinator.unlock() }

        let jobID = UUID()
        let job = root.appendingPathComponent("job-\(jobID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: job, withIntermediateDirectories: false)

        do {
            let activeLock = try InterprocessFileLock.acquire(
                at: job.appendingPathComponent(activeLockName),
                nonBlocking: true
            )
            let manifest = TempArtifactManifest(
                schemaVersion: TempArtifactManifest.schemaVersion,
                jobID: jobID,
                artifacts: []
            )
            try write(manifest: manifest, in: job)
            return TempJobWorkspace(
                url: job,
                root: root,
                fileManager: fileManager,
                activeLock: activeLock,
                manifest: manifest
            )
        } catch {
            _ = SafeFileRemoval.removeItem(
                at: job,
                containedIn: root,
                fileManager: fileManager
            )
            throw error
        }
    }

    @discardableResult
    static func cleanStaleJobs() -> CleanupReport {
        do {
            let operationLock = try QuickSRTOperationLock.acquire()
            defer { operationLock.unlock() }
            return cleanStaleJobs(in: ProjectPaths.tempRoot)
        } catch InterprocessLockError.busy {
            return CleanupReport()
        } catch {
            var report = CleanupReport()
            report.failed(QuickSRTOperationLock.lockURL(in: ProjectPaths.tempRoot), error)
            return report
        }
    }

    @discardableResult
    public static func cleanStaleJobs(
        in root: URL,
        fileManager: FileManager = .default
    ) -> CleanupReport {
        let root = root.standardizedFileURL
        var report = CleanupReport()
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            report.failed(root, error)
            return report
        }

        let coordinator: InterprocessFileLock
        do {
            coordinator = try InterprocessFileLock.acquire(
                at: root.appendingPathComponent(coordinatorName),
                nonBlocking: false
            )
        } catch {
            report.failed(root.appendingPathComponent(coordinatorName), error)
            return report
        }
        defer { coordinator.unlock() }

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            report.failed(root, error)
            return report
        }

        for item in items {
            guard isSafeJobDirectory(item, inside: root) else { continue }
            do {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            } catch {
                report.failed(item, error)
                continue
            }

            let activeLockURL = item.appendingPathComponent(activeLockName)
            let orphanLock: InterprocessFileLock
            do {
                orphanLock = try InterprocessFileLock.acquire(at: activeLockURL, nonBlocking: true)
            } catch InterprocessLockError.busy {
                continue
            } catch {
                report.failed(activeLockURL, error)
                continue
            }
            defer { orphanLock.unlock() }
            report.merge(cleanOrphanJob(at: item, root: root, fileManager: fileManager))
        }
        return report
    }

    public static func isSafeJobDirectory(_ url: URL, inside root: URL) -> Bool {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedURL = url.standardizedFileURL
        let normalizedParent = normalizedURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard normalizedParent == normalizedRoot else { return false }

        let name = normalizedURL.lastPathComponent
        guard name.hasPrefix("job-") else { return false }
        return UUID(uuidString: String(name.dropFirst(4))) != nil
    }

    public static func isSafeOutputStagingName(_ name: String) -> Bool {
        let prefix = ".quicksrt-"
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        guard name.distance(from: start, to: name.endIndex) >= 37 else { return false }
        let end = name.index(start, offsetBy: 36)
        guard UUID(uuidString: String(name[start..<end])) != nil else { return false }
        return name[end] == "-"
    }

    fileprivate static func manifestURL(in job: URL) -> URL {
        job.appendingPathComponent(manifestName)
    }

    fileprivate static func write(manifest: TempArtifactManifest, in job: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= maximumManifestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let pending = job.appendingPathComponent(pendingManifestName)
        let destination = manifestURL(in: job)
        try data.write(to: pending, options: [])
        let result = pending.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    fileprivate static func remove(
        record: TempArtifactRecord,
        fileManager: FileManager
    ) -> CleanupReport {
        let url = URL(fileURLWithPath: record.path)
        let safeRoot = URL(fileURLWithPath: record.safeRootPath, isDirectory: true)
        guard record.kind == .workspace || isSafeOutputStagingName(url.lastPathComponent) else {
            var report = CleanupReport()
            report.failed(url, reason: "Refused an invalid external temporary-file manifest entry.")
            return report
        }
        return SafeFileRemoval.removeItem(
            at: url,
            containedIn: safeRoot,
            fileManager: fileManager
        )
    }

    fileprivate static func finish(_ job: TempJobWorkspace) -> CleanupReport {
        let state: (InterprocessFileLock, TempArtifactManifest)? = job.stateLock.withLock {
            guard let lock = job.activeLock else { return nil }
            job.activeLock = nil
            return (lock, job.manifest)
        }
        guard let (activeLock, manifest) = state else { return CleanupReport() }
        defer { activeLock.unlock() }

        let coordinator: InterprocessFileLock
        do {
            coordinator = try InterprocessFileLock.acquire(
                at: job.root.appendingPathComponent(coordinatorName),
                nonBlocking: false
            )
        } catch {
            var report = CleanupReport()
            report.failed(job.root.appendingPathComponent(coordinatorName), error)
            return report
        }
        defer { coordinator.unlock() }

        guard isSafeJobDirectory(job.url, inside: job.root) else {
            var report = CleanupReport()
            report.failed(job.url, reason: "Refused an invalid temporary job directory.")
            return report
        }
        return clean(manifest: manifest, job: job.url, root: job.root, fileManager: job.fileManager)
    }

    private static func cleanOrphanJob(
        at job: URL,
        root: URL,
        fileManager: FileManager
    ) -> CleanupReport {
        var report = CleanupReport()
        let manifest: TempArtifactManifest
        do {
            manifest = try loadManifest(in: job)
        } catch CocoaError.fileReadNoSuchFile {
            return SafeFileRemoval.removeItem(
                at: job,
                containedIn: root,
                fileManager: fileManager
            )
        } catch {
            report.failed(manifestURL(in: job), error)
            return report
        }
        report.merge(clean(manifest: manifest, job: job, root: root, fileManager: fileManager))
        return report
    }

    private static func clean(
        manifest: TempArtifactManifest,
        job: URL,
        root: URL,
        fileManager: FileManager
    ) -> CleanupReport {
        var report = CleanupReport()
        for record in manifest.artifacts where record.kind == .outputStaging {
            report.merge(remove(record: record, fileManager: fileManager))
        }
        guard report.isSuccessful else { return report }
        report.merge(SafeFileRemoval.removeItem(
            at: job,
            containedIn: root,
            fileManager: fileManager
        ))
        return report
    }

    private static func loadManifest(in job: URL) throws -> TempArtifactManifest {
        let url = manifestURL(in: job)
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        guard status == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0,
              information.st_size <= maximumManifestBytes
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(
            TempArtifactManifest.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        let expectedID = UUID(uuidString: String(job.lastPathComponent.dropFirst(4)))
        guard manifest.schemaVersion == TempArtifactManifest.schemaVersion,
              manifest.jobID == expectedID,
              manifest.artifacts.count <= 1_024
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }
}

public enum ModelStorage {
    static let staleArtifactAge: TimeInterval = 24 * 60 * 60

    @discardableResult
    static func cleanPartialDownloads() -> CleanupReport {
        do {
            let operationLock = try QuickSRTOperationLock.acquire()
            defer { operationLock.unlock() }
            return cleanPartialDownloadsWhileLocked()
        } catch InterprocessLockError.busy {
            return CleanupReport()
        } catch {
            var report = CleanupReport()
            report.failed(QuickSRTOperationLock.lockURL(in: ProjectPaths.tempRoot), error)
            return report
        }
    }

    @discardableResult
    static func cleanPartialDownloadsWhileLocked() -> CleanupReport {
        cleanStalePartialDownloads(
            in: ProjectPaths.mlxWhisperModelsRoot,
            olderThan: Date().addingTimeInterval(-staleArtifactAge)
        )
    }

    @discardableResult
    public static func cleanStalePartialDownloads(
        in root: URL,
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) -> CleanupReport {
        let root = root.standardizedFileURL
        var report = CleanupReport()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: []
        ) else { return report }

        var lockDirectories: [(url: URL, date: Date)] = []
        for case let item as URL in enumerator {
            guard SafeFileRemoval.isContained(item, in: root) else {
                enumerator.skipDescendants()
                continue
            }
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ])
            } catch {
                report.failed(item, error)
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            let modified = values.contentModificationDate ?? .distantFuture
            let isIncomplete = item.lastPathComponent.hasSuffix(".incomplete")
            let isInsideLocks = relativeComponents(of: item, in: root).contains(".locks")

            if isIncomplete {
                if values.isDirectory == true { enumerator.skipDescendants() }
                if modified < cutoff {
                    report.merge(SafeFileRemoval.removeItem(
                        at: item,
                        containedIn: root,
                        fileManager: fileManager
                    ))
                }
                continue
            }

            if values.isDirectory == true, isInsideLocks {
                lockDirectories.append((item, modified))
            } else if values.isDirectory != true, isInsideLocks, modified < cutoff {
                report.merge(SafeFileRemoval.removeItem(
                    at: item,
                    containedIn: root,
                    fileManager: fileManager
                ))
            }
        }

        for directory in lockDirectories.sorted(by: { $0.url.pathComponents.count > $1.url.pathComponents.count }) {
            guard directory.date < cutoff else { continue }
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: directory.url.path)
                if contents.isEmpty {
                    report.merge(SafeFileRemoval.removeItem(
                        at: directory.url,
                        containedIn: root,
                        fileManager: fileManager
                    ))
                }
            } catch {
                report.failed(directory.url, error)
            }
        }
        return report
    }

    private static func relativeComponents(of url: URL, in root: URL) -> [String] {
        Array(url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
