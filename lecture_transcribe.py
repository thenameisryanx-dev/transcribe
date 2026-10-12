from __future__ import annotations

import os
import re
import sys
import time
import shutil
import subprocess
import platform
from pathlib import Path
from typing import Any, Callable

from openai import OpenAI

# =======================
# STANDARD SETTINGS
# =======================
# Use None for auto-detect so mixed-language audio is transcribed as spoken (no forced translation).
LANGUAGE: str | None = None

# Best-quality transcription (no speaker labels)
MODEL_GPT_TRANSCRIBE = "gpt-transcribe"
MODEL_NORMAL = "gpt-4o-transcribe"
MODEL_MINI = "gpt-4o-mini-transcribe"
NORMAL_CHUNK_SECONDS = 10 * 60  # 10 minutes (reliable for 60+ min)
MINI_CHUNK_SECONDS = 5 * 60     # smaller chunks give faster visible progress on mini

# Diarization model + constraints
MODEL_DIARIZE = "gpt-4o-transcribe-diarize"
DIARIZE_MAX_SECONDS = 1400          # hard cap observed from API error
DIARIZE_SINGLE_BUFFER = 1300        # be conservative: single request only if <= 1300s
DIARIZE_CHUNK_SECONDS = 10 * 60     # smaller chunks reduce timeout risk on long recordings

# gpt-transcribe safeguards. Without a `languages` hint it drops speech; even with one it can
# occasionally return no text (reported as `"languages": []`) or loop on repeated phrases.
DEFAULT_LANGUAGES = ["en"]
GPT_TRANSCRIBE_RETRIES = 2           # extra attempts (same model) when a chunk's output fails a check
MAX_PLAUSIBLE_WORDS_PER_MINUTE = 350 # faster than anyone speaks; more means the model repeated itself

# API request behavior
API_TIMEOUT_SECONDS = 20 * 60       # per-request timeout (seconds)
MAX_TRANSCRIBE_RETRIES = 4          # retries for transient API/network errors
RETRY_BASE_SECONDS = 2              # exponential backoff base
DIARIZE_INCLUDE_TIMESTAMPS = False  # keep diarized output cleaner for lecture notes

# Chunk encoding (robust for "any random audio file")
AUDIO_BITRATE = "128k"

# Chunk boundaries move back to the quietest moment in the stretch before each cut, so a
# sentence isn't sliced in half (the model can't transcribe half a word on either side).
SPLIT_SEARCH_SECONDS = 60           # how far back from each nominal cut to look for a pause
SPLIT_FRAME_SECONDS = 0.1           # loudness is measured per frame of this length
SPLIT_PAUSE_FRAMES = 5              # frames averaged together, so the cut lands in a ~0.5s pause

# Cleanup chunk files after successful run
CLEANUP_CHUNKS = True

# Chunks sent to the API at once. Retries absorb occasional 429s; override with TRANSCRIBE_MAX_PARALLEL.
DEFAULT_MAX_PARALLEL_REQUESTS = 4

WORK_ROOT_DIR = Path(os.getenv("TRANSCRIBE_WORKDIR", ".")).expanduser()
CHUNKS_ROOT_DIR = WORK_ROOT_DIR / "chunks"
CONVERTED_ROOT_DIR = WORK_ROOT_DIR / "converted_inputs"
KEYRING_SERVICE = "lecture-transcribe"
KEYRING_USERNAME = "openai_api_key"
BUNDLED_FFMPEG_DIR_NAME = "ffmpeg_bin"
MEDIA_TOOL_CHECK_TIMEOUT_SECONDS = 6
MEDIA_PROCESS_TIMEOUT_SECONDS = 30 * 60
_MEDIA_TOOL_CACHE: dict[str, str] = {}
_LAST_KEYCHAIN_ERROR = ""
# =======================


def is_valid_api_key(key: str) -> bool:
    key = str(key or "")
    return bool(key) and key.startswith("sk-") and ("\n" not in key) and ("\r" not in key) and (key == key.strip())


