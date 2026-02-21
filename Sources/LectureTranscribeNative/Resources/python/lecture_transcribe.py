import os
import re
import sys
import time
import shutil
import subprocess
import threading
import platform
from pathlib import Path
from datetime import datetime
from typing import Any, Callable
from getpass import getpass

from openai import OpenAI

# =======================
# STANDARD SETTINGS
# =======================
# Use None for auto-detect so mixed-language audio is transcribed as spoken (no forced translation).
LANGUAGE: str | None = None

# Best-quality transcription (no speaker labels)
MODEL_NORMAL = "gpt-4o-transcribe"
MODEL_MINI = "gpt-4o-mini-transcribe"
NORMAL_CHUNK_SECONDS = 10 * 60  # 10 minutes (reliable for 60+ min)
MINI_CHUNK_SECONDS = 5 * 60     # smaller chunks give faster visible progress on mini

# Diarization model + constraints
MODEL_DIARIZE = "gpt-4o-transcribe-diarize"
DIARIZE_MAX_SECONDS = 1400          # hard cap observed from API error
DIARIZE_SINGLE_BUFFER = 1300        # be conservative: single request only if <= 1300s
DIARIZE_CHUNK_SECONDS = 10 * 60     # smaller chunks reduce timeout risk on long recordings

# API request behavior
API_TIMEOUT_SECONDS = 20 * 60       # per-request timeout (seconds)
MAX_TRANSCRIBE_RETRIES = 4          # retries for transient API/network errors
RETRY_BASE_SECONDS = 2              # exponential backoff base
DIARIZE_INCLUDE_TIMESTAMPS = False  # keep diarized output cleaner for lecture notes

# Chunk encoding (robust for "any random audio file")
AUDIO_BITRATE = "128k"

# Cleanup chunk files after successful run
CLEANUP_CHUNKS = True

# Terminal progress UI
PROGRESS_BAR_WIDTH = 24
PROGRESS_TICK_SECONDS = 0.25
ESTIMATED_REQUEST_SECONDS = 90

WORK_ROOT_DIR = Path(os.getenv("TRANSCRIBE_WORKDIR", ".")).expanduser()
TRANSCRIPTS_DIR = WORK_ROOT_DIR / "transcripts"
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
            subprocess.run(
                [
                    "security",
                    "add-generic-password",
                    "-U",
                    "-a",
                    KEYRING_USERNAME,
                    "-s",
                    KEYRING_SERVICE,
                    "-w",
                    key,
                ],
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


def ensure_api_key() -> None:
    env_key = os.getenv("OPENAI_API_KEY", "").strip()
    if is_valid_api_key(env_key):
        return

    saved_key = load_api_key_from_keyring()
    if is_valid_api_key(saved_key):
        os.environ["OPENAI_API_KEY"] = saved_key
        return

    print("OpenAI API key is required before transcription can start.")
    entered_key = getpass("Enter OPENAI_API_KEY (input hidden): ").strip()
    if not entered_key:
        raise SystemExit("No API key provided.")
    if not is_valid_api_key(entered_key):
        raise SystemExit("OPENAI_API_KEY looks malformed. It should start with 'sk-' and contain no whitespace/newlines.")

    os.environ["OPENAI_API_KEY"] = entered_key
    save_choice = input("Save API key securely in system keychain for future runs? [y/N]: ").strip().lower()
    if save_choice not in {"y", "yes"}:
        print("Using API key for this session only.")
        return

    if save_api_key_to_keyring(entered_key):
        print("Saved API key to system keychain.")
    else:
        detail = get_last_keychain_error()
        if detail:
            print(f"Could not save key to keychain: {detail}")
        else:
            print("Could not save key to keychain.")


def _candidate_tool_paths(tool_name: str) -> list[Path]:
    env_var = "FFMPEG_BIN" if tool_name == "ffmpeg" else "FFPROBE_BIN"
    candidates: list[Path] = []

    env_path = os.getenv(env_var, "").strip()
    if env_path:
        candidates.append(Path(env_path).expanduser())

    which_path = shutil.which(tool_name)
    if which_path:
        candidates.append(Path(which_path))

    if getattr(sys, "_MEIPASS", None):
        candidates.append(Path(str(sys._MEIPASS)) / BUNDLED_FFMPEG_DIR_NAME / tool_name)

    script_dir = Path(__file__).resolve().parent
    candidates.append(script_dir / BUNDLED_FFMPEG_DIR_NAME / tool_name)

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


def find_media_tool(tool_name: str) -> str | None:
    cached = _MEDIA_TOOL_CACHE.get(tool_name)
    if cached:
        p = Path(cached)
        if p.exists() and p.is_file() and os.access(p, os.X_OK):
            return cached
        _MEDIA_TOOL_CACHE.pop(tool_name, None)

    for p in _candidate_tool_paths(tool_name):
        try:
            if p.exists() and p.is_file() and os.access(p, os.X_OK) and _is_runnable_media_tool(p):
                resolved = str(p)
                _MEDIA_TOOL_CACHE[tool_name] = resolved
                return resolved
        except Exception:
            continue
    return None


def _tool_invocation_prefix(path: Path) -> list[str]:
    """
    On Apple Silicon, Evermeet's binaries are x86_64-only.
    If that's the case, run through Rosetta when available.
    """
    if platform.machine() != "arm64":
        return [str(path)]

    try:
        r = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=MEDIA_TOOL_CHECK_TIMEOUT_SECONDS,
        )
        archs = set(r.stdout.strip().split())
        if "x86_64" in archs and "arm64" not in archs:
            return ["/usr/bin/arch", "-x86_64", str(path)]
    except Exception:
        pass

    return [str(path)]


