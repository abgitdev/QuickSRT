#!/usr/bin/env python3
import argparse
import json
import math
import os
import pathlib
import re
import shutil
import sys
import tempfile
import time
import traceback
import unicodedata


EVENT_PREFIX = "QSR_EVENT\t"
COMPRESSION_RATIO_THRESHOLD = 2.4
LOGPROB_THRESHOLD = -1.0
NO_SPEECH_THRESHOLD = 0.6
QUALITY_WARNING_MINIMUM_REMOVED = 5
QUALITY_WARNING_REMOVED_RATIO = 0.05
TIMELINE_VERSION = 1
MAX_TIMELINE_BYTES = 64 * 1024 * 1024
MAX_DISCARDED_SEGMENTS = 100
MAX_DISCARDED_WORDS_PER_SEGMENT = 64
MAX_DISCARDED_TEXT_CHARACTERS = 2000
SEMANTIC_PAUSE_SECONDS = 0.8
SEMANTIC_MAX_SECONDS = 15.0
NO_SPACE_LANGUAGES = {"ja", "zh"}
SEMANTIC_SENTENCE_ENDINGS = (".", "!", "?", "。", "！", "？", "।", "॥")
SEMANTIC_TRAILING_CLOSERS = "\"'”’»)]}）］｝」』】"
NO_LEADING_SPACE_CHARACTERS = set(
    ".,!?;:%)]}。！？，、；：％）］｝」』】।॥"
)
APOSTROPHE_TRANSLATION = str.maketrans({
    "\u2018": "'",
    "\u2019": "'",
    "\u201b": "'",
    "\u02bc": "'",
    "\uff07": "'",
})
CJK_CODEPOINT_RANGES = (
    (0x1100, 0x11FF),
    (0x3040, 0x30FF),
    (0x3130, 0x318F),
    (0x31F0, 0x31FF),
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xA960, 0xA97F),
    (0xAC00, 0xD7AF),
    (0xD7B0, 0xD7FF),
    (0xF900, 0xFAFF),
    (0x20000, 0x2FA1F),
)


def parse_args():
    parser = argparse.ArgumentParser(description="QuickSRT MLX Whisper SRT runner")
    parser.add_argument("audio")
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", default="en")
    parser.add_argument("--output-dir")
    parser.add_argument("--output-name", default="quicksrt")
    parser.add_argument("--detect-language-only", action="store_true")
    args = parser.parse_args()
    if not args.detect_language_only and not args.output_dir:
        parser.error("--output-dir is required unless --detect-language-only is used")
    return args


def emit_event(event_type, **values):
    print(EVENT_PREFIX + json.dumps({"type": event_type, **values}), flush=True)


def configure_tool_path():
    project_root = pathlib.Path(__file__).resolve().parents[1]
    tools_dir = project_root / "Tools"
    current_path = os.environ.get("PATH", "")
    os.environ["PATH"] = f"{tools_dir}{os.pathsep}{current_path}" if current_path else str(tools_dir)

    if not shutil.which("ffmpeg"):
        raise RuntimeError("The bundled ffmpeg component is unavailable.")


def verify_trusted_model(model_path):
    # This executes before importing MLX or mlx_whisper. In particular, an NPZ
    # archive is never passed to mx.load until its exact hash and safe numeric
    # NPY headers have been checked against the bundled policy.
    from model_integrity import load_policy, validate_model

    model = pathlib.Path(model_path).expanduser().resolve(strict=True)
    project_root = pathlib.Path(__file__).resolve().parents[1]
    policy = load_policy(project_root / "Runtime/model-policy.json")
    validate_model(model, policy, require_manifest=True)

    cache_root = (
        model.parents[1] / "cache"
        if len(model.parents) >= 2 and model.parent.name == "managed"
        else pathlib.Path(tempfile.gettempdir()) / "QuickSRT" / "HuggingFace"
    )
    cache_root.mkdir(parents=True, exist_ok=True)
    os.environ["HF_HOME"] = str(cache_root / "home")
    os.environ["HF_HUB_CACHE"] = str(cache_root / "hub")
    os.environ["HF_XET_CACHE"] = str(cache_root / "xet")
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    return model