def _set_last_keychain_error(message: str) -> None:
    global _LAST_KEYCHAIN_ERROR
    _LAST_KEYCHAIN_ERROR = str(message or "").strip()


def get_last_keychain_error() -> str:
    return _LAST_KEYCHAIN_ERROR


def _summarize_subprocess_error(exc: Exception, default_message: str) -> str:
    if isinstance(exc, subprocess.CalledProcessError):
        details = str(exc.stderr or exc.stdout or "").strip()
        if details:
            return details
    return default_message


def load_api_key_from_keyring() -> str:
    _set_last_keychain_error("")
    try:
        import keyring
    except Exception:
        _set_last_keychain_error("Python package 'keyring' is not installed.")
        keyring = None  # type: ignore[assignment]

    if keyring is not None:
        try:
            saved = str(keyring.get_password(KEYRING_SERVICE, KEYRING_USERNAME) or "").strip()
            if saved:
                _set_last_keychain_error("")
                return saved
        except Exception:
            _set_last_keychain_error("Python keyring backend could not read from keychain.")
            pass

    # Fallback for macOS app bundles where the Python keyring package may be absent.
    if platform.system() == "Darwin":
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-a",
                    KEYRING_USERNAME,
                    "-s",
                    KEYRING_SERVICE,
                    "-w",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            _set_last_keychain_error("")
            return str(result.stdout or "").strip()
        except Exception as exc:
            _set_last_keychain_error(_summarize_subprocess_error(exc, "macOS keychain lookup failed."))
            return ""

    return ""


def save_api_key_to_keyring(key: str) -> bool:
    _set_last_keychain_error("")
    try:
        import keyring
    except Exception:
        _set_last_keychain_error("Python package 'keyring' is not installed.")
        keyring = None  # type: ignore[assignment]

    if keyring is not None:
        try:
            keyring.set_password(KEYRING_SERVICE, KEYRING_USERNAME, key)
            _set_last_keychain_error("")
            return True
        except Exception:
            _set_last_keychain_error("Python keyring backend could not write to keychain.")
            pass

    # Fallback for macOS app bundles where the Python keyring package may be absent.
    if platform.system() == "Darwin":
        try:
            add_args = ["add-generic-password", "-U", "-a", KEYRING_USERNAME, "-s", KEYRING_SERVICE, "-w"]
            if re.fullmatch(r"[A-Za-z0-9_\-]+", key):
                # Feed the command through `security -i` on stdin so the key never appears in `ps` output.
                subprocess.run(
                    ["security", "-i"],
                    input=" ".join(add_args + [key]) + "\n",
                    check=True,
                    capture_output=True,
                    text=True,
                )
            else:
                subprocess.run(
                    ["security", *add_args, key],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            _set_last_keychain_error("")
            return True
        except Exception as exc:
            _set_last_keychain_error(_summarize_subprocess_error(exc, "macOS keychain write failed."))
            return False

    _set_last_keychain_error("No supported secure keychain backend is available.")
    return False


def _candidate_tool_paths(tool_name: str) -> list[Path]:
    env_var = "FFMPEG_BIN" if tool_name == "ffmpeg" else "FFPROBE_BIN"
    candidates: list[Path] = []

    env_path = os.getenv(env_var, "").strip()
    if env_path:
        candidates.append(Path(env_path).expanduser())

    if getattr(sys, "_MEIPASS", None):
        candidates.append(Path(str(sys._MEIPASS)) / BUNDLED_FFMPEG_DIR_NAME / tool_name)

    script_dir = Path(__file__).resolve().parent
    candidates.append(script_dir / BUNDLED_FFMPEG_DIR_NAME / tool_name)

    which_path = shutil.which(tool_name)
    if which_path:
        candidates.append(Path(which_path))

    deduped: list[Path] = []
    seen: set[str] = set()
    for p in candidates:
        key = str(p)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(p)
    return deduped


def _is_runnable_media_tool(path: Path) -> bool:
    try:
        subprocess.run(
            [*_tool_invocation_prefix(path), "-version"],
            check=True,
            capture_output=True,
            text=True,
            timeout=MEDIA_TOOL_CHECK_TIMEOUT_SECONDS,
        )
        return True
    except Exception:
        return False


def _binary_architectures(path: Path) -> set[str]:
    try:
        result = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=MEDIA_TOOL_CHECK_TIMEOUT_SECONDS,
        )
        return {part.strip() for part in result.stdout.split() if part.strip()}
    except Exception:
        return set()


