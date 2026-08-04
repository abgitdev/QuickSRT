import Foundation

public final class BoundedProcessOutputBuffer: @unchecked Sendable {
    public static let defaultMaximumBytes = 256 * 1_024
    public static let structuredEventPrefix = "QSR_EVENT\t"

    private let maximumBytes: Int
    private let lock = NSLock()
    private var retained = ""
    private var pendingLine = ""

    public init(maximumBytes: Int = defaultMaximumBytes) {
        self.maximumBytes = max(1, maximumBytes)
    }

    public var value: String {
        lock.withLock {
            var result = retained
            if !pendingLine.hasPrefix(Self.structuredEventPrefix) {
                result += pendingLine
            }
            return Self.utf8Suffix(result, maximumBytes: maximumBytes)
        }
    }

    public var retainedByteCount: Int {
        value.utf8.count
    }

    public func append(_ text: String) {
        guard !text.isEmpty else { return }

        lock.withLock {
            pendingLine += text.replacingOccurrences(of: "\r", with: "\n")
            let parts = pendingLine.components(separatedBy: "\n")
            pendingLine = parts.last ?? ""

            for line in parts.dropLast() where !line.hasPrefix(Self.structuredEventPrefix) {
                retained = Self.utf8Suffix(retained + line + "\n", maximumBytes: maximumBytes)
            }

            pendingLine = Self.utf8Suffix(pendingLine, maximumBytes: maximumBytes)
        }
    }

    private static func utf8Suffix(_ text: String, maximumBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maximumBytes else { return text }

        var suffix = Array(bytes.suffix(maximumBytes))
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix.removeFirst()
        }
        return String(decoding: suffix, as: UTF8.self)
    }
}

enum LineStreamParserError: LocalizedError, Equatable {
    case lineTooLong(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .lineTooLong(maximumBytes):
            return "Subprocess output contained a line longer than \(maximumBytes) bytes."
        }
    }
}

/// Incrementally splits UTF-8 subprocess output without allowing a missing
/// newline to grow an unbounded in-memory String.
final class LineStreamParser: @unchecked Sendable {
    static let defaultMaximumLineBytes = 64 * 1_024

    private let lock = NSLock()
    private let maximumLineBytes: Int
    private let onLine: @Sendable (String) -> Void
    private let onLimitExceeded: @Sendable () -> Void
    private var pendingBytes: [UInt8] = []
    private var previousWasCarriageReturn = false
    private var storedFailure: LineStreamParserError?

    init(
        maximumLineBytes: Int = defaultMaximumLineBytes,
        onLimitExceeded: @escaping @Sendable () -> Void = {},
        onLine: @escaping @Sendable (String) -> Void
    ) {
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.onLimitExceeded = onLimitExceeded
        self.onLine = onLine
        pendingBytes.reserveCapacity(min(self.maximumLineBytes, 4 * 1_024))
    }

    var bufferedByteCount: Int {
        lock.withLock { pendingBytes.count }
    }

    var failure: LineStreamParserError? {
        lock.withLock { storedFailure }
    }

    func consume(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        var exceededLimit = false
        lock.withLock {
            guard storedFailure == nil else { return }

            for byte in chunk.utf8 {
                if byte == 0x0A {
                    if previousWasCarriageReturn {
                        previousWasCarriageReturn = false
                    } else {
                        emitPendingLine()
                    }
                    continue
                }
                if byte == 0x0D {
                    emitPendingLine()
                    previousWasCarriageReturn = true
                    continue
                }

                previousWasCarriageReturn = false
                guard pendingBytes.count < maximumLineBytes else {
                    storedFailure = .lineTooLong(maximumBytes: maximumLineBytes)
                    pendingBytes.removeAll(keepingCapacity: false)
                    exceededLimit = true
                    break
                }
                pendingBytes.append(byte)
            }
        }

        if exceededLimit {
            onLimitExceeded()
        }
    }

    func finish() throws {
        try lock.withLock {
            if let storedFailure {
                throw storedFailure
            }
            if !pendingBytes.isEmpty {
                emitPendingLine()
            }
        }
    }

    private func emitPendingLine() {
        let line = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: true)
        onLine(line)
    }
}

public enum ProcessOutputSanitizer {
    private static let quotedDoublePath = try! NSRegularExpression(pattern: #"\"/[^\"\r\n]+\""#)
    private static let quotedSinglePath = try! NSRegularExpression(pattern: #"'/[^'\r\n]+'"#)
    private static let unquotedPath = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9:])/(?:[^\s\"'<>\[\](),;]+)"#
    )

    public static func sanitize(
        _ text: String,
        sensitiveValues: [String] = [],
        preservingStructuredEvents: Bool = false
    ) -> String {
        var sanitized = text.replacingOccurrences(of: "\r", with: "\n")
        let replacements = sensitiveValues
            .flatMap { value -> [String] in
                guard !value.isEmpty else { return [] }
                if value.hasPrefix("/") {
                    let name = URL(fileURLWithPath: value).lastPathComponent
                    return name.isEmpty ? [value] : [value, name]
                }
                return [value]
            }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }

        for value in replacements {
            sanitized = sanitized.replacingOccurrences(of: value, with: "<private-path>")
        }

        sanitized = replace(quotedDoublePath, in: sanitized, with: "\"<private-path>\"")
        sanitized = replace(quotedSinglePath, in: sanitized, with: "'<private-path>'")
        sanitized = replace(unquotedPath, in: sanitized, with: "<private-path>")

        guard !preservingStructuredEvents else { return sanitized }
        return sanitized
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix(BoundedProcessOutputBuffer.structuredEventPrefix) }
            .joined(separator: "\n")
    }

    private static func replace(
        _ expression: NSRegularExpression,
        in text: String,
        with replacement: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }
}

public enum ProcessErrorDetails {
    public static let maximumBytes = 16 * 1_024

    public static func make(
        stdout: String,
        stderr: String,
        sensitiveValues: [String] = []
    ) -> String {
        let preferred = meaningfulTail(stderr).isEmpty ? stdout : stderr
        let sanitized = ProcessOutputSanitizer.sanitize(preferred, sensitiveValues: sensitiveValues)
        return utf8Suffix(meaningfulTail(sanitized), maximumBytes: maximumBytes)
    }

    private static func meaningfulTail(_ text: String) -> String {
        var previous: String?
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard
                !line.isEmpty,
                !line.hasPrefix(BoundedProcessOutputBuffer.structuredEventPrefix),
                line != previous
            else { continue }
            lines.append(line)
            previous = line
        }
        return lines.suffix(120).joined(separator: "\n")
    }

    private static func utf8Suffix(_ text: String, maximumBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maximumBytes else { return text }
        var suffix = Array(bytes.suffix(maximumBytes))
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix.removeFirst()
        }
        return String(decoding: suffix, as: UTF8.self)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
