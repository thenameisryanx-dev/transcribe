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
    get_last_keychain_error,
    is_valid_api_key,
    load_api_key_from_keyring,
    save_api_key_to_keyring,
)
from transcription_job import run_transcription_job

MODEL_GPT4O_TRANSCRIBE = "gpt-4o-transcribe"
MODEL_GPT4O_MINI_TRANSCRIBE = "gpt-4o-mini-transcribe"
SUPPORTED_TRANSCRIPTION_MODELS = [MODEL_GPT4O_TRANSCRIBE, MODEL_GPT4O_MINI_TRANSCRIBE]


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


def command_key_status(_args: argparse.Namespace) -> int:
    status = resolve_api_key_status()
    print(json.dumps({"status": status}, ensure_ascii=False))
    return 0


def command_set_key(args: argparse.Namespace) -> int:
    # Prefer stdin so the key is never exposed in the process argument list.
    raw_key = args.key if args.key is not None else sys.stdin.readline()
    key = str(raw_key or "").strip()
    save = bool(args.save)
    if not is_valid_api_key(key):
        print(json.dumps({"error": "Invalid API key format. It should start with 'sk-'."}, ensure_ascii=False))
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
    model = str(args.model or MODEL_GPT4O_TRANSCRIBE).strip()

    if not input_path.exists():
        emit("error", f"Input file not found: {input_path}")
        return 2

    if diarize and model == MODEL_GPT4O_MINI_TRANSCRIBE:
        emit(
            "error",
            "Speaker diarization is not supported with gpt-4o-mini-transcribe. "
            "Select gpt-4o-transcribe or disable diarization.",
        )
        return 2

    if resolve_api_key_status() == "required":
        emit("error", "API key is required. Set a valid key before running transcription.")
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
        )
        emit("done", str(out_path.resolve()))
        return 0
    except KeyboardInterrupt:
        return 130
    except SystemExit as exc:
        emit("error", str(exc))
        return 1
    except Exception as exc:
        emit("error", f"{exc}\n\n{traceback.format_exc()}")
        return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge backend for Lecture Transcribe native macOS UI.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("key-status", help="Get API key availability status.")

    set_key = sub.add_parser("set-key", help="Set and optionally save an OpenAI API key.")
    set_key.add_argument("--key", help="API key value. Omit to read the key from stdin.")
    set_key.add_argument("--save", action="store_true", help="Persist to system keychain.")

    run = sub.add_parser("run", help="Run a transcription job.")
    run.add_argument("--input", required=True, help="Input media file path.")
    run.add_argument("--output", required=True, help="Output directory path.")
    run.add_argument("--diarize", action="store_true", help="Enable speaker diarization.")
    run.add_argument(
        "--model",
        default=MODEL_GPT4O_TRANSCRIBE,
        choices=SUPPORTED_TRANSCRIPTION_MODELS,
        help="Transcription model for non-diarized chunks.",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "key-status":
        return command_key_status(args)
    if args.command == "set-key":
        return command_set_key(args)
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
