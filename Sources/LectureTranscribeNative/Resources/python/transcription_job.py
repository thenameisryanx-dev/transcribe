from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed, wait
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, TypeVar

from openai import OpenAI

from lecture_transcribe import (
    CHUNKS_ROOT_DIR,
    DEFAULT_CHUNK_SECONDS,
    DEFAULT_LANGUAGES,
    DIARIZE_CHUNK_SECONDS,
    DIARIZE_MAX_SECONDS,
    DIARIZE_SINGLE_BUFFER,
    EMBED_SUBTITLE_CODECS,
    KEYWORD_MODELS,
    MAX_COPY_CHANNELS,
    MODEL_DIARIZE,
    MODEL_GPT_TRANSCRIBE,
    MODEL_MINI,
    MODEL_NORMAL,
    RESULTS_MAX_AGE_SECONDS,
    RESULTS_ROOT_DIR,
    SubtitleCue,
    _segment_fields,
    audio_channel_count,
    build_transcript_header,
    cleanup_dir,
    convert_qta_to_m4a_copy,
    diarize_chunk,
    diarize_whole_file,
    embed_subtitles_copy,
    extract_diarization_segments,
    extract_transcription_text,
    format_diarized_lines,
    format_srt,
    get_duration_seconds,
    hhmmss,
    list_audio_tracks,
    max_parallel_requests,
    require_ffmpeg,
    require_ffprobe,
    safe_stem_from_path,
    sentence_lines,
    single_language_hint,
    split_audio_to_chunks,
    subtitle_cues,
    transcribe_chunk_checked,
    transcript_tail,
)

T = TypeVar("T")

# Overall progress (percent) given to preparing the audio; transcribing the chunks fills the rest.
# Preparing a 21-minute episode took about 7s, roughly this share of a whole run.
PREPARE_PROGRESS = 15.0

# Bump when what a saved chunk result holds changes, so results saved by an older version aren't reused.
RESULTS_FORMAT = 1


