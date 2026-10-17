from __future__ import annotations

import json
import math
import os
import re
import sys
import time
import shutil
import subprocess
import platform
import threading
from dataclasses import dataclass
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
# 5-minute chunks dropped fewer words and lines than 10-minute ones in side-by-side tests on every model.
DEFAULT_CHUNK_SECONDS = 5 * 60
CHUNK_SECONDS_CHOICES = (5 * 60, 10 * 60)  # lengths the user can pick

# Diarization model + constraints
MODEL_DIARIZE = "gpt-4o-transcribe-diarize"
DIARIZE_MAX_SECONDS = 1400          # hard cap observed from API error
DIARIZE_SINGLE_BUFFER = 1300        # be conservative: single request only if <= 1300s
DIARIZE_CHUNK_SECONDS = 10 * 60     # smaller chunks reduce timeout risk on long recordings

# Subtitles (.srt). Only the diarize model returns a start and end time for what it hears (the GPT-4o and
# gpt-transcribe models return text alone), so subtitle runs always use it. Its segments can run long, so
# each one is split into cues that fit on screen, with the segment's time shared out by length of text.
# Limits follow Netflix's English (USA) Timed Text Style Guide and its Subtitle Timing Guidelines.
SUBTITLE_LINE_CHARS = 42            # characters per line
SUBTITLE_MAX_LINES = 2
SUBTITLE_MAX_SECONDS = 7.0          # longest a cue stays on screen
SUBTITLE_MIN_SECONDS = 5 / 6        # shortest a cue stays on screen (20 frames at 24fps)
SUBTITLE_READING_CPS = 20.0         # adult reading speed, characters per second; slower text stays up longer
SUBTITLE_LINGER_SECONDS = 0.5       # a cue stays up this long after its speech ends, so it isn't gone mid-read
SUBTITLE_MIN_GAP_SECONDS = 2 / 24   # 2 frames between cues, so the eye sees one cue replace another
SUBTITLE_CHAIN_GAP_SECONDS = 0.5    # shorter gaps than this look like flicker, so the earlier cue is held to the next
# When a short line would be replaced before it can be read, it shares a cue with the next line: as one
# block of text if the same person keeps talking, or one dash-prefixed line per speaker ("-Where were you?" /
# "-Out.") when someone answers.
SUBTITLE_DIALOGUE_DASH = "-"        # Netflix English style: a hyphen with no space
SUBTITLE_SENTENCE_ENDS = (".", "?", "!", "…", '"', "”")

# gpt-transcribe safeguards. Without a `languages` hint it drops speech; even with one it can
# occasionally return no text (reported as `"languages": []`) or loop on repeated phrases.
DEFAULT_LANGUAGES = ["en"]
GPT_TRANSCRIBE_RETRIES = 2           # extra attempts (same model) when a chunk's output fails a check
MAX_PLAUSIBLE_WORDS_PER_MINUTE = 350 # faster than anyone speaks; more means the model repeated itself

# Repeated-passage check (every model). Models occasionally loop and transcribe a stretch twice, which
# the words-per-minute check misses when the chunk was only partly repeated. Short repeats are normal
# speech ("Almost there. Almost there."); only a long run of mostly repeated wording is flagged.
REPEAT_PHRASE_WORDS = 8             # wording is compared in overlapping phrases of this many words
REPEAT_MIN_WORDS = 50               # shortest repeated passage that is flagged
REPEAT_MATCH_SHARE = 0.7            # share of a passage's phrases that must repeat (allows small differences)

# Context prompt. The user's description of the recording goes with every chunk; when context is
# carried between chunks, the end of the previous chunk's transcript is added so sentences and names
# that cross a cut stay consistent. The diarize model doesn't accept a prompt.
PROMPT_MODELS = {MODEL_GPT_TRANSCRIBE, MODEL_NORMAL, MODEL_MINI}
CONTEXT_TAIL_CHARS = 300            # how much of the previous chunk's transcript is carried over
ECHO_MIN_WORDS = 4                  # shortest repeat of that excerpt removed from the next chunk's start

# Keywords: literal terms (names, jargon) gpt-transcribe should expect to hear. Only gpt-transcribe accepts
# them, and the API rejects the whole request if a keyword contains one of these characters.
KEYWORD_MODELS = {MODEL_GPT_TRANSCRIBE}
KEYWORD_FORBIDDEN_CHARS = "<>"

# GPT-4o output cap. gpt-4o-transcribe and gpt-4o-mini-transcribe stop writing after 2,048 output tokens
# (about 1,550 words) and return what they have without an error: a 20-minute test chunk came back with
# output_tokens == 2048 and the last 40% missing. A chunk that reaches the cap is split at a pause and
# each piece is transcribed on its own. gpt-transcribe has no such cap (the same chunk came back whole).
GPT4O_OUTPUT_TOKEN_LIMIT = 2048
GPT4O_OUTPUT_LIMITED_MODELS = {MODEL_NORMAL, MODEL_MINI}
MAX_OUTPUT_SPLIT_DEPTH = 2          # halve a capped chunk at most twice (a 10-minute chunk becomes 2.5-minute pieces)
MIN_OUTPUT_SPLIT_SECONDS = 60       # pieces shorter than this that still hit the cap are looping, not long

# API request behavior
API_TIMEOUT_SECONDS = 20 * 60       # per-request timeout (seconds)
MAX_TRANSCRIBE_RETRIES = 4          # retries for transient API/network errors
RETRY_BASE_SECONDS = 2              # exponential backoff base
DIARIZE_INCLUDE_TIMESTAMPS = False  # keep diarized output cleaner for lecture notes

