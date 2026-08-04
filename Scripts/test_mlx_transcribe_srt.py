import contextlib
import importlib.util
import io
import json
import math
import pathlib
import sys
import tempfile
import types
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("mlx_transcribe_srt.py")
SPEC = importlib.util.spec_from_file_location("mlx_transcribe_srt", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TranscriptSanitizerTests(unittest.TestCase):
    def test_comparison_key_normalizes_nfc_case_and_apostrophes(self):
        self.assertEqual(
            MODULE._comparison_key("CAFE\u0301 L’HOMME"),
            MODULE._comparison_key("café l'homme"),
        )

    def test_comparison_key_preserves_devanagari_combining_marks(self):
        self.assertNotEqual(
            MODULE._comparison_key("कल"),
            MODULE._comparison_key("काल"),
        )

    def test_duplicate_key_does_not_casefold_distinct_german_words_together(self):
        self.assertNotEqual(
            MODULE._duplicate_key("Maße"),
            MODULE._duplicate_key("Masse"),
        )

    def test_preserves_short_intentional_repetition(self):
        text, changed = MODULE.collapse_repeated_phrases("no no no")
        self.assertEqual(text, "no no no")
        self.assertFalse(changed)

    def test_preserves_repeated_chorus_with_healthy_confidence(self):
        chorus = "we will rock you " * 4
        text, changed = MODULE.collapse_repeated_phrases(
            chorus,
            compression_ratio=2.8,
            avg_logprob=-0.2,
        )
        self.assertEqual(text, chorus.strip())
        self.assertFalse(changed)

    def test_preserves_a_long_sentence_repeated_twice(self):
        sentence = "this is a deliberately repeated sentence with several meaningful words"
        text, changed = MODULE.collapse_repeated_phrases(f"{sentence} {sentence}")
        self.assertEqual(text, f"{sentence} {sentence}")
        self.assertFalse(changed)

    def test_removes_extreme_single_word_decoder_loop(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "in " * 50,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, "")
        self.assertTrue(changed)

    def test_removes_extreme_multi_word_decoder_loop(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "in this " * 30,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, "")
        self.assertTrue(changed)

    def test_trims_decoder_loop_but_preserves_meaningful_context(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "Blender and Plasticity " + "income " * 40,
            avg_logprob=-1.2,
        )
        self.assertEqual(
            text,
            "Blender and Plasticity",
        )
        self.assertTrue(changed)

    def test_does_not_create_a_hindi_loop_by_discarding_vowel_marks(self):
        text = " ".join(["कल", "काल"] * 6)
        sanitized, changed = MODULE.collapse_repeated_phrases(text)
        self.assertEqual(sanitized, text)
        self.assertFalse(changed)

    def test_removes_no_space_chinese_decoder_loop(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "你好" * 12,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, "")
        self.assertTrue(changed)

    def test_trims_no_space_cjk_loop_without_rewriting_context(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "今天新闻。" + "谢谢观看" * 12,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, "今天新闻。")
        self.assertTrue(changed)

    def test_uses_reliable_whisper_word_units_for_no_space_text(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "你好" * 12,
            avg_logprob=-1.2,
            word_timestamps=[{"word": "你好"}] * 12,
        )
        self.assertEqual(text, "")
        self.assertTrue(changed)

    def test_preserves_short_intentional_japanese_repetition(self):
        text, changed = MODULE.collapse_repeated_phrases("はいはいはい")
        self.assertEqual(text, "はいはいはい")
        self.assertFalse(changed)

    def test_preserves_natural_multilingual_repetition_without_bad_metrics(self):
        samples = {
            "zh": "哈" * 12,
            "ja": "ハ" * 12,
            "ko": "하" * 12,
            "hi": "हा " * 12,
        }
        for language, source in samples.items():
            with self.subTest(language=language):
                text, changed = MODULE.collapse_repeated_phrases(
                    source,
                    compression_ratio=3.2,
                    avg_logprob=-0.2,
                )
                self.assertEqual(text, source.strip())
                self.assertFalse(changed)

    def test_finds_decoder_loop_hidden_by_larger_benign_repetition(self):
        context = "one two three four five six seven eight " * 4
        text, changed = MODULE.collapse_repeated_phrases(
            context + "glitch " * 20,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, context.strip())
        self.assertTrue(changed)

    def test_preserves_short_cjk_context_after_trimming_a_loop(self):
        text, changed = MODULE.collapse_repeated_phrases(
            "好。" + "谢谢观看" * 12,
            avg_logprob=-1.2,
        )
        self.assertEqual(text, "好。")
        self.assertTrue(changed)

    def test_removes_zero_length_duplicate_and_fully_overlapped_segments(self):
        segments, report = MODULE.sanitize_segments([
            {"start": 1, "end": 1, "text": "bad"},
            {"start": 2, "end": 4, "text": "Hello world."},
            {"start": 3.5, "end": 5, "text": "hello world"},
            {"start": 3, "end": 3.5, "text": "fully covered"},
            {"start": 6, "end": 7, "text": "Next line"},
        ])
        self.assertEqual([item["text"] for item in segments], ["Hello world.", "Next line"])
        self.assertEqual(report["removed"], 3)

    def test_keeps_distinct_hindi_segments_and_preserves_display_text(self):
        display_text = "Cafe\u0301 — L’HOMME"
        segments, report = MODULE.sanitize_segments([
            {"start": 0, "end": 1, "text": "कल"},
            {"start": 1, "end": 2, "text": "काल"},
            {"start": 2, "end": 3, "text": display_text},
        ])
        self.assertEqual(
            [item["text"] for item in segments],
            ["कल", "काल", display_text],
        )
        self.assertEqual(report["removed"], 0)

    def test_keeps_identical_consecutive_non_overlapping_cues(self):
        segments, report = MODULE.sanitize_segments([
            {"start": 0, "end": 1, "text": "Again"},
            {"start": 1, "end": 2, "text": "again"},
            {"start": 2.5, "end": 3.5, "text": "AGAIN"},
        ])
        self.assertEqual(len(segments), 3)
        self.assertEqual(report["removed"], 0)

    def test_keeps_overlapping_german_words_distinct(self):
        segments, report = MODULE.sanitize_segments([
            {"start": 0, "end": 2, "text": "Maße"},
            {"start": 1, "end": 3, "text": "Masse"},
        ])
        self.assertEqual([item["text"] for item in segments], ["Maße", "Masse"])
        self.assertEqual(segments[1]["start"], 2)
        self.assertEqual(report["removed"], 0)
        self.assertEqual(report["overlaps_adjusted"], 1)

    def test_clamps_partial_overlap_and_produces_monotonic_timestamps(self):
        segments, report = MODULE.sanitize_segments([
            {"start": 1, "end": 3, "text": "First"},
            {"start": 2.5, "end": 4, "text": "Second"},
        ])
        self.assertEqual(segments[1]["start"], 3)
        self.assertEqual(report["overlaps_adjusted"], 1)
        MODULE.validate_clean_segments(segments)

    def test_uses_model_quality_metrics_without_discarding_confident_speech(self):
        segments, report = MODULE.sanitize_segments([
            {
                "start": 0,
                "end": 1,
                "text": "Confident speech",
                "avg_logprob": -0.1,
                "no_speech_prob": 0.9,
                "compression_ratio": 1.2,
            },
            {
                "start": 1,
                "end": 2,
                "text": "Unreliable silence",
                "avg_logprob": -1.5,
                "no_speech_prob": 0.9,
                "compression_ratio": 1.2,
            },
            {
                "start": 2,
                "end": 3,
                "text": "Unreliable repetition",
                "avg_logprob": -1.5,
                "no_speech_prob": 0.1,
                "compression_ratio": 3.0,
            },
        ])
        self.assertEqual([item["text"] for item in segments], ["Confident speech"])
        self.assertEqual(report["removed_by_reason"]["no_speech"], 1)
        self.assertEqual(report["removed_by_reason"]["low_confidence_repetition"], 1)

    def test_warns_when_removed_segment_ratio_is_suspicious(self):
        source = [
            {"start": index, "end": index + 0.5, "text": "" if index < 5 else f"line {index}"}
            for index in range(10)
        ]
        _, report = MODULE.sanitize_segments(source)
        self.assertEqual(report["removed"], 5)
        self.assertTrue(report["quality_warning"])

    def test_does_not_warn_for_a_small_number_of_removed_segments(self):
        source = [
            {"start": index, "end": index + 0.5, "text": "" if index < 2 else f"line {index}"}
            for index in range(100)
        ]
        _, report = MODULE.sanitize_segments(source)
        self.assertEqual(report["removed"], 2)
        self.assertFalse(report["quality_warning"])

    def test_writes_monotonic_srt_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "test.srt"
            MODULE.write_srt(path, [{"start": 1.25, "end": 2.5, "text": "Hello"}])
            self.assertIn("00:00:01,250 --> 00:00:02,500", path.read_text())


class TimelineSidecarTests(unittest.TestCase):
    @staticmethod
    def _word(text, start, end, probability=0.9):
        return {
            "text": text,
            "start": start,
            "end": end,
            "probability": probability,
        }

    def test_sanitizer_trace_maps_source_segments_without_changing_public_api(self):
        source = [
            "not a segment",
            {"start": 0, "end": 2, "text": "First"},
            {"start": 1.5, "end": 3, "text": "Second"},
            {"start": 4, "end": 4, "text": "Invalid"},
        ]

        cleaned, report, trace = MODULE._sanitize_segments_with_trace(source)
        public_cleaned, public_report = MODULE.sanitize_segments(source)

        self.assertEqual(public_cleaned, cleaned)
        self.assertEqual(public_report, report)
        self.assertEqual([item["source_index"] for item in trace], [0, 1, 2, 3])
        self.assertEqual(trace[0]["reason"], "invalid_segment")
        self.assertEqual(trace[1]["output_index"], 0)
        self.assertFalse(trace[1]["start_adjusted"])
        self.assertEqual(trace[2]["output_index"], 1)
        self.assertTrue(trace[2]["start_adjusted"])
        self.assertEqual(trace[3]["reason"], "invalid_timestamp")
        self.assertEqual(cleaned[1]["start"], 2)

    def test_timeline_preserves_words_probabilities_and_segment_metrics(self):
        result = {
            "language": "de",
            "segments": [{
                "start": 0,
                "end": 1.2,
                "text": " Lena spricht.",
                "seek": 128,
                "temperature": 0,
                "avg_logprob": -0.21,
                "compression_ratio": 1.08,
                "no_speech_prob": 0.01,
                "words": [
                    {
                        "word": " Lena",
                        "start": 0.1,
                        "end": 0.45,
                        "probability": 0.91,
                    },
                    {
                        "word": " spricht.",
                        "start": 0.45,
                        "end": 1.1,
                        "probability": 0.82,
                    },
                ],
            }],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )

        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="en",
        )

        self.assertEqual(timeline["version"], MODULE.TIMELINE_VERSION)
        self.assertEqual(timeline["language"], "de")
        self.assertEqual(len(timeline["words"]), 2)
        self.assertEqual(timeline["words"][0]["source_word_index"], 0)
        self.assertAlmostEqual(timeline["words"][0]["probability"], 0.91)
        self.assertNotIn("synthetic", timeline["words"][0])
        self.assertEqual(timeline["segments"][0]["word_start"], 0)
        self.assertEqual(timeline["segments"][0]["word_end"], 2)
        self.assertEqual(timeline["segments"][0]["seek"], 128)
        self.assertAlmostEqual(timeline["segments"][0]["avg_logprob"], -0.21)
        self.assertAlmostEqual(timeline["segments"][0]["compression_ratio"], 1.08)
        self.assertAlmostEqual(timeline["segments"][0]["no_speech_prob"], 0.01)
        self.assertEqual(timeline["semantic_units"], [{
            "id": 0,
            "start": 0.1,
            "end": 1.1,
            "text": "Lena spricht.",
            "word_start": 0,
            "word_end": 2,
        }])

    def test_semantic_units_split_on_sentence_endings_and_long_pauses(self):
        words = [
            self._word("Hallo", 0, 0.4),
            self._word(" Welt.\u201d", 0.4, 1.0),
            self._word(" Weiter", 1.1, 1.5),
            self._word(" geht", 1.5, 2.0),
            self._word(" es", 3.0, 3.3),
            self._word(" gut\u0964", 3.3, 4.0),
        ]

        units = MODULE.reconstruct_semantic_units(words, "de")

        self.assertEqual(
            [unit["text"] for unit in units],
            ["Hallo Welt.\u201d", "Weiter geht", "es gut\u0964"],
        )
        self.assertEqual(
            [(unit["word_start"], unit["word_end"]) for unit in units],
            [(0, 2), (2, 4), (4, 6)],
        )

    def test_semantic_units_render_and_split_simplified_chinese_without_spaces(self):
        words = [
            self._word("\u4f60", 0, 0.3),
            self._word("\u597d\u3002", 0.3, 0.7),
            self._word("\u4e0b", 0.8, 1.0),
            self._word("\u53e5\u3002", 1.0, 1.4),
        ]

        units = MODULE.reconstruct_semantic_units(words, "zh")

        self.assertEqual([unit["text"] for unit in units], ["\u4f60\u597d\u3002", "\u4e0b\u53e5\u3002"])
        self.assertEqual([(unit["start"], unit["end"]) for unit in units], [(0, 0.7), (0.8, 1.4)])

    def test_semantic_units_apply_a_hard_duration_boundary(self):
        words = [
            self._word("one", 0, 5),
            self._word(" two", 5, 10),
            self._word(" three", 10, 15),
            self._word(" four", 15, 16),
        ]

        units = MODULE.reconstruct_semantic_units(words, "en")

        self.assertEqual([unit["text"] for unit in units], ["one two three", "four"])
        self.assertEqual([(unit["word_start"], unit["word_end"]) for unit in units], [(0, 3), (3, 4)])

    def test_timeline_uses_a_synthetic_timed_word_when_source_words_are_unsafe(self):
        result = {
            "segments": [{
                "start": 2,
                "end": 3,
                "text": "Hello",
                "words": [{
                    "word": "Wrong",
                    "start": 2,
                    "end": 3,
                    "probability": 0.7,
                }],
            }],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )

        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="en",
        )

        self.assertEqual(len(timeline["words"]), 1)
        self.assertTrue(timeline["words"][0]["synthetic"])
        self.assertIsNone(timeline["words"][0]["probability"])
        self.assertEqual(timeline["words"][0]["text"], "Hello")
        self.assertEqual(timeline["semantic_units"][0]["text"], "Hello")
        self.assertEqual(report["synthetic_word_timing_segments"], 1)
        self.assertEqual(report["retained_low_confidence_segments"], 0)
        self.assertTrue(report["quality_warning"])
        self.assertEqual(
            (timeline["semantic_units"][0]["start"], timeline["semantic_units"][0]["end"]),
            (2.0, 3.0),
        )

    def test_timeline_reports_retained_low_confidence_segments(self):
        result = {
            "segments": [{
                "start": 0,
                "end": 1,
                "text": " Hello",
                "avg_logprob": -1.2,
                "compression_ratio": 1.0,
                "no_speech_prob": 0.0,
                "words": [{
                    "word": " Hello",
                    "start": 0,
                    "end": 1,
                    "probability": 0.4,
                }],
            }],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(result["segments"])

        MODULE.build_timeline(result, cleaned, report, trace, language="en")

        self.assertEqual(report["retained_low_confidence_segments"], 1)
        self.assertEqual(report["synthetic_word_timing_segments"], 0)
        self.assertTrue(report["quality_warning"])

    def test_timeline_rejects_nonmonotonic_words_after_overlap_adjustment(self):
        result = {
            "segments": [
                {
                    "start": 0,
                    "end": 2,
                    "text": " First.",
                    "words": [{
                        "word": " First.",
                        "start": 0,
                        "end": 2,
                        "probability": 0.9,
                    }],
                },
                {
                    "start": 1.5,
                    "end": 3,
                    "text": " Second.",
                    "words": [{
                        "word": " Second.",
                        "start": 1.5,
                        "end": 3,
                        "probability": 0.9,
                    }],
                },
            ],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )

        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="en",
        )

        self.assertFalse(timeline["words"][0].get("synthetic", False))
        self.assertTrue(timeline["words"][1]["synthetic"])
        self.assertEqual(timeline["words"][1]["start"], 2.0)
        self.assertGreaterEqual(
            timeline["words"][1]["start"],
            timeline["words"][0]["end"],
        )

    def test_decoder_loop_trimming_cannot_reuse_stale_word_ranges(self):
        source_words = [{
            "word": " Context",
            "start": 0,
            "end": 0.1,
            "probability": 0.9,
        }]
        source_words.extend({
            "word": " glitch",
            "start": index / 10,
            "end": (index + 1) / 10,
            "probability": 0.1,
        } for index in range(1, 21))
        result = {
            "segments": [{
                "start": 0,
                "end": 3,
                "text": "".join(word["word"] for word in source_words),
                "avg_logprob": -1.2,
                "words": source_words,
            }],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )

        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="en",
        )

        self.assertEqual(cleaned[0]["text"], "Context")
        self.assertTrue(timeline["segments"][0]["decoder_loop_trimmed"])
        self.assertEqual(len(timeline["words"]), 1)
        self.assertTrue(timeline["words"][0]["synthetic"])
        self.assertEqual(timeline["words"][0]["text"], "Context")
        self.assertEqual(timeline["words"][0]["start"], 0.0)
        self.assertEqual(timeline["words"][0]["end"], 3.0)

    def test_timeline_keeps_rejected_segment_evidence_outside_renderable_words(self):
        result = {
            "language": "de",
            "segments": [
                {
                    "start": 0,
                    "end": 1,
                    "text": " Noise",
                    "avg_logprob": -1.5,
                    "no_speech_prob": 0.95,
                    "compression_ratio": 1.1,
                    "words": [{
                        "word": " Noise",
                        "start": 0.1,
                        "end": 0.8,
                        "probability": 0.03,
                    }],
                },
                {
                    "start": 1,
                    "end": 2,
                    "text": " Hallo.",
                    "avg_logprob": -0.1,
                    "no_speech_prob": 0.01,
                    "words": [{
                        "word": " Hallo.",
                        "start": 1.1,
                        "end": 1.8,
                        "probability": 0.97,
                    }],
                },
            ],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )

        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="de",
        )

        self.assertEqual([word["text"] for word in timeline["words"]], [" Hallo."])
        self.assertEqual(len(timeline["discarded_segments"]), 1)
        discarded = timeline["discarded_segments"][0]
        self.assertEqual(discarded["reason"], "no_speech")
        self.assertEqual(discarded["source_index"], 0)
        self.assertEqual(discarded["words"][0]["text"], " Noise")
        self.assertAlmostEqual(discarded["words"][0]["probability"], 0.03)
        self.assertAlmostEqual(discarded["avg_logprob"], -1.5)

    def test_discarded_segment_evidence_is_bounded_and_reports_omissions(self):
        rejected = [{
            "start": index,
            "end": index + 0.5,
            "text": "noise-" + ("x" * 100),
            "avg_logprob": -2.0,
            "no_speech_prob": 0.99,
            "words": [self._word(" noise", index, index + 0.1)] * 5,
        } for index in range(5)]
        accepted = {
            "start": 5,
            "end": 6,
            "text": " Speech.",
            "avg_logprob": -0.1,
            "no_speech_prob": 0.0,
            "words": [self._word(" Speech.", 5, 6)],
        }
        result = {"language": "en", "segments": rejected + [accepted]}
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(result["segments"])

        with mock.patch.object(MODULE, "MAX_DISCARDED_SEGMENTS", 2), \
             mock.patch.object(MODULE, "MAX_DISCARDED_WORDS_PER_SEGMENT", 1), \
             mock.patch.object(MODULE, "MAX_DISCARDED_TEXT_CHARACTERS", 12):
            timeline = MODULE.build_timeline(
                result,
                cleaned,
                report,
                trace,
                language="en",
            )

        self.assertEqual(len(timeline["discarded_segments"]), 2)
        self.assertEqual(timeline["discarded_segments_omitted"], 3)
        self.assertLessEqual(len(timeline["discarded_segments"][0]["text"]), 12)
        self.assertEqual(len(timeline["discarded_segments"][0]["words"]), 1)

    def test_nonfinite_decoder_values_become_json_null(self):
        result = {
            "segments": [{
                "start": 0,
                "end": 1,
                "text": " Test.",
                "seek": float("inf"),
                "temperature": float("nan"),
                "avg_logprob": -0.2,
                "compression_ratio": float("inf"),
                "no_speech_prob": float("nan"),
                "words": [{
                    "word": " Test.",
                    "start": 0.1,
                    "end": 0.9,
                    "probability": float("nan"),
                }],
            }],
        }
        cleaned, report, trace = MODULE._sanitize_segments_with_trace(
            result["segments"]
        )
        timeline = MODULE.build_timeline(
            result,
            cleaned,
            report,
            trace,
            language="en",
        )

        self.assertIsNone(timeline["segments"][0]["seek"])
        self.assertIsNone(timeline["segments"][0]["temperature"])
        self.assertIsNone(timeline["segments"][0]["compression_ratio"])
        self.assertIsNone(timeline["segments"][0]["no_speech_prob"])
        self.assertIsNone(timeline["words"][0]["probability"])
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "timeline.json"
            MODULE.write_timeline(path, timeline)
            decoded = json.loads(path.read_text(encoding="utf-8"))
        self.assertIsNone(decoded["segments"][0]["temperature"])

    def test_timeline_write_is_utf8_atomic_and_cleans_failed_temporary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "clip.timeline.json"
            timeline = {
                "version": 1,
                "language": "zh",
                "words": [{"text": "\u5979\u8bf4\u8bdd\u3002"}],
                "segments": [],
                "semantic_units": [],
            }

            MODULE.write_timeline(path, timeline)

            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8"))["words"][0]["text"],
                "\u5979\u8bf4\u8bdd\u3002",
            )
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                MODULE.write_timeline(path, {"invalid": math.nan})
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(root.glob(".clip.timeline.json.*.tmp")), [])

    def test_timeline_writer_enforces_byte_limit_and_removes_partial_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "bounded.timeline.json"
            with mock.patch.object(MODULE, "MAX_TIMELINE_BYTES", 64):
                with self.assertRaisesRegex(ValueError, "safety limit"):
                    MODULE.write_timeline(path, {"text": "🙂" * 100})

            self.assertFalse(path.exists())
            self.assertEqual(list(root.glob(".bounded.timeline.json.*.tmp")), [])

    def test_main_keeps_srt_cli_contract_and_reports_timeline_file(self):
        captured = {}

        def fake_transcribe(audio, **kwargs):
            captured["audio"] = audio
            captured["kwargs"] = kwargs
            return {
                "language": "de",
                "segments": [{
                    "start": 1.25,
                    "end": 2.5,
                    "text": " Hallo.",
                    "avg_logprob": -0.1,
                    "compression_ratio": 1.0,
                    "no_speech_prob": 0.01,
                    "words": [{
                        "word": " Hallo.",
                        "start": 1.25,
                        "end": 2.5,
                        "probability": 0.98,
                    }],
                }],
            }

        tqdm_module = types.ModuleType("tqdm")
        tqdm_module.tqdm = object()
        mlx_package = types.ModuleType("mlx_whisper")
        mlx_package.__path__ = []
        transcribe_module = types.ModuleType("mlx_whisper.transcribe")
        transcribe_module.transcribe = fake_transcribe

        with tempfile.TemporaryDirectory() as directory:
            output_dir = pathlib.Path(directory)
            argv = [
                str(SCRIPT),
                "/tmp/source.wav",
                "--model",
                "/tmp/model",
                "--language",
                "de",
                "--output-dir",
                str(output_dir),
                "--output-name",
                "german",
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(MODULE, "configure_tool_path"),
                mock.patch.object(MODULE, "verify_trusted_model", return_value=pathlib.Path("/tmp/model")),
                mock.patch.object(sys, "argv", argv),
                mock.patch.dict(sys.modules, {
                    "tqdm": tqdm_module,
                    "mlx_whisper": mlx_package,
                    "mlx_whisper.transcribe": transcribe_module,
                }),
                contextlib.redirect_stdout(stdout),
            ):
                MODULE.main()

            srt_path = output_dir / "german.srt"
            timeline_path = output_dir / "german.timeline.json"
            self.assertEqual(
                srt_path.read_text(encoding="utf-8"),
                "1\n00:00:01,250 --> 00:00:02,500\nHallo.\n\n",
            )
            self.assertTrue(timeline_path.is_file())
            self.assertEqual(
                json.loads(timeline_path.read_text(encoding="utf-8"))["language"],
                "de",
            )

        events = [
            json.loads(line.removeprefix(MODULE.EVENT_PREFIX))
            for line in stdout.getvalue().splitlines()
            if line.startswith(MODULE.EVENT_PREFIX)
        ]
        self.assertEqual(events[-1]["type"], "complete")
        self.assertEqual(events[-1]["timeline_file"], "german.timeline.json")
        self.assertEqual(captured["audio"], "/tmp/source.wav")
        self.assertFalse(captured["kwargs"]["condition_on_previous_text"])
        self.assertTrue(captured["kwargs"]["word_timestamps"])

    def test_ranked_language_probabilities_returns_top_two(self):
        detected, confidence, runner_up = MODULE.ranked_language_probabilities({
            "en": 0.04,
            "fr": 0.91,
            "de": 0.05,
        })
        self.assertEqual(detected, "fr")
        self.assertAlmostEqual(confidence, 0.91)
        self.assertAlmostEqual(runner_up, 0.05)

    def test_detect_language_only_emits_event_without_output_files(self):
        with tempfile.TemporaryDirectory() as directory:
            argv = [
                str(SCRIPT),
                "/tmp/source.wav",
                "--model",
                "/tmp/model",
                "--detect-language-only",
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(MODULE, "configure_tool_path"),
                mock.patch.object(MODULE, "verify_trusted_model", return_value=pathlib.Path("/tmp/model")),
                mock.patch.object(MODULE, "detect_language", return_value=("fr", 0.92, 0.03)),
                mock.patch.object(sys, "argv", argv),
                contextlib.redirect_stdout(stdout),
            ):
                MODULE.main()

            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

        events = [
            json.loads(line.removeprefix(MODULE.EVENT_PREFIX))
            for line in stdout.getvalue().splitlines()
            if line.startswith(MODULE.EVENT_PREFIX)
        ]
        self.assertEqual(events, [{
            "type": "language_detection",
            "language": "fr",
            "confidence": 0.92,
            "runner_up_confidence": 0.03,
        }])

    def test_detect_language_only_reports_model_error_without_output_files(self):
        with tempfile.TemporaryDirectory() as directory:
            argv = [
                str(SCRIPT),
                "/tmp/source.wav",
                "--model",
                "/tmp/broken-model",
                "--detect-language-only",
            ]
            stderr = io.StringIO()
            with (
                mock.patch.object(MODULE, "configure_tool_path"),
                mock.patch.object(MODULE, "verify_trusted_model", return_value=pathlib.Path("/tmp/broken-model")),
                mock.patch.object(
                    MODULE,
                    "detect_language",
                    side_effect=RuntimeError("model could not be loaded"),
                ),
                mock.patch.object(sys, "argv", argv),
                contextlib.redirect_stderr(stderr),
                self.assertRaises(SystemExit) as exit_context,
            ):
                MODULE.main()

            self.assertEqual(exit_context.exception.code, 1)
            self.assertIn("model could not be loaded", stderr.getvalue())
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
