from datetime import datetime
from pathlib import Path

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
    require_ffmpeg,
    require_ffprobe,
    safe_stem_from_path,
    sentence_lines,
    split_audio_to_chunks,
    transcribe_chunk_text,
)


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

        if diarize:
            dur = get_duration_seconds(working_input_path)
            if 0 < dur <= DIARIZE_SINGLE_BUFFER:
                push_event("status", "Diarizing (single request)...")
                content = diarize_whole_file(client, working_input_path)
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
            parts = split_audio_to_chunks(working_input_path, run_chunks_dir, DIARIZE_CHUNK_SECONDS)
            push_event("log", f"Prepared {len(parts)} chunk(s) for diarization.")
            out_lines: list[str] = []
            offset_seconds = 0.0

            try:
                for i, p in enumerate(parts):
                    push_event("status", f"Diarizing chunk {i + 1}/{len(parts)}: {p.name}")
                    resp = diarize_chunk(client, p)
                    segments = extract_diarization_segments(resp)

                    chunk_duration = get_duration_seconds(p)
                    chunk_span = chunk_duration if chunk_duration > 0 else DIARIZE_CHUNK_SECONDS

                    if not segments:
                        out_lines.append(f"\n===== {p.name} =====\n")
                        out_lines.extend(sentence_lines(extract_transcription_text(resp)))
                    else:
                        out_lines.extend(format_diarized_lines(segments, offset_seconds))

                    offset_seconds += chunk_span
                    push_event("progress", ((i + 1) / len(parts)) * 100.0)
            finally:
                cleanup_dir(run_chunks_dir)

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
        parts = split_audio_to_chunks(working_input_path, run_chunks_dir, chunk_seconds)
        push_event("log", f"Prepared {len(parts)} chunk(s) for transcription.")

        try:
            with out_path.open("w", encoding="utf-8") as out:
                out.write(
                    build_transcript_header(
                        input_path=input_path,
                        working_input_path=working_input_path,
                        model=transcription_model,
                        local_chunk_seconds=chunk_seconds,
                    )
                )
                for i, p in enumerate(parts):
                    start = i * chunk_seconds
                    end = start + chunk_seconds
                    push_event("status", f"Transcribing chunk {i + 1}/{len(parts)}: {p.name}")
                    out.write(f"\n\n===== {p.name} ({hhmmss(start)}-{hhmmss(end)}) =====\n\n")
                    chunk_text = transcribe_chunk_text(client, p, model=transcription_model)
                    lines = sentence_lines(chunk_text)
                    if lines:
                        out.write("\n".join(lines))
                    else:
                        out.write(str(chunk_text))
                    push_event("progress", ((i + 1) / len(parts)) * 100.0)
        finally:
            cleanup_dir(run_chunks_dir)

        return out_path
    finally:
        if converted_temp_path and converted_temp_path.exists():
            try:
                converted_temp_path.unlink()
            except Exception:
                pass