def ranked_language_probabilities(probabilities):
    ranked = sorted(
        ((str(code), float(probability)) for code, probability in probabilities.items()),
        key=lambda item: item[1],
        reverse=True,
    )
    if not ranked:
        raise RuntimeError("Whisper did not return language probabilities.")
    detected_code, confidence = ranked[0]
    runner_up_confidence = ranked[1][1] if len(ranked) > 1 else 0.0
    return detected_code, confidence, runner_up_confidence


def detect_language(audio, model_path):
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, load_audio, log_mel_spectrogram, pad_or_trim
    from mlx_whisper.transcribe import ModelHolder

    model = ModelHolder.get_model(model_path, mx.float16)
    waveform = load_audio(audio)
    mel = log_mel_spectrogram(waveform, n_mels=model.dims.n_mels)
    mel_segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
    _, probabilities = model.detect_language(mel_segment)
    return ranked_language_probabilities(probabilities)


def _normalized_token(value, *, use_casefold):
    normalized = unicodedata.normalize("NFC", str(value))
    normalized = normalized.casefold() if use_casefold else normalized.lower()
    normalized = unicodedata.normalize("NFC", normalized).translate(
        APOSTROPHE_TRANSLATION
    )
    comparable = "".join(
        character
        for character in normalized
        if unicodedata.category(character)[0] in {"L", "M", "N"}
        or character == "'"
    )
    if not any(
        unicodedata.category(character)[0] in {"L", "N"}
        for character in comparable
    ):
        return ""
    return comparable


def _comparison_token(value):
    return _normalized_token(value, use_casefold=True)


def _duplicate_token(value):
    return _normalized_token(value, use_casefold=False)


def _normalized_words(words):
    return [_comparison_token(word) for word in words]


def _text_key(text, token_normalizer):
    words = (match.group(0) for match in re.finditer(r"\S+", str(text)))
    return " ".join(filter(None, (token_normalizer(word) for word in words)))


def _comparison_key(text):
    return _text_key(text, _comparison_token)


def _duplicate_key(text):
    return _text_key(text, _duplicate_token)


def _is_cjk_character(character):
    codepoint = ord(character)
    return any(start <= codepoint <= end for start, end in CJK_CODEPOINT_RANGES)


def _is_grapheme_extension(character):
    codepoint = ord(character)
    return (
        unicodedata.category(character) in {"Mn", "Mc", "Me"}
        or 0xFE00 <= codepoint <= 0xFE0F
        or 0x1F3FB <= codepoint <= 0x1F3FF
        or 0xE0100 <= codepoint <= 0xE01EF
    )


def _grapheme_spans(text):
    if not text:
        return []

    spans = []
    start = 0
    for index in range(1, len(text)):
        character = text[index]
        previous = text[index - 1]
        if (
            _is_grapheme_extension(character)
            or character == "\u200d"
            or previous == "\u200d"
        ):
            continue
        spans.append((start, index))
        start = index
    spans.append((start, len(text)))
    return spans


def _timestamp_word_units(text, word_timestamps):
    if not isinstance(word_timestamps, list) or not word_timestamps:
        return None

    raw_words = []
    for item in word_timestamps:
        if not isinstance(item, dict) or not isinstance(item.get("word"), str):
            return None
        raw_words.append(item["word"])

    joined = "".join(raw_words)
    content_start = len(joined) - len(joined.lstrip())
    content_end = len(joined.rstrip())
    if joined[content_start:content_end] != text:
        return None

    units = []
    cursor = 0
    for raw_word in raw_words:
        raw_start = cursor
        raw_end = cursor + len(raw_word)
        cursor = raw_end

        visible_start = max(raw_start, content_start)
        visible_end = min(raw_end, content_end)
        if visible_end <= visible_start:
            continue

        start = visible_start - content_start
        end = visible_end - content_start
        fragment = text[start:end]
        content_match = re.search(r"\S(?:.*\S)?", fragment, flags=re.DOTALL)
        if content_match is None:
            continue
        start += content_match.start()
        end = start + len(content_match.group(0))
        units.append({
            "start": start,
            "end": end,
            "key": _comparison_token(text[start:end]),
        })

    return units if len(units) >= 4 else None


