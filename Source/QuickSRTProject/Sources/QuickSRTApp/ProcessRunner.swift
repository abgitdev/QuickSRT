import Darwin
import CryptoKit
import Foundation

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
}

public enum ChildProcessEnvironment {
    public static func sanitized(parent: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PIP_NO_CACHE_DIR": "1",
        ]
        for key in ["HOME", "TMPDIR", "LC_ALL", "LC_CTYPE"] {
            if let value = parent[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }
}

private struct SupportManifest: Decodable {
    struct Entry: Decodable {
        let path: String
        let type: String
        let sha256: String?
    }

    let schemaVersion: Int
    let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entries
    }
}

enum SupportBundleIntegrity {
    static func validate(file: URL) throws {
        let root = ProjectPaths.root.standardizedFileURL
        let allowsMissingManifest = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Source/QuickSRTProject").path
        )
        try validate(
            file: file,
            root: root,
            allowsMissingManifest: allowsMissingManifest
        )
    }

    static func validate(
        file: URL,
        root: URL,
        allowsMissingManifest: Bool = false
    ) throws {
        let root = root.standardizedFileURL
        let target = file.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPrefix) else {
            return
        }

        let manifestURL = root.appendingPathComponent("support-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            if allowsMissingManifest { return }
            throw NSError(
                domain: "QuickSRT.SupportIntegrity",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Support manifest is missing."]
            )
        }
        let relativePath = String(target.path.dropFirst(rootPrefix.count))
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(SupportManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1,
              let entry = manifest.entries.first(where: { $0.path == relativePath }),
              entry.type == "file",
              let expectedHash = entry.sha256
        else {
            throw NSError(
                domain: "QuickSRT.SupportIntegrity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Untrusted support file: \(relativePath)"]
            )
        }

        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            throw NSError(
                domain: "QuickSRT.SupportIntegrity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Support file integrity check failed: \(relativePath)"]
            )
        }
    }
}

