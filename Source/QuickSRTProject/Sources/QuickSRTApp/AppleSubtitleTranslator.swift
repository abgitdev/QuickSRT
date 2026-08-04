import Foundation
import Translation

@available(macOS 15.0, *)
struct AppleTranslationRequest: Equatable, Sendable {
    let sourceText: String
    let clientIdentifier: String
}

@available(macOS 15.0, *)
struct AppleTranslationResponse: Equatable, Sendable {
    let targetText: String
    let clientIdentifier: String?
}

@available(macOS 15.0, *)
protocol AppleTranslationSessionClient: Sendable {
    func prepare() async throws
    func translate(_ requests: [AppleTranslationRequest]) async throws -> [AppleTranslationResponse]
    func cancel() async
}

/// TranslationSession is not Sendable. This actor is its sole owner and is the
/// only place where framework request/response values cross the isolation boundary.
@available(macOS 15.0, *)
private final class AppleTranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }
}

@available(macOS 15.0, *)
private actor LiveAppleTranslationSessionClient: AppleTranslationSessionClient {
    // TranslationSession lacks Sendable annotations even though this actor is
    // its exclusive owner. The unsafe escape is limited to this stored value;
    // every framework operation remains serialized by the actor.
    private nonisolated(unsafe) let session: TranslationSession

    init(box: AppleTranslationSessionBox) {
        session = box.session
    }

    func prepare() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ requests: [AppleTranslationRequest]) async throws -> [AppleTranslationResponse] {
        let frameworkRequests = requests.map {
            TranslationSession.Request(
                sourceText: $0.sourceText,
                clientIdentifier: $0.clientIdentifier
            )
        }
        var responses: [AppleTranslationResponse] = []
        responses.reserveCapacity(requests.count)
        for try await response in session.translate(batch: frameworkRequests) {
            responses.append(AppleTranslationResponse(
                targetText: response.targetText,
                clientIdentifier: response.clientIdentifier
            ))
        }
        return responses
    }

    func cancel() {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            session.cancel()
        }
#endif
    }
}

@available(macOS 15.0, *)
private actor AppleTranslationCoordinator {
    private let client: any AppleTranslationSessionClient
    private var isCancelled = false
    private var isTranslating = false

    init(client: any AppleTranslationSessionClient) {
        self.client = client
    }

    func prepare() async throws {
        try await client.prepare()
    }

    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard !isCancelled else { throw CancellationError() }
        guard !isTranslating else { throw QuickSRTError.translationNotReady }
        isTranslating = true
        defer { isTranslating = false }

        var translated = Array<String?>(repeating: nil, count: texts.count)
        var completedOffsets: Set<Int> = []

        func recordProgress(for offset: Int) {
            guard completedOffsets.insert(offset).inserted else { return }
            progress(Double(completedOffsets.count) / Double(texts.count))
        }

        // Keep each request group modest so feature-length videos do not create
        // one enormous Translation framework batch in memory.
        for chunkStart in stride(from: 0, to: texts.count, by: 50) {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            let chunkEnd = min(chunkStart + 50, texts.count)
            let requests = (chunkStart..<chunkEnd).map { offset in
                AppleTranslationRequest(
                    sourceText: texts[offset],
                    clientIdentifier: String(offset)
                )
            }

            for response in try await client.translate(requests) {
                try Task.checkCancellation()
                guard
                    let identifier = response.clientIdentifier,
                    let offset = Int(identifier),
                    translated.indices.contains(offset)
                else {
                    throw QuickSRTError.translationOutputInvalid
                }
                guard translated[offset] == nil else {
                    throw QuickSRTError.translationOutputInvalid
                }
                translated[offset] = response.targetText
                recordProgress(for: offset)
            }
        }

        // Retry only missing or technically damaged fragments. A retry uses a
        // single-item request so a bad response cannot invalidate its siblings.
        for offset in texts.indices where translated[offset].flatMap({
            TranslationTextValidator.failure(in: $0)
        }) != nil || translated[offset] == nil {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            let responses = try await client.translate([
                AppleTranslationRequest(
                    sourceText: texts[offset],
                    clientIdentifier: String(offset)
                )
            ])
            guard
                responses.count == 1,
                let response = responses.first,
                response.clientIdentifier == String(offset),
                TranslationTextValidator.failure(in: response.targetText) == nil
            else {
                throw QuickSRTError.translationOutputInvalid
            }
            translated[offset] = response.targetText
            recordProgress(for: offset)
        }

        guard translated.allSatisfy({ value in
            guard let value else { return false }
            return TranslationTextValidator.failure(in: value) == nil
        }) else {
            throw QuickSRTError.translationOutputInvalid
        }
        return translated.compactMap { $0 }
    }

    func cancel() async {
        isCancelled = true
        await client.cancel()
    }
}

@available(macOS 15.0, *)
final class AppleSubtitleTranslator: SubtitleTranslating, @unchecked Sendable {
    private let coordinator: AppleTranslationCoordinator
    private let lock = NSLock()
    private var holder: CheckedContinuation<Void, Never>?
    private var isCancelled = false

    init(session: TranslationSession) {
        let box = AppleTranslationSessionBox(session: session)
        coordinator = AppleTranslationCoordinator(
            client: LiveAppleTranslationSessionClient(box: box)
        )
    }

    init(client: any AppleTranslationSessionClient) {
        coordinator = AppleTranslationCoordinator(client: client)
    }

    func prepare() async throws {
        try await coordinator.prepare()
    }

    func translate(
        texts: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        try await coordinator.translate(texts: texts, progress: progress)
    }

    func cancel() {
        Task { await coordinator.cancel() }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isCancelled = true
            defer { holder = nil }
            return holder
        }
        continuation?.resume()
    }

    /// Keeps the SwiftUI translation task—and therefore its session—alive while
    /// the view uses this translator for one or more subtitle jobs.
    func holdSession() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    guard !isCancelled else { return true }
                    holder = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
