import Foundation
import XCTest
@testable import QuickSRT

final class TimedTranscriptModelsTests: XCTestCase {
    func testTimelineLoaderRejectsOversizedFileBeforeDecoding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-TimelineLimit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.timeline.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(TimedTranscriptValidator.maximumFileSizeBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try TimedTranscriptValidator.load(from: url)) { error in
            guard case let QuickSRTError.invalidTimeline(details) = error else {
                return XCTFail("Expected invalidTimeline, got \(error)")
            }
            XCTAssertTrue(details.contains("safety limit"))
        }
    }

    func testDecodesSnakeCaseTimelineWithFlexibleScalarTypes() throws {
        let data = Data(
            """
            {
              "version": 1,
              "language": "de-DE",
              "words": [
                {"id": 0, "start": "0.0", "end": 0.6, "word": "Hallo"},
                {"id": 1, "start": 0.6, "end": "1.2", "text": "Welt"}
              ],
              "segments": [
                {"id": 0, "start": 0, "end": 1.2, "text": "Hallo Welt", "word_start": 0, "word_end": 2}
              ],
              "semantic_units": [
                {
                  "id": 7,
                  "start": 0,
                  "end": 1.2,
                  "text": "Hallo Welt",
                  "word_start": "0",
                  "word_end": 2
                }
              ]
            }
            """.utf8
        )

        let transcript = try JSONDecoder().decode(TimedTranscript.self, from: data)

        XCTAssertEqual(transcript.version, "1")
        XCTAssertEqual(transcript.language, "de-DE")
        XCTAssertEqual(transcript.words.map(\.text), ["Hallo", "Welt"])
        XCTAssertEqual(transcript.semanticUnits.first?.id, "7")
        XCTAssertEqual(transcript.semanticUnits.first?.wordStart, 0)
        XCTAssertEqual(transcript.semanticUnits.first?.wordEnd, 2)
        XCTAssertEqual(transcript.duration, 1.2, accuracy: 0.000_001)
        XCTAssertNoThrow(try TimedTranscriptValidator.validate(transcript))
    }

    func testMissingMandatoryArraysFailDuringDecoding() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TimedTranscript.self,
                from: Data(#"{"version":1,"language":"de"}"#.utf8)
            )
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected keyNotFound, got \(error)")
            }
        }
    }

    func testMalformedMandatoryArrayFailsDuringDecoding() {
        let malformed = Data(
            #"{"version":1,"language":"de","words":{},"segments":[],"semantic_units":[]}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(TimedTranscript.self, from: malformed)) { error in
            guard case DecodingError.typeMismatch = error else {
                return XCTFail("Expected typeMismatch, got \(error)")
            }
        }
    }

    func testValidatorRejectsInvalidSemanticWordRange() throws {
        let transcript = TimedTranscript(
            language: "en",
            words: [TimedTranscriptWord(id: "0", start: 0, end: 1, text: "Hello")],
            segments: [
                TimedTranscriptSegment(
                    id: "0",
                    start: 0,
                    end: 1,
                    text: "Hello",
                    wordStart: 0,
                    wordEnd: 1
                )
            ],
            semanticUnits: [
                TranscriptSemanticUnit(
                    id: "unit",
                    start: 0,
                    end: 1,
                    text: "Hello",
                    wordStart: 0,
                    wordEnd: 2
                )
            ]
        )

        XCTAssertThrowsError(try TimedTranscriptValidator.validate(transcript)) { error in
            XCTAssertEqual(
                error as? TimedTranscriptValidationError,
                .invalidSemanticUnitWordRange("unit")
            )
        }
    }

    func testValidatorRejectsNonMonotonicWordTimeline() {
        let transcript = TimedTranscript(
            language: "en",
            words: [
                TimedTranscriptWord(id: "0", start: 0, end: 0.7, text: "First"),
                TimedTranscriptWord(id: "1", start: 0.6, end: 1, text: "second")
            ],
            segments: [
                TimedTranscriptSegment(
                    id: "0",
                    start: 0,
                    end: 1,
                    text: "First second",
                    wordStart: 0,
                    wordEnd: 2
                )
            ],
            semanticUnits: [
                TranscriptSemanticUnit(
                    id: "0",
                    start: 0,
                    end: 1,
                    text: "First second",
                    wordStart: 0,
                    wordEnd: 2
                )
            ]
        )

        XCTAssertThrowsError(try TimedTranscriptValidator.validate(transcript)) { error in
            XCTAssertEqual(error as? TimedTranscriptValidationError, .invalidWord(1))
        }
    }

    func testValidatorRejectsUnsupportedSchemaVersion() {
        let transcript = TimedTranscript(
            version: "2",
            language: "en",
            words: [TimedTranscriptWord(id: "0", start: 0, end: 1, text: "Hello")],
            segments: [
                TimedTranscriptSegment(
                    id: "0",
                    start: 0,
                    end: 1,
                    text: "Hello",
                    wordStart: 0,
                    wordEnd: 1
                )
            ],
            semanticUnits: [
                TranscriptSemanticUnit(
                    id: "0",
                    start: 0,
                    end: 1,
                    text: "Hello",
                    wordStart: 0,
                    wordEnd: 1
                )
            ]
        )

        XCTAssertThrowsError(try TimedTranscriptValidator.validate(transcript)) { error in
            XCTAssertEqual(
                error as? TimedTranscriptValidationError,
                .unsupportedVersion("2")
            )
        }
    }
}

