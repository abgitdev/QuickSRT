import Foundation
@testable import QuickSRT
import XCTest

@available(macOS 15.0, *)
final class AppleSubtitleTranslatorTests: XCTestCase {
    func testPrepareAndBatchingPreserveIdentifiersOrderAndProgress() async throws {
        let client = RecordingAppleTranslationClient { requests, _ in
            requests.reversed().map {
                AppleTranslationResponse(
                    targetText: "T:\($0.sourceText)",
                    clientIdentifier: $0.clientIdentifier
                )
            }
        }
        let translator = AppleSubtitleTranslator(client: client)
        let progress = LockedValue<[Double]>([])
        let source = (0..<105).map { "line-\($0)" }

        try await translator.prepare()
        let translated = try await translator.translate(texts: source) { value in
            progress.withLock { $0.append(value) }
        }

        let prepareCount = await client.prepareCount
        let batchSizes = await client.batchSizes
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(batchSizes, [50, 50, 5])
        XCTAssertEqual(translated, source.map { "T:\($0)" })
        XCTAssertEqual(progress.withLock { $0.count }, source.count)
        XCTAssertEqual(progress.withLock { $0.last }, 1)
    }

    func testMissingAndDamagedResponsesAreRetriedIndividually() async throws {
        let client = RecordingAppleTranslationClient { requests, call in
            if call == 1 {
                return requests.compactMap { request in
                    switch request.clientIdentifier {
                    case "0":
                        return AppleTranslationResponse(
                            targetText: "",
                            clientIdentifier: request.clientIdentifier
                        )
                    case "1":
                        return nil
                    default:
                        return AppleTranslationResponse(
                            targetText: "OK:\(request.sourceText)",
                            clientIdentifier: request.clientIdentifier
                        )
                    }
                }
            }
            let request = requests[0]
            return [AppleTranslationResponse(
                targetText: "RETRY:\(request.sourceText)",
                clientIdentifier: request.clientIdentifier
            )]
        }
        let translator = AppleSubtitleTranslator(client: client)

        let translated = try await translator.translate(
            texts: ["alpha", "beta", "gamma"],
            progress: { _ in }
        )

        XCTAssertEqual(translated, ["RETRY:alpha", "RETRY:beta", "OK:gamma"])
        let batchSizes = await client.batchSizes
        XCTAssertEqual(batchSizes, [3, 1, 1])
    }

    func testDuplicateIdentifierIsRejected() async throws {
        let client = RecordingAppleTranslationClient { requests, _ in
            let first = requests[0]
            return [
                AppleTranslationResponse(
                    targetText: "one",
                    clientIdentifier: first.clientIdentifier
                ),
                AppleTranslationResponse(
                    targetText: "duplicate",
                    clientIdentifier: first.clientIdentifier
                ),
            ]
        }
        let translator = AppleSubtitleTranslator(client: client)

        do {
            _ = try await translator.translate(texts: ["one", "two"], progress: { _ in })
            XCTFail("Duplicate framework identifiers must not be accepted.")
        } catch QuickSRTError.translationOutputInvalid {
            // Expected controlled failure.
        }
    }

    func testCancelInterruptsInFlightTranslationAndMakesSessionTerminal() async throws {
        let client = BlockingAppleTranslationClient()
        let translator = AppleSubtitleTranslator(client: client)
        let task = Task {
            try await translator.translate(texts: ["hello"], progress: { _ in })
        }
        try await waitUntil { await client.hasStarted }

        translator.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled translation unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected.
        }
        let wasCancelled = await client.wasCancelled
        XCTAssertTrue(wasCancelled)
        await XCTAssertThrowsCancellation {
            _ = try await translator.translate(texts: ["again"], progress: { _ in })
        }
    }

    func testConcurrentTranslationOnOneSessionIsRejected() async throws {
        let client = BlockingAppleTranslationClient()
        let translator = AppleSubtitleTranslator(client: client)
        let first = Task {
            try await translator.translate(texts: ["first"], progress: { _ in })
        }
        try await waitUntil { await client.hasStarted }

        do {
            _ = try await translator.translate(texts: ["second"], progress: { _ in })
            XCTFail("A session must not run two translation batches concurrently.")
        } catch QuickSRTError.translationNotReady {
            // Expected serialization guard.
        }

        translator.cancel()
        _ = try? await first.value
    }

    func testAllTenCuratedLanguageScriptsRoundTripThroughSessionBoundary() async throws {
        let samples: [RecognitionLanguage: String] = [
            .english: "Hello world",
            .spanish: "Hola, mundo",
            .french: "Bonjour le monde",
            .german: "Hallo Welt",
            .russian: "Привет, мир",
            .japanese: "こんにちは世界",
            .korean: "안녕하세요 세계",
            .chinese: "你好世界",
            .hindi: "नमस्ते दुनिया",
            .italian: "Ciao mondo",
        ]
        XCTAssertEqual(Set(samples.keys), Set(RecognitionLanguage.allCases))
        let client = RecordingAppleTranslationClient { requests, _ in
            requests.map {
                AppleTranslationResponse(
                    targetText: "✓\($0.sourceText)",
                    clientIdentifier: $0.clientIdentifier
                )
            }
        }
        let translator = AppleSubtitleTranslator(client: client)
        let ordered = RecognitionLanguage.allCases.map { samples[$0]! }

        let translated = try await translator.translate(texts: ordered, progress: { _ in })

        XCTAssertEqual(translated, ordered.map { "✓\($0)" })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous translator state.")
    }
}

@available(macOS 15.0, *)
private actor RecordingAppleTranslationClient: AppleTranslationSessionClient {
    typealias Handler = @Sendable ([AppleTranslationRequest], Int) -> [AppleTranslationResponse]

    private let handler: Handler
    private(set) var prepareCount = 0
    private(set) var batchSizes: [Int] = []
    private var callCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func prepare() {
        prepareCount += 1
    }

    func translate(_ requests: [AppleTranslationRequest]) -> [AppleTranslationResponse] {
        callCount += 1
        batchSizes.append(requests.count)
        return handler(requests, callCount)
    }

    func cancel() {}
}

@available(macOS 15.0, *)
private actor BlockingAppleTranslationClient: AppleTranslationSessionClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func prepare() {}

    func translate(_ requests: [AppleTranslationRequest]) async throws -> [AppleTranslationResponse] {
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
        throw CancellationError()
    }

    func cancel() {
        wasCancelled = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@available(macOS 15.0, *)
private func XCTAssertThrowsCancellation(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected CancellationError.", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, got \(error).", file: file, line: line)
    }
}
