#!/usr/bin/env python3
import argparse
import json
import os
import signal
import sys
import threading
import traceback
from pathlib import Path

from lecture_transcribe import (
    CHUNK_SECONDS_CHOICES,
    DEFAULT_LANGUAGES,
    DIARIZATION_MODELS,
    TRANSCRIPTION_MODELS,
    EMBED_SUBTITLE_CODECS,
    list_media_tracks,
    save_edited_tracks,
    parse_keywords,
    parse_language_codes,
    get_last_keychain_error,
    is_valid_api_key,
    list_audio_tracks,
    load_api_key_from_keyring,
    save_api_key_to_keyring,
)
from transcription_job import run_transcription_job

MODEL_GPT_TRANSCRIBE = "gpt-transcribe"
MODEL_GPT4O_TRANSCRIBE = "gpt-4o-transcribe"
SUPPORTED_TRANSCRIPTION_MODELS = list(TRANSCRIPTION_MODELS)


_EMIT_LOCK = threading.Lock()


def emit(kind: str, payload) -> None:
    # Chunk workers log from several threads; write each event as one locked line so they never interleave.
    line = json.dumps({"kind": kind, "payload": payload}, ensure_ascii=False) + "\n"
    with _EMIT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def resolve_api_key_status() -> str:
    env_key = os.getenv("OPENAI_API_KEY", "").strip()
    if is_valid_api_key(env_key):
        return "loaded from environment"

    saved = load_api_key_from_keyring()
    if is_valid_api_key(saved):
        os.environ["OPENAI_API_KEY"] = saved
        return "loaded from system keychain"

    return "required"


def command_key_status(args: argparse.Namespace) -> int:
    status = resolve_api_key_status()
    if getattr(args, "verify", False) and status != "required":
        # Only a definite rejection changes the status; being offline shouldn't flag a good key.
        if check_api_key_with_openai(os.environ.get("OPENAI_API_KEY", "")) == "rejected":
            status = API_KEY_STATUS_REJECTED
    print(json.dumps({"status": status}, ensure_ascii=False))
    return 0


API_KEY_STATUS_REJECTED = "rejected by OpenAI"
# Marks a run error caused by a missing or rejected key, so the app can ask for a new one.
ERROR_KIND_API_KEY = "api_key"


def check_api_key_with_openai(key: str) -> str:
    """Asks OpenAI whether a key works. Returns "ok", "rejected", or "unreachable"."""
    try:
        import openai
    except ImportError:
        return "unreachable"

    try:
        # Listing models is free and only needs a working key.
        openai.OpenAI(api_key=key, timeout=15.0, max_retries=1).models.list()
    except openai.AuthenticationError:
        return "rejected"
    except (openai.APIConnectionError, openai.APITimeoutError):
        return "unreachable"
    except openai.APIStatusError:
        # Rate limits or server errors mean OpenAI accepted the key itself.
        return "ok"
    return "ok"


def command_set_key(args: argparse.Namespace) -> int:
    # Prefer stdin so the key is never exposed in the process argument list.
    raw_key = args.key if args.key is not None else sys.stdin.readline()
    key = str(raw_key or "").strip()
    save = bool(args.save)
    if not is_valid_api_key(key):
        print(json.dumps({"error": "Invalid API key format. It should start with 'sk-'."}, ensure_ascii=False))
        return 2

    if not args.skip_check:
        check = check_api_key_with_openai(key)
        if check == "rejected":
            print(json.dumps({"error": "OpenAI didn't accept this key. Copy it again from platform.openai.com/api-keys."}, ensure_ascii=False))
            return 2
        if check == "unreachable":
            print(json.dumps({"error": "Couldn't reach OpenAI to check this key. Check your internet connection, then try again."}, ensure_ascii=False))
            return 2

    os.environ["OPENAI_API_KEY"] = key
    if not save:
        print(json.dumps({"status": "set for this session only"}, ensure_ascii=False))
        return 0

    if save_api_key_to_keyring(key):
        print(json.dumps({"status": "saved to system keychain"}, ensure_ascii=False))
        return 0

    detail = get_last_keychain_error()
    if detail:
        print(json.dumps({"error": f"Could not save key: {detail}"}, ensure_ascii=False))
    else:
        print(json.dumps({"error": "Could not save key to system keychain."}, ensure_ascii=False))
    return 2