def _repetition_units(text, word_timestamps=None):
    timestamp_units = _timestamp_word_units(text, word_timestamps)
    if timestamp_units is not None:
        return timestamp_units

    whitespace_matches = list(re.finditer(r"\S+", text))
    use_graphemes = (
        len(whitespace_matches) < 4
        and any(_is_cjk_character(character) for character in text)
    )
    spans = (
        _grapheme_spans(text)
        if use_graphemes
        else [(match.start(), match.end()) for match in whitespace_matches]
    )
    return [
        {
            "start": start,
            "end": end,
            "key": _comparison_token(text[start:end]),
        }
        for start, end in spans
    ]


def _finite_metric(segment, name):
    try:
        value = float(segment.get(name))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def _largest_repetition(units, maximum_phrase_length=8, predicate=None):
    normalized = [unit["key"] for unit in units]
    best = None
    for start in range(len(units)):
        maximum = min(maximum_phrase_length, (len(units) - start) // 2)
        for phrase_length in range(1, maximum + 1):
            phrase = normalized[start:start + phrase_length]
            if not any(phrase):
                continue
            repetitions = 1
            while normalized[
                start + repetitions * phrase_length:start + (repetitions + 1) * phrase_length
            ] == phrase:
                repetitions += 1
            repeated_tokens = repetitions * phrase_length
            if repetitions < 2:
                continue
            candidate = {
                "start": start,
                "end": start + repeated_tokens,
                "phrase_length": phrase_length,
                "repetitions": repetitions,
                "repeated_tokens": repeated_tokens,
                "coverage": repeated_tokens / max(1, len(units)),
            }
            if predicate is not None and not predicate(candidate):
                continue
            if best is None or (
                candidate["repetitions"], candidate["repeated_tokens"]
            ) > (best["repetitions"], best["repeated_tokens"]):
                best = candidate
    return best


def _is_decoder_loop(repetition, *, low_logprob):
    if repetition is None:
        return False

    repeated_tokens = repetition["repeated_tokens"]
    repetitions = repetition["repetitions"]

    return (
        low_logprob
        and repetitions >= 4
        and repeated_tokens >= 8
    )


def collapse_repeated_phrases(
    text,
    *,
    compression_ratio=None,
    avg_logprob=None,
    word_timestamps=None,
):
    """Remove only decoder loops; preserve short, plausible spoken repetition."""
    display_text = text.strip()
    units = _repetition_units(display_text, word_timestamps)
    if len(units) < 4:
        return display_text, False

    low_logprob = avg_logprob is not None and avg_logprob < LOGPROB_THRESHOLD
    maximum_phrase_length = 16 if len(display_text.split()) < 4 else 8
    repetition = _largest_repetition(
        units,
        maximum_phrase_length,
        predicate=lambda candidate: _is_decoder_loop(
            candidate,
            low_logprob=low_logprob,
        ),
    )
    if repetition is None:
        return display_text, False

    repeated_start = units[repetition["start"]]["start"]
    repeated_end = units[repetition["end"] - 1]["end"]
    prefix = display_text[:repeated_start]
    suffix = display_text[repeated_end:]
    if prefix and suffix and prefix[-1].isspace() and suffix[0].isspace():
        suffix = suffix.lstrip()
    remaining = f"{prefix}{suffix}".strip()
    if not _comparison_key(remaining):
        return "", True
    return remaining, True


def _quality_rejection_reason(segment):
    compression_ratio = _finite_metric(segment, "compression_ratio")
    avg_logprob = _finite_metric(segment, "avg_logprob")
    no_speech_prob = _finite_metric(segment, "no_speech_prob")
    high_compression = (
        compression_ratio is not None
        and compression_ratio > COMPRESSION_RATIO_THRESHOLD
    )
    low_logprob = avg_logprob is not None and avg_logprob < LOGPROB_THRESHOLD
    likely_silence = (
        no_speech_prob is not None
        and no_speech_prob > NO_SPEECH_THRESHOLD
    )

    if likely_silence and low_logprob:
        return "no_speech"
    if high_compression and low_logprob:
        return "low_confidence_repetition"
    return None


def _empty_report(total):
    return {
        "input_segments": total,
        "output_segments": 0,
        "removed": 0,
        "removed_by_reason": {},
        "overlaps_adjusted": 0,
        "decoder_loops_trimmed": 0,
        "quality_warning": False,
    }


def _record_removal(report, reason):
    report["removed"] += 1
    report["removed_by_reason"][reason] = (
        report["removed_by_reason"].get(reason, 0) + 1
    )


def validate_clean_segments(segments):
    previous_end = 0.0
    for index, segment in enumerate(segments, start=1):
        start = float(segment["start"])
        end = float(segment["end"])
        text = str(segment["text"]).strip()
        if not math.isfinite(start) or not math.isfinite(end):
            raise ValueError(f"Segment {index} has non-finite timestamps.")
        if start < 0 or end <= start:
            raise ValueError(f"Segment {index} has zero or negative duration.")
        if start < previous_end:
            raise ValueError(f"Segment {index} overlaps the preceding segment.")
        if not text:
            raise ValueError(f"Segment {index} has no subtitle text.")
        previous_end = end


def _sanitize_segments_with_trace(segments):
    cleaned = []
    trace = []
    previous_text = None
    previous_end = 0.0
    report = _empty_report(len(segments))

    for source_index, segment in enumerate(segments):
        trace_entry = {"source_index": source_index}
        if not isinstance(segment, dict):
            _record_removal(report, "invalid_segment")
            trace_entry.update(status="removed", reason="invalid_segment")
            trace.append(trace_entry)
            continue

        try:
            start = max(0.0, float(segment.get("start", 0.0)))
            end = max(0.0, float(segment.get("end", 0.0)))
        except (TypeError, ValueError):
            _record_removal(report, "invalid_timestamp")
            trace_entry.update(status="removed", reason="invalid_timestamp")
            trace.append(trace_entry)
            continue
        if not math.isfinite(start) or not math.isfinite(end) or end <= start:
            _record_removal(report, "invalid_timestamp")
            trace_entry.update(status="removed", reason="invalid_timestamp")
            trace.append(trace_entry)
            continue

        rejection = _quality_rejection_reason(segment)
        if rejection is not None:
            _record_removal(report, rejection)
            trace_entry.update(status="removed", reason=rejection)
            trace.append(trace_entry)
            continue

        text, loop_trimmed = collapse_repeated_phrases(
            str(segment.get("text", "")),
            compression_ratio=_finite_metric(segment, "compression_ratio"),
            avg_logprob=_finite_metric(segment, "avg_logprob"),
            word_timestamps=segment.get("words"),
        )
        if loop_trimmed:
            report["decoder_loops_trimmed"] += 1

        normalized = _duplicate_key(text)
        if not normalized:
            _record_removal(report, "empty_or_decoder_loop")
            trace_entry.update(status="removed", reason="empty_or_decoder_loop")
            trace.append(trace_entry)
            continue
        if normalized == previous_text and start < previous_end:
            _record_removal(report, "duplicate")
            trace_entry.update(status="removed", reason="duplicate")
            trace.append(trace_entry)
            continue

        original_start = start
        if start < previous_end:
            start = previous_end
            report["overlaps_adjusted"] += 1
        if end <= start:
            _record_removal(report, "fully_overlapped")
            trace_entry.update(status="removed", reason="fully_overlapped")
            trace.append(trace_entry)
            continue

        output_index = len(cleaned)
        cleaned.append({"start": start, "end": end, "text": text})
        trace_entry.update(
            status="kept",
            output_index=output_index,
            start_adjusted=start != original_start,
            decoder_loop_trimmed=loop_trimmed,
        )
        trace.append(trace_entry)
        previous_text = normalized
        previous_end = end

    validate_clean_segments(cleaned)
    report["output_segments"] = len(cleaned)
    warning_threshold = max(
        QUALITY_WARNING_MINIMUM_REMOVED,
        math.ceil(report["input_segments"] * QUALITY_WARNING_REMOVED_RATIO),
    )
    report["quality_warning"] = report["removed"] >= warning_threshold
    return cleaned, report, trace


def sanitize_segments(segments):
    cleaned, report, _ = _sanitize_segments_with_trace(segments)
    return cleaned, report


def _safe_optional_number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    if isinstance(value, int):
        return value
    return number


def _safe_optional_float(value):
    number = _safe_optional_number(value)
    return float(number) if number is not None else None


def _source_segment_metrics(segment):
    return {
        "seek": _safe_optional_number(segment.get("seek")),
        "temperature": _safe_optional_float(segment.get("temperature")),
        "avg_logprob": _safe_optional_float(segment.get("avg_logprob")),
        "compression_ratio": _safe_optional_float(segment.get("compression_ratio")),
        "no_speech_prob": _safe_optional_float(segment.get("no_speech_prob")),
    }


def _safe_source_words(segment):
    source_words = segment.get("words")
    if not isinstance(source_words, list):
        return []

    words = []
    for source_word_index, source_word in enumerate(source_words):
        if not isinstance(source_word, dict):
            continue
        text = source_word.get("word")
        words.append({
            "source_word_index": source_word_index,
            "text": text if isinstance(text, str) else str(text or ""),
            "start": _safe_optional_float(source_word.get("start")),
            "end": _safe_optional_float(source_word.get("end")),
            "probability": _safe_optional_float(source_word.get("probability")),
        })
    return words


def _usable_source_words(source_segment, cleaned_segment):
    words = _safe_source_words(source_segment)
    cleaned_text = str(cleaned_segment["text"])
    segment_start = float(cleaned_segment["start"])
    segment_end = float(cleaned_segment["end"])
    if not words or "".join(word["text"] for word in words).strip() != cleaned_text:
        return None
    previous_end = segment_start
    for word in words:
        start = word["start"]
        end = word["end"]
        if (
            start is None
            or end is None
            or start < previous_end
            or end <= start
            or start < segment_start
            or end > segment_end
            or not word["text"]
        ):
            return None
        previous_end = end
    return words


def _render_word_text(words, language):
    no_space_language = language in NO_SPACE_LANGUAGES
    rendered = ""
    for word in words:
        token = str(word.get("text", ""))
        if not token:
            continue
        if not rendered:
            rendered = token.lstrip()
            continue
        stripped = token.lstrip()
        if not stripped:
            rendered += token
        elif token[0].isspace() or no_space_language:
            rendered += token
        elif stripped[0] in NO_LEADING_SPACE_CHARACTERS:
            rendered += stripped
        else:
            rendered += " " + token
    return rendered.strip()


def _ends_semantic_sentence(text):
    candidate = str(text).strip().rstrip(SEMANTIC_TRAILING_CLOSERS)
    return candidate.endswith(SEMANTIC_SENTENCE_ENDINGS)


def reconstruct_semantic_units(words, language):
    if not words:
        return []

    units = []
    unit_start = 0
    for index, word in enumerate(words):
        is_last = index == len(words) - 1
        boundary = is_last or _ends_semantic_sentence(word.get("text", ""))
        if not boundary:
            next_word = words[index + 1]
            gap = max(0.0, next_word["start"] - word["end"])
            duration = word["end"] - words[unit_start]["start"]
            boundary = (
                gap >= SEMANTIC_PAUSE_SECONDS
                or duration >= SEMANTIC_MAX_SECONDS
            )
        if not boundary:
            continue

        word_end = index + 1
        unit_words = words[unit_start:word_end]
        units.append({
            "id": len(units),
            "start": unit_words[0]["start"],
            "end": unit_words[-1]["end"],
            "text": _render_word_text(unit_words, language),
            "word_start": unit_start,
            "word_end": word_end,
        })
        unit_start = word_end
    return units


def build_timeline(result, cleaned_segments, report, trace, *, language):
    raw_segments = result.get("segments", []) if isinstance(result, dict) else []
    if not isinstance(raw_segments, list):
        raw_segments = []
    trace_by_output = {
        entry["output_index"]: entry
        for entry in trace
        if entry.get("status") == "kept" and "output_index" in entry
    }

    words = []
    segments = []
    retained_low_confidence_segments = 0
    synthetic_word_timing_segments = 0
    for output_index, cleaned_segment in enumerate(cleaned_segments):
        trace_entry = trace_by_output.get(output_index, {})
        source_index = trace_entry.get("source_index", output_index)
        source_segment = (
            raw_segments[source_index]
            if isinstance(source_index, int)
            and 0 <= source_index < len(raw_segments)
            and isinstance(raw_segments[source_index], dict)
            else {}
        )
        avg_logprob = _finite_metric(source_segment, "avg_logprob")
        if avg_logprob is not None and avg_logprob < LOGPROB_THRESHOLD:
            retained_low_confidence_segments += 1
        cleaned_text = str(cleaned_segment["text"])
        source_words = _usable_source_words(source_segment, cleaned_segment)
        if source_words is None:
            synthetic_word_timing_segments += 1
            source_words = [{
                "source_word_index": None,
                "text": cleaned_text,
                "start": float(cleaned_segment["start"]),
                "end": float(cleaned_segment["end"]),
                "probability": None,
                "synthetic": True,
            }]

        word_start = len(words)
        for source_word in source_words:
            timeline_word = {
                "id": len(words),
                "start": source_word["start"],
                "end": source_word["end"],
                "text": source_word["text"],
                "probability": source_word.get("probability"),
                "segment_id": output_index,
                "source_word_index": source_word.get("source_word_index"),
            }
            if source_word.get("synthetic"):
                timeline_word["synthetic"] = True
            words.append(timeline_word)
        word_end = len(words)

        timeline_segment = {
            "id": output_index,
            "source_index": source_index,
            "start": float(cleaned_segment["start"]),
            "end": float(cleaned_segment["end"]),
            "text": cleaned_text,
            "word_start": word_start,
            "word_end": word_end,
            "start_adjusted": bool(trace_entry.get("start_adjusted", False)),
            "decoder_loop_trimmed": bool(
                trace_entry.get("decoder_loop_trimmed", False)
            ),
            **_source_segment_metrics(source_segment),
        }
        segments.append(timeline_segment)

    report["retained_low_confidence_segments"] = retained_low_confidence_segments
    report["synthetic_word_timing_segments"] = synthetic_word_timing_segments
    if retained_low_confidence_segments or synthetic_word_timing_segments:
        report["quality_warning"] = True

    discarded_segments = []
    for trace_entry in trace:
        if trace_entry.get("status") != "removed":
            continue
        if len(discarded_segments) >= MAX_DISCARDED_SEGMENTS:
            break
        source_index = trace_entry["source_index"]
        source_segment = (
            raw_segments[source_index]
            if 0 <= source_index < len(raw_segments)
            and isinstance(raw_segments[source_index], dict)
            else {}
        )
        discarded_segments.append({
            "source_index": source_index,
            "reason": trace_entry.get("reason", "unknown"),
            "start": _safe_optional_float(source_segment.get("start")),
            "end": _safe_optional_float(source_segment.get("end")),
            "text": str(source_segment.get("text", ""))[
                :MAX_DISCARDED_TEXT_CHARACTERS
            ],
            "words": _safe_source_words(source_segment)[
                :MAX_DISCARDED_WORDS_PER_SEGMENT
            ],
            **_source_segment_metrics(source_segment),
        })

    resolved_language = str(
        result.get("language") or language or ""
    ) if isinstance(result, dict) else str(language or "")
    return {
        "version": TIMELINE_VERSION,
        "language": resolved_language,
        "words": words,
        "segments": segments,
        "semantic_units": reconstruct_semantic_units(words, resolved_language),
        "discarded_segments": discarded_segments,
        "discarded_segments_omitted": max(
            0,
            int(report.get("removed", 0)) - len(discarded_segments),
        ),
        "quality_report": dict(report),
    }


class _LimitedUTF8Writer:
    def __init__(self, output, maximum_bytes):
        self.output = output
        self.maximum_bytes = maximum_bytes
        self.bytes_written = 0

    def write(self, text):
        encoded_size = len(text.encode("utf-8"))
        if self.bytes_written + encoded_size > self.maximum_bytes:
            raise ValueError(
                f"Timeline JSON exceeds the {self.maximum_bytes}-byte safety limit."
            )
        written = self.output.write(text)
        self.bytes_written += encoded_size
        return written


def write_timeline(path, timeline):
    path = pathlib.Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            limited_output = _LimitedUTF8Writer(output, MAX_TIMELINE_BYTES)
            json.dump(
                timeline,
                limited_output,
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
            )
            limited_output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def format_srt_timestamp(seconds):
    milliseconds = max(0, round(seconds * 1000))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1_000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{milliseconds:03d}"


def write_srt(path, segments):
    validate_clean_segments(segments)
    with path.open("w", encoding="utf-8", newline="\n") as output:
        for index, segment in enumerate(segments, start=1):
            output.write(f"{index}\n")
            output.write(
                f"{format_srt_timestamp(segment['start'])} --> "
                f"{format_srt_timestamp(segment['end'])}\n"
            )
            output.write(f"{segment['text']}\n\n")


class ProgressReporter:
    def __init__(self, *args, total=None, **kwargs):
        self.total = max(1, int(total or 1))
        self.current = 0
        self.started = time.monotonic()
        self.last_emitted = -1.0

    def __enter__(self):
        emit_event("progress", fraction=0.0, elapsed=0.0, eta=None)
        return self

    def __exit__(self, exc_type, exc_value, exc_traceback):
        if exc_type is None:
            self._emit(force=True)
        return False

    def update(self, amount=1):
        self.current = min(self.total, self.current + amount)
        self._emit()

    def _emit(self, force=False):
        elapsed = max(0.0, time.monotonic() - self.started)
        fraction = min(1.0, self.current / self.total)
        if not force and fraction < 1.0 and fraction - self.last_emitted < 0.002:
            return
        eta = elapsed * (1.0 - fraction) / fraction if fraction > 0 else None
        emit_event("progress", fraction=fraction, elapsed=elapsed, eta=eta)
        self.last_emitted = fraction


def main():
    args = parse_args()

    try:
        configure_tool_path()
        args.model = str(verify_trusted_model(args.model))
        if args.detect_language_only:
            detected_code, confidence, runner_up_confidence = detect_language(
                args.audio,
                args.model,
            )
            emit_event(
                "language_detection",
                language=detected_code,
                confidence=confidence,
                runner_up_confidence=runner_up_confidence,
            )
            return

        output_dir = pathlib.Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path = output_dir / f"{args.output_name}.srt"
        timeline_path = output_dir / f"{args.output_name}.timeline.json"
        import tqdm
        from mlx_whisper.transcribe import transcribe

        tqdm.tqdm = ProgressReporter
        emit_event("message", text="MLX Whisper large-v3 started")
        result = transcribe(
            args.audio,
            path_or_hf_repo=args.model,
            language=args.language,
            task="transcribe",
            verbose=False,
            condition_on_previous_text=False,
            word_timestamps=True,
            hallucination_silence_threshold=2.0,
            compression_ratio_threshold=COMPRESSION_RATIO_THRESHOLD,
            logprob_threshold=LOGPROB_THRESHOLD,
            no_speech_threshold=NO_SPEECH_THRESHOLD,
        )
        segments, report, trace = _sanitize_segments_with_trace(
            result.get("segments", [])
        )
        if not segments:
            raise RuntimeError("No valid speech segments were detected in the selected video.")
        write_srt(output_path, segments)
        timeline = build_timeline(
            result,
            segments,
            report,
            trace,
            language=args.language,
        )
        segment_count = len(segments)
        del result, segments, trace
        write_timeline(timeline_path, timeline)
        del timeline

        if not output_path.exists() or not timeline_path.exists():
            raise RuntimeError("SRT output was not written.")

        emit_event(
            "complete",
            segments=segment_count,
            timeline_file=timeline_path.name,
            **report,
        )
    except BaseException:
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
