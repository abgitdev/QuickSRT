import Foundation
import XCTest
@testable import QuickSRT

final class AppVersionInfoTests: XCTestCase {
    private let syntheticVersion = "7.3"

    func testDisplayTextIncludesVersionAndBuild() {
        let info = AppVersionInfo(marketingVersion: syntheticVersion, buildNumber: "13")

        XCTAssertEqual(info.displayText, "Version 7.3 · Build 13")
    }

    func testDisplayTextHandlesMissingVersion() {
        let info = AppVersionInfo(marketingVersion: nil, buildNumber: "13")

        XCTAssertEqual(info.displayText, "Build 13")
    }

    func testDisplayTextHandlesMissingBuild() {
        let info = AppVersionInfo(marketingVersion: syntheticVersion, buildNumber: nil)

        XCTAssertEqual(info.displayText, "Version 7.3")
    }

    func testDisplayTextHandlesBothValuesMissing() {
        let info = AppVersionInfo(marketingVersion: nil, buildNumber: nil)

        XCTAssertEqual(info.displayText, "Version unavailable")
    }

    func testDisplayTextIsAvailableInEveryInterfaceLanguage() {
        let info = AppVersionInfo(marketingVersion: syntheticVersion, buildNumber: "23")

        for language in AppLanguage.allCases {
            let text = info.displayText(language: language)
            XCTAssertTrue(text.contains(syntheticVersion), "Missing version for \(language.rawValue)")
            XCTAssertTrue(text.contains("23"), "Missing build for \(language.rawValue)")
            XCTAssertFalse(text.contains("%1$"), "Unresolved placeholder for \(language.rawValue)")
        }
    }
}

final class SubtitleQualityReportTests: XCTestCase {
    func testParsesCompleteQualityEventFromJSON() throws {
        let data = Data("""
        {
          "type": "complete",
          "input_segments": 100,
          "output_segments": 92,
          "removed": 8,
          "overlaps_adjusted": 3,
          "decoder_loops_trimmed": 2,
          "retained_low_confidence_segments": 4,
          "synthetic_word_timing_segments": 5,
          "quality_warning": true
        }
        """.utf8)
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let report = SubtitleQualityReport(event: event)

        XCTAssertEqual(report?.inputSegments, 100)
        XCTAssertEqual(report?.outputSegments, 92)
        XCTAssertEqual(report?.removedSegments, 8)
        XCTAssertEqual(report?.overlapsAdjusted, 3)
        XCTAssertEqual(report?.decoderLoopsTrimmed, 2)
        XCTAssertEqual(report?.retainedLowConfidenceSegments, 4)
        XCTAssertEqual(report?.syntheticWordTimingSegments, 5)
        XCTAssertEqual(report?.requiresUserWarning, true)
    }

    func testRejectsNonCompleteEvent() {
        XCTAssertNil(SubtitleQualityReport(event: ["type": "progress"]))
    }
}