def command_audio_tracks(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser()
    if not input_path.exists():
        print(json.dumps({"error": f"Input file not found: {input_path}"}, ensure_ascii=False))
        return 2
    print(json.dumps({"tracks": list_audio_tracks(input_path)}, ensure_ascii=False))
    return 0


def command_tracks(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser()
    if not input_path.exists():
        print(json.dumps({"error": f"Input file not found: {input_path}"}, ensure_ascii=False))
        return 2
    try:
        tracks = list_media_tracks(input_path)
    except SystemExit as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        return 2
    editable = input_path.suffix.lower() in EMBED_SUBTITLE_CODECS
    print(json.dumps({"tracks": tracks, "editable": editable}, ensure_ascii=False))
    return 0


def command_save_tracks(args: argparse.Namespace) -> int:
    # Cancelled like a run (see command_run), so the partial copy is removed.
    signal.signal(signal.SIGINT, _raise_keyboard_interrupt)
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    input_path = Path(args.input).expanduser()
    out_path = Path(args.output_file).expanduser()
    try:
        plan = json.loads(args.plan)
        if not isinstance(plan, list):
            raise ValueError("expected a list")
    except ValueError as exc:
        emit("error", f"Invalid track list: {exc}")
        return 2
    if not input_path.exists():
        emit("error", f"Input file not found: {input_path}")
        return 2

    emit("status", "Saving...")
    reported = -1

    def report(fraction: float) -> None:
        nonlocal reported
        percent = int(fraction * 100)
        if percent > reported:
            reported = percent
            emit("progress", float(percent))

    try:
        save_edited_tracks(input_path, out_path, plan, on_progress=report, replace_original=bool(args.replace_original))
    except KeyboardInterrupt:
        return 130
    except SystemExit as exc:
        emit("error", str(exc))
        return 1
    except Exception as exc:
        emit("log", traceback.format_exc().rstrip())
        emit("error", describe_run_error(exc))
        return 1
    emit("done", str(out_path.resolve()))
    return 0


def _raise_keyboard_interrupt(_signum, _frame) -> None:
    raise KeyboardInterrupt


def command_run(args: argparse.Namespace) -> int:
    # The app cancels with SIGINT then SIGTERM; route both through KeyboardInterrupt so
    # cleanup (temp chunks) runs instead of the process dying mid-write. SIGINT is set
    # explicitly because Python skips its default handler when the parent ignores SIGINT.
    signal.signal(signal.SIGINT, _raise_keyboard_interrupt)
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    input_path = Path(args.input).expanduser()
    output_dir = Path(args.output).expanduser()
    diarize = bool(args.diarize)
    subtitles = bool(args.subtitles)
    model = str(args.model or MODEL_GPT4O_TRANSCRIBE).strip()

    if not input_path.exists():
        emit("error", f"Input file not found: {input_path}")
        return 2

    # Subtitles always run on the diarize model and drop speaker labels, so the selected model doesn't matter.
    if diarize and not subtitles and model not in DIARIZATION_MODELS:
        emit(
            "error",
            "Speaker diarization is not supported with gpt-4o-mini-transcribe. "
            "Select gpt-transcribe or gpt-4o-transcribe, or disable diarization.",
        )
        return 2

    try:
        languages = parse_language_codes(args.languages or "")
    except ValueError as exc:
        emit("error", f"Invalid spoken languages: {exc}")
        return 2

    try:
        keywords = parse_keywords(args.keywords or "")
    except ValueError as exc:
        emit("error", f"Invalid keywords: {exc}")
        return 2

    if resolve_api_key_status() == "required":
        emit("error_kind", ERROR_KIND_API_KEY)
        emit("error", "Add your OpenAI API key to start transcribing.")
        return 2

    def push_event(kind: str, payload) -> None:
        emit(kind, payload)

    try:
        out_path = run_transcription_job(
            input_path=input_path,
            diarize=diarize,
            output_dir=output_dir,
            transcription_model=model,
            push_event=push_event,
            languages=languages,
            context=args.context,
            carry_context=bool(args.carry_context),
            chunk_seconds=args.chunk_seconds,
            keywords=keywords,
            subtitles=subtitles,
            audio_track=args.audio_track,
            embed_subtitles=bool(args.embed_subtitles),
        )
        emit("done", str(out_path.resolve()))
        return 0
    except KeyboardInterrupt:
        return 130
    except SystemExit as exc:
        emit("error", str(exc))
        return 1
    except Exception as exc:
        # The traceback goes to the run log; the alert gets a short message people can act on.
        emit("log", traceback.format_exc().rstrip())
        if _is_api_key_error(exc):
            emit("error_kind", ERROR_KIND_API_KEY)
        emit("error", describe_run_error(exc))
        return 1


def describe_run_error(exc: BaseException) -> str:
    """Turns an exception into a short message for the error alert and run history."""
    try:
        import openai
    except ImportError:  # pragma: no cover - openai is a hard dependency of the run path
        openai = None

    if openai is not None:
        if isinstance(exc, openai.AuthenticationError):
            return "OpenAI rejected your API key. Set a valid key in Settings, then try again."
        if isinstance(exc, openai.PermissionDeniedError):
            return "Your OpenAI API key doesn't have access to this model. Check your OpenAI project settings."
        if isinstance(exc, openai.RateLimitError):
            if _openai_error_code(exc) == "insufficient_quota":
                return "Your OpenAI account is out of credits. Add billing at platform.openai.com, then try again."
            return "OpenAI is rate limiting requests right now. Wait a minute, then try again."
        if isinstance(exc, (openai.APIConnectionError, openai.APITimeoutError)):
            return "Couldn't reach OpenAI. Check your internet connection, then try again."
        if isinstance(exc, openai.APIStatusError):
            detail = _openai_error_message(exc)
            return f"OpenAI returned an error ({exc.status_code}): {detail}" if detail else f"OpenAI returned an error ({exc.status_code})."

    message = str(exc).strip() or type(exc).__name__
    return message


def _is_api_key_error(exc: BaseException) -> bool:
    try:
        import openai
    except ImportError:
        return False
    return isinstance(exc, openai.AuthenticationError)


def _openai_error_body(exc: BaseException) -> dict:
    body = getattr(exc, "body", None)
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        return body["error"]
    return body if isinstance(body, dict) else {}


def _openai_error_code(exc: BaseException) -> str:
    return str(getattr(exc, "code", None) or _openai_error_body(exc).get("code") or "")


def _openai_error_message(exc: BaseException) -> str:
    message = _openai_error_body(exc).get("message")
    return str(message).strip() if message else ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge backend for Lecture Transcribe native macOS UI.")
    sub = parser.add_subparsers(dest="command", required=True)

    key_status = sub.add_parser("key-status", help="Get API key availability status.")
    key_status.add_argument("--verify", action="store_true", help="Also check the key with OpenAI.")

    set_key = sub.add_parser("set-key", help="Set and optionally save an OpenAI API key.")
    set_key.add_argument("--key", help="API key value. Omit to read the key from stdin.")
    set_key.add_argument("--save", action="store_true", help="Persist to system keychain.")
    set_key.add_argument("--skip-check", action="store_true", help="Don't check the key with OpenAI first.")

    audio_tracks = sub.add_parser("audio-tracks", help="List a file's audio tracks as JSON.")
    audio_tracks.add_argument("--input", required=True, help="Input media file path.")

    tracks = sub.add_parser("tracks", help="List every track in a video as JSON.")
    tracks.add_argument("--input", required=True, help="Video file path.")

    save_tracks = sub.add_parser("save-tracks", help="Save a video with an edited list of tracks.")
    save_tracks.add_argument("--input", required=True, help="Video file path.")
    save_tracks.add_argument(
        "--output-file", required=True, help="Where to save (same format as the video; the video itself with --replace-original)."
    )
    save_tracks.add_argument(
        "--replace-original",
        action="store_true",
        help="Save into the video itself (--output-file must be --input). It's replaced only once the new file is complete.",
    )
    save_tracks.add_argument(
        "--plan",
        required=True,
        help=(
            'JSON list of the audio and subtitle tracks to keep, in order: {"kind", "index" or "file", '
            '"language", "title", "default", "forced"}.'
        ),
    )

    run = sub.add_parser("run", help="Run a transcription job.")
    run.add_argument("--input", required=True, help="Input media file path.")
    run.add_argument("--output", required=True, help="Output directory path.")
    run.add_argument("--diarize", action="store_true", help="Enable speaker diarization.")
    run.add_argument(
        "--audio-track",
        type=int,
        default=0,
        help="Which audio track to transcribe, counting audio tracks only from 0 (default: the first).",
    )
    run.add_argument(
        "--subtitles",
        action="store_true",
        help="Write timed subtitles (.srt) instead of a transcript. Always uses the diarize model; overrides --diarize.",
    )
    run.add_argument(
        "--embed-subtitles",
        action="store_true",
        help=(
            "With --subtitles, also save a copy of the video (.mp4, .m4v, .mov or .mkv, kept in the same format) "
            "with the subtitles built in and shown by default, for players like QuickTime that can't load an .srt file."
        ),
    )
    run.add_argument(
        "--model",
        default=MODEL_GPT4O_TRANSCRIBE,
        choices=SUPPORTED_TRANSCRIPTION_MODELS,
        help="Transcription model for non-diarized chunks.",
    )
    run.add_argument(
        "--languages",
        default="",
        help=(
            "Comma-separated spoken language codes (e.g. en,es). gpt-transcribe uses all of them "
            f"(default {','.join(DEFAULT_LANGUAGES)}); other models use a single code or auto-detect."
        ),
    )
    run.add_argument(
        "--context",
        default="",
        help="Description of the recording sent as the prompt with every chunk (not used with --diarize).",
    )
    run.add_argument(
        "--keywords",
        default="",
        help=(
            f"Names and terms the recording uses, separated by commas or new lines. Sent with every chunk; "
            f"only {MODEL_GPT_TRANSCRIBE} uses them (not used with --diarize)."
        ),
    )
    run.add_argument(
        "--carry-context",
        action="store_true",
        help="Transcribe chunks in order and add the end of each chunk's transcript to the next chunk's prompt.",
    )

    run.add_argument(
        "--chunk-seconds",
        type=int,
        default=None,
        choices=CHUNK_SECONDS_CHOICES,
        help="Length of each chunk sent to the API, cut at the nearest pause (default 300; not used with --diarize).",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "key-status":
        return command_key_status(args)
    if args.command == "set-key":
        return command_set_key(args)
    if args.command == "audio-tracks":
        return command_audio_tracks(args)
    if args.command == "tracks":
        return command_tracks(args)
    if args.command == "save-tracks":
        return command_save_tracks(args)
    if args.command == "run":
        code = command_run(args)
        # In-flight chunk requests run on worker threads that a normal exit would wait on;
        # leave immediately once the result (or cancellation) has been reported.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