class ChunkResults:
    """
    Saves each finished chunk of a run, so a run that fails or is cancelled can pick up where it stopped:
    running it again with the same settings reuses the saved chunks instead of paying OpenAI for them twice.
    A result is filed under a hash of the chunk's audio and everything sent with it, so only an identical
    request reuses it. Splitting the same file the same way gives byte-identical chunks, so a re-run finds
    them; a different file, track, chunk length or ffmpeg build gives different audio and misses.
    """

    def __init__(self, root: Path = RESULTS_ROOT_DIR) -> None:
        self.root = root
        self.total = 0
        self.reused = 0
        self._kept: set[Path] = set()
        self._lock = threading.Lock()

    @property
    def kept(self) -> int:
        """Chunks of this run with a saved result, reused or new."""
        with self._lock:
            return len(self._kept)

    def key(self, chunk_path: Path, request: dict[str, Any]) -> str:
        audio = hashlib.sha256()
        with chunk_path.open("rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                audio.update(block)
        described = json.dumps({"format": RESULTS_FORMAT, "audio": audio.hexdigest(), **request}, sort_keys=True)
        return hashlib.sha256(described.encode("utf-8")).hexdigest()

    def _path(self, key: str) -> Path:
        return self.root / f"{key}.json"

    def load(self, key: str) -> dict[str, Any] | None:
        try:
            data = json.loads(self._path(key).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def mark_reused(self, key: str) -> None:
        with self._lock:
            self._kept.add(self._path(key))
            self.reused += 1

    def save(self, key: str, data: dict[str, Any]) -> None:
        path = self._path(key)
        temp = path.with_name(f"{path.stem}.{threading.get_ident()}.tmp")
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            temp.write_text(json.dumps(data), encoding="utf-8")
            os.replace(temp, path)
        except OSError:
            # Results are only kept for resuming, so failing to save one (a full disk) doesn't fail the run.
            temp.unlink(missing_ok=True)
            return
        with self._lock:
            self._kept.add(path)

    def discard(self) -> None:
        """Deletes this run's results once its output is written; they're not needed again."""
        with self._lock:
            kept, self._kept = self._kept, set()
        for path in kept:
            path.unlink(missing_ok=True)

    def run(
        self,
        chunk_path: Path,
        request: dict[str, Any],
        work: Callable[[], T],
        *,
        encode: Callable[[T], dict[str, Any] | None],
        decode: Callable[[dict[str, Any]], T | None],
        log: Callable[[str], None],
    ) -> T:
        """
        The saved result for this chunk and request, or `work()` saved for next time. `encode` gives what to
        save (None saves nothing) and `decode` turns a saved result back into one (None if it can't be used).
        """
        key = self.key(chunk_path, request)
        saved = self.load(key)
        if saved is not None:
            result = decode(saved)
            if result is not None:
                self.mark_reused(key)
                log(f"Using the saved result of {chunk_path.name} from an earlier attempt.")
                return result
        result = work()
        data = encode(result)
        if data is not None:
            self.save(key, data)
        return result


def prune_chunk_results(root: Path = RESULTS_ROOT_DIR, max_age_seconds: float = RESULTS_MAX_AGE_SECONDS) -> None:
    """Removes saved chunk results that are too old to be from a run anyone will resume."""
    try:
        entries = list(root.iterdir())
    except OSError:
        return
    cutoff = time.time() - max_age_seconds
    for path in entries:
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass


@contextmanager
def _reporting_saved_chunks(results: ChunkResults, push_event):
    """Logs how many chunks were reused, or on failure or cancel, how many are saved for the next attempt."""
    try:
        yield
    except BaseException:
        if results.kept:
            push_event(
                "log",
                f"{results.kept} of {results.total} chunk(s) finished and were saved. "
                "Run this again with the same settings to send only the rest.",
            )
        raise
    if results.reused:
        push_event("log", f"Reused {results.reused} of {results.total} chunk(s) saved from an earlier attempt.")


def _encode_transcript(result: tuple[str, str | None]) -> dict[str, Any] | None:
    text, warning = result
    # A chunk that failed its checks is sent again next time instead of reusing its doubtful text.
    return {"text": text} if warning is None else None


def _decode_transcript(data: dict[str, Any]) -> tuple[str, str | None] | None:
    text = data.get("text")
    return (text, None) if isinstance(text, str) else None


def _encode_diarized(resp: Any) -> dict[str, Any]:
    """The parts of a diarize response the transcript and subtitles use, in a form that reads back the same."""
    segments = []
    for seg in extract_diarization_segments(resp):
        speaker, start, end, text = _segment_fields(seg)
        segments.append({"speaker": speaker, "start": start, "end": end, "text": text})
    return {"text": extract_transcription_text(resp), "segments": segments}


def _decode_diarized(data: dict[str, Any]) -> dict[str, Any] | None:
    return data if isinstance(data.get("segments"), list) and isinstance(data.get("text"), str) else None


def _transcribe_saved(results: ChunkResults, part: Path, request: dict[str, Any], work, log):
    return results.run(part, request, work, encode=_encode_transcript, decode=_decode_transcript, log=log)


def _diarize_saved(results: ChunkResults, client: OpenAI, part: Path, languages: list[str] | None, log):
    return results.run(
        part,
        {"kind": "diarize", "model": MODEL_DIARIZE, "languages": languages},
        lambda: diarize_chunk(client, part, languages=languages, on_log=log),
        encode=_encode_diarized,
        decode=_decode_diarized,
        log=log,
    )


def _prepare_progress(push_event) -> Callable[[float], None]:
    """Progress callback for split_audio_to_chunks that fills the preparing share of the bar."""
    return lambda fraction: push_event("progress", PREPARE_PROGRESS * fraction)


def _chunks_done_progress(done: int, total: int) -> float:
    return PREPARE_PROGRESS + (100.0 - PREPARE_PROGRESS) * done / total


def _chunk_spans(parts: list[Path], fallback_seconds: int) -> list[tuple[float, float]]:
    """(start, end) of each chunk within the original audio, from the chunks' measured lengths."""
    spans: list[tuple[float, float]] = []
    start = 0.0
    for p in parts:
        duration = get_duration_seconds(p)
        end = start + (duration if duration > 0 else fallback_seconds)
        spans.append((start, end))
        start = end
    return spans


def _run_chunks_in_parallel(
    parts: list[Path],
    work: Callable[[Path], T],
    push_event,
    label: str,
) -> list[T]:
    """
    Run `work` over every chunk with a bounded thread pool and return results in chunk order.
    Progress events are emitted from this (the calling) thread as chunks finish.
    """
    total = len(parts)
    workers = max(1, min(max_parallel_requests(), total))
    push_event("log", f"{label} {total} chunk(s), up to {workers} at a time.")
    push_event("status", f"{label}: 0/{total} chunks done")

    results: list[Any] = [None] * total
    stopping = threading.Event()

    def start(part: Path):
        # Once a chunk fails, workers still free don't send any more chunks.
        if stopping.is_set():
            return None
        try:
            return work(part)
        except Exception:
            stopping.set()
            raise

    executor = ThreadPoolExecutor(max_workers=workers)
    futures = {executor.submit(start, part): i for i, part in enumerate(parts)}
    try:
        done = 0
        for future in as_completed(futures):
            i = futures[future]
            results[i] = future.result()
            done += 1
            push_event("log", f"Finished chunk {i + 1}/{total}: {parts[i].name}")
            push_event("status", f"{label}: {done}/{total} chunks done")
            push_event("progress", _chunks_done_progress(done, total))
    except Exception:
        # Chunks already sent are paid for either way, so let them finish and save their results (see
        # ChunkResults) before reporting the failure; the backend exits as soon as it's reported. Chunks
        # not sent yet are dropped. A cancel (KeyboardInterrupt) skips this and stops at once.
        for future in futures:
            future.cancel()
        sent = [future for future in futures if not future.done()]
        if sent:
            push_event("log", f"A chunk failed. Waiting for the {len(sent)} chunk(s) already sent so they can be saved...")
            push_event("status", "Stopping after a failed chunk...")
            wait(sent)
        raise
    finally:
        executor.shutdown(wait=False, cancel_futures=True)
    return results


def _run_chunks_in_order(
    parts: list[Path],
    work: Callable[[Path, T | None], T],
    push_event,
    label: str,
) -> list[T]:
    """
    Run `work(part, previous_result)` one chunk at a time, so each chunk can use the result of the
    chunk before it. Slower than `_run_chunks_in_parallel`, but needed to carry context forward.
    """
    total = len(parts)
    push_event("log", f"{label} {total} chunk(s) one at a time, carrying context between chunks.")
    push_event("status", f"{label}: 0/{total} chunks done")

    results: list[T] = []
    previous: T | None = None
    for i, part in enumerate(parts):
        previous = work(part, previous)
        results.append(previous)
        push_event("log", f"Finished chunk {i + 1}/{total}: {part.name}")
        push_event("status", f"{label}: {i + 1}/{total} chunks done")
        push_event("progress", _chunks_done_progress(i + 1, total))
    return results


def run_transcription_job(
    input_path: Path,
    diarize: bool,
    output_dir: Path,
    transcription_model: str,
    push_event,
    languages: list[str] | None = None,
    context: str | None = None,
    carry_context: bool = False,
    chunk_seconds: int | None = None,
    keywords: list[str] | None = None,
    subtitles: bool = False,
    audio_track: int = 0,
    embed_subtitles: bool = False,
) -> Path:
    require_ffmpeg()
    require_ffprobe()
    prune_chunk_results()

    # Videos can carry one audio track per language; only the chosen one (0 = the first) is transcribed.
    tracks = list_audio_tracks(input_path)
    if tracks and not 0 <= audio_track < len(tracks):
        raise SystemExit(
            f"Audio track {audio_track + 1} doesn't exist; this file has {len(tracks)} audio track(s)."
        )
    if len(tracks) > 1:
        track = tracks[audio_track]
        details = ", ".join(str(v) for v in (track["language"], track["title"]) if v) or "no language tag"
        push_event("log", f"Audio track: {audio_track + 1} of {len(tracks)} ({details}).")

    if subtitles and diarize:
        push_event("log", "Subtitles don't include speaker labels, so diarization is off for this run.")
        diarize = False
    if embed_subtitles and not subtitles:
        push_event("log", "A subtitled copy of the video is only made with subtitles, so none will be saved.")
        embed_subtitles = False

    if transcription_model not in {MODEL_GPT_TRANSCRIBE, MODEL_NORMAL, MODEL_MINI}:
        push_event("log", f"Unknown model '{transcription_model}'. Falling back to {MODEL_NORMAL}.")
        transcription_model = MODEL_NORMAL

    if diarize and transcription_model == MODEL_MINI:
        raise SystemExit(
            "Speaker diarization is not supported with gpt-4o-mini-transcribe. "
            "Select gpt-transcribe or gpt-4o-transcribe, or disable diarization."
        )

    if subtitles:
        push_event("log", f"Making subtitles with {MODEL_DIARIZE}, the model that returns timing for each line.")
    else:
        push_event("log", f"Using transcription model: {transcription_model}")
    # gpt-transcribe takes the whole list; the GPT-4o and diarize models take at most one `language`.
    if transcription_model == MODEL_GPT_TRANSCRIBE and not diarize and not subtitles:
        chunk_languages = languages or list(DEFAULT_LANGUAGES)
        push_event("log", f"Spoken languages: {', '.join(chunk_languages)}")
    else:
        chunk_languages = languages or None
        push_event("log", f"Spoken language: {single_language_hint(chunk_languages) or 'auto-detect'}")

    context = (context or "").strip() or None
    if diarize or subtitles:
        # Both run on the diarize model, which takes no prompt or keywords and has its own chunk size.
        mode = "subtitles" if subtitles else "speaker labels"
        if chunk_seconds is not None:
            push_event("log", f"Chunk length setting isn't used with {mode}; their own chunk size applies.")
        if context or carry_context:
            push_event("log", f"Context prompt isn't supported with {mode}, so it won't be sent.")
        if keywords:
            push_event("log", f"Keywords aren't supported with {mode}, so they won't be sent.")
        context, carry_context, keywords = None, False, None
    else:
        if carry_context and transcription_model != MODEL_GPT_TRANSCRIBE:
            # The GPT-4o models tend to loop or invent text at chunk ends when given the excerpt.
            push_event("log", f"Consistency mode is only used with {MODEL_GPT_TRANSCRIBE}, so it is off for this run.")
            carry_context = False
        push_event("log", f"Context prompt: {f'{len(context)} characters' if context else 'none'}")
        if keywords and transcription_model not in KEYWORD_MODELS:
            push_event("log", f"Keywords are only used with {MODEL_GPT_TRANSCRIBE}, so they won't be sent.")
            keywords = None
        push_event("log", f"Keywords: {', '.join(keywords) if keywords else 'none'}")
        push_event("log", f"Consistency mode (carry context between chunks): {'on' if carry_context else 'off'}")

    def log(message: str) -> None:
        push_event("log", message)

    run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    stem = safe_stem_from_path(input_path)
    output_dir.mkdir(parents=True, exist_ok=True)

    out_suffix = "_diarize" if diarize else ""
    out_path = output_dir / f"{stem}_{run_id}{out_suffix}.txt"
    if subtitles:
        # Video players load subtitles named after the video when they sit next to it, so use its exact name
        # when that file doesn't exist yet. Players that match loosely also find the run-stamped name.
        out_path = output_dir / f"{input_path.stem}.srt"
        if out_path.exists():
            out_path = output_dir / f"{input_path.stem}.{run_id}.srt"

    client = OpenAI()
    results = ChunkResults()
    working_input_path = input_path
    converted_temp_path: Path | None = None

    try:
        if input_path.suffix.lower() == ".qta":
            push_event("log", "Detected .qta input. Converting to .m4a...")
            push_event("status", "Converting .qta input...")
            converted_temp_path = convert_qta_to_m4a_copy(input_path, run_id, audio_track)
            working_input_path = converted_temp_path
            # The converted file holds only the chosen track.
            audio_track = 0
            push_event("log", f"Converted .qta to: {working_input_path.name}")

        # Surround sources keep dialogue in the center channel; split_audio_to_chunks mixes them to mono.
        channels = audio_channel_count(working_input_path, audio_track)
        is_surround = channels is not None and channels > MAX_COPY_CHANNELS
        if is_surround:
            push_event("log", f"Source audio has {channels} channels. Mixing down to mono for transcription.")

        # Transcripts are written only after every chunk succeeds, so a failed or
        # cancelled run never leaves a partial file in the output folder.
        if subtitles:
            _write_subtitles(
                client,
                working_input_path,
                out_path,
                chunks_dir=CHUNKS_ROOT_DIR / f"{stem}_{run_id}_subtitles",
                languages=chunk_languages,
                audio_track=audio_track,
                push_event=push_event,
                results=results,
            )
            results.discard()
            if embed_subtitles:
                _save_subtitled_copy(
                    input_path,
                    out_path,
                    output_dir,
                    run_id=run_id,
                    language=single_language_hint(chunk_languages),
                    audio_track=audio_track,
                    push_event=push_event,
                )
            return out_path

        if diarize:
            dur = get_duration_seconds(working_input_path)
            if 0 < dur <= DIARIZE_SINGLE_BUFFER:
                push_event("status", "Preparing audio...")
                single_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}_single"
                try:
                    # The original file can be too big (WAV, video) or in a format the API rejects, so it
                    # goes through the same copy-or-convert step as chunks. The audio is shorter than
                    # DIARIZE_MAX_SECONDS, so this yields exactly one piece.
                    parts = split_audio_to_chunks(
                        working_input_path,
                        single_dir,
                        DIARIZE_MAX_SECONDS,
                        on_progress=_prepare_progress(push_event),
                        audio_track=audio_track,
                    )
                    if len(parts) != 1:
                        raise SystemExit(f"Expected one audio piece for a single diarize request, got {len(parts)}.")
                    push_event("status", "Diarizing (single request)...")
                    content = diarize_whole_file(client, parts[0], languages=chunk_languages, on_log=log)
                finally:
                    cleanup_dir(single_dir)
                header = build_transcript_header(
                    input_path=input_path,
                    working_input_path=working_input_path,
                    model=MODEL_DIARIZE,
                    response_format="diarized_json",
                    chunking_strategy="auto",
                    duration_seconds=dur,
                )
                out_path.write_text(header + content, encoding="utf-8")
                push_event("progress", 100.0)
                return out_path

            push_event("log", "Long audio detected. Using local chunks for diarization...")
            run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}_diarize"
            push_event("status", "Preparing audio chunks...")
            # Splitting sits inside the try so a cancel or ffmpeg failure mid-split
            # still removes any partial chunks.
            try:
                parts = split_audio_to_chunks(
                    working_input_path,
                    run_chunks_dir,
                    DIARIZE_CHUNK_SECONDS,
                    on_progress=_prepare_progress(push_event),
                    audio_track=audio_track,
                )
                push_event("log", f"Prepared {len(parts)} chunk(s) for diarization.")
                results.total = len(parts)

                # Offsets depend on earlier chunks' real lengths, so measure them before fanning out.
                offsets = [start for start, _ in _chunk_spans(parts, DIARIZE_CHUNK_SECONDS)]

                with _reporting_saved_chunks(results, push_event):
                    responses = _run_chunks_in_parallel(
                        parts,
                        lambda p: _diarize_saved(results, client, p, chunk_languages, log),
                        push_event,
                        "Diarizing",
                    )
            finally:
                cleanup_dir(run_chunks_dir)

            out_lines: list[str] = []
            for p, resp, chunk_offset in zip(parts, responses, offsets):
                segments = extract_diarization_segments(resp)
                if not segments:
                    out_lines.append(f"\n===== {p.name} =====\n")
                    out_lines.extend(sentence_lines(extract_transcription_text(resp)))
                else:
                    out_lines.extend(format_diarized_lines(segments, chunk_offset))

            header = build_transcript_header(
                input_path=input_path,
                working_input_path=working_input_path,
                model=MODEL_DIARIZE,
                response_format="diarized_json",
                chunking_strategy="auto",
                local_chunk_seconds=DIARIZE_CHUNK_SECONDS,
                duration_seconds=dur,
            )
            out_path.write_text(header + "\n".join(out_lines), encoding="utf-8")
            results.discard()
            return out_path

        if chunk_seconds is None:
            chunk_seconds = DEFAULT_CHUNK_SECONDS
        push_event("log", f"Chunk size: {chunk_seconds // 60} minute(s) per request (cut at the nearest pause).")

        run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}"
        push_event("status", "Preparing audio chunks...")
        try:
            parts = split_audio_to_chunks(
                working_input_path,
                run_chunks_dir,
                chunk_seconds,
                on_progress=_prepare_progress(push_event),
                audio_track=audio_track,
            )
            push_event("log", f"Prepared {len(parts)} chunk(s) for transcription.")
            results.total = len(parts)
            # Chunks are cut at pauses, so their lengths vary; measure them for the section headers.
            spans = _chunk_spans(parts, chunk_seconds)

            def transcribe(p: Path, tail: str | None = None) -> tuple[str, str | None]:
                request = {
                    "kind": "transcript",
                    "model": transcription_model,
                    "languages": chunk_languages,
                    "context": context,
                    "keywords": keywords,
                    "previous_tail": tail,
                }
                return _transcribe_saved(
                    results,
                    p,
                    request,
                    lambda: transcribe_chunk_checked(
                        client,
                        p,
                        model=transcription_model,
                        languages=chunk_languages,
                        context=context,
                        keywords=keywords,
                        previous_tail=tail,
                        on_log=log,
                    ),
                    log,
                )

            if carry_context and len(parts) > 1:

                def transcribe_after(p: Path, previous: tuple[str, str | None] | None):
                    tail = None
                    if previous is not None:
                        previous_text, previous_warning = previous
                        if previous_warning or not previous_text.strip():
                            log(f"Not carrying context into {p.name}: the previous chunk failed its check.")
                        else:
                            tail = transcript_tail(previous_text)
                    return transcribe(p, tail)

                with _reporting_saved_chunks(results, push_event):
                    chunk_results = _run_chunks_in_order(parts, transcribe_after, push_event, "Transcribing")
            else:
                with _reporting_saved_chunks(results, push_event):
                    chunk_results = _run_chunks_in_parallel(parts, transcribe, push_event, "Transcribing")
        finally:
            cleanup_dir(run_chunks_dir)

        chunk_warnings = [warning for _, warning in chunk_results if warning]
        for warning in chunk_warnings:
            push_event("warning", warning)

        sections = [
            build_transcript_header(
                input_path=input_path,
                working_input_path=working_input_path,
                model=transcription_model,
                local_chunk_seconds=chunk_seconds,
                languages=chunk_languages,
                context=context or "",
                keywords=keywords,
                consistency_mode=carry_context,
                chunk_warnings=chunk_warnings,
            )
        ]
        for p, (chunk_text, warning), (start, end) in zip(parts, chunk_results, spans):
            sections.append(f"\n\n===== {p.name} ({hhmmss(start)}-{hhmmss(end)}) =====\n\n")
            if warning:
                sections.append(f"[WARNING: {warning}]\n\n")
            lines = sentence_lines(chunk_text)
            sections.append("\n".join(lines) if lines else str(chunk_text))
        out_path.write_text("".join(sections), encoding="utf-8")
        results.discard()

        return out_path
    finally:
        if converted_temp_path and converted_temp_path.exists():
            try:
                converted_temp_path.unlink()
            except Exception:
                pass