def get_media_tool_paths() -> dict[str, str | None]:
    return {
        "ffmpeg": find_media_tool("ffmpeg"),
        "ffprobe": find_media_tool("ffprobe"),
    }


def missing_media_tools() -> list[str]:
    paths = get_media_tool_paths()
    return [name for name in ("ffmpeg", "ffprobe") if not paths.get(name)]


def ffmpeg_bin() -> str:
    path = find_media_tool("ffmpeg")
    if path:
        return path
    raise SystemExit(
        "ffmpeg not found. Reinstall the latest app build (bundled ffmpeg), "
        "or install system ffmpeg with: brew install ffmpeg"
    )


def ffprobe_bin() -> str:
    path = find_media_tool("ffprobe")
    if path:
        return path
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


def ask_yes_no(prompt: str, default: str = "n") -> bool:
    default = default.lower()
    suffix = " [Y/n] " if default == "y" else " [y/N] "
    ans = input(prompt + suffix).strip().lower()
    if not ans:
        ans = default
    return ans in ("y", "yes")


def strip_outer_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and ((s[0] == s[-1] == '"') or (s[0] == s[-1] == "'")):
        return s[1:-1]
    return s


def unescape_drag_path(s: str) -> str:
    """
    When dragging into input(), Terminal often pastes escaped spaces like: /path/New\\ Recording.m4a
    Shell would normally unescape that, but input() won't. So we fix common escapes.
    """
    s = s.strip()
    s = s.replace("\\ ", " ")
    s = s.replace("\\(", "(").replace("\\)", ")")
    s = s.replace("\\[", "[").replace("\\]", "]")
    s = s.replace("\\&", "&")
    return s


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
    return "\n".join(lines) + "\n\n"


def get_audio_path_from_user() -> Path:
    if len(sys.argv) >= 2:
        raw = " ".join(sys.argv[1:])
    else:
        raw = input("Drag an audio file into this Terminal window, then press Enter:\n> ")

    raw = strip_outer_quotes(raw)
    raw = unescape_drag_path(raw)
    raw = os.path.expanduser(raw).strip()

    if not raw:
        raise SystemExit("No file path provided.")

    p = Path(raw)
    if not p.exists():
        raise SystemExit(f"File not found: {p}")
    return p


def get_duration_seconds(path: Path) -> float:
    """
    Uses ffprobe to read duration. Returns -1 if it can't be determined.
    """
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-nostdin",
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=nk=1:nw=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return float(r.stdout.strip())
    except Exception:
        return -1.0


