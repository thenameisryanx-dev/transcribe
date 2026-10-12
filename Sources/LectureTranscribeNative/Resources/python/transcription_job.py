from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, TypeVar

from openai import OpenAI

from lecture_transcribe import (
    CHUNKS_ROOT_DIR,
    DIARIZE_CHUNK_SECONDS,
    DIARIZE_SINGLE_BUFFER,
    MODEL_DIARIZE,
    MODEL_MINI,
    MODEL_NORMAL,
    MINI_CHUNK_SECONDS,
    NORMAL_CHUNK_SECONDS,
    build_transcript_header,
    cleanup_dir,
    convert_qta_to_m4a_copy,
    diarize_chunk,
    diarize_whole_file,
    extract_diarization_segments,
    extract_transcription_text,
    format_diarized_lines,
    get_duration_seconds,
    hhmmss,
    max_parallel_requests,
    require_ffmpeg,
    require_ffprobe,
    safe_stem_from_path,
    sentence_lines,
    split_audio_to_chunks,
    transcribe_chunk_text,
)

T = TypeVar("T")


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
    executor = ThreadPoolExecutor(max_workers=workers)
    try:
        futures = {executor.submit(work, part): i for i, part in enumerate(parts)}
        done = 0
        for future in as_completed(futures):
            i = futures[future]
            results[i] = future.result()
            done += 1
            push_event("log", f"Finished chunk {i + 1}/{total}: {parts[i].name}")
            push_event("status", f"{label}: {done}/{total} chunks done")
            push_event("progress", (done / total) * 100.0)
    finally:
        # On failure or cancellation, drop queued chunks instead of waiting for them.
        executor.shutdown(wait=False, cancel_futures=True)
    return results


def run_transcription_job(
    input_path: Path,
    diarize: bool,
    output_dir: Path,
    transcription_model: str,
    push_event,
) -> Path:
    require_ffmpeg()
    require_ffprobe()

    if transcription_model not in {MODEL_NORMAL, MODEL_MINI}:
        push_event("log", f"Unknown model '{transcription_model}'. Falling back to {MODEL_NORMAL}.")
        transcription_model = MODEL_NORMAL

    if diarize and transcription_model == MODEL_MINI:
        raise SystemExit(
            "Speaker diarization is not supported with gpt-4o-mini-transcribe. "
            "Select gpt-4o-transcribe or disable diarization."
        )

    push_event("log", f"Using transcription model: {transcription_model}")

    def log(message: str) -> None:
        push_event("log", message)

    run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    stem = safe_stem_from_path(input_path)
    output_dir.mkdir(parents=True, exist_ok=True)

    out_suffix = "_diarize" if diarize else ""
    out_path = output_dir / f"{stem}_{run_id}{out_suffix}.txt"

    client = OpenAI()
    working_input_path = input_path
    converted_temp_path: Path | None = None

    try:
        if input_path.suffix.lower() == ".qta":
            push_event("log", "Detected .qta input. Converting to .m4a...")
            push_event("status", "Converting .qta input...")
            converted_temp_path = convert_qta_to_m4a_copy(input_path, run_id)
            working_input_path = converted_temp_path
            push_event("log", f"Converted .qta to: {working_input_path.name}")

        # Transcripts are written only after every chunk succeeds, so a failed or
        # cancelled run never leaves a partial file in the output folder.
        if diarize:
            dur = get_duration_seconds(working_input_path)
            if 0 < dur <= DIARIZE_SINGLE_BUFFER:
                push_event("status", "Diarizing (single request)...")
                content = diarize_whole_file(client, working_input_path, on_log=log)
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
                parts = split_audio_to_chunks(working_input_path, run_chunks_dir, DIARIZE_CHUNK_SECONDS)
                push_event("log", f"Prepared {len(parts)} chunk(s) for diarization.")

                # Offsets depend on earlier chunks' real lengths, so measure them before fanning out.
                offsets: list[float] = []
                offset_seconds = 0.0
                for p in parts:
                    offsets.append(offset_seconds)
                    chunk_duration = get_duration_seconds(p)
                    offset_seconds += chunk_duration if chunk_duration > 0 else DIARIZE_CHUNK_SECONDS

                responses = _run_chunks_in_parallel(
                    parts,
                    lambda p: diarize_chunk(client, p, on_log=log),
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
            return out_path

        chunk_seconds = MINI_CHUNK_SECONDS if transcription_model == MODEL_MINI else NORMAL_CHUNK_SECONDS
        push_event("log", f"Chunk size: {chunk_seconds // 60} minute(s) per request.")

        run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}"
        push_event("status", "Preparing audio chunks...")
        try:
            parts = split_audio_to_chunks(working_input_path, run_chunks_dir, chunk_seconds)
            push_event("log", f"Prepared {len(parts)} chunk(s) for transcription.")

            chunk_texts = _run_chunks_in_parallel(
                parts,
                lambda p: transcribe_chunk_text(client, p, model=transcription_model, on_log=log),
                push_event,
                "Transcribing",
            )
        finally:
            cleanup_dir(run_chunks_dir)

        sections = [
            build_transcript_header(
                input_path=input_path,
                working_input_path=working_input_path,
                model=transcription_model,
                local_chunk_seconds=chunk_seconds,
            )
        ]
        for i, (p, chunk_text) in enumerate(zip(parts, chunk_texts)):
            start = i * chunk_seconds
            end = start + chunk_seconds
            sections.append(f"\n\n===== {p.name} ({hhmmss(start)}-{hhmmss(end)}) =====\n\n")
            lines = sentence_lines(chunk_text)
            sections.append("\n".join(lines) if lines else str(chunk_text))
        out_path.write_text("".join(sections), encoding="utf-8")

        return out_path
    finally:
        if converted_temp_path and converted_temp_path.exists():
            try:
                converted_temp_path.unlink()
            except Exception:
                pass