final class SubtitleProfileTests: XCTestCase {
    func testAllTenLanguagesHaveExpectedAdultSubtitleLimits() {
        let expected: [(RecognitionLanguage, Double, Double, Double)] = [
            (.english, 42, 20, 0.833),
            (.russian, 42, 17, 0.833),
            (.german, 42, 17, 0.833),
            (.spanish, 42, 17, 0.833),
            (.italian, 42, 17, 0.833),
            (.french, 42, 17, 0.833),
            (.japanese, 13, 4, 0.5),
            (.chinese, 16, 9, 0.833),
            (.korean, 16, 12, 0.833),
            (.hindi, 42, 22, 0.833)
        ]

        XCTAssertEqual(RecognitionLanguage.allCases.count, expected.count)
        for (language, cpl, cps, minimumDuration) in expected {
            let profile = language.subtitleProfile
            XCTAssertEqual(profile.language, language)
            XCTAssertEqual(profile.maximumLines, 2)
            XCTAssertEqual(profile.maximumCharactersPerLine, cpl, accuracy: 0.000_001)
            XCTAssertEqual(profile.maximumCharactersPerSecond, cps, accuracy: 0.000_001)
            XCTAssertEqual(profile.minimumDuration, minimumDuration, accuracy: 0.000_001)
            XCTAssertEqual(profile.maximumDuration, 7, accuracy: 0.000_001)
        }
    }

    func testLanguageIdentifiersNormalizeToExistingRecognitionLanguage() {
        XCTAssertEqual(RecognitionLanguage(subtitleIdentifier: "zh_Hans_CN"), .chinese)
        XCTAssertEqual(RecognitionLanguage(subtitleIdentifier: "es-419"), .spanish)
        XCTAssertEqual(RecognitionLanguage(subtitleIdentifier: "JA-jp"), .japanese)
        XCTAssertNil(RecognitionLanguage(subtitleIdentifier: "pt-BR"))
    }

    func testJapaneseAndKoreanUseGuideSpecificHalfUnitCounting() {
        XCTAssertEqual(
            RecognitionLanguage.japanese.subtitleProfile.characterUnits(in: "ＡAｱ"),
            2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RecognitionLanguage.korean.subtitleProfile.characterUnits(in: "한A! "),
            2.5,
            accuracy: 0.000_001
        )
    }
}

final class SemanticUnitBuilderTests: XCTestCase {
    func testAdjacentWhisperFragmentsBecomeOneContextualTranslationGroup() throws {
        let transcript = makeTranscript(
            texts: ["Lena macht", "Kaffee."],
            timings: [(0, 0.7), (0.7, 1.4)]
        )

        let groups = try SemanticUnitBuilder.build(from: transcript, language: .german)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sourceText, "Lena macht Kaffee.")
        XCTAssertEqual(groups[0].start, 0, accuracy: 0.000_001)
        XCTAssertEqual(groups[0].end, 1.4, accuracy: 0.000_001)
    }

    func testBuilderStopsAtPauseAndSuppliesNeighborContext() throws {
        let transcript = makeTranscript(
            texts: ["Erster Satz.", "Zweiter Satz.", "Dritter Satz."],
            timings: [(0, 1), (1.2, 2.2), (3.5, 4.5)]
        )

        let groups = try SemanticUnitBuilder.build(from: transcript, language: .german)
        let units = SemanticUnitBuilder.translationUnits(from: groups)

        XCTAssertEqual(groups.map(\.sourceText), ["Erster Satz. Zweiter Satz.", "Dritter Satz."])
        XCTAssertNil(units[0].precedingContext)
        XCTAssertEqual(units[0].followingContext, "Dritter Satz.")
        XCTAssertEqual(units[1].precedingContext, "Erster Satz. Zweiter Satz.")
        XCTAssertNil(units[1].followingContext)
    }

    func testBuilderExtendsPastPreferredLimitToFinishSentence() throws {
        let transcript = makeTranscript(
            texts: [
                "Questa è una spazzola",
                "e la uso",
                "per spazzolare",
                "i capelli.",
                "Ora accendo il phon."
            ],
            timings: [(0, 2), (2, 4), (4, 6), (6, 8), (8, 10)]
        )

        let groups = try SemanticUnitBuilder.build(from: transcript, language: .italian)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(
            groups[0].sourceText,
            "Questa è una spazzola e la uso per spazzolare i capelli."
        )
        XCTAssertEqual(groups[1].sourceText, "Ora accendo il phon.")
    }

    private func makeTranscript(
        texts: [String],
        timings: [(TimeInterval, TimeInterval)]
    ) -> TimedTranscript {
        let words = zip(texts.indices, zip(texts, timings)).map { index, item in
            TimedTranscriptWord(
                id: String(index),
                start: item.1.0,
                end: item.1.1,
                text: item.0,
                confidence: 0.99
            )
        }
        let segments = zip(texts.indices, zip(texts, timings)).map { index, item in
            TimedTranscriptSegment(
                id: String(index),
                start: item.1.0,
                end: item.1.1,
                text: item.0,
                wordStart: index,
                wordEnd: index + 1
            )
        }
        let units = zip(texts.indices, zip(texts, timings)).map { index, item in
            TranscriptSemanticUnit(
                id: String(index),
                start: item.1.0,
                end: item.1.1,
                text: item.0,
                wordStart: index,
                wordEnd: index + 1
            )
        }
        return TimedTranscript(
            language: "de",
            words: words,
            segments: segments,
            semanticUnits: units
        )
    }
}