final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var processes: [pid_t: RunningProcess] = [:]

    private init() {}

    func register(_ process: RunningProcess) {
        lock.lock()
        processes[process.pid] = process
        lock.unlock()
    }

    func unregister(pid: pid_t) {
        lock.lock()
        processes.removeValue(forKey: pid)
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let active = Array(processes.values)
        lock.unlock()

        for process in active {
            process.terminateTree()
        }
    }

    @discardableResult
    func terminateAllAndWait(timeout: TimeInterval = 8) -> [pid_t] {
        terminateAll()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = lock.sync { Array(processes.keys) }
            if remaining.isEmpty { return [] }
            usleep(20_000)
        }
        return lock.sync { Array(processes.keys).sorted() }
    }
}

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let terminationGracePeriod: TimeInterval
    private var current: RunningProcess?

    public init(terminationGracePeriod: TimeInterval = 2) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public var hasActiveProcess: Bool {
        lock.sync { current != nil }
    }

    public func stopCurrent() {
        let process = lock.sync {
            current
        }
        process?.terminateTree()
    }

    public func run(
        executable: URL,
        arguments: [String],
        label: String,
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try SupportBundleIntegrity.validate(file: executable)
        for argument in arguments where argument.hasPrefix("/") {
            try SupportBundleIntegrity.validate(file: URL(fileURLWithPath: argument))
        }

        let stdout = BoundedProcessOutputBuffer()
        let stderr = BoundedProcessOutputBuffer()
        let sensitiveValues = arguments.filter { $0.hasPrefix("/") }

        let process = try RunningProcess(
            executable: executable,
            arguments: arguments,
            terminationGracePeriod: terminationGracePeriod,
            onStdout: { text in
                stdout.append(text)
                onOutput(ProcessOutputSanitizer.sanitize(
                    text,
                    sensitiveValues: sensitiveValues,
                    preservingStructuredEvents: true
                ))
            },
            onStderr: { text in
                stderr.append(text)
                onOutput(ProcessOutputSanitizer.sanitize(
                    text,
                    sensitiveValues: sensitiveValues,
                    preservingStructuredEvents: true
                ))
            }
        )

        lock.sync {
            current = process
        }

        defer {
            lock.sync {
                if current === process {
                    current = nil
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    let exitCode = await process.waitForExit()
                    let out = stdout.value
                    let err = stderr.value
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    guard exitCode == 0 else {
                        throw QuickSRTError.commandFailed(
                            label: label,
                            exitCode: exitCode,
                            details: ProcessErrorDetails.make(
                                stdout: out,
                                stderr: err,
                                sensitiveValues: sensitiveValues
                            )
                        )
                    }
                    return CommandResult(stdout: out, stderr: err)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    process.terminateTree()
                    throw QuickSRTError.timeout(label: label, seconds: timeout)
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            process.terminateTree()
        }
    }
}

final class RunningProcess: @unchecked Sendable {
    let pid: pid_t

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let onStdout: @Sendable (String) -> Void
    private let onStderr: @Sendable (String) -> Void
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()
    private var terminationController: ProcessTerminationController?

    init(
        executable: URL,
        arguments: [String],
        terminationGracePeriod: TimeInterval,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }

        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGQUIT)
        sigaddset(&defaultSignals, SIGHUP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&attributes, &signalMask)

        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)

        var spawnedPid: pid_t = 0
        let argvStrings = [executable.path] + arguments
        let environment = ChildProcessEnvironment.sanitized(
            parent: ProcessInfo.processInfo.environment
        )
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        let result = argvStrings.withCStringArray { argv in
            envStrings.withCStringArray { env in
                posix_spawn(
                    &spawnedPid,
                    executable.path,
                    &actions,
                    &attributes,
                    argv,
                    env
                )
            }
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard result == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw POSIXError(.init(rawValue: result) ?? .EIO)
        }

        pid = spawnedPid
        stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        self.onStdout = onStdout
        self.onStderr = onStderr

        let identity = ProcessGroupIdentity(groupID: spawnedPid)
        terminationController = ProcessTerminationController(
            pid: spawnedPid,
            gracePeriod: terminationGracePeriod,
            prepareToTerminate: {
                identity.rememberCurrentMembersIfRootMatches()
            },
            isSameProcess: {
                identity.canSafelySignalGroup()
            },
            treeHasMembers: {
                identity.hasKnownMembers()
            }
        )

        let stdoutReadLock = self.stdoutReadLock
        let stderrReadLock = self.stderrReadLock
        stdoutHandle.readabilityHandler = { handle in
            stdoutReadLock.sync {
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                onStdout(String(decoding: data, as: UTF8.self))
            }
        }

        stderrHandle.readabilityHandler = { handle in
            stderrReadLock.sync {
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                onStderr(String(decoding: data, as: UTF8.self))
            }
        }

        ProcessRegistry.shared.register(self)
    }

    func waitForExit() async -> Int32 {
        await Task.detached(priority: .utility) {
            var status: Int32 = 0

            while true {
                let waited = waitpid(self.pid, &status, 0)
                if waited == -1, errno == EINTR {
                    continue
                }
                break
            }

            self.stdoutHandle.readabilityHandler = nil
            self.stderrHandle.readabilityHandler = nil
            self.stdoutReadLock.sync {
                if let data = try? self.stdoutHandle.readToEnd(), !data.isEmpty {
                    self.onStdout(String(decoding: data, as: UTF8.self))
                }
            }
            self.stderrReadLock.sync {
                if let data = try? self.stderrHandle.readToEnd(), !data.isEmpty {
                    self.onStderr(String(decoding: data, as: UTF8.self))
                }
            }
            try? self.stdoutHandle.close()
            try? self.stderrHandle.close()
            self.terminationController?.waitForTreeExit()
            self.terminationController?.markExited()
            ProcessRegistry.shared.unregister(pid: self.pid)

            let signal = status & 0x7f
            if signal == 0 {
                return (status >> 8) & 0xff
            }
            return 128 + signal
        }.value
    }

    func terminateTree() {
        terminationController?.terminateTree()
    }
}

private struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startAbsoluteTime: UInt64

    static func capture(pid: pid_t) -> ProcessIdentity? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        guard result == 0 else {
            return nil
        }
        return ProcessIdentity(pid: pid, startAbsoluteTime: info.ri_proc_start_abstime)
    }

    func matchesCurrentProcess() -> Bool {
        return Self.capture(pid: pid) == self
    }
}

private final class ProcessGroupIdentity: @unchecked Sendable {
    private let groupID: pid_t
    private let rootIdentity: ProcessIdentity?
    private let lock = NSLock()
    private var knownMembers: Set<ProcessIdentity>

    init(groupID: pid_t) {
        self.groupID = groupID
        let root = ProcessIdentity.capture(pid: groupID)
        rootIdentity = root
        knownMembers = Set(root.map { [$0] } ?? [])
    }