def _write_subtitles(
    client: OpenAI,
    working_input_path: Path,
    out_path: Path,
    *,
    chunks_dir: Path,
    languages: list[str] | None,
    audio_track: int,
    push_event,
    results: ChunkResults,
) -> None:
    """Transcribes the audio with the diarize model, whose segments are timed, and writes them as an .srt file."""

    def log(message: str) -> None:
        push_event("log", message)

    push_event("status", "Preparing audio chunks...")
    try:
        parts = split_audio_to_chunks(
            working_input_path,
            chunks_dir,
            DIARIZE_CHUNK_SECONDS,
            on_progress=_prepare_progress(push_event),
            audio_track=audio_track,
        )
        push_event("log", f"Prepared {len(parts)} chunk(s) for subtitles.")
        results.total = len(parts)
        offsets = [start for start, _ in _chunk_spans(parts, DIARIZE_CHUNK_SECONDS)]
        with _reporting_saved_chunks(results, push_event):
            responses = _run_chunks_in_parallel(
                parts,
                lambda p: _diarize_saved(results, client, p, languages, log),
                push_event,
                "Transcribing",
            )
    finally:
        cleanup_dir(chunks_dir)

    cues: list[SubtitleCue] = []
    for chunk, (p, resp, offset) in enumerate(zip(parts, responses, offsets)):
        chunk_cues = subtitle_cues(extract_diarization_segments(resp), offset, chunk)
        if not chunk_cues and extract_transcription_text(resp).strip():
            push_event("warning", f"{p.name}: the model returned text without timing, so this part has no subtitles.")
        cues.extend(chunk_cues)

    if not cues:
        raise SystemExit("No speech was found in this file, so there are no subtitles to write.")
    out_path.write_text(format_srt(cues), encoding="utf-8")
    push_event("log", f"Wrote {len(cues)} subtitle lines.")