final class TargetSubtitleRendererTests: XCTestCase {
    func testRendererBorrowsBriefPrecedingSilenceForTightTranslatedTiming() throws {
        let units = [
            TranscriptSemanticUnit(id: "previous", start: 300, end: 301.02, text: "Previous"),
            TranscriptSemanticUnit(id: "tight", start: 301.92, end: 306.56, text: "Source"),
            TranscriptSemanticUnit(id: "next", start: 306.56, end: 308, text: "Next")
        ]
        let translations = [
            "previous": "Previous.",
            "tight": "That's it, I hope you've learned a lot of interesting things. Thank you for listening to this episode.",
            "next": "Next."
        ]

        let result = TargetSubtitleRenderer.render(
            semanticUnits: units,
            translatedTexts: translations,
            profile: RecognitionLanguage.english.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        let firstTightCue = try XCTUnwrap(
            result.document.cues.first { $0.text.contains("That's it") }
        )
        XCTAssertLessThan(try startMilliseconds(of: firstTightCue), 301_920)
        XCTAssertGreaterThanOrEqual(try startMilliseconds(of: firstTightCue), 301_020)
        assertDocument(result.document, respects: RecognitionLanguage.english.subtitleProfile)
    }

    func testRendererReportsMateriallyInsufficientTimingWindowAsWarning() {
        let units = [
            TranscriptSemanticUnit(id: "previous", start: 300, end: 301.92, text: "Previous"),
            TranscriptSemanticUnit(id: "tight", start: 301.92, end: 306.56, text: "Source"),
            TranscriptSemanticUnit(id: "next", start: 306.56, end: 308, text: "Next")
        ]
        let translations = [
            "previous": "Previous.",
            "tight": "That's it, I hope you've learned a lot of interesting things. Thank you for listening to this episode.",
            "next": "Next."
        ]

        let result = TargetSubtitleRenderer.render(
            semanticUnits: units,
            translatedTexts: translations,
            profile: RecognitionLanguage.english.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors)
        XCTAssertTrue(
            result.qualityReport.issues.contains {
                $0.code == .timingWindowInsufficient && $0.severity == .warning
            }
        )
        XCTAssertGreaterThan(result.qualityReport.reviewWarningCount, 0)
    }

    func testRendererUsesAvailableSilenceForUnevenCueReadingDurations() {
        let longKatakanaToken = String(repeating: "ア", count: 26)
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "uneven", start: 0, end: 1, text: "Source"),
                TranscriptSemanticUnit(id: "next", start: 8, end: 9, text: "Next")
            ],
            translatedTexts: [
                "uneven": "私\(longKatakanaToken)",
                "next": "次"
            ],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertFalse(result.qualityReport.issues.contains { $0.code == .readingSpeedExceeded })
        XCTAssertTrue(
            result.qualityReport.issues.contains {
                $0.code == .lineTooLong && $0.severity == .warning
            },
            "The indivisible synthetic katakana token should remain a separate layout review note."
        )
    }

    func testOversizedJapaneseTokenReportsCapacityWithoutFalseWindowWarning() {
        let oversizedToken = String(repeating: "ア", count: 40)
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "oversized", start: 0, end: 1, text: "Source"),
                TranscriptSemanticUnit(id: "next", start: 20, end: 21, text: "Next")
            ],
            translatedTexts: [
                "oversized": oversizedToken,
                "next": "次"
            ],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        let codes = result.qualityReport.issues.map(\.code)
        XCTAssertTrue(codes.contains(.timingCapacityExceeded))
        XCTAssertTrue(codes.contains(.lineTooLong))
        XCTAssertTrue(codes.contains(.readingSpeedExceeded))
        XCTAssertFalse(codes.contains(.timingWindowInsufficient))
        XCTAssertTrue(result.document.cues.contains { $0.text == oversizedToken })
    }

    func testReviewWarningCountDoesNotDoubleCountPlanningAndFinalCueDiagnostics() {
        let report = SubtitleQAReport(issues: [
            SubtitleQAIssue(
                severity: .warning,
                code: .timingWindowInsufficient,
                unitID: "unit-1",
                message: "Planning diagnostic"
            ),
            SubtitleQAIssue(
                severity: .warning,
                code: .readingSpeedExceeded,
                cueIndex: 1,
                unitID: "unit-1",
                message: "Final cue diagnostic"
            )
        ])

        XCTAssertEqual(report.warningCount, 2)
        XCTAssertEqual(report.reviewWarningCount, 1)
    }

    func testReviewWarningCountKeepsIndependentPlanningDiagnostics() {
        let report = SubtitleQAReport(issues: [
            SubtitleQAIssue(
                severity: .warning,
                code: .timingCapacityExceeded,
                unitID: "planning-only-1",
                message: "First planning diagnostic"
            ),
            SubtitleQAIssue(
                severity: .warning,
                code: .timingWindowInsufficient,
                unitID: "planning-only-1",
                message: "Same constrained unit"
            ),
            SubtitleQAIssue(
                severity: .warning,
                code: .timingWindowInsufficient,
                unitID: "planning-only-2",
                message: "Second constrained unit"
            ),
            SubtitleQAIssue(
                severity: .warning,
                code: .readingSpeedExceeded,
                cueIndex: 1,
                unitID: "different-final-unit",
                message: "Independent final cue diagnostic"
            )
        ])

        XCTAssertEqual(report.warningCount, 4)
        XCTAssertEqual(report.reviewWarningCount, 3)
    }

    func testKoreanRendererAddsCueWhenTwoWaySplitCannotMeetLineCapacity() {
        let text = "이 날은 이러한 유형의 갈등에서 사망한 사람들을 기억하는 데 중요합니다. 따라서 5월 1일이 일요일인 경우, 5월 8일도 마찬가지입니다."
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "ko-boundary", start: 0, end: 10.64, text: "Source")
            ],
            translatedTexts: ["ko-boundary": text],
            profile: RecognitionLanguage.korean.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertGreaterThanOrEqual(result.document.cues.count, 3)
        assertDocument(result.document, respects: RecognitionLanguage.korean.subtitleProfile)
    }

    func testKoreanRealTranslationAddsCueWhenHalfUnitWidthsStraddleLineLimit() {
        let text = "알람 시계가 크게 울립니다. 그녀는 아직도 피곤하지만, 일어납니다."
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "ko-real", start: 0, end: 8, text: "Source")
            ],
            translatedTexts: ["ko-real": text],
            profile: RecognitionLanguage.korean.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertGreaterThanOrEqual(result.document.cues.count, 2)
        assertDocument(result.document, respects: RecognitionLanguage.korean.subtitleProfile)
        XCTAssertEqual(flattenedText(result.document), text)
    }

    func testJapaneseRealTranslationAddsCueWhenNoLegalThirteenCharacterLineSplitExists() {
        let text = "でしょう！ とても悲しいです。 大変申し訳ございません"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "ja-real", start: 0, end: 8, text: "Source")
            ],
            translatedTexts: ["ja-real": text],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertGreaterThanOrEqual(result.document.cues.count, 2)
        assertDocument(result.document, respects: RecognitionLanguage.japanese.subtitleProfile)
        XCTAssertEqual(flattenedText(result.document), text)
    }

    func testJapanesePartitionDoesNotStrandLongBreakableTail() {
        let texts = [
            "大勢の観光客がカフェにやって来ます。 彼らはさまざまなものをたくさん注文します。 レナは落ち着いています。",
            "夕方に、彼女は月曜日のやることリストを作ります。 午後9時30分に、彼女はベッドに横たわり、私が自分の人生に感謝していると思っています。",
            "タスクは、私たちが学んでいる技術により基づいていると思います。 しかし、確かではありません。 ウェブサイトにクラスの説明があります。"
        ]

        for (index, text) in texts.enumerated() {
            let result = TargetSubtitleRenderer.render(
                semanticUnits: [
                    TranscriptSemanticUnit(
                        id: "ja-tail-\(index)",
                        start: 0,
                        end: 18,
                        text: "Source"
                    )
                ],
                translatedTexts: ["ja-tail-\(index)": text],
                profile: RecognitionLanguage.japanese.subtitleProfile
            )

            XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
            XCTAssertFalse(result.qualityReport.issues.contains {
                $0.code == .lineTooLong && $0.severity == .error
            })
            XCTAssertEqual(
                flattenedUnspacedText(result.document).replacingOccurrences(of: " ", with: ""),
                text.replacingOccurrences(of: " ", with: "")
            )
        }
    }

    func testJapaneseCapacityFallbackAvoidsSingleCharacterCueExplosion() {
        let text = "左手でキーボードに触れることができませんし、右手でも作業できません。また、左手はすでに他の操作に自由になっているため、作業速度が向上しています。"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(
                    id: "ja-fragmentation",
                    start: 307.616,
                    end: 319.760,
                    text: "Source"
                )
            ],
            translatedTexts: ["ja-fragmentation": text],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertTrue((3...6).contains(result.document.cues.count), "Unexpected cues: \(result.document.cues)")
        XCTAssertFalse(result.qualityReport.issues.contains { $0.code == .cueTooShort })
        XCTAssertTrue(result.document.cues.allSatisfy {
            $0.text.replacingOccurrences(of: "\n", with: "").count > 1
        })
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
        assertJapaneseTokensRemainWithinDisplayLines(
            ["左手", "右手", "キーボード", "触れる", "作業", "速度", "向上"],
            in: result.document
        )
    }

    func testJapaneseTokenizerProtectsObservedWordsAcrossCueAndLineBreaks() {
        let cases: [(String, [String])] = [
            (
                "必要なものを特定のキーに割り当てることができます。すべてを割り当ててください。これは便利な装置と呼ばれているため、作業速度が向上します。",
                ["必要", "特定", "キー", "割り当てる", "割り当て", "ください", "装置", "呼ば", "作業", "速度", "向上"]
            ),
            (
                "Blender3と3Dモデルを午後9時30分にレンダリングし、コンピューターで確認します。🎬",
                ["Blender3", "3D", "モデル", "午後", "レンダリング", "コンピューター", "確認"]
            )
        ]

        for (index, item) in cases.enumerated() {
            let result = TargetSubtitleRenderer.render(
                semanticUnits: [
                    TranscriptSemanticUnit(
                        id: "ja-tokenizer-\(index)",
                        start: 0,
                        end: 18,
                        text: "Source"
                    )
                ],
                translatedTexts: ["ja-tokenizer-\(index)": item.0],
                profile: RecognitionLanguage.japanese.subtitleProfile
            )

            XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
            XCTAssertEqual(flattenedUnspacedText(result.document), item.0)
            assertJapaneseTokensRemainWithinDisplayLines(item.1, in: result.document)
        }
    }

    func testOversizedJapaneseTokenRemainsWholeWithWarning() {
        let text = "スーパーカリフラジリスティックエクスピアリドーシャス"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "ja-long-token", start: 0, end: 8, text: "Source")
            ],
            translatedTexts: ["ja-long-token": text],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertTrue(result.qualityReport.issues.contains {
            $0.code == .lineTooLong && $0.severity == .warning
        })
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
        assertJapaneseTokensRemainWithinDisplayLines([text], in: result.document)
    }

    func testChinesePartitionDoesNotStrandLongBreakableTail() {
        let text = "下班后，她开车回家，快速洗了个澡，吃了点东西，一碗汤和一块面包。 下午4点30分，她去上德语课程。"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "zh-tail", start: 0, end: 14, text: "Source")
            ],
            translatedTexts: ["zh-tail": text],
            profile: RecognitionLanguage.chinese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertFalse(result.qualityReport.issues.contains {
            $0.code == .lineTooLong && $0.severity == .error
        })
        XCTAssertEqual(
            flattenedUnspacedText(result.document),
            text.replacingOccurrences(of: " ", with: "")
        )
    }

    func testOneGermanSemanticUnitIsResegmentedIntoReadableTargetCues() throws {
        let text = "Heute bereiten Lena und ihre Kollegin gemeinsam Kaffee zu, danach besuchen sie das Café und sehen am Abend einen spannenden Film."
        let unit = TranscriptSemanticUnit(
            id: "de-1",
            start: 0,
            end: 18,
            text: "Source sentence",
            wordStart: 0,
            wordEnd: 1
        )

        let result = TargetSubtitleRenderer.render(
            semanticUnits: [unit],
            translatedTexts: ["de-1": text],
            profile: RecognitionLanguage.german.subtitleProfile
        )

        XCTAssertGreaterThan(result.document.cues.count, 1)
        XCTAssertTrue(result.qualityReport.passed, issueSummary(result.qualityReport))
        assertDocument(result.document, respects: RecognitionLanguage.german.subtitleProfile)
        XCTAssertEqual(
            flattenedText(result.document),
            text,
            "Resegmentation must neither lose nor duplicate translated words."
        )
    }

    func testDifferentTargetLanguagesMayProduceDifferentCueCounts() {
        let unit = TranscriptSemanticUnit(id: "source", start: 0, end: 6, text: "Source")
        let english = TargetSubtitleRenderer.render(
            semanticUnits: [unit],
            translatedTexts: ["source": "They make coffee."],
            profile: RecognitionLanguage.english.subtitleProfile
        )
        let german = TargetSubtitleRenderer.render(
            semanticUnits: [unit],
            translatedTexts: [
                "source": "Lena und ihre Kollegin bereiten gemeinsam einen Kaffee zu und besuchen danach das Café Sonnenschein, bevor sie am Abend einen spannenden Film ansehen."
            ],
            profile: RecognitionLanguage.german.subtitleProfile
        )

        XCTAssertFalse(english.qualityReport.hasErrors, issueSummary(english.qualityReport))
        XCTAssertFalse(german.qualityReport.hasErrors, issueSummary(german.qualityReport))
        XCTAssertNotEqual(english.document.cues.count, german.document.cues.count)
    }

    func testTranslationIDsAreIndependentOfTranslationArrayOrder() {
        let units = [
            TranscriptSemanticUnit(id: "a", start: 0, end: 2, text: "A"),
            TranscriptSemanticUnit(id: "b", start: 2.5, end: 4.5, text: "B")
        ]
        let translations = [
            TranslatedSemanticUnitText(unitID: "b", text: "Second translation"),
            TranslatedSemanticUnitText(unitID: "a", text: "First translation")
        ]

        let result = TargetSubtitleRenderer.render(
            semanticUnits: units,
            translatedTexts: translations,
            profile: RecognitionLanguage.english.subtitleProfile
        )

        XCTAssertEqual(result.document.cues.map(\.text), ["First translation", "Second translation"])
        XCTAssertTrue(result.qualityReport.passed, issueSummary(result.qualityReport))
    }

    func testUnspacedChineseTextWrapsWithinSixteenCharactersAndTwoLines() {
        let text = "今天我们一起学习如何制作一杯香浓咖啡然后去公园看一场有趣的电影"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [TranscriptSemanticUnit(id: "zh-1", start: 0, end: 8, text: text)],
            translatedTexts: ["zh-1": text],
            profile: RecognitionLanguage.chinese.subtitleProfile
        )

        XCTAssertTrue(result.qualityReport.passed, issueSummary(result.qualityReport))
        assertDocument(result.document, respects: RecognitionLanguage.chinese.subtitleProfile)
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
    }

    func testJapaneseUsesThirteenCharacterInterlingualLimit() {
        let text = "今日はみんなでコーヒーを作ってから公園へ映画を見に行きます。"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [TranscriptSemanticUnit(id: "ja-1", start: 0, end: 9, text: text)],
            translatedTexts: ["ja-1": text],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertTrue(result.qualityReport.passed, issueSummary(result.qualityReport))
        assertDocument(result.document, respects: RecognitionLanguage.japanese.subtitleProfile)
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
    }

    func testRendererKeepsContractionsAndElisionsWholeAcrossCueBoundaries() {
        let englishText = "I'm not at home today, I'm going out and so I'm getting ready to go out."
        let english = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "en", start: 0, end: 18, text: "Source")
            ],
            translatedTexts: ["en": englishText],
            profile: RecognitionLanguage.english.subtitleProfile
        )
        let rawFrenchText = "Je suis dans la salle de bain aujourd ' hui et j ' espère sortir bientôt."
        let normalizedFrenchText = "Je suis dans la salle de bain aujourd'hui et j'espère sortir bientôt."
        let french = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "fr", start: 0, end: 14, text: "Source")
            ],
            translatedTexts: ["fr": rawFrenchText],
            profile: RecognitionLanguage.french.subtitleProfile
        )

        XCTAssertFalse(english.qualityReport.hasErrors, issueSummary(english.qualityReport))
        XCTAssertFalse(french.qualityReport.hasErrors, issueSummary(french.qualityReport))
        assertNoApostropheBreaks(in: english.document)
        assertNoApostropheBreaks(in: french.document)
        XCTAssertEqual(flattenedText(english.document), englishText)
        XCTAssertEqual(flattenedText(french.document), normalizedFrenchText)
    }

    func testRendererDoesNotSplitJapaneseNumbersAcrossCues() {
        let text = "現在は10時18分です。現在10時18分ですので、準備を始めます。"
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "ja-number", start: 0, end: 16, text: "Source")
            ],
            translatedTexts: ["ja-number": text],
            profile: RecognitionLanguage.japanese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        let compactCues = result.document.cues.map {
            $0.text.replacingOccurrences(of: "\n", with: "")
        }
        for pair in zip(compactCues, compactCues.dropFirst()) {
            XCTAssertFalse(pair.0.last?.isNumber == true && pair.1.first?.isNumber == true)
        }
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
    }

    func testRendererNormalizesTraditionalChineseToSimplifiedChinese() {
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "zh-hans", start: 0, end: 5, text: "Source")
            ],
            translatedTexts: [
                "zh-hans": "假期有付費嗎？在法國，這是最後一個。阿尔薩斯。"
            ],
            profile: RecognitionLanguage.chinese.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertEqual(
            flattenedUnspacedText(result.document),
            "假期有付费吗？在法国，这是最后一个。阿尔萨斯。"
        )
    }

    func testRendererClampsFinalCuesToMediaDuration() throws {
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [
                TranscriptSemanticUnit(id: "last", start: 300, end: 316.94, text: "Source")
            ],
            translatedTexts: [
                "last": "もしお気に召し、役に立ったのであれば、ぜひチャンネル登録と「いいね」、そしてポッドキャストプラットフォームへの5つ星をご投稿ください。新しいエピソードでまたお会いしましょう！"
            ],
            profile: RecognitionLanguage.japanese.subtitleProfile,
            mediaDuration: 316.557642
        )

        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        let lastCue = try XCTUnwrap(result.document.cues.last)
        XCTAssertLessThanOrEqual(try endMilliseconds(of: lastCue), 316_557)
        XCTAssertFalse(
            result.qualityReport.issues.contains { $0.code == .cuePastMediaEnd },
            issueSummary(result.qualityReport)
        )
    }

    func testQualityAssessorRejectsCuePastMediaDuration() {
        let document = SRTDocument(cues: [
            SRTCue(
                index: 1,
                timingLine: "00:00:04,000 --> 00:00:05,001",
                text: "End"
            )
        ])

        let report = SubtitleQualityAssessor.assess(
            document: document,
            profile: RecognitionLanguage.english.subtitleProfile,
            mediaDuration: 5
        )

        XCTAssertTrue(report.hasErrors)
        XCTAssertTrue(report.issues.contains { $0.code == .cuePastMediaEnd })
    }

    func testOversizedIndivisibleTokenRemainsWholeWithWarning() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 90)
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [TranscriptSemanticUnit(id: "emoji", start: 0, end: 10, text: text)],
            translatedTexts: ["emoji": text],
            profile: RecognitionLanguage.english.subtitleProfile
        )

        XCTAssertFalse(result.qualityReport.issues.contains { $0.code == .forcedLexicalBreak })
        XCTAssertTrue(result.qualityReport.issues.contains {
            $0.code == .lineTooLong && $0.severity == .warning
        })
        XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
        XCTAssertEqual(flattenedUnspacedText(result.document), text)
        XCTAssertTrue(
            result.document.cues
                .flatMap { $0.text.filter { $0 != "\n" } }
                .allSatisfy { String($0) == family }
        )
    }

    func testRendererNeverBreaksObservedWordsOrNumberRuns() {
        let cases: [(RecognitionLanguage, String, [String])] = [
            (.german, "Diese besondere Reise beantwortet diese Frage vollständig.", ["Diese", "diese"]),
            (.spanish, "Vamos a responder cuidadosamente antes de continuar.", ["responder"]),
            (.french, "Les réponses sont basées uniquement sur les faits disponibles.", ["basées"]),
            (.italian, "Lena prepara lentamente una colazione davvero speciale.", ["Lena"]),
            (.english, "The year 1945 remains one indivisible numeric token.", ["1945"])
        ]

        for (language, text, tokens) in cases {
            let result = TargetSubtitleRenderer.render(
                semanticUnits: [
                    TranscriptSemanticUnit(id: language.rawValue, start: 0, end: 2, text: text)
                ],
                translatedTexts: [language.rawValue: text],
                profile: language.subtitleProfile
            )
            XCTAssertFalse(result.qualityReport.hasErrors, issueSummary(result.qualityReport))
            XCTAssertFalse(result.qualityReport.issues.contains { $0.code == .forcedLexicalBreak })
            for token in tokens {
                XCTAssertTrue(
                    result.document.cues.contains { cue in
                        cue.text.components(separatedBy: "\n").contains { $0.contains(token) }
                    },
                    "\(language.rawValue) split token \(token): \(result.document.cues)"
                )
            }
        }
    }

    func testMissingTranslationProducesExplicitQAFailure() {
        let result = TargetSubtitleRenderer.render(
            semanticUnits: [TranscriptSemanticUnit(id: "missing", start: 0, end: 2, text: "Hello")],
            translatedTexts: [:],
            profile: RecognitionLanguage.english.subtitleProfile
        )

        XCTAssertTrue(result.document.cues.isEmpty)
        XCTAssertTrue(result.qualityReport.hasErrors)
        XCTAssertTrue(result.qualityReport.issues.contains { $0.code == .missingTranslation })
    }

    func testTranslationTextValidatorRejectsDamagedUnicodeAndEmptyText() {
        XCTAssertEqual(TranslationTextValidator.failure(in: "  \n"), .empty)
        XCTAssertEqual(
            TranslationTextValidator.failure(in: "亡くなった方々を�留保留する"),
            .replacementCharacter
        )
        XCTAssertEqual(
            TranslationTextValidator.failure(in: "valid\u{0000}text"),
            .disallowedControlCharacter
        )
        XCTAssertNil(TranslationTextValidator.failure(in: "中文、日本語 और हिन्दी ✅"))
    }

    func testQualityAssessorFindsLineDurationAndReadingSpeedViolations() {
        let document = SRTDocument(cues: [
            SRTCue(
                index: 1,
                timingLine: "00:00:00,000 --> 00:00:00,500",
                text: "\(String(repeating: "a", count: 43))\nsecond\nthird"
            )
        ])

        let report = SubtitleQualityAssessor.assess(
            document: document,
            profile: RecognitionLanguage.english.subtitleProfile
        )
        let codes = Set(report.issues.map(\.code))

        XCTAssertTrue(codes.contains(.tooManyLines))
        XCTAssertTrue(codes.contains(.lineTooLong))
        XCTAssertTrue(codes.contains(.cueTooShort))
        XCTAssertTrue(codes.contains(.readingSpeedExceeded))
        XCTAssertFalse(report.passed)
    }

    func testQualityAssessorToleratesOneMillisecondOfSRTRoundingAtCPSBoundary() {
        let toleratedDocument = SRTDocument(cues: [
            SRTCue(
                index: 1,
                timingLine: "00:00:10,001 --> 00:00:11,706",
                text: String(repeating: "a", count: 29)
            )
        ])

        let toleratedReport = SubtitleQualityAssessor.assess(
            document: toleratedDocument,
            profile: RecognitionLanguage.french.subtitleProfile
        )
        XCTAssertFalse(toleratedReport.issues.contains { $0.code == .readingSpeedExceeded })

        let exceededDocument = SRTDocument(cues: [
            SRTCue(
                index: 1,
                timingLine: "00:00:10,001 --> 00:00:11,705",
                text: String(repeating: "a", count: 29)
            )
        ])
        let exceededReport = SubtitleQualityAssessor.assess(
            document: exceededDocument,
            profile: RecognitionLanguage.french.subtitleProfile
        )
        XCTAssertTrue(exceededReport.issues.contains { $0.code == .readingSpeedExceeded })
    }

    private func assertDocument(
        _ document: SRTDocument,
        respects profile: SubtitleProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for cue in document.cues {
            let lines = cue.text.components(separatedBy: "\n")
            XCTAssertLessThanOrEqual(lines.count, 2, file: file, line: line)
            for displayLine in lines {
                XCTAssertLessThanOrEqual(
                    profile.characterUnits(in: displayLine),
                    profile.maximumCharactersPerLine,
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertTrue(
            SubtitleQualityAssessor.assess(document: document, profile: profile).passed,
            file: file,
            line: line
        )
    }

    private func flattenedText(_ document: SRTDocument) -> String {
        document.cues
            .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func flattenedUnspacedText(_ document: SRTDocument) -> String {
        document.cues
            .map { $0.text.replacingOccurrences(of: "\n", with: "") }
            .joined()
    }

    private func startMilliseconds(of cue: SRTCue) throws -> Int {
        let timestamp = try XCTUnwrap(cue.timingLine.components(separatedBy: " --> ").first)
        let timeParts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertEqual(timeParts.count, 3)
        let secondsParts = try XCTUnwrap(timeParts.last).split(separator: ",")
        XCTAssertEqual(secondsParts.count, 2)
        return try XCTUnwrap(Int(timeParts[0])) * 3_600_000
            + (try XCTUnwrap(Int(timeParts[1])) * 60_000)
            + (try XCTUnwrap(Int(secondsParts[0])) * 1_000)
            + (try XCTUnwrap(Int(secondsParts[1])))
    }

    private func endMilliseconds(of cue: SRTCue) throws -> Int {
        let timestamp = try XCTUnwrap(cue.timingLine.components(separatedBy: " --> ").last)
        let timeParts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertEqual(timeParts.count, 3)
        let secondsParts = try XCTUnwrap(timeParts.last).split(separator: ",")
        XCTAssertEqual(secondsParts.count, 2)
        return try XCTUnwrap(Int(timeParts[0])) * 3_600_000
            + (try XCTUnwrap(Int(timeParts[1])) * 60_000)
            + (try XCTUnwrap(Int(secondsParts[0])) * 1_000)
            + (try XCTUnwrap(Int(secondsParts[1])))
    }

    private func assertNoApostropheBreaks(
        in document: SRTDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let compactCues = document.cues.map {
            $0.text.replacingOccurrences(of: "\n", with: "")
        }
        for pair in zip(compactCues, compactCues.dropFirst()) {
            XCTAssertFalse(
                pair.0.last == "'" || pair.0.last == "’",
                "A cue must not end inside an apostrophe-bound word: \(pair.0) | \(pair.1)",
                file: file,
                line: line
            )
        }
    }

    private func assertJapaneseTokensRemainWithinDisplayLines(
        _ tokens: [String],
        in document: SRTDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var compactText = ""
        var displayBreakOffsets: Set<Int> = []

        for (cueIndex, cue) in document.cues.enumerated() {
            if cueIndex > 0 {
                displayBreakOffsets.insert(compactText.count)
            }
            for (lineIndex, displayLine) in cue.text.components(separatedBy: "\n").enumerated() {
                if lineIndex > 0 {
                    displayBreakOffsets.insert(compactText.count)
                }
                compactText.append(displayLine)
            }
        }

        for token in tokens {
            var searchStart = compactText.startIndex
            var found = false
            while searchStart < compactText.endIndex,
                  let range = compactText.range(
                    of: token,
                    range: searchStart..<compactText.endIndex
                  ) {
                found = true
                let start = compactText.distance(from: compactText.startIndex, to: range.lowerBound)
                let end = compactText.distance(from: compactText.startIndex, to: range.upperBound)
                XCTAssertFalse(
                    displayBreakOffsets.contains { start < $0 && $0 < end },
                    "Japanese token was split across a cue or line: \(token) in \(document.cues)",
                    file: file,
                    line: line
                )
                searchStart = range.upperBound
            }
            XCTAssertTrue(found, "Missing expected Japanese token: \(token)", file: file, line: line)
        }
    }

    private func issueSummary(_ report: SubtitleQAReport) -> String {
        report.issues.map { "\($0.code.rawValue): \($0.message)" }.joined(separator: " | ")
    }
}
