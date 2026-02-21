from datetime import datetime
from pathlib import Path

from openai import OpenAI

from lecture_transcribe import (
    CHUNKS_ROOT_DIR,
    DIARIZE_CHUNK_SECONDS,
    DIARIZE_SINGLE_BUFFER,
    MODEL_DIARIZE,
    MODEL_NORMAL,
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
    push_event,
) -> Path:
    require_ffmpeg()
    require_ffprobe()

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
            converted_temp_path = convert_qta_to_m4a_copy(input_path, run_id)
            working_input_path = converted_temp_path

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
            parts = split_audio_to_chunks(working_input_path, run_chunks_dir, DIARIZE_CHUNK_SECONDS)
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

        run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}"
        parts = split_audio_to_chunks(working_input_path, run_chunks_dir, NORMAL_CHUNK_SECONDS)

        try:
            with out_path.open("w", encoding="utf-8") as out:
                out.write(
                    build_transcript_header(
                        input_path=input_path,
                        working_input_path=working_input_path,
                        model=MODEL_NORMAL,
                        local_chunk_seconds=NORMAL_CHUNK_SECONDS,
                    )
                )
                for i, p in enumerate(parts):
                    start = i * NORMAL_CHUNK_SECONDS
                    end = start + NORMAL_CHUNK_SECONDS
                    push_event("status", f"Transcribing chunk {i + 1}/{len(parts)}: {p.name}")
                    out.write(f"\n\n===== {p.name} ({hhmmss(start)}-{hhmmss(end)}) =====\n\n")
                    chunk_text = transcribe_chunk_text(client, p)
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