# Chunk encoding (robust for "any random audio file")
AUDIO_BITRATE = "128k"
# Re-encoded audio is downmixed to mono: speech models use one channel, and surround sources keep
# dialogue in the center channel, which can get lost when the API receives unlabeled 5.1 audio.
AUDIO_CHANNELS = "1"
MAX_COPY_CHANNELS = 2               # sources with more channels are always re-encoded, never copied
# The API rejects uploads over 25 MB. Copied chunks keep the source bitrate, so any bigger than this
# are re-encoded instead (mono 128k AAC stays under it for every chunk length used here).
MAX_UPLOAD_BYTES = 24 * 1024 * 1024

# Chunk boundaries move back to the quietest moment in the stretch before each cut, so a
# sentence isn't sliced in half (the model can't transcribe half a word on either side).
SPLIT_SEARCH_SECONDS = 60           # how far back from each nominal cut to look for a pause
SPLIT_FRAME_SECONDS = 0.1           # loudness is measured per frame of this length
SPLIT_PAUSE_FRAMES = 5              # frames averaged together, so the cut lands in a ~0.5s pause
# Share of split_audio_to_chunks' reported progress spent finding pauses; ffmpeg writing chunks gets the
# rest. On a 21-minute surround episode finding pauses took 0.6s and converting and splitting 6.3s.
SPLIT_PLAN_SHARE = 0.1

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


_MACHO_CPU_TYPES = {0x0100000C: "arm64", 0x01000007: "x86_64"}