def _supports_host_arch(path: Path) -> bool:
    host_arch = platform.machine()
    binary_archs = _binary_architectures(path)
    if not binary_archs:
        return True

    if host_arch == "arm64":
        return "arm64" in binary_archs
    if host_arch in {"x86_64", "amd64"}:
        return "x86_64" in binary_archs
    return True


def find_media_tool(tool_name: str) -> str | None:
    cached = _MEDIA_TOOL_CACHE.get(tool_name)
    if cached:
        p = Path(cached)
        if p.exists() and p.is_file() and os.access(p, os.X_OK) and _supports_host_arch(p):
            return cached
        _MEDIA_TOOL_CACHE.pop(tool_name, None)

    for p in _candidate_tool_paths(tool_name):
        try:
            if (
                p.exists()
                and p.is_file()
                and os.access(p, os.X_OK)
                and _supports_host_arch(p)
                and _is_runnable_media_tool(p)
            ):
                resolved = str(p)
                _MEDIA_TOOL_CACHE[tool_name] = resolved
                return resolved
        except Exception:
            continue
    return None


def _tool_invocation_prefix(path: Path) -> list[str]:
    """
    Always execute media tools natively.
    """
    return [str(path)]


def ffmpeg_bin() -> str:
    path = find_media_tool("ffmpeg")
    if path:
        return path
    if platform.machine() == "arm64":
        raise SystemExit(
            "ffmpeg not found for native Apple Silicon execution. "
            "Reinstall the latest app build with bundled arm64 ffmpeg, "
            "or install arm64 system ffmpeg with: brew install ffmpeg"
        )
    raise SystemExit(
        "ffmpeg not found. Reinstall the latest app build (bundled ffmpeg), "
        "or install system ffmpeg with: brew install ffmpeg"
    )


def ffprobe_bin() -> str:
    path = find_media_tool("ffprobe")
    if path:
        return path
    if platform.machine() == "arm64":
        raise SystemExit(
            "ffprobe not found for native Apple Silicon execution. "
            "Reinstall the latest app build with bundled arm64 ffprobe, "
            "or install arm64 system ffmpeg with: brew install ffmpeg"
        )
    raise SystemExit(
        "ffprobe not found. Reinstall the latest app build (bundled ffprobe), "
        "or install system ffmpeg with: brew install ffmpeg"
    )


def ffmpeg_cmd_prefix() -> list[str]:
    return _tool_invocation_prefix(Path(ffmpeg_bin()))


def ffprobe_cmd_prefix() -> list[str]:
    return _tool_invocation_prefix(Path(ffprobe_bin()))


def require_ffmpeg() -> None:
    try:
        subprocess.run([*ffmpeg_cmd_prefix(), "-version"], check=True, capture_output=True, text=True)
    except SystemExit:
        raise
    except Exception:
        raise SystemExit(
            "ffmpeg executable was found but could not run. "
            "Reinstall app or reinstall with: brew install ffmpeg"
        )


def require_ffprobe() -> None:
    try:
        subprocess.run([*ffprobe_cmd_prefix(), "-version"], check=True, capture_output=True, text=True)
    except SystemExit:
        raise
    except Exception:
        raise SystemExit(
            "ffprobe executable was found but could not run. "
            "Reinstall app or reinstall with: brew install ffmpeg"
        )


