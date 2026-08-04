import Darwin
import Foundation

public struct OutputDestination: Equatable, Sendable {
    public let url: URL
    fileprivate let expectedState: DestinationState

    public static func authorizingCurrentState(_ url: URL) throws -> OutputDestination {
        OutputDestination(url: url, expectedState: try DestinationState.capture(at: url))
    }

    static func assumingAbsent(_ url: URL) -> OutputDestination {
        OutputDestination(url: url, expectedState: .absent)
    }
}

fileprivate enum DestinationState: Equatable, Sendable {
    case absent
    case existing(DestinationFingerprint)

    static func capture(at url: URL) throws -> DestinationState {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT { return .absent }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .existing(DestinationFingerprint(information))
    }
}

fileprivate struct DestinationFingerprint: Equatable, Sendable {
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

public enum SRTValidator {
    public static let maximumFileSize = 50 * 1_024 * 1_024

    public static func validate(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw QuickSRTError.invalidSRT(.notRegularFile)
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw QuickSRTError.invalidSRT(.emptyFile)
        }
        guard fileSize <= maximumFileSize else {
            throw QuickSRTError.invalidSRT(.unexpectedlyLarge)
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let contents = String(data: data, encoding: .utf8) else {
            throw QuickSRTError.invalidSRT(.invalidUTF8)
        }

        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !blocks.isEmpty else {
            throw QuickSRTError.invalidSRT(.noCues)
        }

        var previousEnd: TimeInterval = 0
        for (offset, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3 else {
                throw QuickSRTError.invalidSRT(.cueMissingText(offset + 1))
            }

            let expectedIndex = offset + 1
            guard Int(lines[0].trimmingCharacters(in: .whitespaces)) == expectedIndex else {
                throw QuickSRTError.invalidSRT(.invalidNumbering(expectedIndex))
            }

            let timestamps = lines[1].components(separatedBy: " --> ")
            guard
                timestamps.count == 2,
                let start = parseTimestamp(timestamps[0]),
                let end = parseTimestamp(timestamps[1]),
                end > start,
                start >= previousEnd
            else {
                throw QuickSRTError.invalidSRT(.invalidTimestamps(expectedIndex))
            }

            let text = lines.dropFirst(2).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw QuickSRTError.invalidSRT(.emptyCueText(expectedIndex))
            }
            previousEnd = end
        }
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let components = value
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let hours = Int(components[0]),
            let minutes = Int(components[1]),
            minutes >= 0, minutes < 60
        else {
            return nil
        }

        let secondsParts = components[2].split(separator: ",", omittingEmptySubsequences: false)
        guard
            secondsParts.count == 2,
            secondsParts[1].count == 3,
            let seconds = Int(secondsParts[0]),
            let milliseconds = Int(secondsParts[1]),
            seconds >= 0, seconds < 60,
            milliseconds >= 0, milliseconds < 1_000
        else {
            return nil
        }

        return TimeInterval(hours * 3_600 + minutes * 60 + seconds)
            + TimeInterval(milliseconds) / 1_000
    }
}

public enum SRTOutputWriter {
    public typealias AtomicCommit = (_ stagedURL: URL, _ destination: OutputDestination) throws -> Void

    @discardableResult
    public static func save(
        validatedSource sourceURL: URL,
        to destinationURL: URL,
        workspace: TempJobWorkspace? = nil
    ) throws -> CleanupReport {
        let destination = try OutputDestination.authorizingCurrentState(destinationURL)
        return try save(validatedSource: sourceURL, to: destination, workspace: workspace)
    }

    @discardableResult
    public static func save(
        validatedSource sourceURL: URL,
        to destination: OutputDestination,
        workspace: TempJobWorkspace? = nil
    ) throws -> CleanupReport {
        try save(
            validatedSource: sourceURL,
            to: destination,
            workspace: workspace,
            fileManager: .default,
            commit: atomicCommit
        )
    }

