import Foundation
@testable import QuickSRT
import XCTest

final class ProcessOutputBufferTests: XCTestCase {
    func testLineStreamParserBoundsPendingLineAndReportsControlledError() {
        let parser = LineStreamParser(maximumLineBytes: 16) { _ in
            XCTFail("An oversized line must not be delivered.")
        }

        parser.consume(String(repeating: "x", count: 16))
        XCTAssertEqual(parser.bufferedByteCount, 16)
        parser.consume("y")

        XCTAssertEqual(parser.bufferedByteCount, 0)
        XCTAssertEqual(parser.failure, .lineTooLong(maximumBytes: 16))
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? LineStreamParserError, .lineTooLong(maximumBytes: 16))
        }
    }

    func testLineStreamParserHandlesChunkedCRLFAndFlushesFinalLine() throws {
        let lines = LockedValue<[String]>([])
        let parser = LineStreamParser(maximumLineBytes: 64) { line in
            lines.withLock { $0.append(line) }
        }

        parser.consume("first\r")
        parser.consume("\nsecond")
        try parser.finish()

        XCTAssertEqual(lines.withLock { $0 }, ["first", "second"])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testBufferNeverExceedsByteLimitAndKeepsTail() {
        let buffer = BoundedProcessOutputBuffer(maximumBytes: 64)

        buffer.append(String(repeating: "prefix-🙂-", count: 40))
        buffer.append("FINAL-MESSAGE")

        XCTAssertLessThanOrEqual(buffer.retainedByteCount, 64)
        XCTAssertTrue(buffer.value.hasSuffix("FINAL-MESSAGE"))
        XCTAssertNotNil(buffer.value.data(using: .utf8))
    }

    func testStructuredEventsAreNotRetainedEvenWhenSplitAcrossChunks() {
        let buffer = BoundedProcessOutputBuffer(maximumBytes: 1_024)

        buffer.append("QSR_EV")
        buffer.append("ENT\t{\"type\":\"progress\",\"fraction\":0.5}\n")
        buffer.append("Meaningful diagnostic\n")

        XCTAssertEqual(buffer.value, "Meaningful diagnostic\n")
        XCTAssertFalse(buffer.value.contains("fraction"))
    }

    func testSanitizerRemovesAbsolutePathsAndUserFileNames() {
        let privatePath = "/Users/example/Desktop/Private Family Video.mp4"
        let input = "Failed to read \"\(privatePath)\" from /Users/example/Library/cache.bin"

        let output = ProcessOutputSanitizer.sanitize(input, sensitiveValues: [privatePath])

        XCTAssertFalse(output.contains("/Users/"))
        XCTAssertFalse(output.contains("Private Family Video.mp4"))
        XCTAssertFalse(output.contains("cache.bin"))
        XCTAssertTrue(output.contains("<private-path>"))
    }

    func testErrorDetailsPreferBoundedStderrAndRemoveStructuredEvents() {
        let noisyError = String(repeating: "failure detail\n", count: 2_000)
            + "QSR_EVENT\t{\"type\":\"progress\"}\n"
            + "/Users/example/Desktop/Secret.mov\n"

        let details = ProcessErrorDetails.make(
            stdout: "stdout should not replace an error",
            stderr: noisyError,
            sensitiveValues: ["/Users/example/Desktop/Secret.mov"]
        )

        XCTAssertLessThanOrEqual(details.utf8.count, ProcessErrorDetails.maximumBytes)
        XCTAssertFalse(details.contains("QSR_EVENT"))
        XCTAssertFalse(details.contains("Secret.mov"))
        XCTAssertFalse(details.contains("stdout should not replace an error"))
        XCTAssertTrue(details.contains("failure detail"))
    }

    func testProcessRunnerBoundsLargeSuccessfulOutput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "print('x' * 400000 + 'FINAL')"],
            label: "large output",
            timeout: 10,
            onOutput: { _ in }
        )

        XCTAssertLessThanOrEqual(
            result.stdout.utf8.count,
            BoundedProcessOutputBuffer.defaultMaximumBytes
        )
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("FINAL"))
    }

    func testProcessRunnerDeliversStructuredEventsOnlyToTheParser() async throws {
        let received = LockedTestString()
        let script = "printf 'QSR_EVENT\\t{\\\"type\\\":\\\"progress\\\",\\\"fraction\\\":0.5}\\nvisible\\n'"

        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            label: "structured event probe",
            timeout: 10,
            onOutput: { received.append($0) }
        )

        XCTAssertTrue(received.value.contains("QSR_EVENT"))
        XCTAssertTrue(received.value.contains("visible"))
        XCTAssertFalse(result.stdout.contains("QSR_EVENT"))
        XCTAssertTrue(result.stdout.contains("visible"))
        XCTAssertFalse(ProcessOutputSanitizer.sanitize(received.value).contains("QSR_EVENT"))
    }

    func testProcessRunnerWaitsForInFlightOutputCallbackBeforeReturning() async throws {
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let runFinished = LockedTestFlag()

        let runTask = Task {
            defer { runFinished.set() }
            return try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'visible\\n'"],
                label: "output callback synchronization probe",
                timeout: 10,
                onOutput: { text in
                    guard text.contains("visible") else { return }
                    callbackStarted.signal()
                    _ = releaseCallback.wait(timeout: .now() + 5)
                }
            )
        }

        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 2), .success)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(runFinished.value)

        releaseCallback.signal()
        let result = try await runTask.value
        XCTAssertTrue(result.stdout.contains("visible"))
        XCTAssertTrue(runFinished.value)
    }
}

private final class LockedTestString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