def hhmmss(seconds: float) -> str:
    s = int(seconds)
    h = s // 3600
    m = (s % 3600) // 60
    sec = s % 60
    return f"{h:02d}:{m:02d}:{sec:02d}"


def safe_stem_from_path(p: Path) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", p.stem)


def sentence_lines(text: str) -> list[str]:
    cleaned = " ".join(str(text or "").split())
    if not cleaned:
        return []
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", cleaned) if s.strip()]


def extract_transcription_text(resp: Any) -> str:
    if isinstance(resp, dict):
        return str(resp.get("text") or "")
    return str(getattr(resp, "text", "") or "")


def extract_diarization_segments(resp: Any) -> list[Any]:
    segments = getattr(resp, "segments", None)
    if segments is None and isinstance(resp, dict):
        segments = resp.get("segments", [])
    return list(segments or [])


def _coerce_optional_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        return None


def _segment_fields(seg: Any) -> tuple[Any, float | None, float | None, str]:
    if isinstance(seg, dict):
        speaker = seg.get("speaker")
        start = _coerce_optional_float(seg.get("start"))
        end = _coerce_optional_float(seg.get("end"))
        text = str(seg.get("text") or "")
        return speaker, start, end, text

    speaker = getattr(seg, "speaker", None)
    start = _coerce_optional_float(getattr(seg, "start", None))
    end = _coerce_optional_float(getattr(seg, "end", None))
    text = str(getattr(seg, "text", "") or "")
    return speaker, start, end, text


def format_diarized_lines(segments: list[Any], offset_seconds: float = 0.0) -> list[str]:
    lines: list[str] = []
    for seg in segments:
        speaker, start, end, text = _segment_fields(seg)
        if start is None or end is None:
            continue

        speaker_label = speaker if speaker is not None else "Speaker"
        if DIARIZE_INCLUDE_TIMESTAMPS:
            lines.append(
                f"[{speaker_label}] "
                f"{hhmmss(offset_seconds + start)}-{hhmmss(offset_seconds + end)} "
                f"{text}"
            )
        else:
            lines.append(f"[{speaker_label}] {text}")
    return lines


def build_transcript_header(
    *,
    input_path: Path,
    working_input_path: Path,
    model: str,
    response_format: str | None = None,
    chunking_strategy: str | None = None,
    local_chunk_seconds: int | None = None,
    duration_seconds: float | None = None,
    languages: list[str] | None = None,
    chunk_warnings: list[str] | None = None,
) -> str:
    lines = [
        f"INPUT: {input_path}",
        f"WORKING_INPUT: {working_input_path}",
        f"MODEL: {model}",
    ]
    if response_format is not None:
        lines.append(f"RESPONSE_FORMAT: {response_format}")
    if chunking_strategy is not None:
        lines.append(f'CHUNKING_STRATEGY: "{chunking_strategy}"')
    if local_chunk_seconds is not None:
        lines.append(f"LOCAL_CHUNK_SECONDS: {local_chunk_seconds}")
    if duration_seconds is not None:
        lines.append(f"DURATION_SECONDS: {duration_seconds:.3f}")
    if languages:
        lines.append(f"LANGUAGES: {', '.join(languages)}")
    for warning in chunk_warnings or []:
        lines.append(f"WARNING: {warning}")
    return "\n".join(lines) + "\n\n"


def get_duration_seconds(path: Path) -> float:
    """
    Uses ffprobe to read duration. Returns -1 if it can't be determined.
    """
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=nk=1:nw=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            # ffprobe has no -nostdin flag (it made every call fail); keep it off stdin this way instead.
            stdin=subprocess.DEVNULL,
            timeout=30,
        )
        return float(r.stdout.strip())
    except Exception:
        return -1.0