def split_audio_to_chunks(input_path: Path, run_chunks_dir: Path, chunk_seconds: int) -> list[Path]:
    """
    Split input into chunk_seconds pieces.
    First tries stream copy (no quality loss). Falls back to AAC re-encode for robustness.
    """
    run_chunks_dir.mkdir(parents=True, exist_ok=True)

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
        "-segment_time", str(chunk_seconds),
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
    if parts:
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
        "-segment_time", str(chunk_seconds),
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


class ChunkProgressTracker:
    def __init__(self, parts: list[Path], label: str) -> None:
        self.enabled = sys.stdout.isatty()
        self.label = label
        self.rows = [
            {
                "name": p.name,
                "state": "pending",
                "fraction": 0.0,
                "status": "pending",
            }
            for p in parts
        ]
        self._line_count = len(self.rows) + 1
        self._rendered_once = False
        self._spinner_index = 0
        self._lock = threading.Lock()

        if self.enabled:
            self._render_locked()

    def start_attempt(self, idx: int, attempt: int, total_attempts: int) -> None:
        with self._lock:
            row = self.rows[idx]
            row["state"] = "running"
            row["fraction"] = max(0.01, float(row["fraction"]))
            row["status"] = f"running (attempt {attempt}/{total_attempts})"
            self._render_locked()

    def update_progress(self, idx: int, fraction: float, *, note: str | None = None) -> None:
        with self._lock:
            row = self.rows[idx]
            if row["state"] != "running":
                return
            row["fraction"] = max(float(row["fraction"]), min(0.95, max(0.0, fraction)))
            if note:
                row["status"] = note
            self._render_locked()

    def mark_retry(self, idx: int, attempt: int, total_attempts: int, delay_seconds: int) -> None:
        with self._lock:
            row = self.rows[idx]
            row["state"] = "running"
            row["fraction"] = 0.0
            row["status"] = (
                f"retrying in {delay_seconds}s "
                f"(attempt {attempt + 1}/{total_attempts})"
            )
            self._render_locked()

    def mark_done(self, idx: int) -> None:
        with self._lock:
            row = self.rows[idx]
            row["state"] = "done"
            row["fraction"] = 1.0
            row["status"] = "done"
            self._render_locked()

    def mark_failed(self, idx: int, err: Exception) -> None:
        with self._lock:
            row = self.rows[idx]
            row["state"] = "failed"
            row["fraction"] = 1.0
            row["status"] = f"failed: {str(err).splitlines()[0][:80]}"
            self._render_locked()

    def close(self) -> None:
        if self.enabled and self._rendered_once:
            sys.stdout.write("\n")
            sys.stdout.flush()

    def _render_locked(self) -> None:
        if not self.enabled:
            return

        self._spinner_index += 1
        done_count = sum(1 for r in self.rows if r["state"] == "done")
        failed_count = sum(1 for r in self.rows if r["state"] == "failed")
        header = (
            f"{self.label}: {done_count}/{len(self.rows)} done"
            f"{f', {failed_count} failed' if failed_count else ''}"
        )
        lines = [header]

        for i, row in enumerate(self.rows):
            frac = float(row["fraction"])
            filled = int(PROGRESS_BAR_WIDTH * frac)
            bar = "#" * filled + "-" * (PROGRESS_BAR_WIDTH - filled)
            pct = int(frac * 100)
            spinner = "-\\|/"[self._spinner_index % 4] if row["state"] == "running" else " "
            lines.append(
                f"{spinner} {i + 1:03d}/{len(self.rows):03d} {row['name']:<14} "
                f"[{bar}] {pct:3d}% {row['status']}"
            )

        if self._rendered_once:
            sys.stdout.write(f"\x1b[{self._line_count}A")
        for line in lines:
            sys.stdout.write("\x1b[2K\r" + line + "\n")
        sys.stdout.flush()
        self._rendered_once = True


def run_estimated_progress(
    stop_event: threading.Event,
    on_progress: Callable[[float], None],
) -> None:
    start = time.monotonic()
    while not stop_event.wait(PROGRESS_TICK_SECONDS):
        elapsed = time.monotonic() - start
        on_progress(min(0.95, elapsed / ESTIMATED_REQUEST_SECONDS))