def _binary_architectures(path: Path) -> set[str]:
    """
    Read architectures from the Mach-O header directly. /usr/bin/lipo is a stub on Macs
    without the Command Line Tools and would prompt the user to install them.
    """
    try:
        with open(path, "rb") as handle:
            header = handle.read(8)
            if len(header) < 8:
                return set()
            if header[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
                cpu_type = int.from_bytes(header[4:8], "little")
                return {_MACHO_CPU_TYPES.get(cpu_type, hex(cpu_type))}
            if header[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
                arch_entry_size = 32 if header[3] == 0xBF else 20
                arch_count = int.from_bytes(header[4:8], "big")
                archs: set[str] = set()
                for _ in range(min(arch_count, 16)):
                    entry = handle.read(arch_entry_size)
                    if len(entry) < arch_entry_size:
                        break
                    cpu_type = int.from_bytes(entry[:4], "big")
                    archs.add(_MACHO_CPU_TYPES.get(cpu_type, hex(cpu_type)))
                return archs
        return set()
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


# Where one sentence ends and the next begins. Besides punctuation followed by a space, this breaks where
# the model left the space out ("why not?What if"). It never breaks after a title ("Dr. Doom") or before a
# lowercase word ("U.S.A. is"), since neither starts a new sentence.
SENTENCE_BREAK = re.compile(
    r"(?<!\bMr\.)(?<!\bMrs\.)(?<!\bMs\.)(?<!\bDr\.)(?<!\bSt\.)(?<!\bJr\.)(?<!\bProf\.)"
    r"(?:(?<=[.!?])\s+(?![a-z])|(?<=[a-z0-9][.!?])(?=[A-Z])|(?<=[a-z0-9]\.\.\.)(?=[A-Z]))"
)


def sentence_lines(text: str) -> list[str]:
    cleaned = " ".join(str(text or "").split())
    if not cleaned:
        return []
    return [s.strip() for s in SENTENCE_BREAK.split(cleaned) if s.strip()]


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


def srt_timestamp(seconds: float) -> str:
    ms = max(0, int(round(seconds * 1000)))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


# Where a subtitle may break, after Netflix's English line-break rules: break after punctuation, before a
# conjunction or preposition; never between an article and its noun, a preposition and its object, a subject
# pronoun or auxiliary and its verb, a verb and "not", or a first and last name. Lower cost is better.
_BREAK_CONJUNCTIONS = frozenset(
    "and but or nor so yet because that which who whom whose when whenever while if unless until although "
    "though since where whether than".split()
)
_BREAK_PREPOSITIONS = frozenset(
    "to in on at with from for of about into onto over under after before through without between around "
    "across against during behind near toward towards like by".split()
)
_BREAK_DETERMINERS = frozenset(
    "the a an this these those my your his her its our their some any no every each".split()
)
_BREAK_SUBJECT_PRONOUNS = frozenset("i we they he she".split())
_BREAK_AUXILIARIES = frozenset(
    "am is are was were be been being have has had do does did will would shall should can could may might "
    "must i'm you're we're they're he's she's it's i've you've we've they've i'll you'll we'll they'll i'd "
    "you'd we'd they'd don't doesn't didn't won't wouldn't can't couldn't shouldn't isn't aren't wasn't "
    "weren't haven't hasn't hadn't not".split()
)
_SENTENCE_END_PUNCTUATION = (".", "?", "!", "…")
_PAUSE_PUNCTUATION = (",", ";", ":", "—", "–", "-")
_QUOTE_CHARS = "\"'“”‘’()[]"
BREAK_BALANCE_CHARS = 10            # this many characters of uneven length cost as much as one rule point


def _bare_word(word: str) -> str:
    return word.strip(_QUOTE_CHARS).lower().replace("’", "'")


def _break_cost(left: str, right: str) -> float:
    """Cost of ending a line or cue after `left` and starting the next with `right`."""
    tail = left.rstrip(_QUOTE_CHARS)
    if tail.endswith(_SENTENCE_END_PUNCTUATION):
        return -6.0
    if tail.endswith(_PAUSE_PUNCTUATION):
        return -4.0
    before, after = _bare_word(left), _bare_word(right)
    cost = 0.0
    if after in _BREAK_CONJUNCTIONS:
        cost -= 2.0
    elif after in _BREAK_PREPOSITIONS:
        cost -= 1.0
    if before in _BREAK_DETERMINERS:
        cost += 6.0
    if before in _BREAK_PREPOSITIONS or before in _BREAK_SUBJECT_PRONOUNS or before in _BREAK_AUXILIARIES:
        cost += 4.0
    if before in _BREAK_CONJUNCTIONS:
        cost += 3.0  # "and" belongs at the start of the next line, not the end of this one
    if after == "not":
        cost += 4.0
    if left[:1].isupper() and right[:1].isupper() and before != "i":
        cost += 3.0  # likely a name ("John | Smith")
    return cost


def _joined_length(words: list[str], start: int, stop: int) -> int:
    return sum(len(w) for w in words[start:stop]) + max(0, stop - start - 1)


def _length_cost(length: int, target: float, limit: int) -> float:
    return abs(length - target) / BREAK_BALANCE_CHARS + 100.0 * max(0, length - limit)


def wrap_subtitle_text(text: str, line_chars: int = SUBTITLE_LINE_CHARS) -> list[str]:
    """
    One line if it fits, otherwise two lines broken at the best place (see _break_cost), keeping both lines
    within the limit and close in length, with the bottom line the longer one when it's a close call.
    """
    words = text.split()
    if len(text) <= line_chars or len(words) < 2:
        return [text]
    total = _joined_length(words, 0, len(words))

    def cost(k: int) -> float:
        top, bottom = _joined_length(words, 0, k), _joined_length(words, k, len(words))
        shape = 0.5 if top > bottom else 0.0  # Netflix prefers a bottom-heavy pyramid
        return (
            _break_cost(words[k - 1], words[k])
            + _length_cost(top, total / 2, line_chars)
            + _length_cost(bottom, total / 2, line_chars)
            + shape
        )

    k = min(range(1, len(words)), key=cost)
    return [" ".join(words[:k]), " ".join(words[k:])]


def _split_at_best_breaks(text: str, parts: int, max_chars: int) -> list[str]:
    """Splits text into `parts` pieces of at most max_chars, choosing breaks by _break_cost and even length."""
    words = text.split()
    if parts <= 1 or len(words) < parts:
        return [text]
    target = _joined_length(words, 0, len(words)) / parts
    m = len(words)
    # best[j][k]: lowest cost of splitting words[:k] into j pieces; back[j][k]: where the last piece starts.
    best = [[math.inf] * (m + 1) for _ in range(parts + 1)]
    back = [[0] * (m + 1) for _ in range(parts + 1)]
    best[0][0] = 0.0
    for j in range(1, parts + 1):
        for k in range(j, m - (parts - j) + 1):
            for a in range(j - 1, k):
                if best[j - 1][a] == math.inf:
                    continue
                c = best[j - 1][a] + _length_cost(_joined_length(words, a, k), target, max_chars)
                if a > 0:
                    c += _break_cost(words[a - 1], words[a])
                if c < best[j][k]:
                    best[j][k], back[j][k] = c, a
    pieces: list[str] = []
    k = m
    for j in range(parts, 0, -1):
        a = back[j][k]
        pieces.append(" ".join(words[a:k]))
        k = a
    return pieces[::-1]


def subtitle_pieces(text: str, max_chars: int = SUBTITLE_LINE_CHARS * SUBTITLE_MAX_LINES) -> list[str]:
    """Splits one segment's text into cue texts: whole sentences packed together, long ones split at natural breaks."""
    groups: list[str] = []
    for sentence in sentence_lines(text):
        if groups and len(groups[-1]) + 1 + len(sentence) <= max_chars:
            groups[-1] += " " + sentence
        else:
            groups.append(sentence)
    pieces: list[str] = []
    for group in groups:
        pieces.extend(_split_at_best_breaks(group, math.ceil(len(group) / max_chars), max_chars))
    return pieces


@dataclass
class SubtitleCue:
    start: float
    # When the cue's speech ends (estimated when a long segment was split); the on-screen end is set by format_srt.
    end: float
    text: str
    # Who speaks, scoped to one chunk (the diarize model's labels restart in every request); None if unknown.
    speaker: Any = None
    # Set for a two-speaker cue: one dash-prefixed line per speaker, shown as is.
    lines: tuple[str, ...] | None = None


def subtitle_cues(segments: list[Any], offset_seconds: float = 0.0, chunk: int = 0) -> list[SubtitleCue]:
    """Cues for timed diarize segments, shifted by the chunk's offset in the recording."""
    cues: list[SubtitleCue] = []
    for seg in segments:
        speaker, start, end, text = _segment_fields(seg)
        text = " ".join(text.split())
        if start is None or end is None or not text:
            continue
        end = max(end, start)
        speaker_key = (chunk, speaker) if speaker is not None else None
        pieces = subtitle_pieces(text)
        total_chars = sum(len(p) for p in pieces)
        t = start
        for piece in pieces:
            share = (end - start) * len(piece) / total_chars
            cues.append(SubtitleCue(offset_seconds + t, offset_seconds + t + share, piece, speaker_key))
            t += share
    return cues


def _reading_seconds(chars: int) -> float:
    """How long a cue with this many characters needs on screen to be read."""
    return max(SUBTITLE_MIN_SECONDS, chars / SUBTITLE_READING_CPS)


def _cue_chars(cue: SubtitleCue) -> int:
    return sum(len(line) for line in cue.lines) if cue.lines else len(cue.text)


def merge_quick_cues(cues: list[SubtitleCue]) -> list[SubtitleCue]:
    """
    Joins a cue with the next one when the next starts before the first can be read, if both fit in one cue
    and in the longest time a cue may stay up (a joined cue can join the next one again). The same speaker's lines are joined as text. Two speakers
    (in the same chunk, since labels restart in each) get one dash-prefixed line each, when each line is one
    whole sentence that fits on a line with its dash.
    """
    def fits_dialogue_line(cue: SubtitleCue) -> bool:
        return (
            len(cue.text) + len(SUBTITLE_DIALOGUE_DASH) <= SUBTITLE_LINE_CHARS
            and cue.text.endswith(SUBTITLE_SENTENCE_ENDS)
            and len(sentence_lines(cue.text)) == 1
        )

    ordered = sorted(cues, key=lambda cue: cue.start)
    merged: list[SubtitleCue] = []
    i = 0
    while i < len(ordered):
        first = ordered[i]
        second = ordered[i + 1] if i + 1 < len(ordered) else None
        quick = (
            second is not None
            and first.speaker is not None
            and second.speaker is not None
            and first.lines is None
            and second.lines is None
            # The first line gets less time than it needs before the next one starts.
            and second.start - first.start < _reading_seconds(len(first.text)) + SUBTITLE_LINGER_SECONDS
            and second.end - first.start <= SUBTITLE_MAX_SECONDS
        )
        if quick and first.speaker == second.speaker and (
            len(first.text) + 1 + len(second.text) <= SUBTITLE_LINE_CHARS * SUBTITLE_MAX_LINES
        ):
            # The joined cue takes the next one's place, so a run of quick lines can keep joining while it fits.
            ordered[i + 1] = SubtitleCue(
                first.start, max(first.end, second.end), f"{first.text} {second.text}", first.speaker
            )
            i += 1
        elif (
            quick
            and first.speaker[0] == second.speaker[0]  # same chunk
            and fits_dialogue_line(first)
            and fits_dialogue_line(second)
        ):
            merged.append(SubtitleCue(
                start=first.start,
                end=max(first.end, second.end),
                text=f"{first.text} {second.text}",
                speaker=None,
                lines=(SUBTITLE_DIALOGUE_DASH + first.text, SUBTITLE_DIALOGUE_DASH + second.text),
            ))
            i += 2
        else:
            merged.append(first)
            i += 1
    return merged


def time_subtitle_cues(cues: list[SubtitleCue]) -> list[tuple[float, float, SubtitleCue]]:
    """
    (start, on-screen end, cue) for each cue, in order. A cue appears when its speech starts and stays up
    until its speech ends plus a short linger, or longer if its text needs more reading time, but never past
    7 seconds or into the next cue (a 2-frame gap is kept). A gap shorter than half a second is closed, since
    a cue blinking off and straight back on reads as flicker. Speech that overlaps the next cue keeps its time.
    """
    ordered = sorted(cues, key=lambda cue: cue.start)
    timed: list[tuple[float, float, SubtitleCue]] = []
    for i, cue in enumerate(ordered):
        start = cue.start
        next_start = ordered[i + 1].start if i + 1 < len(ordered) else math.inf
        latest = start + SUBTITLE_MAX_SECONDS
        speech_end = min(cue.end, latest)
        wanted = min(max(speech_end + SUBTITLE_LINGER_SECONDS, start + _reading_seconds(_cue_chars(cue))), latest)
        limit = next_start - SUBTITLE_MIN_GAP_SECONDS
        # Only speech that really overlaps the next cue (two people talking at once) runs into it; pieces of one
        # segment, which end exactly where the next begins, keep the 2-frame gap.
        floor = speech_end if speech_end > next_start + SUBTITLE_MIN_GAP_SECONDS else min(speech_end, limit)
        end = max(min(wanted, limit), floor)
        if 0 < limit - end < SUBTITLE_CHAIN_GAP_SECONDS - SUBTITLE_MIN_GAP_SECONDS and limit <= latest:
            end = limit
        timed.append((start, end, cue))
    return timed


def format_srt(cues: list[SubtitleCue]) -> str:
    """SubRip text for the cues: quick two-speaker exchanges merged, then timed to the standards above."""
    blocks: list[str] = []
    for n, (start, end, cue) in enumerate(time_subtitle_cues(merge_quick_cues(cues)), start=1):
        lines = "\n".join(cue.lines or wrap_subtitle_text(cue.text))
        blocks.append(f"{n}\n{srt_timestamp(start)} --> {srt_timestamp(end)}\n{lines}")
    return "\n\n".join(blocks) + "\n"


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
    context: str | None = None,
    keywords: list[str] | None = None,
    consistency_mode: bool | None = None,
    chunk_warnings: list[str] | None = None,
) -> str:
    """
    context: the prompt sent with each chunk ("" if none); None leaves the line out (e.g. speaker labels).
    keywords: the keywords sent with each chunk; empty or None leaves the line out.
    """
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
    if context is not None:
        # One line, so a multi-line context can't push the header into the transcript.
        lines.append(f"CONTEXT: {' '.join(context.split()) or 'none'}")
    if keywords:
        lines.append(f"KEYWORDS: {', '.join(keywords)}")
    if consistency_mode is not None:
        lines.append(f"CONSISTENCY_MODE: {'on' if consistency_mode else 'off'}")
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


def list_audio_tracks(path: Path) -> list[dict[str, Any]]:
    """
    The file's audio tracks in order, as {"index", "language", "title", "codec", "channels", "default"}.
    `index` counts audio tracks only (0 is the first), matching ffmpeg's `0:a:N`. Empty if ffprobe can't read it.
    """
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-v", "error",
                "-select_streams", "a",
                "-show_entries", "stream=codec_name,channels:stream_tags=language,title:stream_disposition=default",
                "-of", "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            # ffprobe has no -nostdin flag (it made every call fail); keep it off stdin this way instead.
            stdin=subprocess.DEVNULL,
            timeout=30,
        )
        streams = json.loads(r.stdout or "{}").get("streams") or []
    except Exception:
        return []

    tracks: list[dict[str, Any]] = []
    for i, stream in enumerate(streams):
        tags = stream.get("tags") or {}
        language = str(tags.get("language") or "").strip().lower()
        tracks.append({
            "index": i,
            # "und" is how containers mark an unknown language.
            "language": "" if language in ("", "und") else language,
            "title": str(tags.get("title") or "").strip(),
            "codec": str(stream.get("codec_name") or ""),
            "channels": stream.get("channels"),
            "default": bool((stream.get("disposition") or {}).get("default")),
        })
    return tracks