def _copied_m4a_chunk_is_transcribable(path: Path) -> bool:
    """
    Stream-copying into .m4a is only safe when the resulting audio stream is AAC.
    """
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name",
                "-of", "default=nk=1:nw=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            # ffprobe has no -nostdin flag (it made every call fail); keep it off stdin this way instead.
            stdin=subprocess.DEVNULL,
            timeout=30,
        )
        codec_name = str(r.stdout or "").strip().lower()
        return codec_name == "aac"
    except Exception:
        return False


def _quietest_point(input_path: Path, window_start: float, window_seconds: float) -> float | None:
    """
    Return the absolute time of the quietest ~0.5s inside [window_start, window_start + window_seconds],
    or None if the window can't be analyzed.
    """
    sample_rate = 16000
    frame_samples = int(sample_rate * SPLIT_FRAME_SECONDS)
    cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-ss", f"{window_start:.3f}",
        "-t", f"{window_seconds:.3f}",
        "-i", str(input_path),
        "-vn",
        "-map", "0:a:0",
        "-af",
        f"aresample={sample_rate},asetnsamples=n={frame_samples}:p=0,astats=metadata=1:reset=1,"
        "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
        "-f", "null",
        "-",
    ]
    try:
        r = subprocess.run(
            cmd, check=True, capture_output=True, text=True, errors="replace", timeout=120
        )
    except Exception:
        return None

    levels: list[float] = []
    for line in r.stdout.splitlines():
        if line.startswith("lavfi.astats.Overall.RMS_level="):
            raw = line.split("=", 1)[1].strip()
            try:
                level = float(raw)
            except ValueError:
                level = -200.0
            # Digital silence reports -inf.
            levels.append(level if level > -200.0 else -200.0)
    if len(levels) < SPLIT_PAUSE_FRAMES:
        return None

    best_index = 0
    best_level = float("inf")
    for i in range(len(levels) - SPLIT_PAUSE_FRAMES + 1):
        level = sum(levels[i : i + SPLIT_PAUSE_FRAMES]) / SPLIT_PAUSE_FRAMES
        # `<=` keeps the latest of equally quiet spots, so chunks stay close to their nominal length.
        if level <= best_level:
            best_level = level
            best_index = i
    return window_start + (best_index + SPLIT_PAUSE_FRAMES / 2) * SPLIT_FRAME_SECONDS


def plan_chunk_cuts(input_path: Path, chunk_seconds: int) -> list[float]:
    """
    Cut times (seconds) for splitting into chunks of at most chunk_seconds, each moved back to the
    quietest moment before the nominal cut. Empty when the audio fits in one chunk or its length is unknown.
    """
    total = get_duration_seconds(input_path)
    if total <= chunk_seconds:
        return []

    search = min(SPLIT_SEARCH_SECONDS, chunk_seconds / 4)
    cuts: list[float] = []
    previous = 0.0
    while total - previous > chunk_seconds:
        target = previous + chunk_seconds
        window_start = target - search
        cut = _quietest_point(input_path, window_start, search)
        if cut is None or not (window_start <= cut <= target):
            cut = target
        cuts.append(cut)
        previous = cut
    return cuts