def _save_subtitled_copy(
    input_path: Path,
    srt_path: Path,
    output_dir: Path,
    *,
    run_id: str,
    language: str | None,
    audio_track: int,
    push_event,
) -> None:
    """
    Saves a copy of the original video with the .srt built in as a subtitle track, for players like QuickTime
    which can't load an .srt file. The .srt is already written, so a failed copy is a warning, not a failed run.
    """
    if input_path.suffix.lower() not in EMBED_SUBTITLE_CODECS:
        kinds = ", ".join(sorted(EMBED_SUBTITLE_CODECS))
        push_event(
            "log",
            f"Subtitles can only be built into {kinds} videos, "
            f"so no copy of this {input_path.suffix.lower() or 'file'} was saved.",
        )
        return

    # Named after the video like the .srt; a run-stamped name keeps an earlier copy from being overwritten.
    out_path = output_dir / f"{input_path.stem}.subtitled{input_path.suffix}"
    if out_path.exists():
        out_path = output_dir / f"{input_path.stem}.subtitled.{run_id}{input_path.suffix}"
    if out_path.exists():
        push_event("warning", f"{out_path.name} already exists, so no copy of the video with subtitles was saved.")
        return

    push_event("status", "Saving a copy of the video with subtitles...")
    reported = -1

    def report(fraction: float) -> None:
        # The progress bar is already full from transcribing, so the copy's progress goes in the status.
        nonlocal reported
        percent = int(fraction * 100)
        if percent >= reported + 10:
            reported = percent
            push_event("status", f"Saving a copy of the video with subtitles ({percent}%)...")

    try:
        embed_subtitles_copy(
            input_path, srt_path, out_path, language=language, audio_track=audio_track, on_progress=report
        )
    except SystemExit as exc:
        push_event("warning", f"Couldn't save a copy of the video with subtitles: {exc} The .srt file was saved.")
        return
    push_event("log", f"Saved a copy of the video with subtitles: {out_path}")
    push_event("subtitled_copy", str(out_path.resolve()))