    func rememberCurrentMembersIfRootMatches() {
        guard
            rootIdentity?.matchesCurrentProcess() == true,
            getpgid(groupID) == groupID
        else { return }
        let captured = Self.currentMembers(of: groupID)
        lock.sync {
            knownMembers.formUnion(captured)
        }
    }

    func canSafelySignalGroup() -> Bool {
        hasKnownMembers()
    }

    func hasKnownMembers() -> Bool {
        let snapshot = lock.sync { knownMembers }
        return snapshot.contains { identity in
            getpgid(identity.pid) == groupID && identity.matchesCurrentProcess()
        }
    }

    private static func currentMembers(of groupID: pid_t) -> Set<ProcessIdentity> {
        let requiredBytes = proc_listpgrppids(groupID, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let capacity = max(1, Int(requiredBytes) / MemoryLayout<pid_t>.size + 8)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(groupID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Set(pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, getpgid(pid) == groupID else { return nil }
            return ProcessIdentity.capture(pid: pid)
        })
    }
}

public final class ProcessTerminationController: @unchecked Sendable {
    public typealias SignalSender = @Sendable (_ signal: Int32) -> Void

    private let gracePeriod: TimeInterval
    private let queue: DispatchQueue
    private let prepareToTerminate: @Sendable () -> Void
    private let isSameProcess: @Sendable () -> Bool
    private let treeHasMembers: @Sendable () -> Bool
    private let sendSignal: SignalSender
    private let lock = NSLock()
    private var terminationStarted = false
    private var hasExited = false
    private var forcedTermination: DispatchWorkItem?

    public init(
        pid: pid_t,
        gracePeriod: TimeInterval = 2,
        queue: DispatchQueue = DispatchQueue.global(qos: .utility),
        prepareToTerminate: @escaping @Sendable () -> Void = {},
        isSameProcess: @escaping @Sendable () -> Bool,
        treeHasMembers: @escaping @Sendable () -> Bool = { false },
        sendSignal: SignalSender? = nil
    ) {
        self.gracePeriod = gracePeriod
        self.queue = queue
        self.prepareToTerminate = prepareToTerminate
        self.isSameProcess = isSameProcess
        self.treeHasMembers = treeHasMembers
        self.sendSignal = sendSignal ?? { signal in
            Darwin.kill(-pid, signal)
            Darwin.kill(pid, signal)
        }
    }

    public func terminateTree() {
        let workItem: DispatchWorkItem? = lock.sync {
            guard !terminationStarted, !hasExited else {
                return nil
            }

            terminationStarted = true
            let item = DispatchWorkItem { [weak self] in
                self?.forceTerminateIfStillRunning()
            }
            forcedTermination = item
            return item
        }

        guard let workItem else {
            return
        }

        prepareToTerminate()
        sendSignal(SIGTERM)
        queue.asyncAfter(deadline: .now() + gracePeriod, execute: workItem)
    }

    func waitForTreeExit() {
        let shouldWait = lock.sync { terminationStarted && !hasExited }
        guard shouldWait else { return }
        let deadline = Date().addingTimeInterval(gracePeriod + 2)
        while treeHasMembers(), Date() < deadline {
            usleep(10_000)
        }
    }

    public func markExited() {
        let item: DispatchWorkItem? = lock.sync {
            guard !hasExited else {
                return nil
            }
            hasExited = true
            let item = forcedTermination
            forcedTermination = nil
            return item
        }
        item?.cancel()
    }

    private func forceTerminateIfStillRunning() {
        let shouldInspect = lock.sync {
            !hasExited && forcedTermination?.isCancelled == false
        }
        guard shouldInspect, isSameProcess() else {
            lock.sync {
                forcedTermination = nil
            }
            return
        }

        let shouldSignal = lock.sync {
            guard !hasExited, forcedTermination?.isCancelled == false else {
                return false
            }
            forcedTermination = nil
            return true
        }
        guard shouldSignal else {
            return
        }
        sendSignal(SIGKILL)
    }
}

private extension Array where Element == String {
    func withCStringArray<Result>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result) rethrows -> Result {
        let cStrings: [UnsafeMutablePointer<CChar>] = map { strdup($0)! }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }

        var pointers: [UnsafeMutablePointer<CChar>?] = cStrings.map { $0 }
        pointers.append(nil)

        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
