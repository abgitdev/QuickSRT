import Foundation
@testable import QuickSRT
import XCTest

@MainActor
final class OutputFileManagerTests: XCTestCase {
    func testExistingDestinationReplaceRenameAndCancelDecisions() {
        let suggested = URL(fileURLWithPath: "/Volumes/External/video.en.srt")
        let renamed = URL(fileURLWithPath: "/Volumes/External/video-copy.en.srt")

        XCTAssertEqual(
            OutputFileManager.resolveExistingDestination(suggested, decision: .replace),
            suggested
        )
        XCTAssertEqual(
            OutputFileManager.resolveExistingDestination(
                suggested,
                decision: .chooseAnother(renamed)
            ),
            renamed
        )
        XCTAssertNil(OutputFileManager.resolveExistingDestination(suggested, decision: .cancel))
        XCTAssertNil(
            OutputFileManager.resolveExistingDestination(
                suggested,
                decision: .chooseAnother(nil)
            )
        )
    }

    func testUnicodeEmojiAndLongVideoNamesProduceSiblingSRTNames() {
        let names = [
            "Семейное видео 🎬.mov",
            "日本語の長いファイル名.mp4",
            String(repeating: "é", count: 100) + "🙂.mkv",
        ]

        for name in names {
            let video = URL(fileURLWithPath: "/Volumes/Media/\(name)")
            let output = OutputFileManager.suggestedOutputURL(
                for: video,
                targetLanguage: .hindi
            )
            XCTAssertEqual(output.deletingLastPathComponent().path, "/Volumes/Media")
            XCTAssertEqual(output.pathExtension, "srt")
            XCTAssertTrue(output.lastPathComponent.hasSuffix(".hi.srt"))
            XCTAssertTrue(output.lastPathComponent.hasPrefix(video.deletingPathExtension().lastPathComponent))
        }
    }

    func testSymlinkAndDisconnectedVolumePathsRemainLexicalAndScoped() {
        let video = URL(fileURLWithPath: "/Volumes/Disconnected/Linked Folder/video.mov")

        let output = OutputFileManager.suggestedOutputURL(
            for: video,
            targetLanguage: .japanese
        )

        XCTAssertEqual(output.path, "/Volumes/Disconnected/Linked Folder/video.ja.srt")
    }

    func testSameBasenameDifferentExtensionsReceiveDistinctReservedOutputNames() {
        let mp4 = URL(fileURLWithPath: "/Volumes/Media/clip.mp4")
        let mov = URL(fileURLWithPath: "/Volumes/Media/clip.mov")
        let first = OutputFileManager.suggestedOutputURL(for: mp4, targetLanguage: .russian)
        let reserved = [OutputFileManager.reservationKey(for: first)]

        let second = OutputFileManager.suggestedOutputURL(
            for: mov,
            targetLanguage: .russian,
            avoiding: Set(reserved)
        )

        XCTAssertEqual(first.path, "/Volumes/Media/clip.ru.srt")
        XCTAssertEqual(second.path, "/Volumes/Media/clip.mov.ru.srt")
        XCTAssertNotEqual(
            OutputFileManager.reservationKey(for: first),
            OutputFileManager.reservationKey(for: second)
        )
    }

    func testReservationKeysConservativelyNormalizeCaseAndUnicode() {
        let composed = URL(fileURLWithPath: "/Volumes/Media/Café.EN.SRT")
        let decomposed = URL(fileURLWithPath: "/volumes/media/cafe\u{301}.en.srt")

        XCTAssertEqual(
            OutputFileManager.reservationKey(for: composed),
            OutputFileManager.reservationKey(for: decomposed)
        )
    }

    func testUnknownDurationIsAControlledVideoError() throws {
        let data = Data(#"{"streams":[{"codec_type":"audio","duration":"N/A"}],"format":{}}"#.utf8)

        XCTAssertThrowsError(try VideoProbe.parse(data)) { error in
            guard case QuickSRTError.invalidVideo(.durationUnavailable) = error else {
                return XCTFail("Expected controlled unknown-duration failure, got \(error).")
            }
        }
    }

    func testProbeRejectsDurationBeyondProcessingLimitBeforeIntegerConversion() throws {
        let duration = PipelineResourcePreflight.maximumVideoDuration + 1
        let data = Data(
            "{\"streams\":[{\"codec_type\":\"audio\"}],\"format\":{\"duration\":\"\(duration)\"}}".utf8
        )

        XCTAssertThrowsError(try VideoProbe.parse(data)) { error in
            guard case QuickSRTError.videoDurationLimitExceeded = error else {
                return XCTFail("Expected controlled duration-limit failure, got \(error).")
            }
        }
    }

    func testProbeRejectsGreatestFiniteDurationWithoutTrapping() throws {
        let data = Data(
            "{\"streams\":[{\"codec_type\":\"audio\"}],\"format\":{\"duration\":\"\(Double.greatestFiniteMagnitude)\"}}".utf8
        )

        XCTAssertThrowsError(try VideoProbe.parse(data)) { error in
            guard case QuickSRTError.videoDurationLimitExceeded = error else {
                return XCTFail("Expected controlled extreme-duration failure, got \(error).")
            }
        }
        XCTAssertEqual(DurationFormatter.string(from: Double.greatestFiniteMagnitude), "-")
    }
}