def split_audio_to_chunks(input_path: Path, run_chunks_dir: Path, chunk_seconds: int) -> list[Path]:
    """
    Split input into pieces of at most chunk_seconds, cutting at pauses (see plan_chunk_cuts).
    First tries stream copy (no quality loss). Falls back to AAC re-encode for robustness.
    """
    run_chunks_dir.mkdir(parents=True, exist_ok=True)

    cuts = plan_chunk_cuts(input_path, chunk_seconds)
    if cuts:
        segment_args = ["-segment_times", ",".join(f"{c:.3f}" for c in cuts)]
    else:
        segment_args = ["-segment_time", str(chunk_seconds)]

    for old in run_chunks_dir.glob("part_*.m4a"):
        old.unlink()

    copy_cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-i", str(input_path),
        "-vn",
        "-f", "segment",
        *segment_args,
        "-reset_timestamps", "1",
        "-map", "0:a:0",
        "-c:a", "copy",
        str(run_chunks_dir / "part_%03d.m4a"),
    ]
    try:
        subprocess.run(copy_cmd, check=True, timeout=MEDIA_PROCESS_TIMEOUT_SECONDS)
    except Exception:
        pass

    parts = sorted(run_chunks_dir.glob("part_*.m4a"))
    if parts and all(_copied_m4a_chunk_is_transcribable(p) for p in parts[: min(2, len(parts))]):
        return parts

    for old in run_chunks_dir.glob("part_*.m4a"):
        old.unlink()

    reencode_cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-i", str(input_path),
        "-vn",
        "-f", "segment",
        *segment_args,
        "-reset_timestamps", "1",
        "-map", "0:a:0",
        "-c:a", "aac",
        "-b:a", AUDIO_BITRATE,
        str(run_chunks_dir / "part_%03d.m4a"),
    ]
    try:
        subprocess.run(reencode_cmd, check=True, timeout=MEDIA_PROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise SystemExit(
            "Chunking audio timed out while running ffmpeg. "
            "Try a shorter file or check local ffmpeg health."
        ) from None

    parts = sorted(run_chunks_dir.glob("part_*.m4a"))
    if not parts:
        raise SystemExit("No chunks created. Is the input a valid audio file?")
    return parts


def convert_qta_to_m4a_copy(input_path: Path, run_id: str) -> Path:
    """
    Convert .qta (QuickTime container) to .m4a with stream copy to avoid quality loss.
    """
    CONVERTED_ROOT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = CONVERTED_ROOT_DIR / f"{safe_stem_from_path(input_path)}_{run_id}.m4a"
    if out_path.exists():
        out_path.unlink()

    copy_cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "mov",
        "-i", str(input_path),
        "-vn",
        "-map", "0:a:0",
        "-c:a", "copy",
        str(out_path),
    ]

    try:
        subprocess.run(copy_cmd, check=True, timeout=MEDIA_PROCESS_TIMEOUT_SECONDS)
    except Exception:
        if out_path.exists():
            out_path.unlink()
        reencode_cmd = [
            *ffmpeg_cmd_prefix(),
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "mov",
            "-i", str(input_path),
            "-vn",
            "-map", "0:a:0",
            "-c:a", "aac",
            "-b:a", AUDIO_BITRATE,
            str(out_path),
        ]
        try:
            subprocess.run(reencode_cmd, check=True, timeout=MEDIA_PROCESS_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise SystemExit(
                "Timed out converting .qta to .m4a. "
                "Please verify the file opens normally in QuickTime."
            ) from None

    if not out_path.exists() or out_path.stat().st_size == 0:
        raise SystemExit("Failed to convert .qta to .m4a.")
    return out_path


def repair_audio_for_api(input_path: Path) -> Path:
    """
    Re-encode an audio chunk to AAC .m4a if the API rejects the original bytes.
    """
    repaired_path = input_path.with_name(f"{input_path.stem}_repaired.m4a")
    if repaired_path.exists():
        repaired_path.unlink()

    reencode_cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-i", str(input_path),
        "-vn",
        "-c:a", "aac",
        "-b:a", AUDIO_BITRATE,
        str(repaired_path),
    ]
    try:
        subprocess.run(reencode_cmd, check=True, timeout=MEDIA_PROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise SystemExit(
            "Timed out re-encoding audio after the API rejected the original file."
        ) from None
    except Exception as exc:
        raise SystemExit(f"Could not repair audio for transcription: {exc}") from None

    if not repaired_path.exists() or repaired_path.stat().st_size == 0:
        raise SystemExit("Audio repair failed to produce a usable file.")
    return repaired_path


def max_parallel_requests() -> int:
    raw = os.getenv("TRANSCRIBE_MAX_PARALLEL", "").strip()
    try:
        value = int(raw) if raw else DEFAULT_MAX_PARALLEL_REQUESTS
    except ValueError:
        value = DEFAULT_MAX_PARALLEL_REQUESTS
    return max(1, value)


def cleanup_dir(dir_path: Path) -> None:
    if not CLEANUP_CHUNKS:
        return
    try:
        for p in dir_path.glob("part_*.m4a"):
            try:
                p.unlink()
            except Exception:
                pass
        try:
            dir_path.rmdir()
        except Exception:
            pass
    except Exception:
        pass


def parse_language_codes(raw: str) -> list[str]:
    """
    Parse "en, es" style input into unique lowercase ISO 639 codes. Raises ValueError on bad codes.
    """
    codes: list[str] = []
    for token in re.split(r"[\s,]+", raw.strip()):
        if not token:
            continue
        code = token.lower()
        if not re.fullmatch(r"[a-z]{2,3}", code):
            raise ValueError(f"'{token}' is not a language code. Use codes like en, es, zh.")
        if code not in codes:
            codes.append(code)
    return codes


def single_language_hint(languages: list[str] | None) -> str | None:
    """
    The `language` to force on models that take only one (GPT-4o and diarize). Several languages,
    or a code that isn't ISO-639-1, mean auto-detect so mixed-language audio isn't forced into one.
    """
    if languages and len(languages) == 1 and len(languages[0]) == 2:
        return languages[0]
    return LANGUAGE


def _looks_repeated(text: str, duration_seconds: float) -> bool:
    if duration_seconds <= 0:
        return False
    words = len(text.split())
    # The 50-word allowance keeps very short chunks from tripping the check.
    return words > max(50.0, MAX_PLAUSIBLE_WORDS_PER_MINUTE * duration_seconds / 60.0)


def transcribe_chunk_checked(
    client: OpenAI,
    chunk_path: Path,
    *,
    model: str,
    languages: list[str] | None = None,
    on_log: Callable[[str], None] | None = None,
) -> tuple[str, str | None]:
    """
    Transcribe one chunk and return (text, warning or None). Always uses the selected model.
    gpt-transcribe output is checked; empty or implausibly long results are retried with gpt-transcribe,
    and a warning is returned if the last attempt still fails the check.
    """
    if model != MODEL_GPT_TRANSCRIBE:
        return transcribe_chunk_text(client, chunk_path, model=model, languages=languages, on_log=on_log), None

    log = on_log or (lambda _message: None)
    attempts = 1 + GPT_TRANSCRIBE_RETRIES
    warning = None
    text = ""
    for attempt in range(1, attempts + 1):
        resp = create_transcription_with_retry(
            client,
            chunk_path,
            model=MODEL_GPT_TRANSCRIBE,
            response_format="json",
            languages=languages or DEFAULT_LANGUAGES,
            on_log=on_log,
        )
        text = extract_transcription_text(resp).strip()
        if not text:
            warning = f"{chunk_path.name}: {MODEL_GPT_TRANSCRIBE} returned no text"
        elif _looks_repeated(text, get_duration_seconds(chunk_path)):
            warning = (
                f"{chunk_path.name}: {MODEL_GPT_TRANSCRIBE} returned {len(text.split())} words, "
                "more than could be spoken in this chunk (likely repeated text)"
            )
        else:
            return text, None
        log(f"{warning} (attempt {attempt}/{attempts}).")

    return text, f"{warning} after {attempts} attempts."


def transcribe_chunk_text(
    client: OpenAI,
    chunk_path: Path,
    *,
    model: str = MODEL_NORMAL,
    languages: list[str] | None = None,
    on_log: Callable[[str], None] | None = None,
) -> str:
    text = create_transcription_with_retry(
        client,
        chunk_path,
        model=model,
        response_format="text",
        languages=languages,
        on_log=on_log,
    )
    return str(text)


def is_retryable_transcription_error(exc: Exception) -> bool:
    cls = exc.__class__.__name__
    if cls in {"APITimeoutError", "APIConnectionError", "RateLimitError", "InternalServerError"}:
        return True

    status = getattr(exc, "status_code", None)
    if status in {408, 409, 429, 500, 502, 503, 504}:
        return True

    msg = str(exc).lower()
    if any(k in msg for k in ("timed out", "timeout", "connection reset", "temporarily unavailable")):
        return True

    return False


def is_invalid_audio_file_error(exc: Exception) -> bool:
    status = getattr(exc, "status_code", None)
    msg = str(exc).lower()
    return (
        status == 400
        and "audio file might be corrupted or unsupported" in msg
        and "invalid_value" in msg
    )


def create_transcription_with_retry(
    client: OpenAI,
    audio_path: Path,
    *,
    model: str,
    response_format: str,
    chunking_strategy: str | None = None,
    languages: list[str] | None = None,
    on_log: Callable[[str], None] | None = None,
):
    log = on_log or (lambda _message: None)
    active_audio_path = audio_path
    repaired_audio_path: Path | None = None

    try:
        for attempt in range(1, MAX_TRANSCRIBE_RETRIES + 1):
            with active_audio_path.open("rb") as f:
                kwargs = {
                    "model": model,
                    "file": f,
                    "response_format": response_format,
                    "timeout": API_TIMEOUT_SECONDS,
                }
                if model == MODEL_GPT_TRANSCRIBE:
                    # gpt-transcribe takes a `languages` list instead of `language`; the SDK doesn't expose it yet.
                    hint = languages or ([LANGUAGE] if LANGUAGE else None)
                    if hint:
                        kwargs["extra_body"] = {"languages": hint}
                elif language := single_language_hint(languages):
                    kwargs["language"] = language
                if chunking_strategy is not None:
                    kwargs["chunking_strategy"] = chunking_strategy

                try:
                    return client.audio.transcriptions.create(**kwargs)
                except Exception as e:
                    if repaired_audio_path is None and is_invalid_audio_file_error(e):
                        log(
                            f"API rejected {active_audio_path.name} as unsupported. "
                            "Re-encoding once and retrying..."
                        )
                        repaired_audio_path = repair_audio_for_api(audio_path)
                        active_audio_path = repaired_audio_path
                        continue

                    if attempt == MAX_TRANSCRIBE_RETRIES or not is_retryable_transcription_error(e):
                        raise

                    delay = RETRY_BASE_SECONDS * (2 ** (attempt - 1))
                    log(
                        f"Transient transcription error on {active_audio_path.name} "
                        f"(attempt {attempt}/{MAX_TRANSCRIBE_RETRIES}): {e}. Retrying in {delay}s..."
                    )
                    time.sleep(delay)
    finally:
        if repaired_audio_path and repaired_audio_path.exists():
            try:
                repaired_audio_path.unlink()
            except Exception:
                pass


def diarize_whole_file(
    client: OpenAI,
    input_path: Path,
    *,
    languages: list[str] | None = None,
    on_log: Callable[[str], None] | None = None,
) -> str:
    """
    Single diarize request (only for shorter audio).
    """
    resp = create_transcription_with_retry(
        client,
        input_path,
        model=MODEL_DIARIZE,
        response_format="diarized_json",
        chunking_strategy="auto",
        languages=languages,
        on_log=on_log,
    )

    segments = extract_diarization_segments(resp)
    if not segments:
        return extract_transcription_text(resp)
    return "\n".join(format_diarized_lines(segments))


def diarize_chunk(
    client: OpenAI,
    chunk_path: Path,
    *,
    languages: list[str] | None = None,
    on_log: Callable[[str], None] | None = None,
):
    """
    Diarize a single chunk (< 1400s). Requires chunking_strategy for diarize model.
    """
    return create_transcription_with_retry(
        client,
        chunk_path,
        model=MODEL_DIARIZE,
        response_format="diarized_json",
        chunking_strategy="auto",
        languages=languages,
        on_log=on_log,
    )