def audio_codec_name(path: Path, audio_track: int = 0) -> str | None:
    """Codec of the given audio track (e.g. "aac", "mp3"), or None if ffprobe can't tell."""
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-v", "error",
                "-select_streams", f"a:{audio_track}",
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
        return str(r.stdout or "").strip().lower() or None
    except Exception:
        return None


def _copied_m4a_chunk_is_transcribable(path: Path) -> bool:
    """
    Stream-copying into .m4a is only safe when the resulting audio stream is AAC.
    """
    return audio_codec_name(path) == "aac"


def audio_channel_count(path: Path, audio_track: int = 0) -> int | None:
    """Channels in the given audio track, or None if ffprobe can't tell."""
    try:
        r = subprocess.run(
            [
                *ffprobe_cmd_prefix(),
                "-v", "error",
                "-select_streams", f"a:{audio_track}",
                "-show_entries", "stream=channels",
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
        return int(str(r.stdout or "").strip().splitlines()[0])
    except Exception:
        return None


def _quietest_point(
    input_path: Path, window_start: float, window_seconds: float, audio_track: int = 0
) -> float | None:
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
        "-map", f"0:a:{audio_track}",
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


def plan_chunk_cuts(
    input_path: Path,
    chunk_seconds: int,
    on_progress: Callable[[float], None] | None = None,
    audio_track: int = 0,
) -> list[float]:
    """
    Cut times (seconds) for splitting into chunks of at most chunk_seconds, each moved back to the
    quietest moment before the nominal cut. Empty when the audio fits in one chunk or its length is unknown.
    on_progress receives the share of the audio planned so far (0 to 1).
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
        cut = _quietest_point(input_path, window_start, search, audio_track)
        if cut is None or not (window_start <= cut <= target):
            cut = target
        cuts.append(cut)
        previous = cut
        if on_progress:
            on_progress(previous / total)
    return cuts


def _run_ffmpeg_with_progress(
    cmd: list[str],
    total_seconds: float,
    on_progress: Callable[[float], None] | None,
    *,
    quiet: bool = False,
) -> None:
    """
    Run an ffmpeg command that includes `-progress pipe:1`, passing the share of the input processed so
    far (0 to 1) to on_progress. Raises like subprocess.run(cmd, check=True, timeout=...). quiet hides
    ffmpeg's error output.
    """
    timed_out = threading.Event()
    with subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL if quiet else None,
        text=True,
        errors="replace",
    ) as proc:

        def kill_after_timeout() -> None:
            timed_out.set()
            proc.kill()

        timer = threading.Timer(MEDIA_PROCESS_TIMEOUT_SECONDS, kill_after_timeout)
        timer.start()
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                # out_time_us is the position reached in the input; it keeps counting across segments.
                if on_progress and total_seconds > 0 and line.startswith("out_time_us="):
                    try:
                        done_seconds = int(line.split("=", 1)[1]) / 1_000_000
                    except ValueError:
                        continue  # "N/A" until the first audio is written
                    on_progress(min(max(done_seconds / total_seconds, 0.0), 1.0))
            proc.wait()
        except BaseException:
            proc.kill()
            raise
        finally:
            timer.cancel()
    if timed_out.is_set():
        raise subprocess.TimeoutExpired(cmd, MEDIA_PROCESS_TIMEOUT_SECONDS)
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)


def split_audio_to_chunks(
    input_path: Path,
    run_chunks_dir: Path,
    chunk_seconds: int,
    on_progress: Callable[[float], None] | None = None,
    audio_track: int = 0,
) -> list[Path]:
    """
    Split input into pieces of at most chunk_seconds, cutting at pauses (see plan_chunk_cuts).
    Only `audio_track` (0 = the first audio track) is used; videos can carry one track per language.
    Mono/stereo AAC is stream-copied (no quality loss) when every piece fits under MAX_UPLOAD_BYTES;
    anything else, including surround audio, is re-encoded to mono AAC.
    on_progress receives how far along the split is (0 to 1).
    """
    run_chunks_dir.mkdir(parents=True, exist_ok=True)

    reported = 0.0

    def report(fraction: float) -> None:
        # Never move backwards, e.g. when a finished copy is rejected and the audio is re-encoded.
        nonlocal reported
        if on_progress and fraction > reported:
            reported = fraction
            on_progress(fraction)

    def report_writing(fraction: float) -> None:
        report(SPLIT_PLAN_SHARE + (1 - SPLIT_PLAN_SHARE) * fraction)

    total = get_duration_seconds(input_path)
    cuts = plan_chunk_cuts(
        input_path, chunk_seconds, on_progress=lambda f: report(SPLIT_PLAN_SHARE * f), audio_track=audio_track
    )
    report(SPLIT_PLAN_SHARE)
    if cuts:
        segment_args = ["-segment_times", ",".join(f"{c:.3f}" for c in cuts)]
    else:
        segment_args = ["-segment_time", str(chunk_seconds)]

    for old in run_chunks_dir.glob("part_*.m4a"):
        old.unlink()

    channels = audio_channel_count(input_path, audio_track)
    # Only AAC can be copied into .m4a. Other codecs skip straight to re-encoding: MP3 would copy
    # fine but then be rejected, and WAV would fail to copy at all.
    if (channels is None or channels <= MAX_COPY_CHANNELS) and audio_codec_name(input_path, audio_track) in (None, "aac"):
        copy_cmd = [
            *ffmpeg_cmd_prefix(),
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-progress", "pipe:1",
            "-nostats",
            "-i", str(input_path),
            "-vn",
            "-f", "segment",
            *segment_args,
            "-reset_timestamps", "1",
            "-map", f"0:a:{audio_track}",
            "-c:a", "copy",
            str(run_chunks_dir / "part_%03d.m4a"),
        ]
        try:
            # A failed copy is handled by re-encoding below, so ffmpeg's error output is kept out of the log.
            _run_ffmpeg_with_progress(copy_cmd, total, report_writing, quiet=True)
            copy_finished = True
        except Exception:
            copy_finished = False

        parts = sorted(run_chunks_dir.glob("part_*.m4a"))
        # A copy that stopped partway leaves only the first chunks, which would silently drop the rest.
        if (
            copy_finished
            and parts
            and all(p.stat().st_size <= MAX_UPLOAD_BYTES for p in parts)
            and all(_copied_m4a_chunk_is_transcribable(p) for p in parts[: min(2, len(parts))])
        ):
            return parts

    for old in run_chunks_dir.glob("part_*.m4a"):
        old.unlink()

    reencode_cmd = [
        *ffmpeg_cmd_prefix(),
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-progress", "pipe:1",
        "-nostats",
        "-i", str(input_path),
        "-vn",
        "-f", "segment",
        *segment_args,
        "-reset_timestamps", "1",
        "-map", f"0:a:{audio_track}",
        "-c:a", "aac",
        "-ac", AUDIO_CHANNELS,
        "-b:a", AUDIO_BITRATE,
        str(run_chunks_dir / "part_%03d.m4a"),
    ]
    try:
        _run_ffmpeg_with_progress(reencode_cmd, total, report_writing)
    except subprocess.TimeoutExpired:
        raise SystemExit(
            "Chunking audio timed out while running ffmpeg. "
            "Try a shorter file or check local ffmpeg health."
        ) from None

    parts = sorted(run_chunks_dir.glob("part_*.m4a"))
    if not parts:
        raise SystemExit("No chunks created. Is the input a valid audio file?")
    return parts


def convert_qta_to_m4a_copy(input_path: Path, run_id: str, audio_track: int = 0) -> Path:
    """
    Convert .qta (QuickTime container) to .m4a with stream copy to avoid quality loss.
    The result holds only `audio_track`, so it is the converted file's first (and only) track.
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
        "-map", f"0:a:{audio_track}",
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
            "-map", f"0:a:{audio_track}",
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
        "-ac", AUDIO_CHANNELS,
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


def parse_keywords(raw: str) -> list[str]:
    """
    Parse keywords separated by commas or new lines, dropping blanks and repeats (ignoring case).
    Raises ValueError for a keyword the API would reject.
    """
    keywords: list[str] = []
    seen: set[str] = set()
    for token in re.split(r"[,\r\n]+", raw):
        keyword = " ".join(token.split())
        if not keyword:
            continue
        if any(c in keyword for c in KEYWORD_FORBIDDEN_CHARS):
            raise ValueError(f"'{keyword}' contains < or >, which OpenAI doesn't accept in keywords.")
        if keyword.casefold() not in seen:
            seen.add(keyword.casefold())
            keywords.append(keyword)
    return keywords


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


def find_repeated_passage(text: str) -> tuple[int, str] | None:
    """
    Find the longest passage of at least REPEAT_MIN_WORDS words that mostly repeats earlier wording
    in `text`. Returns (approximate length in words, its opening words) or None.
    """
    words = text.split()
    keys = [_word_key(w) for w in words]
    n = REPEAT_PHRASE_WORDS
    if len(keys) < REPEAT_MIN_WORDS + n:
        return None

    # repeated[i]: the phrase starting at word i already appeared earlier, without overlapping itself.
    first_seen: dict[tuple[str, ...], int] = {}
    repeated = [False] * len(keys)
    for i in range(len(keys) - n + 1):
        phrase = tuple(keys[i : i + n])
        earlier = first_seen.setdefault(phrase, i)
        if earlier + n <= i:
            repeated[i] = True

    # Slide a REPEAT_MIN_WORDS window and merge windows where enough phrases repeat into passages.
    window = REPEAT_MIN_WORDS
    needed = REPEAT_MATCH_SHARE * window
    count = sum(repeated[:window])
    best: tuple[int, int] | None = None
    start = end = -1
    for i in range(len(keys) - window + 1):
        if i > 0:
            count += repeated[i + window - 1] - repeated[i - 1]
        if count >= needed:
            if i > end:
                start = i
            end = i + window
            if best is None or end - start > best[1] - best[0]:
                best = (start, end)
    if best is None:
        return None
    first = next(i for i in range(best[0], best[1]) if repeated[i])
    opening = " ".join(words[first : first + 8])
    return best[1] - first, opening


def build_chunk_prompt(context: str | None, previous_tail: str | None) -> str | None:
    """The prompt for one chunk: the user's context, then the previous chunk's closing words if any."""
    parts = []
    if context and context.strip():
        parts.append(context.strip())
    if previous_tail:
        parts.append(f'The recording begins right after this transcript excerpt:\n"…{previous_tail}"')
    return "\n\n".join(parts) or None


def transcript_tail(text: str, max_chars: int = CONTEXT_TAIL_CHARS) -> str:
    """The last whole sentences of `text` that fit in `max_chars`, or the end of one long sentence."""
    tail: list[str] = []
    length = 0
    for sentence in reversed(sentence_lines(text)):
        if tail and length + 1 + len(sentence) > max_chars:
            break
        tail.insert(0, sentence)
        length += len(sentence) + (1 if length else 0)
    joined = " ".join(tail)
    if len(joined) > max_chars:
        # A single sentence longer than the limit: keep its end, starting at a word boundary.
        cut = joined[-max_chars:]
        space = cut.find(" ")
        joined = cut[space + 1:] if 0 <= space < len(cut) - 1 else cut
    return joined


def _word_key(word: str) -> str:
    return re.sub(r"[^\w]", "", word.casefold())


def strip_echoed_tail(text: str, tail: str) -> tuple[str, int]:
    """
    Remove the previous chunk's closing words if the model repeated them at the start of `text`.
    Returns (text, number of words removed). Short overlaps are left alone, since a speaker can
    genuinely say the same couple of words again.
    """
    words = text.split()
    keys = [_word_key(w) for w in words]
    tail_keys = [_word_key(w) for w in tail.split()]
    for n in range(min(len(tail_keys), len(words)), ECHO_MIN_WORDS - 1, -1):
        if keys[:n] == tail_keys[-n:]:
            return " ".join(words[n:]), n
    return text, 0


def _log_chunk_prompt(log: Callable[[str], None], chunk_path: Path, prompt: str | None) -> None:
    if prompt:
        log(f"Prompt for {chunk_path.name}:\n{prompt}")
    else:
        log(f"Prompt for {chunk_path.name}: (none)")


def _remove_echo(
    text: str, previous_tail: str | None, chunk_path: Path, log: Callable[[str], None]
) -> str:
    if not previous_tail:
        return text
    stripped, removed = strip_echoed_tail(text, previous_tail)
    if removed:
        log(f"{chunk_path.name}: removed {removed} word(s) at the start that repeated the previous chunk's excerpt.")
    return stripped


def _chunk_check_failure(text: str, chunk_path: Path, model: str) -> str | None:
    """Why a chunk's transcript looks wrong, or None if it passes."""
    if model == MODEL_GPT_TRANSCRIBE:
        if not text:
            return f"{chunk_path.name}: {model} returned no text"
        if _looks_repeated(text, get_duration_seconds(chunk_path)):
            return (
                f"{chunk_path.name}: {model} returned {len(text.split())} words, "
                "more than could be spoken in this chunk (likely repeated text)"
            )
    repeat = find_repeated_passage(text)
    if repeat:
        length, opening = repeat
        return (
            f'{chunk_path.name}: {model} repeated a passage of about {length} words, '
            f'starting "{opening}…" (check this part of the transcript)'
        )
    return None


def transcribe_chunk_checked(
    client: OpenAI,
    chunk_path: Path,
    *,
    model: str,
    languages: list[str] | None = None,
    context: str | None = None,
    keywords: list[str] | None = None,
    previous_tail: str | None = None,
    on_log: Callable[[str], None] | None = None,
    split_depth: int = 0,
) -> tuple[str, str | None]:
    """
    Transcribe one chunk and return (text, warning or None). Always uses the selected model.
    Every model's output is checked for a repeated passage; gpt-transcribe output is also checked for
    empty or implausibly long results. A failed check is retried with the same model, and if the last
    attempt still fails, its text is kept and a warning is returned.
    `context` and `previous_tail` form the prompt; retries after a failed check drop `previous_tail`
    so the carried-over excerpt can't cause the same failure twice. `keywords` go only to gpt-transcribe.
    A GPT-4o chunk that reaches the output cap is split and transcribed in pieces (see
    _transcribe_in_pieces); `split_depth` counts how many times this audio was already split.
    """
    log = on_log or (lambda _message: None)
    prompting = context is not None or previous_tail is not None
    prompt = build_chunk_prompt(context, previous_tail)
    if prompting:
        _log_chunk_prompt(log, chunk_path, prompt)

    attempts = 1 + GPT_TRANSCRIBE_RETRIES
    warning = None
    text = ""
    tail = previous_tail
    for attempt in range(1, attempts + 1):
        if attempt > 1 and tail:
            tail = None
            prompt = build_chunk_prompt(context, None)
            log(f"Retrying {chunk_path.name} without the previous chunk's excerpt.")
            _log_chunk_prompt(log, chunk_path, prompt)
        if model == MODEL_GPT_TRANSCRIBE:
            resp = create_transcription_with_retry(
                client,
                chunk_path,
                model=MODEL_GPT_TRANSCRIBE,
                response_format="json",
                languages=languages or DEFAULT_LANGUAGES,
                prompt=prompt,
                keywords=keywords,
                on_log=on_log,
            )
            raw_text = extract_transcription_text(resp).strip()
        else:
            raw_text, output_tokens = transcribe_chunk_text(
                client, chunk_path, model=model, languages=languages, prompt=prompt, on_log=on_log
            )
            if model in GPT4O_OUTPUT_LIMITED_MODELS and (output_tokens or 0) >= GPT4O_OUTPUT_TOKEN_LIMIT:
                return _transcribe_in_pieces(
                    client,
                    chunk_path,
                    capped_text=raw_text,
                    model=model,
                    languages=languages,
                    context=context,
                    on_log=on_log,
                    split_depth=split_depth,
                )
        text = _remove_echo(raw_text, tail, chunk_path, log)
        warning = _chunk_check_failure(text, chunk_path, model)
        if warning is None:
            return text, None
        log(f"{warning} (attempt {attempt}/{attempts}).")

    return text, f"{warning} after {attempts} attempts."


def _transcribe_in_pieces(
    client: OpenAI,
    chunk_path: Path,
    *,
    capped_text: str,
    model: str,
    languages: list[str] | None,
    context: str | None,
    on_log: Callable[[str], None] | None,
    split_depth: int,
) -> tuple[str, str | None]:
    """
    Re-transcribe a chunk whose transcript hit the GPT-4o output cap, as smaller pieces cut at pauses.
    Pieces are named after the chunk (part_002 -> part_002a, part_002b). If the chunk can't be split
    further, the capped text is kept with a warning that its end is missing.
    """
    log = on_log or (lambda _message: None)
    capped_warning = (
        f"{chunk_path.name}: {model} hit its {GPT4O_OUTPUT_TOKEN_LIMIT}-token output limit, "
        "so the end of this part is likely missing"
    )
    duration = get_duration_seconds(chunk_path)
    if split_depth >= MAX_OUTPUT_SPLIT_DEPTH or duration < 2 * MIN_OUTPUT_SPLIT_SECONDS:
        log(f"{capped_warning}.")
        return capped_text, capped_warning

    log(
        f"{chunk_path.name}: {model} stopped at its {GPT4O_OUTPUT_TOKEN_LIMIT}-token output limit "
        f"({len(capped_text.split())} words), so the end was cut off. Splitting it and transcribing the pieces..."
    )
    pieces_dir = chunk_path.parent / f"{chunk_path.stem}_pieces"
    pieces: list[Path] = []
    try:
        try:
            parts = split_audio_to_chunks(chunk_path, pieces_dir, math.ceil(duration / 2))
        except (Exception, SystemExit) as exc:
            log(f"{chunk_path.name}: couldn't split it ({exc}). {capped_warning}.")
            return capped_text, capped_warning
        for i, part in enumerate(parts):
            piece = part.with_name(f"{chunk_path.stem}{chr(ord('a') + i)}.m4a")
            part.rename(piece)
            pieces.append(piece)
        log(f"{chunk_path.name}: split into {len(pieces)} pieces.")

        texts: list[str] = []
        warnings: list[str] = []
        for piece in pieces:
            piece_text, piece_warning = transcribe_chunk_checked(
                client,
                piece,
                model=model,
                languages=languages,
                context=context,
                on_log=on_log,
                split_depth=split_depth + 1,
            )
            texts.append(piece_text)
            if piece_warning:
                warnings.append(piece_warning)
        return " ".join(t for t in texts if t), "; ".join(warnings) or None
    finally:
        # The renamed pieces only match cleanup_dir's part_*.m4a pattern when the chunk itself is a part_ file.
        if CLEANUP_CHUNKS:
            for piece in pieces:
                piece.unlink(missing_ok=True)
        cleanup_dir(pieces_dir)


def _output_tokens(resp: Any) -> int | None:
    """Output tokens the model generated, from the response's token usage (None if not reported)."""
    usage = resp.get("usage") if isinstance(resp, dict) else getattr(resp, "usage", None)
    value = usage.get("output_tokens") if isinstance(usage, dict) else getattr(usage, "output_tokens", None)
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def transcribe_chunk_text(
    client: OpenAI,
    chunk_path: Path,
    *,
    model: str = MODEL_NORMAL,
    languages: list[str] | None = None,
    prompt: str | None = None,
    on_log: Callable[[str], None] | None = None,
) -> tuple[str, int | None]:
    """Transcribe one chunk; returns (text, output tokens used). JSON, unlike plain text, reports token usage."""
    resp = create_transcription_with_retry(
        client,
        chunk_path,
        model=model,
        response_format="json",
        languages=languages,
        prompt=prompt,
        on_log=on_log,
    )
    return extract_transcription_text(resp).strip(), _output_tokens(resp)


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
    prompt: str | None = None,
    keywords: list[str] | None = None,
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
                extra_body = {}
                if model == MODEL_GPT_TRANSCRIBE:
                    # gpt-transcribe takes a `languages` list instead of `language`; the SDK doesn't expose it yet.
                    hint = languages or ([LANGUAGE] if LANGUAGE else None)
                    if hint:
                        extra_body["languages"] = hint
                elif language := single_language_hint(languages):
                    kwargs["language"] = language
                if keywords and model in KEYWORD_MODELS:
                    # Not exposed by the SDK yet either.
                    extra_body["keywords"] = keywords
                if extra_body:
                    kwargs["extra_body"] = extra_body
                if chunking_strategy is not None:
                    kwargs["chunking_strategy"] = chunking_strategy
                if prompt and model in PROMPT_MODELS:
                    kwargs["prompt"] = prompt

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
                        if "prompt" in kwargs and "prompt" in str(e).lower():
                            log(
                                f"The API rejected the prompt for {active_audio_path.name} "
                                f"({len(prompt or '')} characters). Try a shorter Context in Settings."
                            )
                        if "extra_body" in kwargs and "keyword" in str(e).lower():
                            log(
                                f"The API rejected the keywords for {active_audio_path.name} "
                                f"({len(keywords or [])} keywords). Try fewer or shorter keywords."
                            )
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