    @discardableResult
    public static func save(
        validatedSource sourceURL: URL,
        to destinationURL: URL,
        workspace: TempJobWorkspace? = nil,
        fileManager: FileManager = .default,
        commit: AtomicCommit
    ) throws -> CleanupReport {
        let destination = try OutputDestination.authorizingCurrentState(destinationURL)
        return try save(
            validatedSource: sourceURL,
            to: destination,
            workspace: workspace,
            fileManager: fileManager,
            commit: commit
        )
    }

    @discardableResult
    public static func save(
        validatedSource sourceURL: URL,
        to destination: OutputDestination,
        workspace: TempJobWorkspace? = nil,
        fileManager: FileManager = .default,
        commit: AtomicCommit
    ) throws -> CleanupReport {
        try SRTValidator.validate(sourceURL)

        let destinationURL = destination.url
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let stagingURL = parent.appendingPathComponent(
            ".quicksrt-\(UUID().uuidString)-\(destinationURL.lastPathComponent).tmp"
        )
        if let workspace {
            try workspace.trackOutputStagingArtifact(stagingURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            try SRTValidator.validate(stagingURL)
            try synchronize(stagingURL)
            try commit(stagingURL, destination)
        } catch {
            let cleanup = cleanupStaging(
                stagingURL,
                workspace: workspace,
                fileManager: fileManager
            )
            if !cleanup.isSuccessful {
                throw QuickSRTError.cleanupFailed(
                    primaryFailure: error.localizedDescription,
                    failures: cleanup.failures
                )
            }
            throw error
        }

        return cleanupStaging(
            stagingURL,
            workspace: workspace,
            fileManager: fileManager
        )
    }

    private static func cleanupStaging(
        _ stagingURL: URL,
        workspace: TempJobWorkspace?,
        fileManager: FileManager
    ) -> CleanupReport {
        if let workspace {
            return workspace.removeTrackedArtifact(stagingURL)
        }
        return SafeFileRemoval.removeItem(
            at: stagingURL,
            containedIn: stagingURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    private static func atomicCommit(from stagedURL: URL, to destination: OutputDestination) throws {
        let destinationURL = destination.url
        guard try DestinationState.capture(at: destinationURL) == destination.expectedState else {
            throw QuickSRTError.outputDestinationChanged
        }

        switch destination.expectedState {
        case .absent:
            let result = rename(stagedURL, destinationURL, flags: UInt32(RENAME_EXCL))
            guard result == 0 else {
                if errno == EEXIST { throw QuickSRTError.outputDestinationChanged }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        case .existing:
            let result = rename(stagedURL, destinationURL, flags: UInt32(RENAME_SWAP))
            guard result == 0 else {
                if errno == ENOENT { throw QuickSRTError.outputDestinationChanged }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            guard try DestinationState.capture(at: stagedURL) == destination.expectedState else {
                let rollback = rename(stagedURL, destinationURL, flags: UInt32(RENAME_SWAP))
                guard rollback == 0 else {
                    let recoveryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
                        ".quicksrt-recovered-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
                    )
                    let preserveResult = stagedURL.path.withCString { sourcePath in
                        recoveryURL.path.withCString { recoveryPath in
                            Darwin.rename(sourcePath, recoveryPath)
                        }
                    }
                    let preservedPath = preserveResult == 0 ? recoveryURL.path : stagedURL.path
                    throw QuickSRTError.cleanupFailed(
                        primaryFailure: QuickSRTError.outputDestinationChanged.localizedDescription,
                        failures: [CleanupFailure(
                            path: preservedPath,
                            reason: "The unexpected previous destination was preserved because the atomic rollback failed."
                        )]
                    )
                }
                throw QuickSRTError.outputDestinationChanged
            }
        }
    }

    private static func rename(_ source: URL, _ destination: URL, flags: UInt32) -> Int32 {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, flags)
            }
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