def transcribe_chunk_text(
    client: OpenAI,
    chunk_path: Path,
    *,
    model: str = MODEL_NORMAL,
    chunk_idx: int | None = None,
    progress: ChunkProgressTracker | None = None,
) -> str:
    text = create_transcription_with_retry(
        client,
        chunk_path,
        model=model,
        response_format="text",
        chunk_idx=chunk_idx,
        progress=progress,
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


def _stop_progress_thread(
    stop_event: threading.Event | None,
    progress_thread: threading.Thread | None,
) -> None:
    if stop_event is not None:
        stop_event.set()
    if progress_thread is not None:
        progress_thread.join(timeout=0.5)


def create_transcription_with_retry(
    client: OpenAI,
    audio_path: Path,
    *,
    model: str,
    response_format: str,
    chunking_strategy: str | None = None,
    chunk_idx: int | None = None,
    progress: ChunkProgressTracker | None = None,
):
    use_progress = (
        progress is not None
        and progress.enabled
        and chunk_idx is not None
    )

    for attempt in range(1, MAX_TRANSCRIBE_RETRIES + 1):
        if use_progress:
            progress.start_attempt(chunk_idx, attempt, MAX_TRANSCRIBE_RETRIES)

        progress_thread = None
        stop_event = None
        if use_progress:
            stop_event = threading.Event()
            progress_thread = threading.Thread(
                target=run_estimated_progress,
                args=(stop_event, lambda frac: progress.update_progress(chunk_idx, frac)),
                daemon=True,
            )
            progress_thread.start()

        with audio_path.open("rb") as f:
            kwargs = {
                "model": model,
                "file": f,
                "response_format": response_format,
                "timeout": API_TIMEOUT_SECONDS,
            }
            if LANGUAGE:
                kwargs["language"] = LANGUAGE
            if chunking_strategy is not None:
                kwargs["chunking_strategy"] = chunking_strategy

            try:
                result = client.audio.transcriptions.create(**kwargs)
                if use_progress:
                    progress.mark_done(chunk_idx)
                return result
            except Exception as e:
                _stop_progress_thread(stop_event, progress_thread)

                if attempt == MAX_TRANSCRIBE_RETRIES or not is_retryable_transcription_error(e):
                    if use_progress:
                        progress.mark_failed(chunk_idx, e)
                    raise

                delay = RETRY_BASE_SECONDS * (2 ** (attempt - 1))
                if use_progress:
                    progress.mark_retry(chunk_idx, attempt, MAX_TRANSCRIBE_RETRIES, delay)
                else:
                    print(
                        f"Transient transcription error on {audio_path.name} "
                        f"(attempt {attempt}/{MAX_TRANSCRIBE_RETRIES}): {e}"
                    )
                    print(f"Retrying in {delay}s...")
                time.sleep(delay)
            finally:
                _stop_progress_thread(stop_event, progress_thread)


def diarize_whole_file(client: OpenAI, input_path: Path) -> str:
    """
    Single diarize request (only for shorter audio).
    """
    resp = create_transcription_with_retry(
        client,
        input_path,
        model=MODEL_DIARIZE,
        response_format="diarized_json",
        chunking_strategy="auto",
    )

    segments = extract_diarization_segments(resp)
    if not segments:
        return extract_transcription_text(resp)
    return "\n".join(format_diarized_lines(segments))


def diarize_chunk(
    client: OpenAI,
    chunk_path: Path,
    *,
    chunk_idx: int | None = None,
    progress: ChunkProgressTracker | None = None,
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
        chunk_idx=chunk_idx,
        progress=progress,
    )


def diarize_long_with_local_chunks(client: OpenAI, input_path: Path, run_chunks_dir: Path) -> str:
    """
    Split locally into ~10min chunks (600s) to reduce timeout risk, then offset timestamps.
    """
    parts = split_audio_to_chunks(input_path, run_chunks_dir, DIARIZE_CHUNK_SECONDS)

    out_lines = []
    progress = ChunkProgressTracker(parts, "Diarization Chunk Progress")
    offset_seconds = 0.0
    try:
        for i, p in enumerate(parts):
            chunk_duration = get_duration_seconds(p)
            chunk_span = chunk_duration if chunk_duration > 0 else DIARIZE_CHUNK_SECONDS

            if not progress.enabled:
                print(f"Diarizing {p.name} ...")

            resp = diarize_chunk(client, p, chunk_idx=i, progress=progress)
            segments = extract_diarization_segments(resp)

            if not segments:
                # fallback to whole chunk text
                out_lines.append(f"\n===== {p.name} =====\n")
                out_lines.extend(sentence_lines(extract_transcription_text(resp)))
                offset_seconds += chunk_span
                continue

            # Note: speaker letters (A/B/...) may reset per chunk.
            out_lines.extend(format_diarized_lines(segments, offset_seconds))

            offset_seconds += chunk_span
    finally:
        progress.close()
        cleanup_dir(run_chunks_dir)
    return "\n".join(out_lines)


def main():
    ensure_api_key()
    require_ffmpeg()
    require_ffprobe()

    input_path = get_audio_path_from_user()
    diarize = ask_yes_no("Add speaker labels (diarize)?", default="n")

    run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    stem = safe_stem_from_path(input_path)

    TRANSCRIPTS_DIR.mkdir(exist_ok=True)

    out_suffix = "_diarize" if diarize else ""
    out_path = TRANSCRIPTS_DIR / f"{stem}_{run_id}{out_suffix}.txt"

    client = OpenAI()
    working_input_path = input_path
    converted_temp_path: Path | None = None

    try:
        if input_path.suffix.lower() == ".qta":
            print("Detected .qta input. Converting to .m4a with stream copy (no re-encoding)...")
            converted_temp_path = convert_qta_to_m4a_copy(input_path, run_id)
            working_input_path = converted_temp_path

        if diarize:
            dur = get_duration_seconds(working_input_path)
            # If duration unknown, play it safe and do local chunking
            if 0 < dur <= DIARIZE_SINGLE_BUFFER:
                print("Transcribing with diarization (single request, server-side chunking_strategy=auto)...")
                content = diarize_whole_file(client, working_input_path)
                header = build_transcript_header(
                    input_path=input_path,
                    working_input_path=working_input_path,
                    model=MODEL_DIARIZE,
                    response_format="diarized_json",
                    chunking_strategy="auto",
                    duration_seconds=dur,
                )
            else:
                # Long audio: must local-chunk to respect diarize model duration cap
                print("Long audio detected (or duration unknown). Using local chunks for diarization...")
                run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}_diarize"
                content = diarize_long_with_local_chunks(client, working_input_path, run_chunks_dir)
                header = build_transcript_header(
                    input_path=input_path,
                    working_input_path=working_input_path,
                    model=MODEL_DIARIZE,
                    response_format="diarized_json",
                    chunking_strategy="auto",
                    local_chunk_seconds=DIARIZE_CHUNK_SECONDS,
                    duration_seconds=dur,
                )

            out_path.write_text(header + content, encoding="utf-8")
            print(f"\n✅ Done. Wrote: {out_path.resolve()}")
            return

        # Non-diarize: always local split into 10-minute chunks (reliable for 60+ minutes)
        run_chunks_dir = CHUNKS_ROOT_DIR / f"{stem}_{run_id}"
        parts = split_audio_to_chunks(working_input_path, run_chunks_dir, NORMAL_CHUNK_SECONDS)
        progress = ChunkProgressTracker(parts, "Transcription Chunk Progress")

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
                    out.write(f"\n\n===== {p.name} ({hhmmss(start)}–{hhmmss(end)}) =====\n\n")
                    if not progress.enabled:
                        print(f"Transcribing {p.name} ...")
                    chunk_text = transcribe_chunk_text(client, p, chunk_idx=i, progress=progress)
                    lines = sentence_lines(chunk_text)
                    if lines:
                        out.write("\n".join(lines))
                    else:
                        out.write(str(chunk_text))
        finally:
            progress.close()
            cleanup_dir(run_chunks_dir)
        print(f"\n✅ Done. Wrote: {out_path.resolve()}")
    finally:
        if converted_temp_path and converted_temp_path.exists():
            try:
                converted_temp_path.unlink()
            except Exception:
                pass


if __name__ == "__main__":
    main()
